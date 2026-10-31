#!/bin/sh
# HP OMEN 8912 - FreeBSD 15.1
# CONTROL EXPERIMENTAL SOLO MEDIANTE WMI HP DOCUMENTADO.
# v0.4.2: los tacometros (incluso 0 RPM) informan, no bloquean el control; respuesta WMI se verifica.
# No escribe directamente EC, nunca invoca GM10/GM2E ni fija RPM individuales.
# Uso bajo root/pkexec. Cambios en firmware no tienen rollback garantizado.
set -eu
LC_ALL=C; export LC_ALL
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH
ACPI_CALL=/usr/local/sbin/acpi_call
EC='\_SB.PCI0.SBRG.EC0'
WMI='\_SB.WMID.WMAA'
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail 'El control necesita autorizacion administrativa (sudo/pkexec).'
[ -x "$ACPI_CALL" ] || fail 'No existe acpi_call.'

read_ec() {
    case "$1" in ECON|GPUT|SW2S|HPCM|FFFS|FS1H|FS1L|FS2H|FS2L|OMCC|SRP1|SRP2|FMR1|FMR2|FAS1|FAS2|FSUS) : ;; *) fail 'Registro no permitido' ;; esac
    byte=$("$ACPI_CALL" -p "$EC.$1") || fail "Fallo leyendo $1"
    case "$byte" in ''|*[!0-9]*) fail "Respuesta EC invalida: $1=$byte" ;; esac
    [ "$byte" -ge 0 ] && [ "$byte" -le 255 ] || fail "EC fuera de rango: $1=$byte"
    printf '%s\n' "$byte"
}
profile_name() {
    case "$1" in 48) printf Balanced ;; 49) printf Performance ;; 80) printf Cool ;; *) fail 'Perfil HP desconocido' ;; esac
}
fan_speed() {
    a=$(read_ec FS1H); b=$(read_ec FS1L); c=$(read_ec FS2H); d=$(read_ec FS2L)
    rpm0=$((a * 256 + b)); rpm1=$((c * 256 + d))
}
# Confirmacion de temperaturas antes de cambiar una politica de ventilacion.
check_thermal() {
    for name in dev.amdtemp.0.core0.sensor0 hw.acpi.thermal.tz0.temperature; do
        value=$(sysctl -n "$name" 2>/dev/null) || fail "No hay sensor termico: $name"
        case "$value" in *C) value=${value%C} ;; *) fail "Temperatura invalida: $name" ;; esac
        awk -v t="$value" 'BEGIN {if (t !~ /^[0-9]+([.][0-9]+)?$/ || t >= 75) exit 1}' || fail "Temperatura alta o invalida en $name: $value C (umbral 75C)"
        case "$name" in
          dev.amdtemp.0.core0.sensor0) cpu_c=$value ;;
          hw.acpi.thermal.tz0.temperature) zone_c=$value ;;
        esac
    done
}
preflight() {
    [ "$(read_ec ECON)" = 1 ] || fail 'EC no disponible'
    [ "$(read_ec SW2S)" = 1 ] || fail 'SW2S inactivo; sin cambiar parametros de potencia'
    gpu=$(read_ec GPUT)
    case "$gpu" in 1|2|4|5|6) : ;; *) fail "GPUT=$gpu no reconocido" ;; esac
    current_profile=$(read_ec HPCM)
    case "$current_profile" in 48|49|80) : ;; *) fail "Perfil EC no reconocido: $current_profile" ;; esac
    max_before=$(read_ec FFFS)
    [ "$max_before" = 0 ] || [ "$max_before" = 1 ] || fail "FFFS inesperado: $max_before"
    fan_speed
    check_thermal
    # v0.4.2: la telemetria no es una autorizacion. HP puede ordenar fan-stop
    # y las lecturas del EC pueden ser transitorias. NO bloquear botones ni
    # comandos de perfil o FAN MAX por 0 RPM, tampoco con solo un tacometro a 0.
    # El estado se comprueba DESPUES de escribir WMI. Los avisos NO son prueba
    # de que el fan-stop sea normal: supervisar flujo de aire/temperatura.
    fan_stop_probable=0
    [ "$rpm0" -le 12000 ] && [ "$rpm1" -le 12000 ] || fail 'Tacometro fuera de rango'
    if [ "$rpm0" -eq 0 ] || [ "$rpm1" -eq 0 ]; then
        fan_stop_probable=1
        printf 'AVISO: lectura de tacometros %s/%s RPM; no se usa para impedir cambios de perfil o MAX. Verificar refrigeracion, especialmente si hay calor.\n' "$rpm0" "$rpm1" >&2
    fi
    power=$(sysctl -n hw.acpi.acline 2>/dev/null || printf 'indefinido')
}
# En FreeBSD acpi_call -o b devuelve representacion ACPICA Buffer de 24 bytes
# seguida de firma HP PASS, codigo 0, y datos. Ya verificado con esta BIOS.
wmi_write() {
    cmd=$1; count=$2; bytes=$3
    case "$cmd/$count/$bytes" in
        1a/2/ff30|1a/2/ff31|1a/2/ff50|27/4/01000000|27/4/00000000) : ;;
        *) fail 'Peticion WMI fuera de lista blanca' ;;
    esac
    case "$count" in 2) size=02000000 ;; 4) size=04000000 ;; *) fail 'Tamano invalido' ;; esac
    zeros=$((256 - ${#bytes}))
    [ "$zeros" -gt 0 ] || fail 'Error de tamano WMI'
    pad=$(printf "%0${zeros}d" 0)
    req="5345435508000200${cmd}000000${size}${bytes}${pad}"
    [ "${#req}" -eq 288 ] || fail 'Peticion WMI invalida'
    # HPWMI_GM, salida de 8 bytes para escrituras, usando el protocolo Linux.
    resp=$("$ACPI_CALL" -p "$WMI" -i 0 -i 1 -b "$req" -o b) || fail 'Fallo ejecutando WMAA'
    case "$resp" in 03000000*) : ;; *) fail "Respuesta ACPI inesperada: $resp" ;; esac
    case "$resp" in *[!0-9a-fA-F]*) fail 'Respuesta WMI invalida' ;; esac
    [ "${#resp}" -ge 64 ] || fail 'Respuesta WMI demasiado corta'
    signature=$(printf '%s' "$resp" | cut -c49-56)
    code=$(printf '%s' "$resp" | cut -c57-64)
    [ "$signature" = 50415353 ] || fail "Firma HP incorrecta: $signature"
    [ "$code" = 00000000 ] || fail "Respuesta HP no satisfactoria: $code"
    # Auditoria de escrituras confirmadas a traves de este backend (no captura el firmware).
    case "$cmd/$count/$bytes" in
        27/4/01000000) audit_action=FAN_MAX_ON ;;
        27/4/00000000) audit_action=FAN_MAX_OFF ;;
        *) audit_action=POWER_PROFILE ;;
    esac
    (umask 077; printf '%s action=%s pid=%s fffs_after=%s hpcm_after=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$audit_action" "$$" \
        "$(read_ec FFFS 2>/dev/null || printf unknown)" \
        "$(read_ec HPCM 2>/dev/null || printf unknown)" \
        >> /var/log/omen-firmware-writes.log) || :
}
# Informe puramente de lectura: no infiere que 0xFF sea automaticamente
# un comando de restauracion ni que dos ceros demuestren parada fisica.
fan_audit() {
    [ "$(read_ec ECON)" -eq 1 ] || fail 'EC no activo'
    current_profile=$(read_ec HPCM)
    gpu=$(read_ec GPUT)
    max_before=$(read_ec FFFS)
    omcc=$(read_ec OMCC)
    s1=$(read_ec SRP1); s2=$(read_ec SRP2)
    fmr1=$(read_ec FMR1); fmr2=$(read_ec FMR2)
    fas1=$(read_ec FAS1); fas2=$(read_ec FAS2)
    fsus=$(read_ec FSUS)
    fan_speed
    first0=$rpm0; first1=$rpm1
    check_thermal
    sleep 1
    fan_speed
    printf '=== HP OMEN 8912 | auditoria SIN escrituras ===\n'
    printf 'Perfil EC HPCM=%s | GPUT=%s | FFFS=%s | OMCC=%s\n' "$current_profile" "$gpu" "$max_before" "$omcc"
    printf 'SRP1=%s SRP2=%s | FMR1=%s FMR2=%s | FAS1=%s FAS2=%s FSUS=%s\n' "$s1" "$s2" "$fmr1" "$fmr2" "$fas1" "$fas2" "$fsus"
    printf 'RPM t0=%s/%s | RPM t+1s=%s/%s\n' "$first0" "$first1" "$rpm0" "$rpm1"
    printf 'CPU=%s C | zona ACPI=%s C\n' "$cpu_c" "$zone_c"
    if [ "$max_before" = 1 ]; then
        printf 'Modo observado: FAN MAX solicitado (FFFS=1).\n'
    elif [ "$omcc" = 0 ] && [ "$s1" = 255 ] && [ "$s2" = 255 ]; then
        if [ "$rpm0" = 0 ] && [ "$rpm1" = 0 ] && [ "$first0" = 0 ] && [ "$first1" = 0 ]; then
            printf 'Modo observado: compatible con control firmware y FAN-STOP; verificar flujo de aire.\n'
        else
            printf 'Modo observado: compatible con regulacion firmware (no prueba absoluta).\n'
        fi
    else
        printf 'Modo observado: estado EC no identificado; NO ejecutar pruebas manuales.\n'
    fi
    printf 'Manual GM2E: BLOQUEADO. Retorno seguro no validado en placa 8912.\n'
    printf 'IMPORTANTE: No escribir 0x00 ni 0xFF en SRP1/SRP2 sin validar su semantica.\n'
}


