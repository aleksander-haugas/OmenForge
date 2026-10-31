#!/bin/sh
# HP OMEN 8912 Power + Thermal v0.4.3 / FreeBSD 15.1
# WMI whitelist. No direct fan setpoints; AUTO selects firmware power profile.
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin; export PATH
BACKEND=/usr/local/libexec/omenctl-control
SERVICE=/usr/local/etc/rc.d/omen_power_auto
STATE=/var/run/omen-power-thermal.state
ACPI=/usr/local/sbin/acpi_call
EC='\_SB.PCI0.SBRG.EC0'
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Identificador opcional del click actual; solo digitos, no interpretado como comando.
REQUEST_ID=''
case "${1:-}" in
  power|thermal)
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || fail 'Uso: power|thermal <modo> [id]'
    if [ "$#" -eq 3 ]; then
      case "$3" in ''|*[!0-9]*) fail 'Identificador no numerico';; esac
      [ "${#3}" -ge 12 ] && [ "${#3}" -le 20 ] || fail 'Longitud de identificador invalida'
      REQUEST_ID=$3
    fi
    ;;
esac
[ "$(id -u)" -eq 0 ] || fail 'Se requiere autenticacion administrativa (KDE su/pkexec/sudo).'
[ -x "$BACKEND" ] || fail "Backend ausente: $BACKEND"
read_ec(){ "$ACPI" -p "$EC.$1" 2>/dev/null || printf 'N/D\n'; }
write_state(){
    # Atomic and readable by desktop; never source this file as executable code.
    tmp="${STATE}.$$"
    (umask 022; printf 'mode=%s\nselected=%s\ntime=%s\nrequest_id=%s\n' "$1" "$2" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$REQUEST_ID" > "$tmp")
    mv -f "$tmp" "$STATE"
}
profile_of(){
    case "$(read_ec HPCM)" in 48) printf balanced;; 49) printf performance;; 80) printf eco;; *) printf unknown;; esac
}
release_max(){
    fffs=$(read_ec FFFS)
    case "$fffs" in
      0) : ;;
      1) "$BACKEND" fan-max off --apply || fail 'No se pudo desactivar FAN MAX';;
      *) fail "FFFS inesperado: $fffs" ;;
    esac
}
assert_idle(){
    [ ! -e /var/run/omenctl-fan-max-test ] || fail 'Existe un FAN MAX activo: no cambiar perfil hasta que termine'
    [ "$(read_ec FFFS)" = 0 ] || fail 'FFFS no es 0; devolver primero FAN MAX a AUTO'
}
stop_auto(){
    if [ -x "$SERVICE" ]; then "$SERVICE" onestop >/dev/null 2>&1 || :; fi
}
case "${1:-}" in
  status)
    [ "$#" -eq 1 ] || exit 2
    printf 'Power firmware: %s | FFFS=%s\n' "$(profile_of)" "$(read_ec FFFS)"
    if [ -r "$STATE" ]; then
        cat "$STATE"
        requested=$(sed -n 's/^mode=//p' "$STATE" | head -n 1)
        actual_fffs=$(read_ec FFFS)
        if [ "$requested" = maximum ]; then
            case "$actual_fffs" in
              1) printf 'maximum_confirmation=confirmed\n' ;;
              0) printf 'maximum_confirmation=lost (FFFS=0, modo solicitado maximum)\n' ;;
              *) printf 'maximum_confirmation=unavailable\n' ;;
            esac
        fi
    else printf 'mode=unknown (sin estado tras reinicio)\n'; fi
    if [ -x "$SERVICE" ] && "$SERVICE" onestatus >/dev/null 2>&1; then
        printf 'automatic_service=running\n'
    else
        printf 'automatic_service=stopped\n'
    fi
    ;;
  power)
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || exit 2
    case "$2" in eco) hp=cool;;balanced) hp=balanced;;performance) hp=performance;;*) fail 'Power: eco|balanced|performance' ;;esac
    release_max
    assert_idle
    write_state switching "$(profile_of)"
    stop_auto
    if ! "$BACKEND" profile "$hp" --apply; then
        write_state manual "$(profile_of)"
        fail 'Perfil no confirmado. Thermal Manual; comprueba HPCM antes de reintentar'
    fi
    [ "$(profile_of)" = "$2" ] || { write_state manual "$(profile_of)"; fail 'HPCM no coincide con perfil solicitado'; }
    write_state manual "$2"
    printf 'MANUAL: se conserva Power Mode %s hasta nuevo cambio. Fan HP en automatico.\n' "$2"
    ;;
  thermal)
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || exit 2
    case "$2" in
      manual)
        release_max
        assert_idle
        write_state switching "$(profile_of)"
        stop_auto
        current=$(profile_of)
        [ "$current" != unknown ] || fail 'Perfil HPCM desconocido'
        write_state manual "$current"
        printf 'MANUAL: perfil %s fijado; velocidad de ventiladores controlada por HP.\n' "$current"
        ;;
      automatic)
        release_max
        assert_idle
        [ -x "$SERVICE" ] || fail 'Falta servicio omen_power_auto; ejecuta instalador v0.4.1'
        [ -x /usr/local/bin/omen-control-client ] || fail 'Falta omen-control-client actualizado'
        # Do not run two independent policy controllers at the same time.
        if [ -x /usr/local/etc/rc.d/omen_thermal_auto ] && \
            /usr/local/etc/rc.d/omen_thermal_auto onestatus >/dev/null 2>&1; then
            fail 'Supervisor antiguo omen_thermal_auto activo. Detenlo con: sudo service omen_thermal_auto onestop'
        fi
        # Every Automatic activation gets a fresh generation ID. Stop a previous
        # supervisor before publishing that ID, then start exactly one instance.
        if "$SERVICE" onestatus >/dev/null 2>&1; then
            "$SERVICE" onestop >/dev/null 2>&1 || fail 'No se pudo detener el supervisor anterior'
            "$SERVICE" onestatus >/dev/null 2>&1 && fail 'El supervisor anterior sigue activo'
        fi
        if [ -z "$REQUEST_ID" ]; then REQUEST_ID="$(date +%s)$(printf '%05d' "$$")"; fi
        write_state automatic "$(profile_of)"
        # Isolate daemon(8) stdin/stdout/stderr so GUI response pipes cannot be inherited.
        if "$SERVICE" onestart >>/var/log/omen-power-auto-start.log 2>&1 </dev/null; then
            printf 'AUTOMATIC: supervisor activado; cambios de perfil serializados por daemon.\n'
        else
            write_state manual "$(profile_of)"
            fail 'No pudo arrancar el supervisor, regresando a modo Manual'
        fi
        ;;
      maximum)
        stop_auto
        previous=$(profile_of)
        [ "$previous" != unknown ] || fail 'HPCM desconocido'
        # Perfil Performance cuando es seguro y permitido; FAN MAX disponible
        # aun con temperatura >=75C o sensores RPM=0. No forzar potencia bajo calor.
        if [ "$(read_ec FFFS)" = 0 ]; then
            if "$BACKEND" preflight-boost >/dev/null 2>&1; then
                "$BACKEND" profile performance --apply || \
                  printf 'AVISO: Performance no disponible; FAN MAX usa perfil actual.\n' >&2
            fi
        fi
        if "$BACKEND" fan-max on --apply && [ "$(read_ec FFFS)" = 1 ]; then
            write_state maximum "$(profile_of)"
            printf 'MAXIMUM activo indefinidamente; selecciona Manual, Automatic o un perfil Power para salir.\n'
        else
            write_state error "$(profile_of)"
            fail 'FAN MAX no confirmado (FFFS!=1); verificar firmware HP'
        fi
        ;;
      *) fail 'Thermal: automatic|manual|maximum' ;;
    esac
    ;;
  *) fail 'Uso: omen-mode-control status | power eco|balanced|performance | thermal automatic|manual|maximum' ;;
esac
