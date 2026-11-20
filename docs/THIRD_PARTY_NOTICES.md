# Сторонние компоненты и товарные знаки

Этот репозиторий содержит независимый установщик и конфигуратор. Он не является официальным проектом, совместной разработкой или продуктом, одобренным авторами перечисленного ниже программного обеспечения и сервисов.

Упоминание названий используется только для описания совместимости и действий установщика. Все товарные знаки, названия проектов и логотипы принадлежат их соответствующим владельцам.

## Используемые проекты и сервисы

- [3x-ui](https://github.com/MHSanaei/3x-ui) — сторонняя панель, которую скрипт загружает из официального репозитория проекта. Лицензия: [GNU GPL v3](https://github.com/MHSanaei/3x-ui/blob/master/LICENSE). Авторы этого установщика не заявляют авторских прав на 3x-ui.
- [Xray-core](https://github.com/XTLS/Xray-core) — стороннее сетевое ядро, используемое 3x-ui. Лицензия: [Mozilla Public License 2.0](https://github.com/XTLS/Xray-core/blob/main/LICENSE).
- [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) — модуль ядра и утилиты из официального PPA Amnezia.
- [Hysteria 2](https://github.com/HyNetworks/hysteria) — отдельная служба QUIC. Лицензия [MIT](https://github.com/HyNetworks/hysteria/blob/master/LICENSE).
- [INCY link encoder](https://github.com/INCY-DEV/incy-link-encoder) описывает совместимый формат crypt1 и публикует общий ключ приложения. Установщик использует этот формат с системной библиотекой Node.js.
- [Cloudflare WARP](https://www.cloudflare.com/application/terms/) — сторонний сервис Cloudflare. Этот проект лишь автоматизирует настройку поддерживаемой 3x-ui интеграции и не связан с Cloudflare. Пользователь самостоятельно отвечает за соблюдение применимых условий сервиса и его доступность в своей юрисдикции.
- [NGINX](https://github.com/nginx/nginx), Ubuntu и системные пакеты устанавливаются из репозиториев операционной системы и сохраняют собственные лицензии и условия распространения.
- Профили клиентской маршрутизации HAPP и INCY загружаются при установке из независимого проекта [hydraponique/roscomvpn-routing](https://github.com/hydraponique/roscomvpn-routing). Этот установщик не является частью RoscomVPN и не заявляет авторских прав на его правила или списки.

Сам установщик не изменяет лицензии сторонних компонентов. При изменении способа загрузки, включении сторонних файлов непосредственно в репозиторий или публичном распространении готовых образов следует повторно проверить требования соответствующих лицензий и условий сервисов.

## Фотографии сайта-заглушки

Установщик скачивает выбранную фотографию на VPS. Фотографии распространяются по [Unsplash License](https://unsplash.com/license).

| Тема | Автор | Источник |
|---|---|---|
| Engineering consultancy | Dave Meckler | [Unsplash](https://unsplash.com/photos/xYeGSXRhV80) |
| Digital infrastructure | Eric Stoynov | [Unsplash](https://unsplash.com/photos/k27hkqXuveo) |
| Logistics and operations | Bernd Dittrich | [Unsplash](https://unsplash.com/photos/F2C_mSrb6iM) |
| Architecture studio | Grigorii Shcheglov | [Unsplash](https://unsplash.com/photos/A9HNu8LiHQc) |
| Industrial service | TECNIC Bioprocess Solutions | [Unsplash](https://unsplash.com/photos/VFrbWve7eAs) |
