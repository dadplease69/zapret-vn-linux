# Changelog

## [1.0.0] — 2026-10-14

Первый релиз Linux-порта.

- Обёртка `zapret-vn.sh` вокруг официального `nfqws` из zapret v72.13 (x86_64 и arm64, проверка хешей).
- Те же 10 стратегий и списки доменов, что в Windows-версии Zapret VN.
- Правила nftables (предпочтительно) или iptables; автосписок; служба systemd.
- `install` — установка в `/opt/zapret-vn`, служба с автозапуском, защищённый DNS (DoT) с автооткатом, проверка.
- `check`, `pick` (автоподбор стратегии), `strategy`, `dns-on` / `dns-off`, `verify`, `rules`, `args`.
