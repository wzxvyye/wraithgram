# Wraithgram — сборка и проверка

Это форк **Wraithgram** (неофициальный клиент Telegram для iOS) на исходниках Telegram iOS 13.1.1.
В проекте уже сделано:

- приложение и его расширения называются **Wraithgram**;
- основная иконка заменена на `Wraithgram.png` (1024×1024, без альфа-канала);
- пользовательские тексты в `Wraithgram/Strings/*` и `InfoPlist.strings` заменены на Wraithgram;
- IPA теперь называется `Wraithgram.ipa`;
- добавлен скрипт проверки `tools/verify_wraithgram.py`.

Все технические имена переименованы под Wraithgram: папка исходников — `Wraithgram/`, идентификатор
`org.wraithgram.app`, URL-схемы `wraithgram://` и `wg://`. Внутренние префиксы модулей (`WGCore`,
`WGHooks`, `WGSettingsUI` и т. п.) оставлены как есть — это внутренние имена кода, они не видны
пользователю и не влияют на бренд приложения.

---

## 1. Проверка на Windows (без Mac)

Нужен только Python 3. В папке проекта:

```powershell
python tools\verify_wraithgram.py
```

Скрипт проверяет:

- иконка существует, 1024×1024, без прозрачности, `Contents.json` ссылается на неё;
- в `Telegram/BUILD` имя приложения и расширений — Wraithgram;
- в строках и `InfoPlist.strings` не осталось пользовательского «Wraithgram»;
- строковые таблицы Swift не устарели (`Wraithgram/Strings/check.py`).

Ожидаемый результат в конце:

```text
OK: name, icon and string tables are consistent.
```

Это статическая проверка. Собрать `.ipa` на Windows нельзя: iOS-приложения собираются только
macOS + Xcode. **Visual Studio и его плагины для этого не подходят.**

---

## 2. Сборка IPA без Mac (GitHub Actions)

Если Mac нет, `.ipa` можно собрать на бесплатном macOS-раннере GitHub. Готовый репозиторий
лежит в `D:\Users\wzxvyye\Desktop\wraithgram-ci`; там же — пошаговая инструкция в `README.md`.

Коротко:

1. Создайте **публичный** пустой репозиторий на GitHub.
2. Загрузите в него **содержимое** папки `wraithgram-ci` (включая `.github` и `overlay`).
3. Откройте **Actions → Wraithgram IPA → Run workflow**.
4. Через 1–3 часа скачайте артефакт **Wraithgram-ipa** — внутри `Wraithgram.ipa`.
5. Установите его через **Sideloadly** или **AltStore**, подписав своим Apple ID.

Workflow скачивает upstream WraithGram, накладывает 82 файла брендинга из `overlay/` и собирает
**unsigned** IPA с фейковой подписью — ровно так же, как это делает upstream CI. Mac, Xcode и
Apple Developer account не нужны. Репозиторий должен быть публичным: для приватных macOS-минуты
считаются с коэффициентом ×10.

Если у вас уже есть готовый `.ipa` WraithGram (не из App Store), компиляция вообще не нужна:

```powershell
python -m pip install pillow
python tools\rebrand_ipa.py "C:\путь\Wraithgram.ipa"
```

Скрипт заменит имя и иконки и создаст `Wraithgram.ipa`.

---

## 3. Что установить для сборки

- Mac (Apple Silicon или Intel) с macOS, на которой работает Xcode;
- **Xcode 27.1** и macOS 27 — именно это закреплено в `versions.json`;
- Python 3;
- интернет: Bazel скачается сам при первом запуске.

Другие версии Xcode могут собраться, но проект рассчитан на 27.1. Если Xcode другой, скрипты
используют `--overrideXcodeVersion`, однако совместимость не гарантируется.

---

## 4. Конфигурация

Скопируйте шаблон:

```sh
cp build-system/wraithgram-configuration.example.json build-system/wraithgram-configuration.json
```

Откройте `build-system/wraithgram-configuration.json` и заполните:

