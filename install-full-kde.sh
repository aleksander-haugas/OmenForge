#!/bin/sh
# Compila OMEN Panel v0.4.16 e instala la interfaz y el parche de serialización.
# Run as the regular desktop user from anywhere: sh /path/to/install-full-kde.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

for cmd in cmake c++ make sudo; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing command: $cmd" >&2
        [ "$cmd" != sudo ] || echo "Install/configure sudo first." >&2
        exit 1
    }
done

for f in main.cpp CMakeLists.txt assets.qrc assets/omen-icon.svg assets/omen-icon-256.png omen-panel.desktop install-auto-serialization-patch.sh omen-diagnostics.sh; do
    [ -f "$f" ] || { echo "Required project file missing: $f" >&2; exit 1; }
done

printf '\n== 1/5: Configure Release build ==\n'
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local

printf '\n== 2/5: Build app and C++ control components ==\n'
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
case "$JOBS" in ''|*[!0-9]*) JOBS=2 ;; esac
cmake --build build -j "$JOBS"

printf '\n== 3/5: Install the serialization patch (does not start automatic supervisor) ==\n'
sudo sh "$ROOT/install-auto-serialization-patch.sh"

printf '\n== 4/5: Back up and install GUI, desktop entry and icon ==\n'
STAMP=$(date '+%Y%m%d-%H%M%S')
backup_if_exists() {
    src=$1
    [ ! -e "$src" ] || sudo cp -p "$src" "$src.pre-full-kde-$STAMP"
}
backup_if_exists /usr/local/bin/omen-panel
backup_if_exists /usr/local/share/applications/omen-panel.desktop
backup_if_exists /usr/local/share/icons/hicolor/scalable/apps/omen-thermal-control.svg
backup_if_exists /usr/local/share/icons/hicolor/256x256/apps/omen-thermal-control.png

sudo install -d -o root -g wheel -m 755 \
    /usr/local/bin \
    /usr/local/share/applications \
    /usr/local/share/icons/hicolor/scalable/apps \
    /usr/local/share/icons/hicolor/256x256/apps
sudo install -o root -g wheel -m 755 build/omen-panel /usr/local/bin/omen-panel
sudo install -o root -g wheel -m 644 omen-panel.desktop /usr/local/share/applications/omen-panel.desktop
sudo install -o root -g wheel -m 644 assets/omen-icon.svg /usr/local/share/icons/hicolor/scalable/apps/omen-thermal-control.svg
sudo install -o root -g wheel -m 644 assets/omen-icon-256.png /usr/local/share/icons/hicolor/256x256/apps/omen-thermal-control.png

printf '\n== 5/5: Refresh KDE application/icon cache ==\n'
if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 --noincremental || echo "Warning: kbuildsycoca6 failed; log out/in to refresh Plasma." >&2
else
    echo "kbuildsycoca6 not found; log out/in of KDE Plasma to refresh its launcher cache." >&2
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    sudo update-desktop-database /usr/local/share/applications || true
fi

printf '\nInstalación de OMEN Panel v0.4.16 completada.\n'
printf 'App:     /usr/local/bin/omen-panel\n'
printf 'Desktop: /usr/local/share/applications/omen-panel.desktop\n'
printf 'Icon:    /usr/local/share/icons/hicolor/256x256/apps/omen-thermal-control.png\n'
printf '\nVerify:  /usr/local/bin/omen-panel\n'
printf 'Daemon:  sudo service omen_control_daemon status\n'
printf 'Client:  sudo /usr/local/bin/omen-control-client status\n'
printf '\nDiagnostics: sudo sh %s/omen-diagnostics.sh\n' "$ROOT"
printf 'The script does NOT enable or start omen_power_auto. Keep it disabled until the checks pass.\n'
