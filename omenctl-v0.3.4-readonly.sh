#!/bin/sh
# omenctl v0.3.4 - FreeBSD 15.1 / HP OMEN 8912
# SOLO LECTURA. No escribe registros EC, no cambia perfiles ni envia WMI de escritura.
# Usa el lector probado en el HP OMEN: acpi_call sin '-o i' para campos EC.
set -eu
LC_ALL=C
export LC_ALL

VERSION='0.3.4'
ACPI_CALL=${ACPI_CALL:-/usr/local/sbin/acpi_call}
SYSCTL_CMD=${SYSCTL_CMD:-sysctl}
# rc.d/service(8) puede usar PATH sin /usr/local/bin. Elegir ruta absoluta.
# Se puede sobreescribir con NVIDIA_SMI=/ruta/al/binario.
NVIDIA_SMI=${NVIDIA_SMI:-}
EC='\_SB.PCI0.SBRG.EC0'
WMI='\_SB.WMID.WMAA'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
HP OMEN 8912 / FreeBSD - omenctl v0.3.4 (SOLO LECTURA)
  sudo omenctl status
  sudo omenctl fans
  sudo omenctl profile
  sudo omenctl diagnose
  sudo omenctl watch [intervalo] [--count N] [--log RUTA]
  sudo omenctl help

  watch: intervalo 2..60 segundos (predeterminado 3).
  --count N: termina tras N muestras e imprime minimos/maximos.
  --log RUTA: agrega muestras TSV al archivo indicado; NO registra por defecto.
  Lecturas de 0 RPM se repiten; WMI contrasta ceros EC persistentes.
  No permite escribir EC, establecer RPM ni cambiar perfiles.
HELP
}

# Ayuda sin privilegios; el resto de funciones requiere root para evaluar ACPI.
case "${1:-status}" in help|-h|--help) usage; exit 0 ;; esac
[ -x "$ACPI_CALL" ] || fail "No existe acpi_call: $ACPI_CALL"
[ "$(id -u)" -eq 0 ] || fail 'Ejecuta con sudo.'

read_ec() {
    case "$1" in
        ECON|GPUT|SW2S|HPCM|FFFS|FS1H|FS1L|FS2H|FS2L|RPM1|RPM2|RPM3|RPM4) : ;;
        *) fail "Registro EC no permitido: $1" ;;
    esac
    byte=$("$ACPI_CALL" -p "$EC.$1") || fail "Fallo ACPI al leer $1"
    case "$byte" in ''|*[!0-9]*) fail "Valor EC invalido: $1=$byte" ;; esac
    [ "$byte" -ge 0 ] && [ "$byte" -le 255 ] || fail "Valor EC fuera de rango: $1=$byte"
    printf '%s\n' "$byte"
}

profile_name() {
    case "$1" in
        48) printf 'Balanced' ;; 49) printf 'Performance' ;; 80) printf 'Cool' ;;
        *) printf 'Desconocido (%s)' "$1" ;;
    esac
}

# Lee cuatro campos de tacometro. Dos lecturas consecutivas a cero no prueban
# que el motor fisico este parado: solo confirman la lectura del tacometro.
read_fans_once() {
    [ "$(read_ec ECON)" = 1 ] || fail 'ECON no activo'
    fh0=$(read_ec FS1H); fl0=$(read_ec FS1L)
    fh1=$(read_ec FS2H); fl1=$(read_ec FS2L)
    fan0=$((fh0 * 256 + fl0))
    fan1=$((fh1 * 256 + fl1))
}

