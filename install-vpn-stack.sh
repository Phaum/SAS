#!/usr/bin/env bash
# Unattended 3x-UI + nginx + Grafana/Loki/Alloy installer for Debian/Ubuntu.
set -Eeuo pipefail
set +x
umask 077

readonly SCRIPT_VERSION="1.0.0"
declare -A CFG=()
BACKUP_DIR=
NGINX_TOUCHED=no
readonly -a ALLOWED_KEYS=(
  PANEL_DOMAIN SUB_DOMAIN LETSENCRYPT_EMAIL PUBLIC_IP
  XUI_USERNAME XUI_PASSWORD XUI_PANEL_PORT XUI_SUB_PORT
  XUI_WEB_BASE_PATH XUI_SUB_PATH XUI_VERSION XUI_INSTALL_REF
  GRAFANA_USERNAME GRAFANA_PASSWORD LOG_RETENTION
  RESTORE_XUI_DB SKIP_DNS_CHECK
  LOKI_IMAGE GRAFANA_IMAGE ALLOY_IMAGE
)

log() { printf '[vpn-stack] %s\n' "$*" >&2; }
die() { log "ОШИБКА: $*"; exit 1; }
usage() {
  cat <<'EOF'
Автономная установка 3x-UI, nginx и панели логирования.

Использование:
  sudo bash install-vpn-stack.sh --check [--env FILE]
  sudo bash install-vpn-stack.sh --install [--env FILE]

Опции:
  --check       Проверить ОС, DNS, порты и конфигурацию без изменений (по умолчанию).
  --install     Выполнить установку или привести существующую установку к конфигурации.
  --env FILE    Файл настроек (по умолчанию install.env рядом со скриптом).
  --help        Показать справку.

Файл настроек разбирается как KEY=value и никогда не исполняется как shell-код.
EOF
}

