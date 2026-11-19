# VPN VPS Install

Установщик VPN для Ubuntu VPS. Поддерживает Vision и XHTTP с REALITY, AmneziaWG (AWG) и Hysteria 2. Для подписок Vision и XHTTP рекомендуются [Happ](https://www.happ.su/) и [INCY](https://incy.cc/).

| Пункт | Транспорт | Порт | Режим |
|---|---|---|---|
| 1 | Vision + REALITY Self-steal | TCP/443 | Самостоятельный сервер или нода 3x-ui |
| 2 | XHTTP + REALITY Self-steal | TCP/443 | Самостоятельный сервер или нода 3x-ui |
| 3 | AmneziaWG с поддержкой протокола 3.1 и новее | Выбранный установщиком UDP-порт | Самостоятельный сервер |
| 4 | Hysteria 2 | UDP/443 | Самостоятельный сервер |

## Что входит

- Последние стабильные релизы 3x-ui, Xray-core и Hysteria 2 загружаются при установке с проверкой SHA-256. AmneziaWG и системные пакеты устанавливаются через APT.
- Nginx cover-site и сертификат Let's Encrypt.
- Полное обновление всех установленных пакетов свежего Ubuntu VPS перед настройкой VPN.
- UFW, Fail2ban, BBR, выбираемая SSH-политика и обновления безопасности.
- Основной вариант SSH — новый sudo-пользователь с сертификатом. Мастер проверяет второй вход до отключения прямого входа `root` и паролей. Можно выбрать вход по ключу или паролю и отдельно ограничить SSH одним IPv4.
- Опционально можно включить 2FA панели с подтверждением в 3x-ui, перенести SSH на высокий порт после проверки входа и выключить ответы на IPv4 ping.
- По умолчанию исправления безопасности Ubuntu устанавливаются ежедневно в 05:30. По воскресеньям в это же окно обновляются пакеты APT, удаляются ненужные зависимости и проверяются стабильные релизы VPN-компонентов выбранного транспорта. При необходимости сервер перезагружается после обслуживания. Часовой пояс по умолчанию — `Europe/Moscow`.
- Для Vision и XHTTP доступны подписки HAPP, INCY и Mihomo, опциональный WARP и панель с доступом через localhost по умолчанию.
- Ссылки HAPP и INCY формируются в зашифрованных форматах приложений по умолчанию. Этот выбор можно изменить в мастере.
- По умолчанию ссылка на встроенную страницу профиля скрыта, ответы подписок запрещено кешировать. Доступен зашифрованный экспорт резервной копии.
- Пункт `Install standalone VPN and import VLESS users from a 3x-ui SQLite backup` переносит пользователей выбранного VLESS inbound на новый VPS.
- Для AmneziaWG и Hysteria 2 установщик создаёт отдельный клиентский профиль.
- Проверка/восстановление, удаление без архива и профиль снижения расхода памяти.

## Требования

Обязательно:

- Чистый Ubuntu 22.04, 24.04 или 26.04 LTS с systemd на `x86_64`, `arm64`, `armv7l` или `s390x`. CI проверяет все три выпуска.
- Root-доступ, публичный IPv4 и доступ VPS в Интернет.
- Домен с единственной прямой A-записью на IPv4 VPS, без AAAA и DNS-прокси.
- Свободные и доступные извне TCP/80, TCP/443 и текущий порт SSH.
- Для Hysteria 2 откройте UDP/443 в firewall провайдера. Для AmneziaWG откройте UDP-порт, указанный в итоговых настройках. Ядро VPS должно поддерживать загрузку модуля DKMS AmneziaWG и иметь доступные заголовки.
- Отсутствие установленных 3x-ui, Nginx, ACME и настроенного UFW.

Для режима SSH по умолчанию подготовьте открытый Ed25519-ключ CA и подписанный пользовательский сертификат. Белые списки SSH и панели, WARP и Tailscale настраиваются по выбору.

## Установка

Вставьте весь блок в SSH-терминал от `root`. Он подходит для минимальных образов Ubuntu. При необходимости блок установит `curl` и корневые сертификаты, скачает архив стабильной версии и запустит мастер. Git для этого не нужен. Для проверки конкретного коммита можно указать его полный SHA вместо тега.

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

  revision=v1.0.0
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

Для тестовой установки на чистом VPS используйте `bash ./install-xhttp-vps.sh --staging` в последней строке блока. Мастер проверит DNS и выполнит HTTP-01 через [Let’s Encrypt staging](https://letsencrypt.org/docs/staging-environment/). Для HTTPS-проверок мастер использует отдельный набор тестовых корневых сертификатов. Браузерам и VPN-клиентам для проверки TLS в этом режиме требуется отдельное тестовое хранилище доверия.

## Команды

На уже настроенном VPS запустите актуальный установщик из репозитория и выберите `4) Refresh automatic maintenance`. Установщик обновит обслуживание с учётом ранее выбранного режима.

Для зашифрованного экспорта данных выберите `5) Export an encrypted recovery backup`. Скопируйте выданный архив с VPS и отдельно сохраните его парольную фразу.

```bash
# Открыть меню и показать сохранённые настройки
sudo /root/install-xhttp-vps.sh

# Продолжить или восстановить установку
sudo /root/finish-xhttp-vps.sh

# Применить профиль снижения расхода памяти для Vision или XHTTP
sudo bash /root/optimize-xhttp-memory.sh
```

Удаление выполняется через пункт `3` меню установленного сервера и не создаёт архив. Перед закрытием первой SSH-сессии обязательно проверьте вход выбранным администратором во втором терминале.

[Подробная документация](docs/DETAILS.md) · [Безопасность](SECURITY.md) · [История изменений](CHANGELOG.md) · [Лицензии компонентов](THIRD_PARTY_NOTICES.md)