sample_fans() {
    read_fans_once
    fan_note='OK'
    if [ "$fan0" -ne 0 ] && [ "$fan1" -ne 0 ]; then
        return 0
    fi

    before0=$fan0; before1=$fan1
    sleep 1
    read_fans_once
    if [ "$fan0" -ne 0 ] && [ "$fan1" -ne 0 ]; then
        fan_note='CERO_TRANSITORIO'
        printf 'AVISO: lectura EC transitoria de cero (%s/%s); repeticion: %s/%s RPM.\n' \
            "$before0" "$before1" "$fan0" "$fan1" >&2
        return 0
    fi

    # Solo si un tacometro repite cero, contrastar ese ventilador con la
    # consulta WMI HP 0x11 (solo lectura). No presupone que el motor se paro.
    ec0=$fan0; ec1=$fan1
    valid0=1; valid1=1
    if [ "$fan0" -eq 0 ]; then
        valid0=0
        if wmi0=$(wmi_query_fan 0 2>/dev/null); then
            wrpm0=${wmi0%%|*}
            if [ "$wrpm0" -gt 0 ] 2>/dev/null; then
                fan0=$wrpm0
                valid0=1
            fi
        fi
    fi
    if [ "$fan1" -eq 0 ]; then
        valid1=0
        if wmi1=$(wmi_query_fan 1 2>/dev/null); then
            wrpm1=${wmi1%%|*}
            if [ "$wrpm1" -gt 0 ] 2>/dev/null; then
                fan1=$wrpm1
                valid1=1
            fi
        fi
    fi

    if [ "$valid0" -eq 1 ] && [ "$valid1" -eq 1 ]; then
        fan_note='EC_CERO_WMI_OK'
        printf 'AVISO: EC devolvio cero dos veces (%s/%s); WMI recupero %s/%s RPM.\n' \
            "$ec0" "$ec1" "$fan0" "$fan1" >&2
    else
        fan_note='CERO_SIN_VALIDAR'
        printf 'ALERTA: RPM sin validar, EC=%s/%s; tras comprobacion WMI=%s/%s. ' \
            "$ec0" "$ec1" "$fan0" "$fan1" >&2
        printf 'Comprueba flujo de aire y temperaturas; no fuerces cargas.\n' >&2
    fi
}

get_sysctl_temp() {
    raw=$("$SYSCTL_CMD" -n "$1" 2>/dev/null) || { printf 'N/D\n'; return; }
    case "$raw" in
        *C) t=${raw%C} ;;
        *) printf 'N/D\n'; return ;;
    esac
    case "$t" in ''|*[!0-9.]*) printf 'N/D\n'; return ;; esac
    # Proteccion contra datos no numericos o decimales malformados.
    if awk -v v="$t" 'BEGIN {exit (v ~ /^[0-9]+([.][0-9]+)?$/) ? 0 : 1}'; then
        printf '%s\n' "$t"
    else
        printf 'N/D\n'
    fi
}

# En FreeBSD, nvidia-smi admite --query-gpu con csv,noheader,nounits.
# Fallos del controlador o GPU no disponible nunca abortan la lectura EC.
resolve_gpu_command() {
    if [ -n "$NVIDIA_SMI" ]; then
        command -v "$NVIDIA_SMI" >/dev/null 2>&1
        return $?
    fi
    for candidate in /usr/local/bin/nvidia-smi /usr/local/sbin/nvidia-smi /usr/bin/nvidia-smi; do
        if [ -x "$candidate" ]; then
            NVIDIA_SMI=$candidate
            return 0
        fi
    done
    return 1
}

