# Как помочь проекту

Спасибо за интерес к TouTou! Ниже — короткий путь от идеи до pull request.

## Окружение

- macOS 13+ (Ventura или новее), Xcode с принятой лицензией.
- Swift 5.9+ (идёт с Xcode), Python 3 по пути `/usr/bin/python3`.
- Для проверки лимитов нужны установленные Cursor и/или ChatGPT desktop (Codex).

```bash
git clone https://github.com/youtonplus/TouTou.git
cd TouTou
swift run                      # запуск в режиме разработки
python3 -m unittest discover -s Tests -v
```

## Перед pull request

1. `swift build -c release` собирается без предупреждений.
2. `python3 -m unittest discover -s Tests -v` проходит; новые ветки логики в `scripts/*.py` покрыты тестами.
3. Вёрстка проверена через `TOUTOU_DEMO=1 .build/release/TouTou --snapshot /tmp/panel` — приложите PNG к PR, если меняли интерфейс.
4. Если изменение касается данных аккаунтов или сети — обновите `SECURITY.md`.
5. Одна тема — один PR. Описание: что меняется, зачем, как проверяли.

## Принципы

- **Приватность по умолчанию.** Никаких новых сетевых запросов, логов с токенами, телеметрии. Ошибки показываются пользователю без содержимого исключений.
- **Экономия ресурсов.** Приложение живёт в строке меню круглосуточно и часто от батареи. Любой таймер должен иметь `tolerance`, любая анимация — причину быть включённой. Проверяйте `top -pid $(pgrep -x TouTou)` до и после.
- **Без зависимостей.** Только SwiftUI, AppKit, Foundation, IOKit и стандартная библиотека Python.
- **Наблюдение, а не управление.** Hooks Cursor только читают события; разрешения и подтверждения остаются в Cursor.

## Структура

```
Sources/QuotaAlerts/
  QuotaAlerts.swift    пороги уведомлений о лимите
  QuotaForecast.swift  оценка оставшегося времени окна
Sources/TouTou/
  main.swift      панель, персонаж, AppDelegate, вкладки, меню
  Usage.swift     модель лимитов и запуск fetch_usage.py
  Alerts.swift    баннеры macOS
  Power.swift     крышка (`pmset`), агент (`caffeinate`), IOKit
scripts/
  fetch_usage.py        чтение лимитов Cursor и ChatGPT / Codex
  cursor_hook.py        адаптер Cursor hooks → JSON-события
  configure_cursor.py   генерация cursor-hooks.json с абсолютными путями
  install_cursor.py     слияние hooks в ~/.cursor/hooks.json с бэкапом
  build.sh              release-сборка и упаковка TouTou.app
Tests/                  unittest для Python-модулей
docs/screenshots/       PNG для README (демо-данные)
```

## Сообщения об ошибках

Укажите версию macOS, модель Mac (есть ли вырез камеры), версию TouTou, какие из Cursor / ChatGPT установлены и вывод `python3 scripts/fetch_usage.py` (в нём нет токенов — только проценты и даты).
