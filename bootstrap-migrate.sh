#!/usr/bin/env bash
# Run this script on the NEW server. It pulls data from the old 3x-UI server.
set -Eeuo pipefail
set +x
umask 077

readonly REPO_RAW="https://raw.githubusercontent.com/Phaum/SAS/main"
readonly WORK_DIR="/root/SAS-migration"
SOURCE_PASSWORD=
REGRU_USERNAME_VALUE=
REGRU_PASSWORD_VALUE=
DNS_SWITCHED=no
OLD_IP=
NEW_IP=
DNS_ZONE=
PANEL_RECORD=
SUB_RECORD=

log() { printf '[SAS migration] %s\n' "$*" >&2; }
die() { log "ОШИБКА: $*"; exit 1; }
ask() {
  local var=$1 prompt=$2 default=${3:-} value
  printf '%s%s: ' "$prompt" "${default:+ [$default]}" >&2
  IFS= read -r value || die 'Ввод прерван'
  printf -v "$var" '%s' "${value:-$default}"
}
ask_secret() {
  local var=$1 prompt=$2 value
  printf '%s: ' "$prompt" >&2
  IFS= read -r -s value || die 'Ввод прерван'
  printf '\n' >&2
  [[ -n $value ]] || die "$prompt не может быть пустым"
  printf -v "$var" '%s' "$value"
}
confirm() {
  local answer
  printf '%s [yes/NO]: ' "$1" >&2
  IFS= read -r answer || die 'Ввод прерван'
  [[ $answer == yes ]]
}
valid_ipv4() {
  local ip=$1 o; local -a p
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a p <<< "$ip"
  for o in "${p[@]}"; do ((10#$o <= 255)) || return 1; done
}
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_record() { [[ $1 == @ || $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$ ]]; }
safe_line() { [[ $1 != *$'\n'* && $1 != *$'\r'* ]]; }

rollback_dns() {
  local rc=$?
  trap - ERR INT TERM
  set +e
  if [[ $DNS_SWITCHED == yes ]]; then
    log 'Миграция после переключения DNS завершилась ошибкой; выполняется возврат A-записей'
    REGRU_USERNAME=$REGRU_USERNAME_VALUE REGRU_PASSWORD=$REGRU_PASSWORD_VALUE \
      bash "$WORK_DIR/regru-change-ip.sh" "$DNS_ZONE" "$NEW_IP" "$OLD_IP" --record "$PANEL_RECORD"
    if [[ $SUB_RECORD != "$PANEL_RECORD" ]]; then
      REGRU_USERNAME=$REGRU_USERNAME_VALUE REGRU_PASSWORD=$REGRU_PASSWORD_VALUE \
        bash "$WORK_DIR/regru-change-ip.sh" "$DNS_ZONE" "$NEW_IP" "$OLD_IP" --record "$SUB_RECORD"
    fi
    log 'Проверьте фактические DNS-записи и доступность старого сервера.'
  fi
  exit "$rc"
}

install_bootstrap_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=180 update
  apt-get -o DPkg::Lock::Timeout=180 install -y \
    ca-certificates curl openssh-client sshpass sqlite3 dnsutils jq
}

download_scripts() {
  install -d -m 700 "$WORK_DIR"
  curl -fL --retry 4 --connect-timeout 15 --max-time 120 \
    "$REPO_RAW/install-vpn-stack.sh" -o "$WORK_DIR/install-vpn-stack.sh"
  curl -fL --retry 4 --connect-timeout 15 --max-time 120 \
    "$REPO_RAW/regru-change-ip.sh" -o "$WORK_DIR/regru-change-ip.sh"
  chmod 700 "$WORK_DIR/install-vpn-stack.sh" "$WORK_DIR/regru-change-ip.sh"
  bash -n "$WORK_DIR/install-vpn-stack.sh" "$WORK_DIR/regru-change-ip.sh"
}

trust_source_host() {
  local source_ip=$1 source_port=$2 scan fingerprint
  install -d -m 700 /root/.ssh
  touch /root/.ssh/known_hosts
  chmod 600 /root/.ssh/known_hosts
  if ssh-keygen -F "[$source_ip]:$source_port" -f /root/.ssh/known_hosts >/dev/null 2>&1; then return; fi
  scan=$(ssh-keyscan -T 10 -p "$source_port" "$source_ip" 2>/dev/null) || die 'Не удалось получить SSH host key источника'
  [[ -n $scan ]] || die 'Пустой SSH host key источника'
  fingerprint=$(ssh-keygen -lf /dev/stdin <<< "$scan" | awk '{$1=$1; print}')
  log "SSH fingerprint старого сервера:\n$fingerprint"
  confirm 'Вы сверили fingerprint и доверяете этому ключу?' || die 'SSH host key не подтверждён'
  printf '%s\n' "$scan" >> /root/.ssh/known_hosts
}

ssh_source() {
  local source_ip=$1 source_port=$2; shift 2
  sshpass -d 9 ssh -p "$source_port" -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    "root@$source_ip" "$@" 9<<< "$SOURCE_PASSWORD"
}

snapshot_source_db() {
  local source_ip=$1 source_port=$2 metadata remote_dir remote_sha local_db local_sha
  metadata=$(ssh_source "$source_ip" "$source_port" 'bash -s' <<'REMOTE'
set -Eeuo pipefail
[[ -f /etc/x-ui/x-ui.db && -x /usr/local/x-ui/x-ui ]] || { echo '3x-UI SQLite database not found' >&2; exit 1; }
d=$(mktemp -d /var/tmp/sas-xui-snapshot.XXXXXXXX)
trap 'systemctl start x-ui >/dev/null 2>&1 || true' EXIT
systemctl stop x-ui
cp --preserve=mode,ownership,timestamps /etc/x-ui/x-ui.db "$d/x-ui.db"
systemctl start x-ui
trap - EXIT
chmod 700 "$d"
chmod 600 "$d/x-ui.db"
printf '%s|%s\n' "$d" "$(sha256sum "$d/x-ui.db" | awk '{print $1}')"
REMOTE
  )
  IFS='|' read -r remote_dir remote_sha <<< "$metadata"
  [[ $remote_dir =~ ^/var/tmp/sas-xui-snapshot\.[A-Za-z0-9]+$ && $remote_sha =~ ^[a-f0-9]{64}$ ]] || \
    die 'Источник вернул некорректные метаданные snapshot'
  local_db="$WORK_DIR/source-x-ui.db"
  sshpass -d 9 scp -P "$source_port" -o StrictHostKeyChecking=yes \
    "root@$source_ip:$remote_dir/x-ui.db" "$local_db" 9<<< "$SOURCE_PASSWORD"
  local_sha=$(sha256sum "$local_db" | awk '{print $1}')
  [[ $local_sha == "$remote_sha" ]] || die 'SHA256 перенесённой базы не совпадает'
  ssh_source "$source_ip" "$source_port" "find '$remote_dir' -depth -delete"
  chmod 600 "$local_db"
  log "База 3x-UI перенесена и проверена: $local_sha"
}

db_setting() {
  sqlite3 "$WORK_DIR/source-x-ui.db" "SELECT value FROM settings WHERE key='$1' ORDER BY id DESC LIMIT 1;" 2>/dev/null || true
}

write_install_env() {
  local panel_domain=$1 sub_domain=$2 email=$3 xui_user=$4 xui_pass=$5 web_path=$6 sub_path=$7 grafana_user=$8 grafana_pass=$9
  for value in "$panel_domain" "$sub_domain" "$email" "$xui_user" "$xui_pass" "$web_path" "$sub_path" "$grafana_user" "$grafana_pass"; do
    safe_line "$value" || die 'Переносы строк в настройках запрещены'
  done
  cat > "$WORK_DIR/install.env" <<EOF
PANEL_DOMAIN=$panel_domain
SUB_DOMAIN=$sub_domain
LETSENCRYPT_EMAIL=$email
PUBLIC_IP=$NEW_IP
XUI_USERNAME=$xui_user
XUI_PASSWORD=$xui_pass
XUI_PANEL_PORT=9999
XUI_SUB_PORT=2096
XUI_WEB_BASE_PATH=$web_path
XUI_SUB_PATH=$sub_path
XUI_VERSION=
XUI_INSTALL_REF=main
GRAFANA_USERNAME=$grafana_user
GRAFANA_PASSWORD=$grafana_pass
LOG_RETENTION=168h
RESTORE_XUI_DB=$WORK_DIR/source-x-ui.db
SKIP_DNS_CHECK=no
LOKI_IMAGE=grafana/loki:3.7.0
GRAFANA_IMAGE=grafana/grafana:13.2.1
ALLOY_IMAGE=grafana/alloy:v1.19.2
EOF
  chmod 600 "$WORK_DIR/install.env"
}

change_dns_record() {
  local record=$1
  REGRU_USERNAME=$REGRU_USERNAME_VALUE REGRU_PASSWORD=$REGRU_PASSWORD_VALUE \
    bash "$WORK_DIR/regru-change-ip.sh" "$DNS_ZONE" "$OLD_IP" "$NEW_IP" \
      --record "$record" --backup-dir "$WORK_DIR/regru-backups"
}

wait_authoritative_dns() {
  local domain=$1 deadline ns value ok
  deadline=$((SECONDS + 900))
  while ((SECONDS < deadline)); do
    ok=yes
    while IFS= read -r ns; do
      [[ -n $ns ]] || continue
      value=$(dig +short +time=5 +tries=1 "@$ns" A "$domain" | sort -u | paste -sd, -)
      [[ ,$value, == *,"$NEW_IP",* ]] || ok=no
    done < <(dig +short NS "$DNS_ZONE")
    [[ $ok == yes ]] && { log "$domain опубликован на $NEW_IP"; return; }
    log "Ожидание DNS для $domain..."
    sleep 15
  done
  die "DNS $domain не обновился за 15 минут"
}

open_inbound_ports() {
  local protocol port stream network
  command -v ufw >/dev/null || return
  ufw status | grep -q '^Status: active' || return
  while IFS='|' read -r protocol port stream; do
    [[ $port =~ ^[0-9]+$ ]] || continue
    network=$(jq -r '.network // "tcp"' <<< "$stream" 2>/dev/null || printf tcp)
    if [[ $protocol == wireguard || $network == kcp || $network == quic ]]; then
      ufw allow "$port/udp"
    else
      ufw allow "$port/tcp"
    fi
  done < <(sqlite3 -separator '|' /etc/x-ui/x-ui.db \
    "SELECT protocol,port,stream_settings FROM inbounds WHERE enable=1;")
}

main() {
  local source_ip source_port panel_domain sub_domain email xui_user xui_pass web_path sub_path grafana_user grafana_pass old_panel old_sub old_web old_subpath
  [[ $EUID == 0 ]] || die 'Запустите скрипт от root на НОВОМ сервере'
  [[ -t 0 ]] || die 'Для безопасного ввода паролей требуется интерактивный терминал'
  install_bootstrap_dependencies
  download_scripts
  NEW_IP=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api4.ipify.org)
  valid_ipv4 "$NEW_IP" || die 'Не удалось определить IP нового сервера'

  ask source_ip 'IPv4 старого сервера'
  valid_ipv4 "$source_ip" || die 'Неверный IPv4 старого сервера'
  OLD_IP=$source_ip
  [[ $OLD_IP != "$NEW_IP" ]] || die 'Старый и новый IP совпадают'
  ask source_port 'SSH-порт старого сервера' 22
  valid_port "$source_port" || die 'Неверный SSH-порт'
  ask_secret SOURCE_PASSWORD 'Пароль root старого сервера'
  trust_source_host "$source_ip" "$source_port"
  ssh_source "$source_ip" "$source_port" 'systemctl is-active --quiet x-ui && test -f /etc/x-ui/x-ui.db' || \
    die '3x-UI на старом сервере не готов к миграции'
  snapshot_source_db "$source_ip" "$source_port"

  old_panel=$(db_setting webDomain)
  old_sub=$(db_setting subDomain)
  old_web=$(db_setting webBasePath)
  old_subpath=$(db_setting subPath)
  ask panel_domain 'Домен панели' "$old_panel"
  ask sub_domain 'Домен подписок' "$old_sub"
  ask email 'Email для Let’s Encrypt'
  ask xui_user 'Новый логин 3x-UI' root
  ask_secret xui_pass 'Новый пароль 3x-UI'
  ask web_path 'Скрытый путь панели' "${old_web:-/$(openssl rand -hex 12)/}"
  ask sub_path 'Путь подписок' "${old_subpath:-/podpiska/}"
  ask grafana_user 'Логин Grafana' root
  ask_secret grafana_pass 'Пароль Grafana'
  ask DNS_ZONE 'DNS-зона REG.RU (например payfpp.xyz)'
  ask PANEL_RECORD 'Имя A-записи панели (например panel)'
  ask SUB_RECORD 'Имя A-записи подписок (например fpp)'
  valid_domain "$panel_domain" || die 'Неверный домен панели'
  valid_domain "$sub_domain" || die 'Неверный домен подписок'
  valid_domain "$DNS_ZONE" || die 'Неверная DNS-зона'
  valid_record "$PANEL_RECORD" || die 'Неверное имя A-записи панели'
  valid_record "$SUB_RECORD" || die 'Неверное имя A-записи подписок'
  ask_secret REGRU_USERNAME_VALUE 'Логин REG.RU API'
  ask_secret REGRU_PASSWORD_VALUE 'Пароль REG.RU API'

  write_install_env "$panel_domain" "$sub_domain" "$email" "$xui_user" "$xui_pass" \
    "$web_path" "$sub_path" "$grafana_user" "$grafana_pass"
  log 'Проверяется план изменения DNS без записи...'
  REGRU_USERNAME=$REGRU_USERNAME_VALUE REGRU_PASSWORD=$REGRU_PASSWORD_VALUE \
    bash "$WORK_DIR/regru-change-ip.sh" "$DNS_ZONE" "$OLD_IP" "$NEW_IP" --record "$PANEL_RECORD" --check
  if [[ $SUB_RECORD != "$PANEL_RECORD" ]]; then
    REGRU_USERNAME=$REGRU_USERNAME_VALUE REGRU_PASSWORD=$REGRU_PASSWORD_VALUE \
      bash "$WORK_DIR/regru-change-ip.sh" "$DNS_ZONE" "$OLD_IP" "$NEW_IP" --record "$SUB_RECORD" --check
  fi

  log 'Подготавливается новый сервер без переключения DNS...'
  bash "$WORK_DIR/install-vpn-stack.sh" --prepare --env "$WORK_DIR/install.env"
  confirm "Переключить DNS с $OLD_IP на $NEW_IP и завершить миграцию?" || \
    die "Остановлено до изменения DNS. Для продолжения используйте файлы в $WORK_DIR"

  trap rollback_dns ERR INT TERM
  change_dns_record "$PANEL_RECORD"
  DNS_SWITCHED=yes
  [[ $SUB_RECORD == "$PANEL_RECORD" ]] || change_dns_record "$SUB_RECORD"
  wait_authoritative_dns "$panel_domain"
  wait_authoritative_dns "$sub_domain"
  bash "$WORK_DIR/install-vpn-stack.sh" --finish --env "$WORK_DIR/install.env"
  open_inbound_ports
  systemctl is-active --quiet x-ui nginx docker
  trap - ERR INT TERM
  DNS_SWITCHED=no

  log 'Миграция завершена. Старый сервер оставлен включённым для ручного отката.'
  log "Панель: https://$panel_domain$web_path"
  log "Логи: https://$panel_domain/logs/"
  log "Подписки: https://$sub_domain$sub_path"
  log 'Проверьте VPN-клиентов, затем отдельно отключите старый сервер.'
}

main "$@"