get_gpu() {
    gpu_temp='N/D'; gpu_util='N/D'; gpu_power='N/D'
    gpu_state='SIN_BINARIO'
    if ! resolve_gpu_command; then return 0; fi
    # Mantener libre de errores toda la captura EC si falta el driver de GPU.
    gpu_state='CONSULTA_FALLIDA'
    rawgpu=$("$NVIDIA_SMI" -i 0 \
        --query-gpu=temperature.gpu,utilization.gpu,power.draw \
        --format=csv,noheader,nounits 2>/dev/null) || return 0
    gpu_state='FORMATO_INVALIDO'
    parsed=$(printf '%s\n' "$rawgpu" | awk -F, '
        NR == 1 {
            for (i=1; i<=3; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
            if ($1 ~ /^[0-9]+([.][0-9]+)?$/) t=$1; else t="N/D"
            if ($2 ~ /^[0-9]+([.][0-9]+)?$/) u=$2; else u="N/D"
            if ($3 ~ /^[0-9]+([.][0-9]+)?$/) p=$3; else p="N/D"
            print t "|" u "|" p
        }')
    [ -n "$parsed" ] || return 0
    gpu_temp=${parsed%%|*}
    rest=${parsed#*|}
    gpu_util=${rest%%|*}
    gpu_power=${rest#*|}
    gpu_state='OK'
    if [ "$gpu_temp" = N/D ] || [ "$gpu_util" = N/D ] || [ "$gpu_power" = N/D ]; then
        gpu_state='DATOS_PARCIALES'
    fi
}

read_snapshot() {
    sample_fans
    prof_id=$(read_ec HPCM)
    prof=$(profile_name "$prof_id")
    gpu_type=$(read_ec GPUT)
    sw2s=$(read_ec SW2S)
    maxfan=$(read_ec FFFS)
    cpu_temp=$(get_sysctl_temp dev.amdtemp.0.core0.sensor0)
    acpi_temp=$(get_sysctl_temp hw.acpi.thermal.tz0.temperature)
    get_gpu
}

status() {
    read_snapshot
    printf 'HP OMEN - FreeBSD | omenctl %s (solo lectura)\n' "$VERSION"
    printf 'Perfil termico: %s (HPCM=%s)\n' "$prof" "$prof_id"
    printf 'Fan 0: %s RPM\nFan 1: %s RPM\n' "$fan0" "$fan1"
    [ "$fan_note" = OK ] || printf 'Estado tacometros: %s\n' "$fan_note"
    printf 'CPU: %s C | ACPI: %s C | NVIDIA: %s C\n' "$cpu_temp" "$acpi_temp" "$gpu_temp"
    printf 'NVIDIA: %s %% utilizacion | %s W\n' "$gpu_util" "$gpu_power"
    printf 'Estado NVIDIA: %s\n' "$gpu_state"
    printf 'GPUT: %s | SW2S: %s | FFFS: %s\n' "$gpu_type" "$sw2s" "$maxfan"
}

fans() {
    sample_fans
    printf 'Fan 0: %s RPM\nFan 1: %s RPM\n' "$fan0" "$fan1"
    [ "$fan_note" = OK ] || printf 'Estado tacometros: %s\n' "$fan_note"
}

profile() {
    prof_id=$(read_ec HPCM)
    printf 'Perfil termico: %s (HPCM=%s)\n' "$(profile_name "$prof_id")" "$prof_id"
}

wmi_query_fan() {
    case "$1" in 0) idx=00 ;; 1) idx=01 ;; *) fail 'Indice fan invalido' ;; esac
    # Consulta WMI 0x11: HP GM (0x20008), 1 byte de entrada, sin escrituras.
    request="53454355080002001100000001000000${idx}$(printf '%0254d' 0)"
    [ "${#request}" -eq 288 ] || fail 'Peticion WMI invalida'
    response=$("$ACPI_CALL" -p "$WMI" -i 0 -i 2 -b "$request" -o b) || fail 'Fallo consulta WMI'
    case "$response" in 030000000C000000*) : ;; *) fail 'Cabecera de respuesta WMI inesperada' ;; esac
    [ "${#response}" -ge 72 ] || fail 'Respuesta WMI incompleta'
    case "$response" in *[!0-9a-fA-F]*) fail 'Respuesta WMI no hexadecimal' ;; esac
    signature=$(printf '%s' "$response" | cut -c49-56)
    code=$(printf '%s' "$response" | cut -c57-64)
    [ "$signature" = 50415353 ] && [ "$code" = 00000000 ] || fail 'Respuesta HP WMI no satisfactoria'
    data=$(printf '%s' "$response" | cut -c65-72)
    high=$(printf '%s' "$data" | cut -c5-6)
    low=$(printf '%s' "$data" | cut -c7-8)
    printf '%s|%s\n' "$((0x$high * 256 + 0x$low))" "$data"
}

