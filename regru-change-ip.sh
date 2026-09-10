#!/usr/bin/env bash
# REG.API v2: replace matching IPv4 A records in one DNS zone.
set +x
set -Eeuo pipefail
umask 077
API=https://api.reg.ru/api/regru2/zone
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'EOF'
bash regru-change-ip.sh DOMAIN OLD_IP NEW_IP [опции]
  --credentials FILE   JSON-файл с username и password для API REG.RU
  --check              Показать план без изменения DNS
  --record NAME        Только одно имя: @, www, vpn, *.vpn; иначе вся зона
  --backup-dir DIR     Каталог снимков (по умолчанию ./regru-backups)
Можно передать REGRU_USERNAME и REGRU_PASSWORD через окружение.
Укажите старый и новый IPv4.
По умолчанию выполняется замена. DNS зоны должен обслуживаться REG.RU.
EOF
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
dependencies() {
  local c missing=no
  for c in curl jq; do command -v "$c" >/dev/null || missing=yes; done
  if [[ $missing == yes ]]; then
    local -a runner=()
    command -v apt-get >/dev/null || die 'Установите curl и jq'
    if ((EUID != 0)); then
      command -v sudo >/dev/null && sudo -n true || die 'Для автоустановки curl/jq нужен root или sudo без пароля'
      runner=(sudo -n)
    fi
    "${runner[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update >&2
    "${runner[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y curl jq ca-certificates >&2
  fi
}
api() {
  local method=$1 params=$2 response=$3 rc=0
  jq -s '.[0] + .[1]' "$WORK/auth.json" "$params" > "$WORK/request.json"
  # Credentials are in a private file, never in curl argv or a GET URL.
  curl --silent --show-error --fail --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 60 --request POST \
    --data-urlencode input_format=json --data-urlencode output_format=json \
    --data-urlencode "input_data@$WORK/request.json" \
    --output "$response" "$API/$method" || rc=$?
  rm -f "$WORK/request.json"
  if ((rc)); then log "API $method: ошибка транспорта ($rc); результат запроса может быть неопределённым"; return 1; fi
  if ! jq -e --arg domain "$DOMAIN" '
    .result == "success" and
    (.answer.domains | type == "array") and
    ([.answer.domains[] | select((.dname | ascii_downcase | rtrimstr(".")) == $domain)] |
      length == 1 and all(.[]; .result == "success"))
    ' "$response" >/dev/null 2>&1; then
    log "API $method: REG.RU вернул ошибку или неизвестный формат ответа (тело с данными не выводится)"
    return 1
  fi
}
fetch() {
  local output=$1
  api get_resource_records "$WORK/base.json" "$WORK/response.json" || return 1
  jq -e --arg domain "$DOMAIN" '
    .answer.domains[] | select((.dname | ascii_downcase | rtrimstr(".")) == $domain) |
    {dname, soa, rrs} |
    if (.rrs | type) != "array" then error("Missing rrs") else . end |
    if all(.rrs[]; (.rectype|type)=="string" and (.subname|type)=="string" and (.content|type)=="string")
    then . else error("Invalid record schema") end |
    .rrs |= map(.subname |= if . == "" then "@" else . end)
    ' "$WORK/response.json" > "$output" || return 1

}
normalize() {
  jq -S '[.rrs[] | {rectype, subname, content}] | unique | sort_by(.rectype,.subname,.content)' "$1"
}
same_records() {
  normalize "$1" > "$WORK/left.json"
  normalize "$2" > "$WORK/right.json"
  cmp -s "$WORK/left.json" "$WORK/right.json"
}
mutate() {
  local action=$1 name=$2 original
  # Re-read before each write; stop if another actor has changed the zone.
  fetch "$WORK/fresh.json" || die 'Не удалось перечитать зону перед изменением'
  same_records "$WORK/current.json" "$WORK/fresh.json" || die 'Зона изменилась параллельно. Остановлено; проверьте backup и повторите запуск'
  if [[ $action == add_alias ]]; then
    jq --arg name "$name" --arg ip "$NEW" '. + {subdomain:$name, ipaddr:$ip}' "$WORK/base.json" > "$WORK/params.json"
    jq --arg name "$name" --arg ip "$NEW" --arg type "$TYPE" '.rrs += [{rectype:$type,subname:$name,content:$ip}]' "$WORK/current.json" > "$WORK/expected.json"
  else
    # content is mandatory here: never delete all A records for a name.
    original=$(jq -r --arg name "$name" --arg ip "$OLD" --arg type "$TYPE" '[.rrs[] | select(.rectype==$type and .subname==$name and .content==$ip) | (.original_content // .content)][0]' "$WORK/current.json")
    [[ -n $original && $original != null ]] || die 'Старая запись исчезла'
    jq --arg name "$name" --arg ip "$original" --arg type "$TYPE" '. + {subdomain:$name, record_type:$type, content:$ip}' "$WORK/base.json" > "$WORK/params.json"
    jq --arg name "$name" --arg ip "$OLD" --arg type "$TYPE" '.rrs |= map(select((.rectype==$type and .subname==$name and .content==$ip)|not))' "$WORK/current.json" > "$WORK/expected.json"
  fi
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$action" "$name" >> "$BACKUP/operations.tsv"
  # Never blindly retry writes. On timeout, inspect actual API state.
  if ! api "$action" "$WORK/params.json" "$WORK/write-response.json"; then
    log 'Проверяется, было ли изменение всё-таки применено...'
  fi
  fetch "$WORK/after.json" || die "Результат изменения неизвестен. Повторный запуск перечитает зону. Backup: $BACKUP"
  cp "$WORK/after.json" "$BACKUP/last-observed.json"
  same_records "$WORK/expected.json" "$WORK/after.json" || die "Фактическая зона не совпадает с ожидаемой. Возможен частичный перенос. Backup: $BACKUP"
  cp "$WORK/after.json" "$WORK/current.json"
  printf '%s\tverified\t%s\n' "$(date -u +%FT%TZ)" "$name" >> "$BACKUP/operations.tsv"
}
main() {
  [[ ${1:-} != --help && ${1:-} != -h ]] || { usage; return; }
  (($# >= 3)) || { usage; exit 2; }
  DOMAIN=${1,,}; DOMAIN=${DOMAIN%.}; OLD=$2; NEW=$3; shift 3
  local credentials='' check=no only='' backup_root=./regru-backups label mode name change
  while (($#)); do
    case $1 in
      --check) check=yes; shift;;
      --credentials|--record|--backup-dir)
        (($# >= 2)) || die "Нет значения $1"
        case $1 in --credentials) credentials=$2;; --record) only=$2;; --backup-dir) backup_root=$2;; esac
        shift 2;;
      *) die "Неизвестный параметр $1";;
    esac
  done
  TYPE=A
  valid_ip "$OLD" && valid_ip "$NEW" || die 'Укажите корректные IPv4 без ведущих нулей'
  [[ $OLD != "$NEW" ]] || die 'Исходный и целевой IP совпадают'
  [[ ${#DOMAIN} -le 253 && $DOMAIN == *.* && $DOMAIN != *..* ]] || die 'Укажите доменную зону, например example.com'
  local -a labels
  IFS=. read -r -a labels <<< "$DOMAIN"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die 'Домен должен быть в ASCII/Punycode без схемы и пути'
  done
  dependencies
  WORK=$(mktemp -d)
  trap 'rm -rf -- "$WORK"' EXIT
  if [[ -n $credentials ]]; then
    [[ -f $credentials && ! -L $credentials ]] || die 'Файл credentials не найден или является symlink'
    mode=$(stat -c %a "$credentials")
    (( (8#$mode & 077) == 0 )) || die 'Выполните chmod 600 для файла credentials'
    jq -e '{username,password} | select((.username|type)=="string" and (.password|type)=="string" and (.username|length)>0 and (.password|length)>0)' "$credentials" > "$WORK/auth.json" || die 'Нужен JSON с непустыми username и password'
  else
    [[ -n ${REGRU_USERNAME:-} && -n ${REGRU_PASSWORD:-} ]] || die 'Задайте --credentials FILE или REGRU_USERNAME/REGRU_PASSWORD'
    export -n REGRU_USERNAME REGRU_PASSWORD
    printf %s "$REGRU_USERNAME" > "$WORK/username"
    printf %s "$REGRU_PASSWORD" > "$WORK/password"
    unset REGRU_USERNAME REGRU_PASSWORD
    jq -n --rawfile u "$WORK/username" --rawfile p "$WORK/password" '{username:$u,password:$p}' > "$WORK/auth.json"
    rm -f "$WORK/username" "$WORK/password"
  fi
  jq -n --arg domain "$DOMAIN" '{domains:[{dname:$domain}],output_content_type:"plain",output_format:"json"}' > "$WORK/base.json"
  fetch "$WORK/current.json" || die 'Не удалось прочитать зону. Проверьте доступ к API, пароль, разрешённый IP и DNS-серверы домена'
  jq -n --arg old "$OLD" --arg new "$NEW" '[{type:"A",old:$old,new:$new}]' > "$WORK/pairs.json"
  jq --slurpfile pairs "$WORK/pairs.json" --arg only "$only" '.rrs as $rrs |
    [$pairs[0][] as $p | $p + {names:([$rrs[] | select(.rectype==$p.type and .content==$p.old and ($only=="" or .subname==$only)) | .subname] | unique)} | select(.names|length>0)]' "$WORK/current.json" > "$WORK/changes.json"
  if [[ $(jq length "$WORK/changes.json") == 0 ]]; then
    log 'Подходящих A-записей со старыми IP нет. Ничего не изменено.'; return
  fi
  log "План: $DOMAIN"
  jq -r '.[] | . as $p | .names[] | "  \($p.type) \(.)  \($p.old) → \($p.new)"' "$WORK/changes.json" >&2
  [[ $check != yes ]] || { log 'Только проверка; DNS не изменён.'; return; }
  mkdir -p -- "$backup_root"
  BACKUP=$(mktemp -d "$backup_root/$DOMAIN-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
  cp "$WORK/current.json" "$BACKUP/before.json"
  jq -n --arg domain "$DOMAIN" --slurpfile changes "$WORK/changes.json" \
    '{domain:$domain,changes:$changes[0]}' > "$BACKUP/plan.json"
  log "Снимок зоны: $BACKUP/before.json"
  while IFS= read -r change; do
    TYPE=$(jq -r .type <<< "$change"); OLD=$(jq -r .old <<< "$change"); NEW=$(jq -r .new <<< "$change")
    while IFS= read -r name; do
      if ! jq -e --arg name "$name" --arg ip "$NEW" --arg type "$TYPE" 'any(.rrs[]; .rectype==$type and .subname==$name and .content==$ip)' "$WORK/current.json" >/dev/null; then
        mutate add_alias "$name"
      fi
      mutate remove_record "$name"
      log "Готово: $TYPE $name.$DOMAIN → $NEW"
    done < <(jq -r '.names[]' <<< "$change")
  done < <(jq -c '.[]' "$WORK/changes.json")
  fetch "$WORK/final.json" || die 'Не удалось выполнить итоговую проверку'
  same_records "$WORK/current.json" "$WORK/final.json" || die 'Зона изменилась после последней операции'
  cp "$WORK/final.json" "$BACKUP/after.json"
  log 'Все запланированные A-записи заменены и проверены через API. DNS-кэши обновятся согласно TTL.'
}
main "$@"
