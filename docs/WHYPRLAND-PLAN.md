# whyprland: Hyprland ohne Omarchy

Stand: 2026-11-14

## Ziel

whyprland ist ein Fork von [womarchy](https://github.com/sytelus/womarchy). Der Desktop läuft weiter in WSL auf
Arch Linux, aber mit einem schlichten **Hyprland** statt mit Omarchy. Der technische Kern bleibt: das WSL-Backend
für Hyprland/aquamarine, Mesa über D3D12 und der Windows-Viewer.

**Nicht enthalten:** andere Distros (Fedora oder Ubuntu kämen später, falls gewünscht), Omarchy-Themes und das
Omarchy-Menü.

## Was bleibt

- Die Patches unter `patches/` und `linux/packages/{aquamarine,hyprland,mesa-womarchy}`. Die PKGBUILDs sind von Arch
  abgeleitet, die Hypr-Abhängigkeiten kommen aus Arch `extra`.
- Das Protokoll (`protocol/wdp.h`) und der Windows-Viewer (`windows/omarchy`, wird umbenannt).
- `womarchy-session` (uwsm → Hyprland) sowie Clipboard, Audio und GPU unter `linux/overlay/wsl/`.

## Schritte

| # | Schritt | Dateien | Aufwand | Stand |
|---|---|---|---|---|
| 1 | Image ohne Omarchy: Pakete aus dem Arch-Archiv mit festem Datum, eigene Paketliste (hyprland, uwsm, waybar, fuzzel, mako, kitty, hyprpaper, pipewire, xdg-desktop-portal-hyprland) | `linux/image/build-image.sh`, `verify-image.sh`, `omarchy-key.env`, `snapshot-watch.yml` | ½ Tag | offen |
| 2 | `womarchy-compat` verschlanken: Ersatz für limine und snapper raus, Omarchys Schlüssel und `[omarchy]`-Repo raus | `linux/packages/womarchy-compat`, `linux/overlay/wsl/pacman.sh`, `womarchy-apply-system` | 2 h | offen |
| 3 | User-Setup: eigene Standard-`hyprland.lua` (Terminal, Starter, Logout, Leiste), Windows-Anpassungen (Super+L, Ctrl+Alt+Del) ohne `o.bind` | `womarchy-provision-user`, `linux/overlay/user/` | ½ Tag | offen |
| 4 | Update und Rollback über `pacman -Syu` statt `omarchy update`, Rollback-Hook bleibt | `womarchy-rollback`, `rollback-point`, `windows/omarchy/src/maintain.rs` | 2 h | offen |
| 5 | Umbenennen: `omarchy.exe` → `whyprland.exe`, Distro „Whyprland“, Start-Menü, `install.ps1`, Links auf `corexo/whyprland` | `windows/`, `install.ps1`, `README.md`, `.github/` | ½ Tag | offen |
| 6 | Eigener GPG-Signierschlüssel für das Paket-Repo (der bisherige gehört sytelus), im Tresor und als CI-Secret | `linux/packages/womarchy-keyring`, `.github/workflows/packages.yml` | 1 h | offen |
| 7 | Bauen und auf Windows testen (Build-Distro `womarchy-build`, echter Desktop, GPU) | `linux/image/README.md`, `lab/` | ½ Tag | offen |

## Fertig, wenn

- `build-image.sh` baut ein Image ohne ein einziges `omarchy*`-Paket.
- `whyprland` in einem Windows-Terminal startet Hyprland im Vollbild auf allen Monitoren, mit GPU (`eglinfo` zeigt d3d12).
- Clipboard, Ton und Monitorwechsel funktionieren wie bei womarchy.
- `whyprland update` und `whyprland rollback` funktionieren.

## Risiken

- Arch `extra` kann neuere Hypr-Bibliotheken liefern, als Hyprland v0.56.2 erwartet. Deshalb wird das Archiv-Datum
  festgeschrieben und mit `patches/versions.sh` abgeglichen.
- Ohne Omarchy fehlen die Helfer, die Omarchys Konfiguration erwartet. Deshalb wird alles in `womarchy.lua` und
  `womarchy-session` auf `omarchy-*`-Aufrufe geprüft.