trim_cr() { printf '%s' "${1%$'\r'}"; }
load_env() {
  local file=$1 line key value allowed
  [[ -f $file && ! -L $file ]] || die "Нет обычного файла настроек: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(trim_cr "$line")
    [[ -n $line && $line != \#* ]] || continue
    [[ $line == *=* ]] || die "Неверная строка в $file: ожидается KEY=value"
    key=${line%%=*}; value=${line#*=}; allowed=no
    for candidate in "${ALLOWED_KEYS[@]}"; do
      [[ $key != "$candidate" ]] || allowed=yes
    done
    [[ $allowed == yes ]] || die "Неизвестная настройка: $key"
    [[ ! -v CFG[$key] ]] || die "Повторяющаяся настройка: $key"
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "Многострочное значение: $key"
    CFG[$key]=$value
  done < "$file"
  chmod 600 "$file"
}

set_defaults() {
  : "${CFG[XUI_PANEL_PORT]:=9999}"
  : "${CFG[XUI_SUB_PORT]:=2096}"
  : "${CFG[XUI_WEB_BASE_PATH]:=}"
  : "${CFG[XUI_SUB_PATH]:=/podpiska/}"
  : "${CFG[XUI_VERSION]:=}"
  : "${CFG[XUI_INSTALL_REF]:=main}"
  : "${CFG[GRAFANA_USERNAME]:=root}"
  : "${CFG[LOG_RETENTION]:=168h}"
  : "${CFG[RESTORE_XUI_DB]:=}"
  : "${CFG[SKIP_DNS_CHECK]:=no}"
  : "${CFG[LOKI_IMAGE]:=grafana/loki:3.7.0}"
  : "${CFG[GRAFANA_IMAGE]:=grafana/grafana:13.2.1}"
  : "${CFG[ALLOY_IMAGE]:=grafana/alloy:v1.19.2}"
}

valid_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_path() { [[ $1 =~ ^/[A-Za-z0-9._~/-]*/$ && $1 != *//* ]]; }
valid_ipv4() {
  local ip=$1 o; local -a parts
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  for o in "${parts[@]}"; do ((10#$o <= 255)) || return 1; done
}
require_value() { [[ -n ${CFG[$1]-} ]] || die "Не заполнено $1"; }
validate_config() {
  local key
  for key in PANEL_DOMAIN SUB_DOMAIN LETSENCRYPT_EMAIL XUI_USERNAME XUI_PASSWORD GRAFANA_USERNAME GRAFANA_PASSWORD; do
    require_value "$key"
  done
  valid_domain "${CFG[PANEL_DOMAIN]}" || die 'Неверный PANEL_DOMAIN'
  valid_domain "${CFG[SUB_DOMAIN]}" || die 'Неверный SUB_DOMAIN'
  [[ ${CFG[PANEL_DOMAIN]} != "${CFG[SUB_DOMAIN]}" ]] || die 'PANEL_DOMAIN и SUB_DOMAIN должны отличаться'
  [[ ${CFG[LETSENCRYPT_EMAIL]} == *@*.* ]] || die 'Неверный LETSENCRYPT_EMAIL'
  valid_port "${CFG[XUI_PANEL_PORT]}" || die 'Неверный XUI_PANEL_PORT'
  valid_port "${CFG[XUI_SUB_PORT]}" || die 'Неверный XUI_SUB_PORT'
  [[ ${CFG[XUI_PANEL_PORT]} != "${CFG[XUI_SUB_PORT]}" ]] || die 'Порты панели и подписок должны отличаться'
  valid_path "${CFG[XUI_SUB_PATH]}" || die 'XUI_SUB_PATH должен иметь вид /podpiska/'
  if [[ -n ${CFG[XUI_WEB_BASE_PATH]} ]]; then
    valid_path "${CFG[XUI_WEB_BASE_PATH]}" || die 'XUI_WEB_BASE_PATH должен иметь вид /secret-path/'
    ((${#CFG[XUI_WEB_BASE_PATH]} >= 8)) || die 'XUI_WEB_BASE_PATH слишком короткий'
  fi
  [[ ${CFG[SKIP_DNS_CHECK]} == yes || ${CFG[SKIP_DNS_CHECK]} == no ]] || die 'SKIP_DNS_CHECK: yes или no'
  [[ ${CFG[LOG_RETENTION]} =~ ^[1-9][0-9]*[hd]$ ]] || die 'LOG_RETENTION: например 168h или 7d'
  if [[ -n ${CFG[PUBLIC_IP]} ]]; then valid_ipv4 "${CFG[PUBLIC_IP]}" || die 'Неверный PUBLIC_IP'; fi
  if [[ -n ${CFG[RESTORE_XUI_DB]} ]]; then
    [[ ${CFG[RESTORE_XUI_DB]} == /* && -f ${CFG[RESTORE_XUI_DB]} && ! -L ${CFG[RESTORE_XUI_DB]} ]] || \
      die 'RESTORE_XUI_DB должен быть абсолютным путём к обычному файлу на сервере'
  fi
  for key in XUI_USERNAME XUI_PASSWORD GRAFANA_USERNAME GRAFANA_PASSWORD; do
    [[ ${CFG[$key]} != *:* ]] || die "$key не должен содержать двоеточие"
  done
}

detect_public_ip() {
  [[ -n ${CFG[PUBLIC_IP]} ]] && return
  CFG[PUBLIC_IP]=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api4.ipify.org || true)
  valid_ipv4 "${CFG[PUBLIC_IP]}" || die 'Не удалось определить PUBLIC_IP; заполните его вручную'
}

dns_check() {
  local domain answer
  [[ ${CFG[SKIP_DNS_CHECK]} == no ]] || { log 'DNS-проверка отключена'; return; }
  for domain in "${CFG[PANEL_DOMAIN]}" "${CFG[SUB_DOMAIN]}"; do
    answer=$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u | paste -sd, -)
    [[ ,$answer, == *,"${CFG[PUBLIC_IP]}",* ]] || \
      die "$domain не указывает на ${CFG[PUBLIC_IP]} (получено: ${answer:-нет A-записи})"
    if getent ahostsv6 "$domain" >/dev/null 2>&1; then
      log "ПРЕДУПРЕЖДЕНИЕ: у $domain есть AAAA-запись; проверьте IPv6"
    fi
  done
}

port_check() {
  local p
  for p in 80 443 "${CFG[XUI_PANEL_PORT]}" "${CFG[XUI_SUB_PORT]}" 3000 3100; do
    if ss -H -lnt "sport = :$p" 2>/dev/null | grep -q .; then
      case $p in
        80|443) command -v nginx >/dev/null && log "Порт $p уже занят (допустимо для повторного запуска)" || die "Порт $p занят не nginx";;
        "${CFG[XUI_PANEL_PORT]}"|"${CFG[XUI_SUB_PORT]}") command -v x-ui >/dev/null || die "Порт $p уже занят";;
        3000) docker ps --format '{{.Names}}' 2>/dev/null | grep -qx vpn-grafana || die 'Порт 3000 уже занят';;
        3100) :;;
      esac
    fi
  done
}

preflight() {
  [[ $EUID == 0 ]] || die 'Запустите от root (sudo)'
  [[ -r /etc/os-release ]] || die 'Не найдена /etc/os-release'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ $ID == ubuntu || $ID == debian ]] || die 'Поддерживаются только Debian и Ubuntu'
  command -v apt-get >/dev/null || die 'Не найден apt-get'
  detect_public_ip
  dns_check
  command -v ss >/dev/null || log 'Пакет iproute2 будет установлен'
  command -v ss >/dev/null && port_check
  log "Preflight пройден: $ID ${VERSION_ID:-}, IP ${CFG[PUBLIC_IP]}"
}

backup_existing() {
  local stamp backup
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup="/var/backups/vpn-stack/$stamp"
  BACKUP_DIR=$backup
  install -d -m 700 "$backup"
  [[ ! -f /etc/x-ui/x-ui.db ]] || cp -a /etc/x-ui/x-ui.db "$backup/x-ui.db"
  [[ ! -d /etc/nginx ]] || tar -C / -czf "$backup/nginx.tar.gz" etc/nginx
  [[ ! -d /opt/vpn-stack ]] || tar -C / -czf "$backup/vpn-stack.tar.gz" opt/vpn-stack
  log "Резервная копия: $backup"
}

rollback_nginx_on_error() {
  local rc=$?
  trap - ERR
  set +e
  if [[ $NGINX_TOUCHED == yes ]]; then
    log 'Ошибка установки: восстанавливается прежняя конфигурация nginx'
    rm -f /etc/nginx/sites-enabled/vpn-stack /etc/nginx/sites-enabled/vpn-stack-http \
      /etc/nginx/sites-available/vpn-stack /etc/nginx/sites-available/vpn-stack-http
    if [[ -f $BACKUP_DIR/nginx.tar.gz ]]; then
      tar -C / -xzf "$BACKUP_DIR/nginx.tar.gz"
    elif [[ -f /etc/nginx/sites-available/default ]]; then
      ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    fi
    nginx -t && systemctl reload nginx
  fi
  exit "$rc"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=180 update
  apt-get -o DPkg::Lock::Timeout=180 install -y \
    ca-certificates curl nginx certbot python3-certbot-nginx sqlite3 docker.io \
    openssl jq iproute2 dnsutils
  systemctl enable --now nginx docker
}

install_xui() {
  local installer
  if [[ ! -x /usr/local/x-ui/x-ui ]]; then
    installer=$(mktemp /var/tmp/3x-ui-install.XXXXXXXX.sh)
    trap 'rm -f -- "${installer:-}"' RETURN
    curl -fL --retry 4 --connect-timeout 15 --max-time 120 \
      "https://raw.githubusercontent.com/MHSanaei/3x-ui/${CFG[XUI_INSTALL_REF]}/install.sh" -o "$installer"
    chmod 700 "$installer"
    XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none \
      XUI_USERNAME="${CFG[XUI_USERNAME]}" XUI_PASSWORD="${CFG[XUI_PASSWORD]}" \
      XUI_PANEL_PORT="${CFG[XUI_PANEL_PORT]}" XUI_WEB_BASE_PATH="${CFG[XUI_WEB_BASE_PATH]}" \
      XUI_SERVER_IP="${CFG[PUBLIC_IP]}" XUI_ENABLE_FAIL2BAN=true \
      bash "$installer" "${CFG[XUI_VERSION]}"
  else
    log '3x-UI уже установлен; бинарные файлы не заменяются'
  fi
  [[ -x /usr/local/x-ui/x-ui && -f /etc/x-ui/x-ui.db ]] || die '3x-UI не установился'

  if [[ -n ${CFG[RESTORE_XUI_DB]} ]]; then
    systemctl stop x-ui
    install -o root -g root -m 600 "${CFG[RESTORE_XUI_DB]}" /etc/x-ui/x-ui.db
  fi

  if [[ -z ${CFG[XUI_WEB_BASE_PATH]} ]]; then
    CFG[XUI_WEB_BASE_PATH]="/$(openssl rand -hex 12)/"
  fi
  /usr/local/x-ui/x-ui setting \
    -username "${CFG[XUI_USERNAME]}" -password "${CFG[XUI_PASSWORD]}" \
    -port "${CFG[XUI_PANEL_PORT]}" -webBasePath "${CFG[XUI_WEB_BASE_PATH]}"

  systemctl stop x-ui 2>/dev/null || true
  local db=/etc/x-ui/x-ui.db q_panel q_sub q_subpath q_suburi
  q_panel=${CFG[PANEL_DOMAIN]//\'/\'\'}
  q_sub=${CFG[SUB_DOMAIN]//\'/\'\'}
  q_subpath=${CFG[XUI_SUB_PATH]//\'/\'\'}
  q_suburi="https://${q_sub}${q_subpath}"
  sqlite3 "$db" <<SQL
UPDATE settings SET value='127.0.0.1' WHERE key='webListen';
INSERT INTO settings(key,value) SELECT 'webListen','127.0.0.1' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='webListen');
UPDATE settings SET value='$q_panel' WHERE key='webDomain';
INSERT INTO settings(key,value) SELECT 'webDomain','$q_panel' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='webDomain');
UPDATE settings SET value='${CFG[XUI_PANEL_PORT]}' WHERE key='webPort';
INSERT INTO settings(key,value) SELECT 'webPort','${CFG[XUI_PANEL_PORT]}' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='webPort');
UPDATE settings SET value='' WHERE key IN ('webCertFile','webKeyFile');
INSERT INTO settings(key,value) SELECT 'webCertFile','' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='webCertFile');
INSERT INTO settings(key,value) SELECT 'webKeyFile','' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='webKeyFile');
UPDATE settings SET value='true' WHERE key='subEnable';
INSERT INTO settings(key,value) SELECT 'subEnable','true' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='subEnable');
UPDATE settings SET value='127.0.0.1' WHERE key='subListen';
INSERT INTO settings(key,value) SELECT 'subListen','127.0.0.1' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='subListen');
UPDATE settings SET value='$q_sub' WHERE key='subDomain';
INSERT INTO settings(key,value) SELECT 'subDomain','$q_sub' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='subDomain');
UPDATE settings SET value='${CFG[XUI_SUB_PORT]}' WHERE key='subPort';
INSERT INTO settings(key,value) SELECT 'subPort','${CFG[XUI_SUB_PORT]}' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='subPort');
UPDATE settings SET value='$q_subpath' WHERE key='subPath';
INSERT INTO settings(key,value) SELECT 'subPath','$q_subpath' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='subPath');
UPDATE settings SET value='$q_suburi' WHERE key='subURI';
INSERT INTO settings(key,value) SELECT 'subURI','$q_suburi' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='subURI');
UPDATE settings SET value='' WHERE key IN ('subCertFile','subKeyFile');
INSERT INTO settings(key,value) SELECT 'subCertFile','' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='subCertFile');
INSERT INTO settings(key,value) SELECT 'subKeyFile','' WHERE NOT EXISTS(SELECT 1 FROM settings WHERE key='subKeyFile');
SQL
  systemctl enable --now x-ui
}

write_http_bootstrap() {
  NGINX_TOUCHED=yes
  install -d -m 755 /var/www/acme
  rm -f /etc/nginx/sites-enabled/vpn-stack
  cat > /etc/nginx/sites-available/vpn-stack-http <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${CFG[PANEL_DOMAIN]} ${CFG[SUB_DOMAIN]};
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 404; }
}
EOF
  ln -sfn /etc/nginx/sites-available/vpn-stack-http /etc/nginx/sites-enabled/vpn-stack-http
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
}

issue_certificate() {
  certbot certonly --webroot -w /var/www/acme --non-interactive --agree-tos \
    --keep-until-expiring --email "${CFG[LETSENCRYPT_EMAIL]}" \
    --cert-name "${CFG[PANEL_DOMAIN]}" \
    -d "${CFG[PANEL_DOMAIN]}" -d "${CFG[SUB_DOMAIN]}"
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-vpn-stack <<'EOF'
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-vpn-stack
}

write_logging_config() {
  install -d -m 755 /opt/vpn-stack/provisioning/datasources \
    /opt/vpn-stack/provisioning/dashboards /opt/vpn-stack/dashboards-json
  cat > /opt/vpn-stack/loki.yaml <<EOF
auth_enabled: false
server:
  http_listen_port: 3100
common:
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore: {store: inmemory}
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
schema_config:
  configs:
    - from: 2024-04-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index: {prefix: index_, period: 24h}
limits_config:
  retention_period: ${CFG[LOG_RETENTION]}
compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
analytics: {reporting_enabled: false}
EOF
  cat > /opt/vpn-stack/alloy.alloy <<'EOF'
local.file_match "server_logs" {
  path_targets = [
    { "__path__" = "/host/var/log/nginx/*.log", "job" = "nginx" },
    { "__path__" = "/host/var/log/x-ui/*.log", "job" = "x-ui" },
    { "__path__" = "/host/var/log/syslog", "job" = "system" },
    { "__path__" = "/host/var/log/auth.log", "job" = "auth" },
  ]
}
loki.source.file "server_logs" {
  targets = local.file_match.server_logs.targets
  forward_to = [loki.write.local.receiver]
}
loki.write "local" {
  endpoint { url = "http://vpn-loki:3100/loki/api/v1/push" }
}
EOF
  cat > /opt/vpn-stack/provisioning/datasources/loki.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Loki
    uid: vpn-loki
    type: loki
    access: proxy
    url: http://vpn-loki:3100
    isDefault: true
    editable: false
EOF
  cat > /opt/vpn-stack/provisioning/dashboards/provider.yaml <<'EOF'
apiVersion: 1
providers:
  - name: VPN monitoring
    folder: 3x-UI Monitoring
    type: file
    allowUiUpdates: true
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/dashboards-json
EOF
  cat > /opt/vpn-stack/dashboards-json/overview.json <<'EOF'
{
  "uid":"vpn-stack-overview","title":"3x-UI Server Overview","tags":["3x-ui","vpn","logs"],
  "schemaVersion":41,"refresh":"10s","time":{"from":"now-6h","to":"now"},
  "panels":[
    {"id":1,"type":"timeseries","title":"Logs by service","gridPos":{"x":0,"y":0,"w":16,"h":8},"datasource":{"type":"loki","uid":"vpn-loki"},"targets":[{"refId":"A","expr":"sum by (job) (count_over_time({job=~\".+\"}[$__interval]))","legendFormat":"{{job}}","queryType":"range"}]},
    {"id":2,"type":"stat","title":"SSH attack attempts","gridPos":{"x":16,"y":0,"w":8,"h":8},"datasource":{"type":"loki","uid":"vpn-loki"},"targets":[{"refId":"A","expr":"sum(count_over_time({job=\"auth\"} |~ \"(?i)failed password|invalid user|authentication failure\" [$__range])) or vector(0)","queryType":"instant"}]},
    {"id":3,"type":"timeseries","title":"Subscription success / errors","gridPos":{"x":0,"y":8,"w":12,"h":8},"datasource":{"type":"loki","uid":"vpn-loki"},"targets":[{"refId":"A","expr":"sum(count_over_time({job=\"nginx\"} |~ \"GET /podpiska/[A-Za-z0-9]+ HTTP\" |~ \" 2[0-9][0-9] \" [$__interval])) or vector(0)","legendFormat":"2xx","queryType":"range"},{"refId":"B","expr":"sum(count_over_time({job=\"nginx\"} |~ \"GET /podpiska/[A-Za-z0-9]+ HTTP\" |~ \" [45][0-9][0-9] \" [$__interval])) or vector(0)","legendFormat":"4xx/5xx","queryType":"range"}]},
    {"id":4,"type":"timeseries","title":"Accepted / rejected VPN connections","gridPos":{"x":12,"y":8,"w":12,"h":8},"datasource":{"type":"loki","uid":"vpn-loki"},"targets":[{"refId":"A","expr":"sum(count_over_time({job=\"x-ui\"} |= \" accepted \" [$__interval])) or vector(0)","legendFormat":"accepted","queryType":"range"},{"refId":"B","expr":"sum(count_over_time({job=\"x-ui\"} |= \"REALITY\" |= \"invalid connection\" [$__interval])) or vector(0)","legendFormat":"rejected","queryType":"range"}]},
    {"id":5,"type":"logs","title":"Latest service warnings and errors","gridPos":{"x":0,"y":16,"w":12,"h":10},"datasource":{"type":"loki","uid":"vpn-loki"},"targets":[{"refId":"A","expr":"{job=~\"nginx|x-ui|system\"} |~ \"(?i)warn|error|failed|invalid|panic\"","queryType":"range"}],"options":{"showTime":true,"wrapLogMessage":true,"sortOrder":"Descending","dedupStrategy":"none"}},
    {"id":6,"type":"logs","title":"Latest subscription requests","gridPos":{"x":12,"y":16,"w":12,"h":10},"datasource":{"type":"loki","uid":"vpn-loki"},"targets":[{"refId":"A","expr":"{job=\"nginx\"} |~ \"GET /podpiska/[A-Za-z0-9]+ HTTP\"","queryType":"range"}],"options":{"showTime":true,"wrapLogMessage":true,"sortOrder":"Descending","dedupStrategy":"none"}}
  ]
}
EOF
  sed -i "s#/podpiska/#${CFG[XUI_SUB_PATH]}#g" /opt/vpn-stack/dashboards-json/overview.json
  chmod 644 /opt/vpn-stack/loki.yaml /opt/vpn-stack/alloy.alloy \
    /opt/vpn-stack/provisioning/datasources/loki.yaml \
    /opt/vpn-stack/provisioning/dashboards/provider.yaml \
    /opt/vpn-stack/dashboards-json/overview.json
  cat > /opt/vpn-stack/grafana.env <<EOF
GF_SECURITY_ADMIN_USER=${CFG[GRAFANA_USERNAME]}
GF_SECURITY_ADMIN_PASSWORD=${CFG[GRAFANA_PASSWORD]}
GF_SERVER_ROOT_URL=https://${CFG[PANEL_DOMAIN]}/logs/
GF_SERVER_SERVE_FROM_SUB_PATH=true
GF_USERS_ALLOW_SIGN_UP=false
EOF
  chmod 600 /opt/vpn-stack/grafana.env
}

managed_container() {
  local name=$1
  ! docker container inspect "$name" >/dev/null 2>&1 || \
    [[ $(docker inspect -f '{{index .Config.Labels "vpn-stack.managed"}}' "$name" 2>/dev/null) == true ]] || \
    die "Контейнер $name существует и не управляется этим установщиком"
}
replace_container() {
  local name=$1
  managed_container "$name"
  if docker container inspect "$name" >/dev/null 2>&1; then docker rm -f "$name" >/dev/null; fi
}

install_logging() {
  write_logging_config
  docker network inspect vpn-logging >/dev/null 2>&1 || docker network create vpn-logging >/dev/null
  docker volume create vpn-loki-data >/dev/null
  docker volume create vpn-grafana-data >/dev/null
  docker volume create vpn-alloy-data >/dev/null
  docker pull "${CFG[LOKI_IMAGE]}"
  docker pull "${CFG[GRAFANA_IMAGE]}"
  docker pull "${CFG[ALLOY_IMAGE]}"
  replace_container vpn-alloy
  replace_container vpn-grafana
  replace_container vpn-loki
  docker run -d --name vpn-loki --label vpn-stack.managed=true --restart unless-stopped \
    --network vpn-logging --memory 700m -v vpn-loki-data:/loki \
    -v /opt/vpn-stack/loki.yaml:/etc/loki/config.yaml:ro \
    "${CFG[LOKI_IMAGE]}" -config.file=/etc/loki/config.yaml >/dev/null
  docker run -d --name vpn-grafana --label vpn-stack.managed=true --restart unless-stopped \
    --network vpn-logging --memory 500m -p 127.0.0.1:3000:3000 \
    --env-file /opt/vpn-stack/grafana.env -v vpn-grafana-data:/var/lib/grafana \
    -v /opt/vpn-stack/provisioning:/etc/grafana/provisioning:ro \
    -v /opt/vpn-stack/dashboards-json:/etc/grafana/dashboards-json:ro \
    "${CFG[GRAFANA_IMAGE]}" >/dev/null
  docker run -d --name vpn-alloy --label vpn-stack.managed=true --restart unless-stopped \
    --network vpn-logging --memory 350m --user 0 \
    -v vpn-alloy-data:/var/lib/alloy/data -v /var/log:/host/var/log:ro \
    -v /opt/vpn-stack/alloy.alloy:/etc/alloy/config.alloy:ro \
    "${CFG[ALLOY_IMAGE]}" run --storage.path=/var/lib/alloy/data /etc/alloy/config.alloy >/dev/null
}

write_final_nginx() {
  local cert="/etc/letsencrypt/live/${CFG[PANEL_DOMAIN]}"
  cat > /etc/nginx/sites-available/vpn-stack <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${CFG[PANEL_DOMAIN]} ${CFG[SUB_DOMAIN]};
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${CFG[PANEL_DOMAIN]};
    ssl_certificate ${cert}/fullchain.pem;
    ssl_certificate_key ${cert}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:VPNSSL:10m;

    location = /logs { return 301 /logs/; }
    location /logs/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    location / {
        proxy_pass http://127.0.0.1:${CFG[XUI_PANEL_PORT]};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${CFG[SUB_DOMAIN]};
    ssl_certificate ${cert}/fullchain.pem;
    ssl_certificate_key ${cert}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ${CFG[XUI_SUB_PATH]} {
        proxy_pass http://127.0.0.1:${CFG[XUI_SUB_PORT]};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
    location / { return 404; }
}
EOF
  ln -sfn /etc/nginx/sites-available/vpn-stack /etc/nginx/sites-enabled/vpn-stack
  rm -f /etc/nginx/sites-enabled/vpn-stack-http
  nginx -t
  systemctl reload nginx
}

configure_firewall() {
  command -v ufw >/dev/null || return 0
  ufw status | grep -q '^Status: active' || return 0
  ufw allow 80/tcp
  ufw allow 443/tcp
  log 'UFW активен: разрешены 80/tcp и 443/tcp. Порты inbound 3x-UI открывайте отдельно.'
}

verify_install() {
  local i
  systemctl is-active --quiet x-ui nginx docker || die 'Одна из системных служб не запущена'
  nginx -t
  for i in {1..30}; do
    curl -fsS http://127.0.0.1:3000/api/health >/dev/null 2>&1 && break
    sleep 2
  done
  curl -fsS http://127.0.0.1:3000/api/health >/dev/null || die 'Grafana не готова'
  curl -fsS -u "${CFG[GRAFANA_USERNAME]}:${CFG[GRAFANA_PASSWORD]}" \
    http://127.0.0.1:3000/api/user >/dev/null || \
    die 'Учётные данные Grafana не подходят (при повторной установке не меняйте их в install.env)'
  for i in {1..30}; do
    docker exec vpn-grafana wget -qO- http://vpn-loki:3100/ready 2>/dev/null | grep -qx ready && break
    sleep 2
  done
  docker exec vpn-grafana wget -qO- http://vpn-loki:3100/ready 2>/dev/null | grep -qx ready || die 'Loki не готов'
  curl -kfsS --resolve "${CFG[PANEL_DOMAIN]}:443:127.0.0.1" \
    "https://${CFG[PANEL_DOMAIN]}${CFG[XUI_WEB_BASE_PATH]}" >/dev/null || die 'Панель не отвечает через nginx'
  curl -kfsS --resolve "${CFG[PANEL_DOMAIN]}:443:127.0.0.1" \
    "https://${CFG[PANEL_DOMAIN]}/logs/login" >/dev/null || die 'Grafana не отвечает через nginx'
}

write_result() {
  cat > /root/vpn-stack-credentials.txt <<EOF
3x-UI: https://${CFG[PANEL_DOMAIN]}${CFG[XUI_WEB_BASE_PATH]}
3x-UI login: ${CFG[XUI_USERNAME]}
3x-UI password: ${CFG[XUI_PASSWORD]}
Subscriptions: https://${CFG[SUB_DOMAIN]}${CFG[XUI_SUB_PATH]}<subscription-id>
Grafana: https://${CFG[PANEL_DOMAIN]}/logs/
Grafana login: ${CFG[GRAFANA_USERNAME]}
Grafana password: ${CFG[GRAFANA_PASSWORD]}
EOF
  chmod 600 /root/vpn-stack-credentials.txt
  log 'Установка завершена. Учётные данные: /root/vpn-stack-credentials.txt (600)'
  cat /root/vpn-stack-credentials.txt
}

main() {
  local dir env_file mode=check
  dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  env_file="$dir/install.env"
  while (($#)); do
    case $1 in
      --check) mode=check; shift;;
      --install) mode=install; shift;;
      --env) (($# >= 2)) || die '--env требует путь'; env_file=$2; shift 2;;
      --help|-h) usage; return 0;;
      *) die "Неизвестная опция: $1";;
    esac
  done
  load_env "$env_file"
  set_defaults
  validate_config
  preflight
  [[ $mode == install ]] || { log 'Проверка завершена; изменений нет. Для установки добавьте --install.'; return; }
  backup_existing
  trap rollback_nginx_on_error ERR
  install_packages
  write_http_bootstrap
  configure_firewall
  issue_certificate
  install_xui
  install_logging
  write_final_nginx
  verify_install
  trap - ERR
  write_result
}

main "$@"
