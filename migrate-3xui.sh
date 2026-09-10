#!/usr/bin/env bash
# Standard 3x-ui + SQLite + nginx migration, Debian/Ubuntu, Bash >= 4.
set +x
set -Eeuo pipefail
umask 077

PATHS=(etc/x-ui usr/local/x-ui usr/bin/x-ui
  etc/systemd/system/x-ui.service etc/systemd/system/x-ui.service.d
  etc/default/x-ui etc/nginx etc/letsencrypt root/cert var/www)
SERVICES=(x-ui nginx)
die() { echo "Ошибка: $*" >&2; exit 1; }
log() { echo "$*" >&2; }
present() { [[ -e /$1 || -L /$1 ]]; }
pack() {
  local output=$1 p
  local -a found=()
  for p in "${PATHS[@]}"; do present "$p" && found+=("$p"); done
  if ((${#found[@]})); then
    tar --acls --xattrs --numeric-owner -czpf "$output" -C / -- "${found[@]}"
  else
    tar -czpf "$output" --files-from /dev/null
  fi
}
unpack() { tar --acls --xattrs --numeric-owner -xzpf "$1" -C /; }
remove_paths() {
  local p
  for p in "${PATHS[@]}"; do rm -rf -- "/$p" || return 1; done
}
check_parents() {
  local p parent
  for p in "${PATHS[@]}"; do
    parent=$(dirname "/$p")
    while [[ $parent != / ]]; do
      [[ ! -L $parent ]] || die "Родитель каталога является symlink: $parent"
      parent=$(dirname "$parent")
    done
  done
}
service_state() {
  local s=$1 state
  state=$(systemctl is-enabled "$s" 2>/dev/null) || :
  case $state in enabled|disabled|not-found) ;; '') state=not-found;;
    *) die "Неподдерживаемое состояние $s: $state";; esac
  printf '%s\n' "$state"
}
facts() {
  [[ $EUID == 0 ]] || die 'Требуется SSH-доступ root'
  [[ -d /run/systemd/system ]] || die 'Требуется systemd'
  . /etc/os-release
  [[ $ID == debian || $ID == ubuntu ]] || die 'Поддерживаются Debian/Ubuntu'
  printf 'os=%s:%s\narch=%s\nmachine=%s\n' "$ID" "$VERSION_ID" "$(uname -m)" "$(cat /etc/machine-id)"
}
install_common() {
  local c missing=no
  for c in tar flock realpath sha256sum awk; do
    if ! command -v "$c" >/dev/null; then missing=yes; fi
  done
  if [[ $missing == yes ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=120 update >&2
    apt-get -o DPkg::Lock::Timeout=120 install -y tar util-linux coreutils gawk >&2
  fi
}
install_target() {
  local package
  facts >/dev/null
  for package in "$@"; do
    [[ $package =~ ^(nginx([-a-z0-9]*)?|libnginx-mod-[-a-z0-9]+|certbot|python3-certbot[-a-z0-9]*)(:[a-z0-9]+)?$ ]] || die "Недопустимое имя пакета: $package"
  done
  export DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1
  apt-get -o DPkg::Lock::Timeout=120 update >&2
  apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold install -y \
    tar util-linux coreutils gawk ca-certificates "$@" >&2
  command -v nginx >/dev/null || die 'Пакеты источника не установили nginx'
}
nginx_packages() {
  dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' | \
    awk '$2 == "installed" && $1 ~ /^(nginx($|[-:])|libnginx-mod-|certbot($|:)|python3-certbot)/ {print $1}'
}
preflight() {
  local role=$1 c p unit envtext package
  [[ $EUID == 0 ]] || die 'Требуется SSH-доступ root'
  for c in tar systemctl nginx dpkg-query sha256sum awk flock realpath; do
    command -v "$c" >/dev/null || die "Не найден $c. Установите зависимости (включая nginx)."
  done
  [[ -d /run/systemd/system ]] || die 'Требуется systemd'
  # OS-owned file, never read from the transferred archive.
  . /etc/os-release
  [[ $ID == debian || $ID == ubuntu ]] || die 'Поддерживаются Debian/Ubuntu'
  check_parents
  nginx -t >&2
  if [[ $role == source ]]; then
    for p in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui /etc/systemd/system/x-ui.service; do
      [[ -f $p && ! -L $p ]] || die "Нет стандартного файла: $p"
    done
    [[ ! -L /etc/x-ui && ! -L /usr/local/x-ui && ! -L /etc/nginx ]] || die 'Основные каталоги не должны быть symlink'
    unit=$(systemctl show x-ui -p FragmentPath --value)
    [[ $unit == /etc/systemd/system/x-ui.service ]] || die 'Нестандартное расположение unit x-ui'
    envtext=$(systemctl cat x-ui; systemctl show x-ui -p Environment --value
      for p in /etc/default/x-ui /usr/local/x-ui/.env; do [[ ! -f $p ]] || cat "$p"; done)
    if grep -Eq 'XUI_DB_(TYPE|DSN|FOLDER)' <<<"$envtext"; then
      die 'Обнаружены настройки БД через окружение: требуется отдельная проверка, эта версия переносит стандартную SQLite'
    fi
    # External EnvironmentFile may contain a database path or secrets outside the transfer set.
    if grep -E '^[[:space:]]*EnvironmentFile=' <<<"$envtext" | grep -Ev '^EnvironmentFile=-?/etc/default/x-ui[[:space:]]*$' >/dev/null; then
      die 'Нестандартный EnvironmentFile в unit x-ui'
    fi
    systemctl is-active --quiet x-ui || die 'Исходная служба x-ui должна работать'
  else
    for c in "${SERVICES[@]}"; do service_state "$c" >/dev/null; done
  fi
  printf 'os=%s:%s\narch=%s\nmachine=%s\n' "$ID" "$VERSION_ID" "$(uname -m)" "$(cat /etc/machine-id)"
  printf 'nginx=%s\n' "$(nginx -v 2>&1)"
  # Numeric ownership in the archive must agree on both machines.
  printf 'www=%s\n' "$(getent passwd www-data | cut -d: -f3,4)"
  printf 'free=%s\n' "$(df -PB1 /var/tmp | awk 'NR==2 {print $4}')"
  for p in "${PATHS[@]}"; do present "$p" && printf 'path=/%s\n' "$p"; done
  return 0
}
source_snapshot() {
  local d
  d=$(mktemp -d /var/tmp/3xui-source-XXXXXXXX)
  # EXIT restores service even if tar or systemctl stop fails.
  trap 'rc=$?; trap - EXIT; if ! systemctl start x-ui; then log "КРИТИЧНО: запустите x-ui на источнике вручную"; rc=1; fi; if ((rc)); then rm -rf -- "$d"; fi; exit "$rc"' EXIT
  systemctl stop x-ui
  pack "$d/payload.tar.gz"
  systemctl start x-ui
  trap - EXIT
  printf 'directory=%s\nsha256=%s\nsize=%s\n' "$d" "$(sha256sum "$d/payload.tar.gz" | awk '{print $1}')" "$(stat -c %s "$d/payload.tar.gz")"
}
validate_backup_dir() {
  [[ $1 =~ ^/var/tmp/3xui-target-[a-zA-Z0-9]+$ && -d $1 && ! -L $1 ]] || die 'Недопустимый каталог backup'
}
restore_target() {
  local d=$1 s enabled was_active failed=0
  validate_backup_dir "$d"
  [[ -f $d/READY ]] || { log 'Нет завершённой резервной копии'; return 1; }
  check_parents || return 1
  for s in "${SERVICES[@]}"; do
    systemctl stop "$s" 2>/dev/null || ! systemctl is-active --quiet "$s" || return 1
  done
  remove_paths || return 1
  unpack "$d/before.tar.gz" || return 1
  systemctl daemon-reload || return 1
  for s in "${SERVICES[@]}"; do
    read -r enabled was_active < "$d/$s.state"
    case $enabled in
      enabled) systemctl enable "$s" || failed=1;;
      disabled) systemctl disable "$s" || failed=1;;
      not-found) systemctl disable "$s" 2>/dev/null || :;;
    esac
    if [[ $was_active == yes ]]; then systemctl start "$s" || failed=1; fi
  done
  ((failed == 0))
}
target_apply() {
  local d=$1 sha=$2 s enabled was_active rc
  validate_backup_dir "$d"
  [[ $sha =~ ^[a-f0-9]{64}$ ]] || die 'Недопустимая контрольная сумма'
  [[ $(sha256sum "$d/payload.tar.gz" | awk '{print $1}') == "$sha" ]] || die 'SHA256 архива не совпадает'
  [[ ! -e $d/READY ]] || die 'Этот backup уже использован'
  preflight target >/dev/null
  # Snapshot current states immediately before stopping the destination services.
  for s in "${SERVICES[@]}"; do
    enabled=$(service_state "$s")
    was_active=no; if systemctl is-active --quiet "$s"; then was_active=yes; fi
    printf '%s %s\n' "$enabled" "$was_active" > "$d/$s.state"
  done
  trap 'rc=$?; trap - EXIT; if ((rc)); then if [[ -f $d/READY ]]; then log "Сбой переноса; выполняется откат"; restore_target "$d" || log "КРИТИЧНО: автоматический откат не завершён: $d"; else for s in "${SERVICES[@]}"; do read -r enabled was_active < "$d/$s.state"; if [[ $was_active == yes ]]; then systemctl start "$s" || :; fi; done; fi; fi; exit "$rc"' EXIT
  for s in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$s"; then systemctl stop "$s"; fi
  done
  pack "$d/before.tar.gz"
  touch "$d/READY"
  remove_paths
  unpack "$d/payload.tar.gz"
  systemctl daemon-reload
  nginx -t
  systemctl enable x-ui nginx
  systemctl start x-ui nginx
  sleep 5
  systemctl is-active --quiet x-ui
  systemctl is-active --quiet nginx
  touch "$d/SUCCESS"
  trap - EXIT
  log "Перенос завершён. Backup цели: $d"
}
worker() {
  local action=$1; shift
  [[ $EUID == 0 ]] || die 'Требуется root'
  case $action in
    info) preflight "$1"; return;;
    facts) facts; return;;
    packages) nginx_packages; return;;
    install-common) facts >/dev/null; install_common; return;;
    install-target) install_target "$@"; return;;
  esac
  # Prevent overlapping writes made by this script on either server.
  exec 9>/run/lock/migrate-3xui.lock
  flock -n 9 || die 'Другая миграция уже выполняется'
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  case $action in
    snapshot) preflight source >/dev/null; source_snapshot;;
    prepare) mktemp -d /var/tmp/3xui-target-XXXXXXXX;;
    apply) target_apply "$1" "$2";;
    rollback) restore_target "$1";;
    cleanup)
      [[ $1 =~ ^/var/tmp/3xui-source-[a-zA-Z0-9]+$ && ! -L $1 ]] || die 'Недопустимый путь'
      rm -rf -- "$1";;
    *) die "Неизвестная операция: $action";;
  esac
}
usage() {
  cat <<'EOF'
Использование: bash migrate-3xui.sh SOURCE_IP TARGET_IP [опции]
  --check                Только проверки, без установки и переноса
  --apply                Явно выбрать перенос (это режим по умолчанию)
  --source-port PORT     SSH-порт источника (22)
  --target-port PORT     SSH-порт цели (22)
Требуется SSH root по паролю и заранее проверенные записи known_hosts.
Пароли: SOURCE_SSH_PASSWORD и TARGET_SSH_PASSWORD в окружении или скрытый ввод.
Поддерживаются IPv4; одинаковые Debian/Ubuntu и архитектура, обычный x-ui + SQLite.
На цели автоматически устанавливаются nginx, его модули и Certbot по списку пакетов источника.
EOF
}
valid_ip() {
  local ip=$1 octet
  local -a octets
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    [[ $octet == 0 || $octet != 0* ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}
field() { sed -n "s/^$2=//p" <<< "$1"; }
remote() {
  local host=$1 port=$2 command; shift 2
  printf -v command '%q ' bash -s -- --worker "$@"
  local password=$TARGET_SSH_PASSWORD
  [[ $host != "$SOURCE_HOST" ]] || password=$SOURCE_SSH_PASSWORD
  sshpass -d 8 ssh "${SSH_OPTS[@]}" -p "$port" "root@$host" "$command" 8<<< "$password" < "$SELF"
}
copy() {
  local port=$1 host=$2 password=$TARGET_SSH_PASSWORD; shift 2
  [[ $host != "$SOURCE_HOST" ]] || password=$SOURCE_SSH_PASSWORD
  sshpass -d 8 scp "${SSH_OPTS[@]}" -P "$port" -- "$@" 8<<< "$password"
}
main() {
  [[ ${1:-} != --help && ${1:-} != -h ]] || { usage; return; }
  (($# >= 2)) || { usage; exit 2; }
  local src=$1 dst=$2 sport=22 dport=22 apply=yes srcinfo dstinfo snap sha size free dest packages name
  local -a pkglist=()
  shift 2
  while (($#)); do
    case $1 in
      --apply) apply=yes; shift;;
      --check) apply=no; shift;;
      --source-port|--target-port)
        (($# >= 2)) || die "Нет значения для $1"
        case $1 in --source-port) sport=$2;; --target-port) dport=$2;; esac
        shift 2;;
      *) die "Неизвестный аргумент: $1";;
    esac
  done
  valid_ip "$src" && valid_ip "$dst" || die 'Укажите два корректных IPv4-адреса'
  [[ $src != "$dst" ]] || die 'Источник и цель совпадают'
  for port in "$sport" "$dport"; do
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || die 'Неверный SSH-порт'
  done
  for c in ssh scp realpath; do command -v "$c" >/dev/null || die "Не найден $c"; done
  export -n SOURCE_SSH_PASSWORD TARGET_SSH_PASSWORD
  for name in SOURCE_SSH_PASSWORD TARGET_SSH_PASSWORD; do
    if [[ -z ${!name:-} ]]; then
      [[ -t 0 ]] || die "Не задан $name"
      IFS= read -r -s -p "$name (пароль root): " "$name" || die 'Ввод прерван'
      log ''
    fi
    [[ -n ${!name} && ${!name} != *$'\n'* && ${!name} != *$'\r'* ]] || die "Некорректный $name"
  done
  if ! command -v sshpass >/dev/null; then
    local -a installer=()
    command -v apt-get >/dev/null || die 'Установите sshpass'
    if ((EUID != 0)); then
      command -v sudo >/dev/null && sudo -n true || die 'Для установки sshpass нужен root или sudo без пароля'
      installer=(sudo -n)
    fi
    "${installer[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update >&2
    "${installer[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y sshpass >&2
  fi
  SOURCE_HOST=$src
  SELF=$(realpath "${BASH_SOURCE[0]}")
  SSH_OPTS=(-o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=yes -o ConnectTimeout=15
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
  log 'Проверка источника и цели...'
  srcinfo=$(remote "$src" "$sport" facts)
  dstinfo=$(remote "$dst" "$dport" facts)
  [[ $(field "$srcinfo" machine) != "$(field "$dstinfo" machine)" ]] || die 'Совпадает machine-id серверов'
  for f in os arch; do
    [[ $(field "$srcinfo" "$f") == "$(field "$dstinfo" "$f")" ]] || die "Не совпадает $f серверов"
  done
  if [[ $apply == yes ]]; then remote "$src" "$sport" install-common; fi
  srcinfo=$(remote "$src" "$sport" info source)
  packages=$(remote "$src" "$sport" packages)
  [[ -n $packages ]] || die 'nginx источника установлен вне APT: автоматическая установка не поддерживается'
  mapfile -t pkglist <<< "$packages"
  log "Пакеты для установки на цели: ${pkglist[*]}"
  if [[ $apply == no ]]; then
    log 'Базовые проверки ОС/архитектуры и исходной установки пройдены. Цель пока не изменена.'
    log 'После установки пакетов будут дополнительно проверены nginx, UID/GID и службы цели.'
    log 'Для автоматической установки и переноса запустите без --check.'
    return
  fi
  log 'Автоматическая установка nginx, модулей и зависимостей на цели...'
  remote "$dst" "$dport" install-target "${pkglist[@]}"
  dstinfo=$(remote "$dst" "$dport" info target)
  [[ $(field "$srcinfo" machine) != "$(field "$dstinfo" machine)" ]] || die 'Совпадает machine-id серверов'
  for f in os arch www; do
    [[ $(field "$srcinfo" "$f") == "$(field "$dstinfo" "$f")" ]] || die "Не совпадает $f серверов"
  done
  log "Источник: $(field "$srcinfo" os), $(field "$srcinfo" nginx)"
  log "Цель: $(field "$dstinfo" os), $(field "$dstinfo" nginx)"
  log 'Будут заменены целиком следующие пути цели (включая отсутствующие на источнике):'
  printf '  /%s\n' "${PATHS[@]}" >&2
  WORK=$(mktemp -d); SOURCE_BACKUP=''
  # Global values for the EXIT trap; locals disappear after main returns.
  CLEAN_SRC=$src CLEAN_PORT=$sport
  trap 'rc=$?; trap - EXIT; if [[ -n $SOURCE_BACKUP ]]; then remote "$CLEAN_SRC" "$CLEAN_PORT" cleanup "$SOURCE_BACKUP" || log "Временный архив остался на источнике: $SOURCE_BACKUP"; fi; rm -rf -- "$WORK"; exit "$rc"' EXIT
  log 'Создание согласованной копии; исходный x-ui временно остановится.'
  snap=$(remote "$src" "$sport" snapshot)
  SOURCE_BACKUP=$(field "$snap" directory)
  sha=$(field "$snap" sha256); size=$(field "$snap" size)
  [[ $SOURCE_BACKUP =~ ^/var/tmp/3xui-source-[a-zA-Z0-9]+$ && $sha =~ ^[a-f0-9]{64}$ && $size =~ ^[0-9]+$ ]] || die 'Некорректный ответ источника'
  free=$(field "$dstinfo" free)
  ((free > size * 3)) || die 'Недостаточно места в /var/tmp цели'
  copy "$sport" "$src" "root@$src:$SOURCE_BACKUP/payload.tar.gz" "$WORK/payload.tar.gz"
  dest=$(remote "$dst" "$dport" prepare)
  [[ $dest =~ ^/var/tmp/3xui-target-[a-zA-Z0-9]+$ ]] || die 'Некорректный ответ цели'
  copy "$dport" "$dst" "$SELF" "root@$dst:$dest/migrate-3xui.sh"
  log "Ручной откат на целевом сервере: bash $dest/migrate-3xui.sh --worker rollback $dest"
  copy "$dport" "$dst" "$WORK/payload.tar.gz" "root@$dst:$dest/payload.tar.gz"
  remote "$dst" "$dport" apply "$dest" "$sha"
  log 'Службы работают. Проверьте панель и клиентов, затем переключите DNS/IP. Источник остаётся включённым.'
}
if [[ ${1:-} == --worker ]]; then shift; worker "$@"; else main "$@"; fi
