# Автономная установка VPN-стека

`install-vpn-stack.sh` устанавливает на чистый Debian/Ubuntu:

- 3x-UI с SQLite;
- nginx и сертификат Let's Encrypt для панели и подписок;
- Grafana, Loki и Alloy в Docker;
- сбор логов nginx, 3x-UI/Xray, SSH и системы;
- готовый дашборд `3x-UI Server Overview`;
- HTTPS-доступ к панели без внутренних портов.

Внутренние порты панели, подписок, Grafana и Loki привязываются к localhost или внутренней Docker-сети. Публично nginx использует только `80/tcp` и `443/tcp`. Порты созданных VPN inbound скрипт не угадывает и не открывает.

## Подготовка

Создайте две A-записи, указывающие на новый сервер:

```text
panel.example.com -> IP сервера
vpn.example.com   -> IP сервера
```

Не включайте проксирование Cloudflare. Удалите старые AAAA-записи, если IPv6 на сервере не настроен.

Подготовьте конфигурацию:

```bash
cd "/путь/vpn server"
cp install.env.example install.env
chmod 600 install.env
nano install.env
```

Пароли не передавайте аргументами команд. Файл `install.env` не исполняется как shell-код.

## Проверка и установка

```bash
sudo bash install-vpn-stack.sh --check
sudo bash install-vpn-stack.sh --install
```

Для другого файла настроек:

```bash
sudo bash install-vpn-stack.sh --check --env /root/server.env
sudo bash install-vpn-stack.sh --install --env /root/server.env
```

После установки адреса и пароли сохраняются в `/root/vpn-stack-credentials.txt` с правами `600`.

## Восстановление пользователей

Скопируйте резервную копию базы на целевой сервер и задайте:

```text
RESTORE_XUI_DB=/root/x-ui.db
```

Установщик восстановит базу, а затем заменит только параметры веб-панели и подписок на значения нового сервера. Inbound-порты и пользователи останутся из резервной копии. Перед переносом базы штатно остановите 3x-UI на источнике либо используйте встроенное резервное копирование панели.

## Повторный запуск и резервные копии

Скрипт можно запускать повторно. Перед изменениями создаётся каталог `/var/backups/vpn-stack/<UTC-время>`. Чужие Docker-контейнеры с совпадающими именами не удаляются. Управляемые контейнеры отмечены label `vpn-stack.managed=true`.

При повторном запуске сохраняйте прежние `GRAFANA_USERNAME` и `GRAFANA_PASSWORD`: bootstrap-переменные не переименовывают уже созданного пользователя в существующем Docker volume.

Установщик не меняет DNS, SSH, VPN inbound и правила маршрутизации. При активном UFW разрешаются только `80/tcp` и `443/tcp`; порты VPN нужно разрешить после создания inbound.

## Проверка состояния

```bash
systemctl status x-ui nginx docker
docker ps --filter label=vpn-stack.managed=true
nginx -t
curl -I https://panel.example.com/
```

Grafana доступна по `https://PANEL_DOMAIN/logs/`. Логи по умолчанию хранятся семь дней.