# Auditoria de interfaces de lectura GM28, GM2D y GM2F.
# AVISO: GM10, aunque tenga nombre GET_FAN_COUNT, puede activar/refrescar
# un estado termico de usuario en ciertos firmware HP: no consultarlo aqui.
# No se ejecuta GM2E ni se escriben registros EC.
hex_to_dec() {
    h=$1
    case "$h" in
        ''|*[!0-9a-fA-F]*) fail "Hexadecimal invalido: $h" ;;
    esac
    printf '%d\n' "0x$h"
}
wmi_read_128() {
    query=$1
    case "$query" in
        28) insize=08000000 ;;
        2d) insize=01000000 ;;
        2f) insize=04000000 ;;
        *) fail 'Comando fuera de lista blanca de consultas WMI' ;;
    esac
    req="5345435508000200${query}000000${insize}$(printf '%0256d' 0)"
    [ "${#req}" -eq 288 ] || fail "Peticion $query con tamano invalido"
    answer=$("$ACPI_CALL" -p "$WMI" -i 0 -i 3 -b "$req" -o b) || fail "WMI $query sin respuesta"
    case "$answer" in *[!0-9a-fA-F]*|'') fail "Respuesta hexadecimal WMI $query invalida" ;; esac
    [ "${#answer}" -ge 68 ] || fail "Respuesta WMI $query truncada"
    signature=$(printf '%s' "$answer" | cut -c49-56)
    ret_code=$(printf '%s' "$answer" | cut -c57-64)
    [ "$signature" = 50415353 ] || fail "Consulta $query sin firma PASS ($signature)"
    [ "$ret_code" = 00000000 ] || fail "Consulta $query rechazada por HP ($ret_code)"
    # 32 bytes de cabecera ACPICA+HP en este equipo; datos empiezan en byte 33.
    printf '%s\n' "$answer" | cut -c65-
}
fan_capabilities() {
    [ "$(read_ec ECON)" -eq 1 ] || fail 'EC no activo'
    current_profile=$(read_ec HPCM)
    gpu=$(read_ec GPUT)
    fffs=$(read_ec FFFS)
    omcc=$(read_ec OMCC)
    srp1=$(read_ec SRP1); srp2=$(read_ec SRP2)
    fan_speed
    ec0=$rpm0; ec1=$rpm1

    design=$(wmi_read_128 28)
    speeds=$(wmi_read_128 2d)
    table=$(wmi_read_128 2f)
    [ "${#design}" -ge 16 ] || fail 'System Design demasiado corto'
    [ "${#speeds}" -ge 4 ] || fail 'Lectura Fan Speed demasiado corta'
    [ "${#table}" -ge 10 ] || fail 'Tabla de velocidades demasiado corta'
    vhex=$(printf '%s' "$design" | cut -c7-8)
    version=$(hex_to_dec "$vhex")
    ahex=$(printf '%s' "$speeds" | cut -c1-2)
    bhex=$(printf '%s' "$speeds" | cut -c3-4)
    active0=$(($(hex_to_dec "$ahex") * 100))
    active1=$(($(hex_to_dec "$bhex") * 100))
    num_fans=$(hex_to_dec "$(printf '%s' "$table" | cut -c1-2)")
    meta=$(hex_to_dec "$(printf '%s' "$table" | cut -c3-4)")
    printf '=== HP OMEN 8912 | capacidades WMI (SOLO LECTURA) ===\n'
    printf 'HPCM=%s | GPUT=%s | FFFS=%s | OMCC=%s | SRP=%s/%s\n' "$current_profile" "$gpu" "$fffs" "$omcc" "$srp1" "$srp2"
    printf '0x28 System Design: %s | politica termica V%s (byte 3)\n' "$(printf '%s' "$design" | cut -c1-16)" "$version"
    printf '0x2D WMI (pasos 100 RPM): %s/%s | EC: %s/%s (muestras no simultaneas)\n' "$active0" "$active1" "$ec0" "$ec1"
    printf '0x2F Fan Table: ventiladores=%s | segundo byte=%s (semantica no garantizada)\n' "$num_fans" "$meta"
    [ "$num_fans" -eq 2 ] || fail 'Tabla incompatible: numero de ventiladores distinto de 2'
    printf '  Nivel | Fan 0 | Fan 1 | Extra\n'
    i=1
    count=0
    while [ "$i" -le 40 ]; do
        start=$((5 + (i - 1) * 6))
        end=$((start + 5))
        [ "${#table}" -ge "$end" ] || break
        triplet=$(printf '%s' "$table" | cut -c"${start}-${end}")
        c0=$(hex_to_dec "$(printf '%s' "$triplet" | cut -c1-2)")
        c1=$(hex_to_dec "$(printf '%s' "$triplet" | cut -c3-4)")
        noise=$(hex_to_dec "$(printf '%s' "$triplet" | cut -c5-6)")
        [ "$c0" -ne 0 ] || [ "$c1" -ne 0 ] || [ "$noise" -ne 0 ] || break
        printf '  %5s | %5s | %5s | %s\n' "$i" "$((c0 * 100))" "$((c1 * 100))" "$noise"
        i=$((i + 1))
        count=$((count + 1))
    done
    printf 'Entradas presentes (hasta primer 000000): %s\n' "$count"
    printf 'Interpretacion: WMI 0x2D en pasos de 100 RPM; puede indicar lectura redondeada o nivel interno.\n'
    printf 'Los tripletes 0x2F incluyen un tercer campo (noise_db en Linux) no validado como medida fisica.\n'
    printf 'Tabla y telemetria legibles; NO prueba el soporte de escritura GM2E.\n'
    printf 'GM2E BLOQUEADO: no se ha validado una recuperacion segura en HP 8912.\n'
    printf 'Nota: NO se llama a GM10 porque puede modificar el estado termico en algunos HP.\n'
}