diagnose() {
    printf '=== EC y temperaturas ===\n'
    status
    printf '\n=== Comparacion RPM EC / WMI ===\n'
    for index in 0 1; do
        result=$(wmi_query_fan "$index")
        rpm=${result%%|*}
        data=${result#*|}
        printf 'Fan %s WMI: %s RPM (bytes=%s)\n' "$index" "$rpm" "$data"
    done
    printf 'Nota: los valores EC y WMI son consecutivos, no simultaneos.\n'
}

min0=''; max0=''; min1=''; max1=''; mincpu=''; maxcpu=''; minacpi=''; maxacpi=''; mingpu=''; maxgpu=''
samples=0
warnings=0

update_range() {
    # $1 = etiqueta de variable; $2 = entero escalado por 10 para temperatura.
    key=$1; value=$2
    case "$key" in
        f0) [ -n "$min0" ] || { min0=$value; max0=$value; }
            [ "$value" -lt "$min0" ] && min0=$value
            [ "$value" -gt "$max0" ] && max0=$value ;;
        f1) [ -n "$min1" ] || { min1=$value; max1=$value; }
            [ "$value" -lt "$min1" ] && min1=$value
            [ "$value" -gt "$max1" ] && max1=$value ;;
        cpu) [ -n "$mincpu" ] || { mincpu=$value; maxcpu=$value; }
            [ "$value" -lt "$mincpu" ] && mincpu=$value
            [ "$value" -gt "$maxcpu" ] && maxcpu=$value ;;
        acpi) [ -n "$minacpi" ] || { minacpi=$value; maxacpi=$value; }
            [ "$value" -lt "$minacpi" ] && minacpi=$value
            [ "$value" -gt "$maxacpi" ] && maxacpi=$value ;;
        gpu) [ -n "$mingpu" ] || { mingpu=$value; maxgpu=$value; }
            [ "$value" -lt "$mingpu" ] && mingpu=$value
            [ "$value" -gt "$maxgpu" ] && maxgpu=$value ;;
    esac
    return 0
}

scale_tenths() {
    case "$1" in N/D|'') return 1 ;; esac
    awk -v v="$1" 'BEGIN {if (v !~ /^[0-9]+([.][0-9]+)?$/) exit 1; printf "%d\n", int(v*10+0.5)}'
}

format_tenths() {
    if [ -z "$1" ]; then printf 'N/D'; else printf '%s.%s' "$(( $1 / 10 ))" "$(( $1 % 10 ))"; fi
}

watch_summary() {
    printf '\n=== Resumen de monitorizacion: %s muestras ===\n' "$samples"
    if [ -z "$min0" ]; then
        printf 'Fan 0: N/D | Fan 1: N/D\n'
    else
        printf 'Fan 0: %s..%s RPM | Fan 1: %s..%s RPM\n' "$min0" "$max0" "$min1" "$max1"
    fi
    printf 'CPU: %s..%s C | ACPI: %s..%s C | NVIDIA: %s..%s C\n' \
        "$(format_tenths "$mincpu")" "$(format_tenths "$maxcpu")" \
        "$(format_tenths "$minacpi")" "$(format_tenths "$maxacpi")" \
        "$(format_tenths "$mingpu")" "$(format_tenths "$maxgpu")"
    printf 'Muestras con cero transitorio o confirmado: %s\n' "$warnings"
    if [ -n "${logfile:-}" ]; then printf 'Registro: %s\n' "$logfile"; fi
}

