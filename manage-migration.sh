#!/usr/bin/env bash
# Interactive coordinator; .env is parsed as data, never sourced.
set +x
set -Eeuo pipefail
umask 077
unset REGRU_USERNAME REGRU_PASSWORD SOURCE_SSH_PASSWORD TARGET_SSH_PASSWORD
declare -A CFG=()
declare -A LEGACY=([MIGRATE_IPV6]=no [SOURCE_IPV6]= [TARGET_IPV6]=)
KEYS=(SOURCE_IP TARGET_IP SOURCE_PORT TARGET_PORT SOURCE_SSH_PASSWORD TARGET_SSH_PASSWORD DOMAIN DNS_RECORD
  DNS_OLD_IPV4 DNS_NEW_IPV4 REGRU_USERNAME REGRU_PASSWORD)
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'EOF'
bash manage-migration.sh [опции]
  --env FILE          Файл настроек (по умолчанию .env рядом со скриптом)
  --configure         Повторно запросить все настройки
  --configure-only    Запросить и сохранить настройки, без запуска
  --non-interactive   Взять все настройки из .env, не задавать вопросов
  --check             Проверки без миграции и смены DNS
После успешной миграции следующий запуск продолжает смену DNS, не копирует базу повторно.
EOF
}
load_env() {
  local line key value found allowed
  [[ ! -L $ENV_FILE ]] || die '.env не должен быть symlink'
  [[ -e $ENV_FILE ]] || return 0
  [[ -f $ENV_FILE && -O $ENV_FILE ]] || die '.env должен быть обычным файлом текущего пользователя'
  chmod 600 "$ENV_FILE"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -n $line && $line != \#* ]] || continue
    [[ $line == *=* ]] || die 'Неверная строка .env: требуется KEY=value'
    key=${line%%=*}; value=${line#*=}; found=no
    case $key in MIGRATE_IPV6|SOURCE_IPV6|TARGET_IPV6) LEGACY[$key]=$value; continue;; esac
    [[ $key != SSH_IDENTITY ]] || continue # Ignore obsolete key setting from previous versions.
    for allowed in "${KEYS[@]}"; do [[ $key != "$allowed" ]] || found=yes; done
    [[ $found == yes ]] || die 'В .env есть неизвестное имя настройки'
    [[ ! -v CFG[$key] ]] || die "Повторяющаяся настройка $key"
    CFG[$key]=$value
  done < "$ENV_FILE"
}
ask() {
  local key=$1 label=$2 default=${3:-} secret=${4:-no} value current
  if [[ $CONFIGURE == no && -v CFG[$key] ]]; then
    if [[ -n ${CFG[$key]} ]]; then return; fi
    case $key in DNS_RECORD) return;; esac
  fi
  current=${CFG[$key]-$default}
  if [[ $NONINTERACTIVE == yes ]]; then
    CFG[$key]=$current
    return
  fi
  [[ -t 0 ]] || die 'Нужен терминал для вопросов или --non-interactive с заполненным .env'
  if [[ $secret == yes ]]; then
    printf '%s%s: ' "$label" "${current:+ [Enter — сохранить]}" >&2
    IFS= read -r -s value || die 'Ввод прерван'
    printf '\n' >&2
  else
    printf '%s [%s]: ' "$label" "$current" >&2
    IFS= read -r value || die 'Ввод прерван'
  fi
  CFG[$key]=${value:-$current}
}
save_env() {
  local key tmp
  tmp=$(mktemp "$(dirname "$ENV_FILE")/.env-save-XXXXXXXX")
  {
    printf '# Literal KEY=value. No shell expansion; do not source this file.\n'
    for key in "${KEYS[@]}"; do printf '%s=%s\n' "$key" "${CFG[$key]-}"; done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$ENV_FILE"
}
valid_ip() {
  local value=$1 octet
  local -a octets
  [[ $value =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    [[ $octet == 0 || $octet != 0* ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}
validate() {
  local key value
  for key in SOURCE_IP TARGET_IP DNS_OLD_IPV4 DNS_NEW_IPV4; do
    valid_ip "${CFG[$key]}" || die "Неверный IPv4: $key"
  done
  [[ ${CFG[SOURCE_IP]} != "${CFG[TARGET_IP]}" ]] || die 'Источник совпадает с целью'
  [[ ${CFG[DNS_OLD_IPV4]} != "${CFG[DNS_NEW_IPV4]}" ]] || die 'Старый и новый IPv4 DNS совпадают'
  for key in SOURCE_PORT TARGET_PORT; do
    value=${CFG[$key]}
    [[ $value =~ ^[1-9][0-9]{0,4}$ ]] && ((value <= 65535)) || die "Неверный порт: $key"
  done
  for key in DOMAIN REGRU_USERNAME REGRU_PASSWORD SOURCE_SSH_PASSWORD TARGET_SSH_PASSWORD; do
    [[ -n ${CFG[$key]} ]] || die "Не заполнено $key"
  done
  for key in "${KEYS[@]}"; do
    [[ ${CFG[$key]-} != *$'\n'* && ${CFG[$key]-} != *$'\r'* ]] || die 'Многострочные значения .env не поддерживаются'
  done
}
dns() (
  # Credentials are inherited only by the DNS subprocess, not SSH or migration.
  export REGRU_USERNAME=${CFG[REGRU_USERNAME]} REGRU_PASSWORD=${CFG[REGRU_PASSWORD]}
  bash "$DIR/regru-change-ip.sh" "${DNS_ARGS[@]}" "$@"
)
mark() {
  printf '%s\n' "$1" > "$STATE_FILE.tmp"
  mv -f -- "$STATE_FILE.tmp" "$STATE_FILE"
}
migrate() (
  export SOURCE_SSH_PASSWORD=${CFG[SOURCE_SSH_PASSWORD]} TARGET_SSH_PASSWORD=${CFG[TARGET_SSH_PASSWORD]}
  bash "$DIR/migrate-3xui.sh" "${MIGRATE_ARGS[@]}" "$@"
)
ensure_sshpass() {
  command -v sshpass >/dev/null && return
  local -a installer=()
  command -v apt-get >/dev/null || die 'Установите sshpass'
  if ((EUID != 0)); then
    command -v sudo >/dev/null && sudo -n true || die 'Для установки sshpass нужен root или sudo без пароля'
    installer=(sudo -n)
  fi
  "${installer[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update >&2
  "${installer[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y sshpass >&2
}
verify_target() {
  local -a options=(-o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=yes -o ConnectTimeout=15
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p "${CFG[TARGET_PORT]}")
  sshpass -d 8 ssh "${options[@]}" "root@${CFG[TARGET_IP]}" 'nginx -t && systemctl is-active --quiet x-ui && systemctl is-active --quiet nginx' 8<<< "${CFG[TARGET_SSH_PASSWORD]}"
}
main() {
  DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  ENV_FILE=$DIR/.env
  CONFIGURE=no NONINTERACTIVE=no
  local configure_only=no check=no key state=new fingerprint c
  while (($#)); do
    case $1 in
      --help|-h) usage; return;;
      --env) (($# >= 2)) || die '--env требует путь'; ENV_FILE=$2; shift 2;;
      --configure) CONFIGURE=yes; shift;;
      --configure-only) CONFIGURE=yes; configure_only=yes; shift;;
      --non-interactive) NONINTERACTIVE=yes; shift;;
      --check) check=yes; shift;;
      *) die "Неизвестная опция: $1";;
    esac
  done
  for c in realpath sha256sum flock ssh; do command -v "$c" >/dev/null || die "Не найден $c"; done
  ENV_FILE=$(realpath -m -- "$ENV_FILE")
  [[ -d $(dirname "$ENV_FILE") ]] || die 'Каталог для .env должен существовать'
  # One coordinator per config directory. State stores no API credentials.
  STATE_DIR=$(dirname "$ENV_FILE")/.migration-state
  [[ ! -L $STATE_DIR ]] || die 'Каталог состояния не должен быть symlink'
  mkdir -p -- "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  exec 9>"$STATE_DIR/lock"
  flock -n 9 || die 'Управляющий скрипт уже работает'
  for c in migrate-3xui.sh regru-change-ip.sh; do [[ -f $DIR/$c ]] || die "Поместите рядом $c"; done
  load_env
  ask SOURCE_IP 'IPv4 исходного сервера'
  ask TARGET_IP 'IPv4 целевого сервера'
  ask SOURCE_PORT 'SSH-порт источника' 22
  ask TARGET_PORT 'SSH-порт цели' 22
  ask SOURCE_SSH_PASSWORD 'Пароль root исходного сервера' '' yes
  ask TARGET_SSH_PASSWORD 'Пароль root целевого сервера' '' yes
  ask DOMAIN 'DNS-зона REG.RU, например example.com'
  ask DNS_RECORD 'Имя записи: @, vpn; пусто — все совпадения в зоне'
  ask DNS_OLD_IPV4 'Старый IPv4 в DNS' "${CFG[SOURCE_IP]}"
  ask DNS_NEW_IPV4 'Новый IPv4 в DNS' "${CFG[TARGET_IP]}"
  ask REGRU_USERNAME 'Логин REG.RU'
  ask REGRU_PASSWORD 'Пароль API REG.RU' '' yes
  validate
  save_env
  log "Настройки сохранены: $ENV_FILE (600)"
  [[ $configure_only != yes ]] || return 0
  MIGRATE_ARGS=("${CFG[SOURCE_IP]}" "${CFG[TARGET_IP]}" --source-port "${CFG[SOURCE_PORT]}" --target-port "${CFG[TARGET_PORT]}")
  DNS_ARGS=("${CFG[DOMAIN]}" "${CFG[DNS_OLD_IPV4]}" "${CFG[DNS_NEW_IPV4]}" --backup-dir "$(dirname "$ENV_FILE")/regru-backups")
  [[ -z ${CFG[DNS_RECORD]} ]] || DNS_ARGS+=(--record "${CFG[DNS_RECORD]}")
  fingerprint=$({
    for key in "${KEYS[@]}"; do
      case $key in REGRU_*|*_SSH_PASSWORD|SOURCE_PORT|TARGET_PORT) continue;; esac
      printf '%s=%s\n' "$key" "${CFG[$key]}"
    done
  } | sha256sum)
  STATE_FILE=$STATE_DIR/${fingerprint%% *}.state
  # Reuse progress from versions that included IPv6 fields; never re-copy silently.
  if [[ ! -e $STATE_FILE ]]; then
    local legacy_fingerprint
    legacy_fingerprint=$({
      for key in "${KEYS[@]}"; do
        case $key in REGRU_*|*_SSH_PASSWORD|SOURCE_PORT|TARGET_PORT) continue;; esac
        printf '%s=%s\n' "$key" "${CFG[$key]}"
        if [[ $key == DNS_NEW_IPV4 ]]; then
          printf 'MIGRATE_IPV6=%s\nSOURCE_IPV6=%s\nTARGET_IPV6=%s\n' "${LEGACY[MIGRATE_IPV6]}" "${LEGACY[SOURCE_IPV6]}" "${LEGACY[TARGET_IPV6]}"
        fi
      done
    } | sha256sum)
    if [[ -f $STATE_DIR/${legacy_fingerprint%% *}.state ]]; then
      cp -- "$STATE_DIR/${legacy_fingerprint%% *}.state" "$STATE_FILE"
    fi
  fi
  [[ ! -f $STATE_FILE ]] || IFS= read -r state < "$STATE_FILE"
  case $state in new|migration-started|dns-pending|done) ;; *) die 'Неизвестное состояние запуска';; esac
  ensure_sshpass
  if [[ $check == yes ]]; then
    migrate --check
    dns --check
    log 'Проверки завершены. Серверы не мигрированы, DNS не изменён.'
    return
  fi
  [[ $state != done ]] || { log 'Этот перенос уже завершён. Повторная миграция не выполняется.'; return; }
  log 'Проверка доступа REG.RU и плана DNS до начала миграции...'
  dns --check || die 'Проверка DNS не пройдена; миграция не запускается'
  if [[ $state == migration-started ]]; then
    die "Предыдущая миграция была прервана или завершилась ошибкой. Проверьте серверы. Инструкция восстановления: README-manager.md; файл состояния: $STATE_FILE"
  fi
  if [[ $state == new ]]; then
    log 'Этап 1/2: установка и миграция 3x-ui/nginx...'
    mark migration-started
    if migrate; then
      mark dns-pending
    else
      die "Миграция завершилась ошибкой. DNS не изменён. Проверьте серверы; состояние: $STATE_FILE"
    fi
  else
    log 'Миграция ранее завершена; продолжается только этап DNS.'
  fi
  verify_target || die 'Целевые службы не прошли проверку. DNS не изменяется; после исправления повторите запуск'
  log 'Этап 2/2: смена A-записей REG.RU...'
  dns || die 'Смена DNS не завершена; возможны частичные изменения. Повторите запуск для продолжения без миграции'
  mark done
  log 'Последовательность завершена. Учтите TTL DNS и проверьте клиентские подключения. Исходный сервер продолжает работать.'
}
main "$@"