- `api_id` и `api_hash` — получите свои на <https://my.telegram.org> (нельзя использовать чужие);
- `team_id` — ваш Apple Team ID;
- `bundle_id` — ваш уникальный идентификатор, например `com.вашеимя.wraithgram`.

Для быстрой проверки **в симуляторе** без своего Apple-аккаунта можно использовать фейковую подпись:

```json
{
  "bundle_id": "ph.telegra.Telegraph",
  "team_id": "C67CF9S4VU",
  "api_id": "ваш api_id",
  "api_hash": "ваш api_hash",
  "app_center_id": "0",
  "is_internal_build": "false",
  "is_appstore_build": "false",
  "appstore_id": "0",
  "app_specific_url_scheme": "tg",
  "premium_iap_product_id": "",
  "enable_siri": false,
  "enable_icloud": false
}
```

`ph.telegra.Telegraph` / `C67CF9S4VU` — это данные фейковых профилей из
`build-system/fake-codesigning`. Они годятся только для симулятора.

---

## 5. Сборка и запуск в симуляторе

Из корня проекта:

```sh
build-system/WGBuild.sh
```

Скрипт сам скачает Bazel, применит патчи и соберёт `debug_sim_arm64`.

Затем установите сборку в загруженный симулятор:

```sh
# открыть Simulator и загрузить устройство, если оно ещё не запущено
open -a Simulator

# распаковать свежий IPA и поставить приложение
STAGE=$(mktemp -d)
unzip -q -o bazel-bin/Telegram/Telegram.ipa -d "$STAGE"
xcrun simctl install booted "$STAGE/Payload/Wraithgram.app"
xcrun simctl launch booted ph.telegra.Telegraph
```

Проверьте на экране:

1. под иконкой написано **Wraithgram**, иконка — призрак из вашего PNG;
2. приложение запускается и показывает экран входа;
3. в **Настройки → Wraithgram** открывается меню, заголовок «Wraithgram».

Если имя или иконка не изменились, значит установилась старая сборка. Удалите приложение из
симулятора и повторите установку, либо используйте свежий `bazel-bin/Telegram/Telegram.ipa`
(не `Telegram_archive-root/` — он может быть устаревшим).

---

## 6. Сборка IPA для iPhone

Нужны настоящие сертификат и provisioning profiles для вашего `bundle_id`:

- положите distribution-сертификат `.p12` (пустой пароль) в
  `build-system/wraithgram-codesigning/certs`;
- положите профили приложения и всех расширений в
  `build-system/wraithgram-codesigning/profiles`;
- соберите:

```sh
build-system/WGBuildRelease.sh 1
```

Результат: `build-output/ipa/Wraithgram.ipa`.

Установка на iPhone:

- через **TestFlight** (нужен Apple Developer Program) — `build-system/WGUploadTestFlight.sh`;
- через **Sideloadly / AltStore** на Windows или Mac — ими можно подписать IPA вашим Apple ID;
- через Xcode: `Window → Devices and Simulators → +`.

Для бесплатного Apple ID приложению нужен **уникальный bundle id**, поэтому надёжнее всего
платный Apple Developer Program и свои профили. Если своего Mac нет, те же команды выполняются
на арендованном Mac (MacinCloud, Mac mini в облаке) или на macOS-раннере GitHub Actions.

---

## 7. Полезные команды

```sh
# проверить брендинг (Windows/macOS)
python3 tools/verify_wraithgram.py

# перегенерировать строки после правки JSON
python3 Wraithgram/Strings/generate.py

# проверить строки
python3 Wraithgram/Strings/check.py --no-upstream --allow-unused

# симулятор
build-system/WGBuild.sh

# IPA с подписью
build-system/WGBuildRelease.sh 1
```

---

## 8. Юридические заметки

- Используйте **свой** `api_id`/`api_hash` с my.telegram.org.
- Не называйте приложение Telegram и не используйте его логотип.
- Проект распространяется по GNU GPL v2; исходники изменённого клиента нужно публиковать.
- Это неофициальный клиент, не связанный с Telegram.