# Comparacion temporal de lectura WMI 0x2D y tachometros EC.
# No escribe firmware, no llama al metodo GM10 ni a GM2E.
# Telemetria secundaria en una prueba FAN MAX ya conocida. No modifica firmware.
# La resolucion de GM2D es 100 RPM; EC y WMI se leen sucesivamente.
fan_trace_wmi() {
    [ "$trace_wmi" = 1 ] || return 0
    if speed_data=$(wmi_read_128 2d 2>/dev/null) && [ "${#speed_data}" -ge 4 ]; then
        w0=$(($(hex_to_dec "$(printf '%s' "$speed_data" | cut -c1-2)") * 100))
        w1=$(($(hex_to_dec "$(printf '%s' "$speed_data" | cut -c3-4)") * 100))
        printf '    GM2D: %4s/%4s RPM | EC: %4s/%4s RPM | diferencia: %+d/%+d RPM\n' \
            "$w0" "$w1" "$rpm0" "$rpm1" "$((w0 - rpm0))" "$((w1 - rpm1))"
        if [ "$w0" -gt "$wmi_peak0" ]; then wmi_peak0=$w0; fi
        if [ "$w1" -gt "$wmi_peak1" ]; then wmi_peak1=$w1; fi
        wmi_samples=$((wmi_samples + 1))
    else
        printf '    AVISO: GM2D no disponible en esta lectura; continuar y solicitar OFF normalmente.\n' >&2
    fi
}
fan_readback() {
    samples=$1
    case "$samples" in 2|5|10) : ;; *) fail 'Muestras permitidas: 2, 5 o 10' ;; esac
    [ "$(read_ec ECON)" = 1 ] || fail 'EC inactivo'
    printf '=== 0x2D versus tacometros EC | %s muestras cada 2s (SOLO LECTURA) ===\n' "$samples"
    printf '  N  |  WMI0  WMI1 |   EC0   EC1 | d0   d1 (WMI-EC)\n'
    j=1
    while [ "$j" -le "$samples" ]; do
        fan_speed
        e0=$rpm0; e1=$rpm1
        speed_data=$(wmi_read_128 2d)
        [ "${#speed_data}" -ge 4 ] || fail '0x2D sin dos velocidades'
        w0=$(($(hex_to_dec "$(printf '%s' "$speed_data" | cut -c1-2)") * 100))
        w1=$(($(hex_to_dec "$(printf '%s' "$speed_data" | cut -c3-4)") * 100))
        printf '%3s  | %5s %5s | %5s %5s | %+4d %+4d\n' \
            "$j" "$w0" "$w1" "$e0" "$e1" "$((w0 - e0))" "$((w1 - e1))"
        [ "$j" -lt "$samples" ] && sleep 2
        j=$((j + 1))
    done
    printf 'NOTA: EC y WMI son lecturas consecutivas, no simultaneas; los niveles WMI son de 100 RPM.\n'
}

