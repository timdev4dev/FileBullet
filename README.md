# FileBullet (macOS)

[![CI](https://github.com/timdev4dev/FileBullet/actions/workflows/ci.yml/badge.svg)](https://github.com/timdev4dev/FileBullet/actions/workflows/ci.yml)
[![Release](https://github.com/timdev4dev/FileBullet/actions/workflows/release.yml/badge.svg)](https://github.com/timdev4dev/FileBullet/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/timdev4dev/FileBullet)](https://github.com/timdev4dev/FileBullet/releases/latest)

Простой нативный SFTP/FTP-клиент для macOS на SwiftUI. Позволяет подключаться к
серверу по SSH/SFTP или FTP, ходить по папкам, смотреть файлы и **редактировать
их во внешнем редакторе** — изменения автоматически заливаются обратно на сервер
при каждом сохранении.

## Установка

Скачайте последнюю версию со страницы [**Releases**](https://github.com/timdev4dev/FileBullet/releases/latest):
`FileBullet.dmg` (перетащите в Applications) или `FileBullet.zip`. Приложение
подписано ad-hoc — при первом запуске: правый клик → **Открыть**.

## Возможности
- Подключение по паролю (хост / порт / пользователь / пароль).
- Навигация по директориям, переход вверх, обновление.
- Двойной клик по папке — войти, по файлу — скачать и открыть в редакторе по
  умолчанию (`NSWorkspace.open`, т.е. VS Code / TextEdit / что назначено).
- Авто-загрузка обратно на сервер: пока файл открыт, приложение раз в ~1.5 с
  проверяет дату изменения локальной копии и при сохранении пушит её на сервер.
- Панель «Редактируемые файлы» с индикатором синхронизации, ручным
  «Сохранить», «Открыть», «В Finder» и закрытием отслеживания.

## Стек
- SwiftUI + AppKit (нативное окно).
- [Citadel](https://github.com/orlandos-nl/Citadel) — чистый Swift SSH/SFTP на
  SwiftNIO.

## Запуск

Через Swift Package Manager (для разработки):

```sh
swift run
```

Собрать двойным-кликабельный `.app`:

```sh
./make-app.sh
open FileBullet.app          # или перетащить в /Applications
```

## Замечания
- Ключ хоста принимается без проверки (`.acceptAnything()`) — клиент рассчитан
  на доверенные/локальные серверы. Для продакшена стоит закрепить host key.
- Редактирование текстовое: файл скачивается во временную папку
  (`$TMPDIR/SFTPClient/`) и открывается системным приложением по умолчанию.
- Поддержка ключей (ed25519/rsa/p256…) есть в Citadel — форму входа легко
  расширить (`SSHAuthenticationMethod.ed25519(...)` и т.п.).
