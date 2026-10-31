#!/bin/sh
# Read-only local diagnostic report for OMEN Panel on FreeBSD.
# Does not start/stop services, change profiles, or edit configuration.
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Ejecuta como root para incluir todos los estados/logs: sudo sh $0" >&2
    exit 1
fi
umask 077
STAMP=$(date '+%Y%m%d-%H%M%S')
OUT="/tmp/omen-panel-diagnostics-${STAMP}.txt"

section() { printf '\n\n===== %s =====\n' "$1"; }
run() {
    printf '\n$'
    printf ' %s' "$@"
    printf '\n'
    "$@" 2>&1 || printf '[comando terminó con código %s]\n' "$?"
}
file_info() {
    for f in "$@"; do
        if [ -e "$f" ]; then
            ls -ldT "$f" 2>&1
            if [ -f "$f" ]; then sha256 "$f" 2>&1; fi
        else
            printf 'MISSING: %s\n' "$f"
        fi
    done
}

{
    echo 'OMEN Panel diagnostic report (read-only)'
    echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo 'This report may contain system configuration and hardware telemetry. Review before sharing.'

    section 'Operating system and hardware'
    run uname -a
    run sysctl kern.osrelease
    run sysctl hw.model
    run sysctl hw.ncpu

    section 'Package versions'
    run pkg info -e qt6-base
    run pkg info -e cmake
    run pkg info -e sudo

    section 'Services'
    run service omen_control_daemon status
    run service omen_collector status
    run service omen_power_auto status

    section 'Relevant rc.conf settings'
    if [ -r /etc/rc.conf ]; then
        grep -nE '^(omen_(power_auto|control_daemon|collector)_enable)=' /etc/rc.conf || echo 'No matching settings found.'
    else
        echo '/etc/rc.conf unavailable'
    fi

    section 'OMEN control state'
    for f in /var/run/omen-control/thermal.state /var/run/omen-power-thermal.state /var/run/omenctl/status; do
        if [ -r "$f" ]; then
            echo "--- $f ---"
            sed -n '1,80p' "$f"
        else
            echo "Missing or unreadable: $f"
        fi
    done
    if [ -S /var/run/omen-control/control.sock ]; then ls -lT /var/run/omen-control/control.sock; else echo 'Socket not found at /var/run/omen-control/control.sock'; fi

    section 'Installed component files'
    file_info \
        /usr/local/bin/omen-panel \
        /usr/local/bin/omen-control-client \
        /usr/local/sbin/omen-control-daemon \
        /usr/local/libexec/omen-mode-control \
        /usr/local/libexec/omen-power-auto \
        /usr/local/libexec/omen-collector \
        /usr/local/share/applications/omen-panel.desktop \
        /usr/local/share/icons/hicolor/scalable/apps/omen-thermal-control.svg \
        /usr/local/share/icons/hicolor/256x256/apps/omen-thermal-control.png

    section 'Control client status'
    if [ -x /usr/local/bin/omen-control-client ]; then
        run /usr/local/bin/omen-control-client status
    else
        echo 'omen-control-client not installed'
    fi

    section 'Recent logs (if present)'
    for f in /var/log/omen-power-auto.log /var/log/omen-control-daemon.log /var/log/omen_collector.log; do
        if [ -r "$f" ]; then
            echo "--- last 40 lines: $f ---"
            tail -n 40 "$f"
        else
            echo "No readable log: $f"
        fi
    done

    section 'End'
    echo 'No configuration or service state was changed by this diagnostic script.'
} > "$OUT" 2>&1

chmod 600 "$OUT"
echo "Informe creado: $OUT"
echo 'El informe puede contener información de tu equipo; revísalo antes de compartirlo.'