usage() {
    cat <<'HELP'
omenctl-control (EXPERIMENTAL) - HP OMEN 8912 / FreeBSD
  sudo /usr/local/libexec/omenctl-control status
  sudo /usr/local/libexec/omenctl-control profile balanced|performance|cool --apply
  sudo /usr/local/libexec/omenctl-control fan-audit
  sudo /usr/local/libexec/omenctl-control fan-capabilities  # solo lectura GM28/GM2D/GM2F
  sudo /usr/local/libexec/omenctl-control fan-readback [2|5|10]  # serie EC vs GM2D
  sudo /usr/local/libexec/omenctl-control fan-max on --apply
  sudo /usr/local/libexec/omenctl-control fan-max off --apply

  --apply es obligatorio; SOLO comandos HP WMI 0x1A y 0x27.
  FAN MAX no tiene temporizador en el software de produccion.
  No establece una velocidad media o un porcentaje.
  No escribe GM2E ni modifica el modo de ventilacion individual.
  Modo FAN MAX ya validado por el usuario en HP 8912.
  No hay control porcentual de ventiladores; GM2E deshabilitado.
HELP
}
[ "$#" -ge 1 ] || { usage; exit 2; }
case "$1" in
    status)
        [ "$#" -eq 1 ] || fail 'Uso: status'
        preflight
        printf 'Perfil: %s (%s) | FFFS: %s | RPM: %s/%s | GPUT=%s | AC=%s\n' "$(profile_name "$current_profile")" "$current_profile" "$max_before" "$rpm0" "$rpm1" "$gpu" "$power"
        ;;
    fan-capabilities)
        [ "$#" -eq 1 ] || fail 'Uso: fan-capabilities'
        fan_capabilities
        ;;
    fan-readback)
        [ "$#" -le 2 ] || fail 'Uso: fan-readback [2|5|10]'
        count=${2:-5}
        fan_readback "$count"
        ;;
    fan-manual|fan-speed)
        fail 'Control manual GM2E BLOQUEADO: falta verificar retorno seguro al modo firmware en HP 8912.'
        ;;
    profile)
        [ "$#" -eq 3 ] && [ "$3" = --apply ] || fail 'Uso: profile balanced|performance|cool --apply'
        case "$2" in balanced) target=48; hex=30 ;; performance) target=49; hex=31 ;; cool) target=80; hex=50 ;; *) fail 'Perfil invalido' ;; esac
        preflight
        [ "$max_before" = 0 ] || fail 'Desactiva primero ventilacion maxima y verifica el estado.'
        [ "$power" = 1 ] || fail 'Cambio de perfil requiere CA confirmada (hw.acpi.acline=1).'
        if [ "$current_profile" = "$target" ]; then printf 'Perfil %s ya activo. Sin cambios.\n' "$(profile_name "$target")"; exit 0; fi
        printf 'AVISO: firmware HP modifica perfil, limites de potencia y politica termica.\n'
        printf 'Anterior: %s (%s); solicitado: %s (%s); GPUT=%s\n' "$(profile_name "$current_profile")" "$current_profile" "$(profile_name "$target")" "$target" "$gpu"
        [ "$(read_ec HPCM)" = "$current_profile" ] || fail 'HPCM ha cambiado; cancelar'
        [ "$(read_ec GPUT)" = "$gpu" ] || fail 'GPUT ha cambiado; cancelar'
        wmi_write 1a 2 "ff$hex"
        sleep 2
        after=$(read_ec HPCM)
        fan_speed
        printf 'HP PASS; HPCM=%s; RPM=%s/%s\n' "$after" "$rpm0" "$rpm1"
        [ "$after" = "$target" ] || fail 'Cambio de perfil no confirmado'
        [ "$rpm0" -gt 0 ] && [ "$rpm1" -gt 0 ] || printf 'AVISO: RPM a cero tras cambio; verificar fisicamente y volver a consultar.\n' >&2
        ;;
    fan-max)
        # MAX persistente: ON/OFF exclusivamente a peticion explicita del usuario.
        if [ "$#" -eq 3 ] && [ "$2" = on ] && [ "$3" = --apply ]; then
            [ "$(read_ec ECON)" = 1 ] || fail 'EC no disponible'
            before=$(read_ec FFFS)
            [ "$before" = 0 ] || { [ "$before" = 1 ] && { echo 'FAN MAX ya activo'; exit 0; }; fail 'FFFS invalido'; }
            # RPM=0 y temperatura no bloquean pedir mas ventilacion.
            # No desactivar limites/protecciones propios de HP.
            wmi_write 27 4 01000000
            sleep 1
            after=$(read_ec FFFS)
            [ "$after" = 1 ] || fail 'HP no confirmo FAN MAX; FFFS distinto de 1'
            printf 'FAN MAX permanente solicitado y confirmado (FFFS=1); OFF solo manual o por firmware HP.\n'
            exit 0
        fi
        # Solo ON y OFF manual. No hay temporizadores ni watchdog en esta ruta.
        [ "$#" -eq 3 ] && [ "$2" = off ] && [ "$3" = --apply ] || \
            fail 'Uso: fan-max on|off --apply (pruebas temporizadas retiradas)'
        [ "$(read_ec ECON)" = 1 ] || fail 'EC no disponible; no se puede confirmar OFF'
        before=$(read_ec FFFS)
        if [ "$before" = 0 ]; then
            printf 'FFFS=0: modo de ventilacion maxima ya desactivado.\n'
            exit 0
        fi
        [ "$before" = 1 ] || fail 'FFFS invalido; no modificar firmware'
        wmi_write 27 4 00000000
        sleep 1
        after=$(read_ec FFFS)
        [ "$after" = 0 ] || fail 'Desactivacion FFFS no confirmada'
        printf 'FAN MAX OFF confirmado; FFFS=0.\n'
        ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
