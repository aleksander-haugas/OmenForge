#!/bin/sh
# Narrow installation of automatic profile serialization patch.
set -eu
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo sh install-auto-serialization-patch.sh" >&2; exit 1; }
cd "$(dirname "$0")"

for f in omen-control-daemon.cpp omen-control-client.cpp omen-mode-control.sh omen-power-auto.sh; do
    [ -f "$f" ] || { echo "Missing source: $f" >&2; exit 1; }
done
for f in /usr/local/sbin/omen-control-daemon /usr/local/bin/omen-control-client \
         /usr/local/libexec/omen-mode-control /usr/local/libexec/omen-power-auto; do
    [ -x "$f" ] || { echo "Installed component missing: $f; refusing partial install." >&2; exit 1; }
done

sh -n omen-mode-control.sh
sh -n omen-power-auto.sh
tmp=$(/usr/bin/mktemp -d /tmp/omen-auto-serialization.XXXXXX)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

: "${CXX:=c++}"
"$CXX" -std=c++17 -O2 -Wall -Wextra -Wpedantic omen-control-daemon.cpp -o "$tmp/omen-control-daemon"
"$CXX" -std=c++17 -O2 -Wall -Wextra -Wpedantic omen-control-client.cpp -o "$tmp/omen-control-client"

stamp=$(date '+%Y%m%d-%H%M%S')
B_DAEMON="/usr/local/sbin/omen-control-daemon.pre-auto-serialization-$stamp"
B_CLIENT="/usr/local/bin/omen-control-client.pre-auto-serialization-$stamp"
B_MODE="/usr/local/libexec/omen-mode-control.pre-auto-serialization-$stamp"
B_AUTO="/usr/local/libexec/omen-power-auto.pre-auto-serialization-$stamp"
cp -p /usr/local/sbin/omen-control-daemon "$B_DAEMON"
cp -p /usr/local/bin/omen-control-client "$B_CLIENT"
cp -p /usr/local/libexec/omen-mode-control "$B_MODE"
cp -p /usr/local/libexec/omen-power-auto "$B_AUTO"

restore_previous() {
    echo "Installation/restart failed; restoring previous components..." >&2
    cp -p "$B_DAEMON" /usr/local/sbin/omen-control-daemon
    cp -p "$B_CLIENT" /usr/local/bin/omen-control-client
    cp -p "$B_MODE" /usr/local/libexec/omen-mode-control
    cp -p "$B_AUTO" /usr/local/libexec/omen-power-auto
    service omen_control_daemon onerestart >/dev/null 2>&1 || :
}
if ! install -o root -g wheel -m 755 "$tmp/omen-control-daemon" /usr/local/sbin/omen-control-daemon ||
   ! install -o root -g wheel -m 755 "$tmp/omen-control-client" /usr/local/bin/omen-control-client ||
   ! install -o root -g wheel -m 755 omen-mode-control.sh /usr/local/libexec/omen-mode-control ||
   ! install -o root -g wheel -m 755 omen-power-auto.sh /usr/local/libexec/omen-power-auto; then
    restore_previous
    exit 1
fi

if service omen_control_daemon onestatus >/dev/null 2>&1; then
    if ! service omen_control_daemon onerestart; then restore_previous; exit 1; fi
else
    if ! service omen_control_daemon onestart; then restore_previous; exit 1; fi
fi

echo
echo "Serialization patch installed; backups:"
echo "  $B_DAEMON"
echo "  $B_CLIENT"
echo "  $B_MODE"
echo "  $B_AUTO"
echo "omen_power_auto was NOT started. /etc/rc.conf was NOT modified."
echo "Next checks: sudo service omen_control_daemon status"
echo "             sudo /usr/local/bin/omen-control-client status"
