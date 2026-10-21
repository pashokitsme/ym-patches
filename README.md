# ym-patches

Локальные патчи для десктопных клиентов Яндекс Мессенджера на macOS.

## telemost — Yandex Telemost (Qt 6.8 + QtWebEngine)

![Шапка окна после патча](docs/screenshot.png)

Что меняет:

| | До | После |
|---|---|---|
| Превью ссылок | Клиент запрашивает превью для каждой ссылки и рисует карточку (когда сервер разрешает) | Не запрашивает и не рисует нигде: ни в чате, ни во вкладке «Ссылки» |
| Рамка окна | Чёрная рамка 12px со скруглением вокруг всего интерфейса | Интерфейс до краёв окна |
| Заголовок окна | Системный titlebar 28pt над контентом | Прозрачный titlebar, контент под ним, кнопки окна в шапке сайдбара на одной линии с аватаркой |
| Перетаскивание окна | За titlebar | За верхнюю полосу 56pt, двойной клик — zoom |

### Как устроено

Телемост — нативное Qt-приложение. Чат — веб-бандл Яндекс Мессенджера (`ychat://files/index.html`), зашитый в Qt-ресурсы бинарника и открытый в `QWebEnginePage`. Минифицированный JS меняется с каждой сборкой, поэтому бандл не правится. Вместо этого в процесс подгружается свой dylib:

1. **`insert_dylib.py`** добавляет `LC_LOAD_DYLIB @executable_path/../Frameworks/TelemostTweaks.dylib` в оба слайса (arm64, x86_64) главного бинарника.
2. **`tweaks.mm`** → `TelemostTweaks.dylib`:
   - через `__DATA,__interpose` перехватывает конструкторы `QWebEnginePage` и кладёт в `page->scripts()` скрипт `tweaks.js` (`DocumentCreation`, main world);
   - для главного окна (`QNSWindow` с заголовком «Telemost») включает `NSWindowStyleMaskFullSizeContentView` и прозрачный titlebar, переносит кнопки окна и ставит монитор событий для перетаскивания;
   - обнуляет `safeAreaInsets` у `QNSView` этого окна: Qt 6.8 вычитает safe area из layout виджетов, без этого веб-вью остаётся на 28pt ниже.
3. **`tweaks.js`**:
   - превью ссылок в бандле гейтятся селектором `e => a(e, "url_previews_enabled")`, который читает `state.config.degradation.url_previews_enabled` — серверный kill-switch Яндекса (поэтому превью то есть, то нет). Скрипт ловит инициализацию webpack-рантайма (`webpackChunk_yandex_int_messenger.push`), оборачивает `__webpack_require__.d` и подменяет экспорт-функцию, тело которой содержит `"url_previews_enabled"`, на `() => false`. Поиск идёт по строке протокола, а не по минифицированным именам. Этот же селектор стоит и перед запросом (`preview/update` thunk), и перед рендером, так что сеть не трогается вообще;
   - CSS: убирает `padding` у `.yamb-root__content_window-frame` и скругление у `.yamb-root__layout`, сдвигает `.yamb-sidebar-navigation-header__identity` вправо под кнопки окна, на всякий случай прячет `.yamb-url-preview`.
4. **Подпись.** После правки бинарника подпись Яндекса недействительна, а arm64-бинарник без валидной подписи ядро убивает. `patch.sh` переподписывает бандл ad-hoc **без hardened runtime**: с ним library validation не дала бы загрузить Qt-фреймворки Яндекса (Team ID `477EAT77S3`) рядом с ad-hoc бинарником. Entitlements сохраняются.

### Установка

```bash
cd telemost && ./install.sh
```

`install.sh` собирает dylib (нужны Xcode CLT и заголовки Qt из Homebrew: `brew install qt`), копирует всё в `~/Library/Application Support/TelemostTweaks`, патчит Телемост и регистрирует LaunchAgent `local.telemost-tweaks`.

### Обновления Телемоста

LaunchAgent следит (`WatchPaths`) за `Contents/MacOS/Yandex.Telemost` и `Contents/Info.plist`. Когда обновление подменяет бинарник, агент запускает `patch.sh`. Тот:
- ждёт, пока апдейтер допишет бандл;
- бэкапит оригинальный бинарник и `_CodeSignature` в `~/Library/Application Support/TelemostTweaks/backup/<CFBundleVersion>/`;
- вставляет dylib и переподписывает;
- если Телемост в этот момент запущен, показывает уведомление «перезапусти».

Проверено симуляцией: `patch.sh --restore` вернул оригинальный бинарник, через ~7 секунд агент перепатчил его сам.

Если новая версия сломает якоря:
- превью: в консоли страницы `window.__telemostTweaks.requireHooked` будет `false`;
- окно: в логе не будет строк `chrome applied` / `safeAreaInsets hooked`.

### Отладка

- Лог: `~/Library/Logs/TelemostTweaks.log`.
- Править CSS/JS без пересборки: положи свой вариант в `~/Library/Application Support/TelemostTweaks/tweaks.js`, он имеет приоритет над вшитым.
- DevTools: запусти `QTWEBENGINE_REMOTE_DEBUGGING=127.0.0.1:9333 /Applications/Yandex.Telemost.app/Contents/MacOS/Yandex.Telemost` и открой `http://127.0.0.1:9333`.

### Откат

```bash
cd telemost && ./install.sh --uninstall
```

Удаляет агент и возвращает оригинальный бинарник с подписью Яндекса (из бэкапа текущей версии).

### Побочные эффекты ad-hoc подписи

- macOS может заново спросить доступ к камере, микрофону и записи экрана: TCC привязан к подписи.
- Keychain может спросить доступ к сохранённым ключам. Ответь «Всегда разрешать».

### Известное

- На широком окне Телемост показывает слева рейку папок, и кнопки окна ложатся на неё. Не исправлено.
