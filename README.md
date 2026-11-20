# VPN VPS Install

Установщик VPN для Ubuntu VPS. **Vision и XHTTP с REALITY** работают как отдельный сервер или нода 3x-ui с подписками для Happ и INCY. **AmneziaWG и Hysteria 2** работают как отдельный сервер.

## Требования

- Чистый VPS с Ubuntu 22.04, 24.04 или 26.04 LTS, доступом `root` и публичным IPv4.
- Домен с единственной прямой A-записью на IPv4 VPS, без AAAA и DNS-прокси.
- Открытые TCP/80, TCP/443 и порт SSH. Для Hysteria 2 нужен UDP/443, для AmneziaWG — UDP-порт из итогового отчёта.

## Установка

Вставьте блок целиком в SSH-терминал от `root`. Git не требуется.

```bash
(
  set -e
  if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'Запустите этот блок от root.' >&2
    exit 1
  fi

  if ! command -v curl >/dev/null || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    apt-get -o DPkg::Lock::Timeout=300 update
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 \
      install -y --no-install-recommends curl ca-certificates
  fi

  revision=v1.1.0
  workdir=$(mktemp -d)
  trap 'rm -rf -- "$workdir"' EXIT
  curl -q --fail --silent --show-error --location --retry 3 --connect-timeout 10 \
    --proto '=https' --proto-redir '=https' \
    "https://github.com/yazmann/vpn-vps-install/archive/$revision.tar.gz" \
    --output "$workdir/source.tar.gz"
  tar -xzf "$workdir/source.tar.gz" -C "$workdir" --strip-components=1 \
    --no-same-owner --no-same-permissions
  cd "$workdir"
  chmod u+x ./install-xhttp-vps.sh
  bash ./install-xhttp-vps.sh
)
```

Перед закрытием первой SSH-сессии проверьте вход во втором терминале.

[Настройки, обновление и восстановление](docs/DETAILS.md) · [История изменений](docs/CHANGELOG.md)