watch() {
    delay=3; limit=0; count_specified=0; logfile=''
    if [ "$#" -gt 0 ]; then
        case "$1" in --*) : ;; *) delay=$1; shift ;; esac
    fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --count) [ "$#" -ge 2 ] || fail 'Falta N tras --count'; limit=$2; count_specified=1; shift 2 ;;
            --log) [ "$#" -ge 2 ] || fail 'Falta ruta tras --log'; logfile=$2; shift 2 ;;
            *) fail "Opcion watch desconocida: $1" ;;
        esac
    done
    case "$delay" in ''|*[!0-9]*) fail 'Intervalo debe ser entero 2..60' ;; esac
    [ "$delay" -ge 2 ] && [ "$delay" -le 60 ] || fail 'Intervalo permitido: 2..60 segundos'
    case "$limit" in ''|*[!0-9]*) fail '--count requiere un entero positivo' ;; esac
    if [ "$count_specified" -eq 1 ]; then
        [ "$limit" -ge 1 ] && [ "$limit" -le 1000000 ] || fail '--count debe ser 1..1000000'
    fi

    if [ -n "$logfile" ]; then
        case "$logfile" in /*) : ;; *) fail '--log requiere ruta absoluta' ;; esac
        [ -d "$(dirname "$logfile")" ] || fail 'No existe el directorio del registro'
        [ ! -L "$logfile" ] || fail 'No se permite registrar en un enlace simbolico'
        umask 077
        if [ ! -e "$logfile" ]; then
            printf 'timestamp\tperfil\tfan0_rpm\tfan1_rpm\tcpu_c\tacpi_c\tnvidia_c\tnvidia_uso_pct\tnvidia_w\testado_tacometro\n' >> "$logfile" || fail 'No se pudo abrir archivo de registro'
        fi
        [ -f "$logfile" ] || fail 'El destino del registro no es un archivo normal'
    fi
    trap 'watch_summary; exit 130' INT
    trap 'watch_summary; exit 143' TERM
    printf 'Monitor cada %s s. Ctrl+C para terminar. Solo lectura.\n' "$delay"
    while :; do
        read_snapshot
        samples=$((samples + 1))
        timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
        printf '%s | %-11s | F0 %4s | F1 %4s RPM | CPU %s C | ACPI %s C | NVIDIA %s C | %s\n' \
            "$timestamp" "$prof" "$fan0" "$fan1" "$cpu_temp" "$acpi_temp" "$gpu_temp" "$fan_note"
        [ "$fan_note" = OK ] || warnings=$((warnings + 1))
        # Ceros aislados no contaminan las estadisticas; inconsistencias se etiquetan.
        if [ "$fan_note" != CERO_TRANSITORIO ] && [ "$fan_note" != CERO_SIN_VALIDAR ]; then
            update_range f0 "$fan0"
            update_range f1 "$fan1"
        fi
        x=$(scale_tenths "$cpu_temp") && update_range cpu "$x" || :
        x=$(scale_tenths "$acpi_temp") && update_range acpi "$x" || :
        x=$(scale_tenths "$gpu_temp") && update_range gpu "$x" || :
        if [ -n "$logfile" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$timestamp" "$prof" "$fan0" "$fan1" "$cpu_temp" "$acpi_temp" \
                "$gpu_temp" "$gpu_util" "$gpu_power" "$fan_note" >> "$logfile" \
                || fail 'No se pudo escribir el archivo de registro'
        fi
        if [ "$limit" -ne 0 ] && [ "$samples" -ge "$limit" ]; then break; fi
        sleep "$delay"
    done
    trap - INT TERM
    watch_summary
}

case "${1:-status}" in
    status) [ "$#" -le 1 ] || fail 'Uso: status'; status ;;
    fans) [ "$#" -eq 1 ] || fail 'Uso: fans'; fans ;;
    profile) [ "$#" -eq 1 ] || fail 'Uso: profile'; profile ;;
    diagnose) [ "$#" -eq 1 ] || fail 'Uso: diagnose'; diagnose ;;
    watch) shift; watch "$@" ;;
    set-profile|set-fan|fan-set|set-max) fail 'Las escrituras al firmware estan DESHABILITADAS en v0.3.2.' ;;
    *) usage >&2; exit 2 ;;
esac
