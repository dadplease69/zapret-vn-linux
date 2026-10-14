# Сторонние компоненты

Пакет содержит **неизменённые** файлы из официального релиза
[zapret v72.13](https://github.com/bol-van/zapret/releases/tag/v72.13) (© 2016–2024 bol-van, лицензия MIT — `LICENSE.zapret`):

| Файл в пакете | Источник в релизе | Проверка |
|---|---|---|
| `bin/nfqws-x86_64` | `binaries/linux-x86_64/nfqws` | SHA-256 есть в официальном `sha256sum.txt` |
| `bin/nfqws-arm64` | `binaries/linux-arm64/nfqws` | SHA-256 есть в официальном `sha256sum.txt` |
| `fake/*.bin` | `files/fake/` | побайтно совпадают с файлами из архива релиза |

Списки доменов (`lists/vietnam.txt`, `lists/exclude.txt`) и набор стратегий взяты из
[Zapret VN](https://github.com/MrMe0ws/zapret-vietnam) v1.0.0 (© 2026 Meows, MIT — `LICENSE.zapret-vn`).
Скрипт `zapret-vn.sh` — отдельная реализация для Linux по мотивам Windows-версии.
