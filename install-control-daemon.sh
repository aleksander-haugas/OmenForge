#!/bin/sh
# Deliberate one-time administrator action to provision a restricted root broker.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Ejecutar con sudo sh install-control-daemon.sh' >&2; exit 1; }
cd "$(dirname "$0")"
[ -x build/omen-control-daemon ] && [ -x build/omen-control-client ] || {
    echo 'Compila primero: cmake -S . -B build ... && cmake --build build -j2' >&2;exit 1;
}
[ -x /usr/local/sbin/acpi_call ] || { echo 'Falta /usr/local/sbin/acpi_call' >&2;exit 1; }
if ! /usr/sbin/pw groupshow omencontrol >/dev/null 2>&1; then
    /usr/sbin/pw groupadd omencontrol
fi
install -d -m 755 /usr/local/libexec /usr/local/etc/rc.d /usr/local/sbin /usr/local/bin
for name in omenctl-control omen-mode-control omen-power-auto;do
    if [ -f "/usr/local/libexec/$name" ];then
        cp -p "/usr/local/libexec/$name" "/usr/local/libexec/$name.pre-v0.4.4.bak"
    fi
done
install -o root -g wheel -m 755 omenctl-control.sh /usr/local/libexec/omenctl-control
install -o root -g wheel -m 755 omen-mode-control.sh /usr/local/libexec/omen-mode-control
install -o root -g wheel -m 755 omen-power-auto.sh /usr/local/libexec/omen-power-auto
install -o root -g wheel -m 755 rc.d/omen_power_auto /usr/local/etc/rc.d/omen_power_auto
[ -e /usr/local/etc/omen-power-auto.conf ] || install -o root -g wheel -m 644 omen-power-auto.conf /usr/local/etc/omen-power-auto.conf
install -o root -g wheel -m 755 build/omen-control-daemon /usr/local/sbin/omen-control-daemon
install -o root -g wheel -m 755 build/omen-control-client /usr/local/bin/omen-control-client
install -o root -g wheel -m 755 rc.d/omen_control_daemon /usr/local/etc/rc.d/omen_control_daemon
# No changing WMI here. A privileged service *is* explicitly enabled for boot.
sysrc omen_control_daemon_enable=YES
if service omen_control_daemon onestatus >/dev/null 2>&1; then
    service omen_control_daemon onerestart
else
    service omen_control_daemon onestart
fi
printf '\nInstalado. El daemon arranca en proximos reinicios.\n'
printf 'Unica autorizacion de cuenta pendiente: sudo pw groupmod omencontrol -m <tu_usuario>\n'
printf 'Cierra sesion KDE y entra de nuevo para obtener los permisos del grupo.\n'
printf 'No se ha cambiado ningun perfil HP ni FFFS durante la instalacion.\n'
