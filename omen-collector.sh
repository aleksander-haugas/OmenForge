#!/bin/sh
# Colector de telemetría HP OMEN para FreeBSD.
# Publica muestras completas para la interfaz y registra solo cambios de estado.
# Una lectura de 0 RPM no demuestra por sí sola que exista un fallo: el firmware
# puede detener los ventiladores cuando no necesita refrigeración.
set -eu
umask 022

interval=${1:-3}
case "$interval" in ''|*[!0-9]*) echo 'Uso: sudo sh omen-collector.sh [segundos 2..60]' >&2; exit 2 ;; esac
[ "$interval" -ge 2 ] && [ "$interval" -le 60 ] || { echo 'Intervalo permitido: 2..60 segundos' >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo 'Ejecuta el colector como root; NO el GUI' >&2; exit 1; }
OMENCTL=${OMENCTL:-/usr/local/sbin/omenctl}
[ -x "$OMENCTL" ] || { echo "No existe omenctl: $OMENCTL" >&2; exit 1; }

OUTDIR=${OMEN_OUTDIR:-/var/run/omenctl}
[ ! -L "$OUTDIR" ] || { echo 'Salida es un enlace simbolico' >&2; exit 1; }
install -d -m 0755 "$OUTDIR"
[ -d "$OUTDIR" ] || exit 1
last_state=''

cleanup() { rm -f "${temp_status:-}" "${temp_error:-}"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

printf 'Colector HP OMEN iniciado cada %ss. Salida: %s/status\n' "$interval" "$OUTDIR"
printf 'Ctrl+C para detener. Solo lectura; los estados repetidos no generan avisos duplicados.\n'
while :; do
    temp_status=$(mktemp "$OUTDIR/.status.XXXXXXXX") || exit 1
    temp_error=$(mktemp "$OUTDIR/.error.XXXXXXXX") || exit 1
    if LC_ALL=C "$OMENCTL" status > "$temp_status" 2> "$temp_error"; then
        # No sustituir una muestra válida por una respuesta incompleta.
        if grep -q '^Fan 0: [0-9][0-9]* RPM$' "$temp_status" && \
           grep -q '^Fan 1: [0-9][0-9]* RPM$' "$temp_status"; then
            chmod 0644 "$temp_status"
            mv -f "$temp_status" "$OUTDIR/status"
            temp_status=''
            # La interfaz recibe todos los estados; solo el registro de consola se deduplica.
            state=$(sed -n 's/^Estado tacometros: //p' "$OUTDIR/status" | head -n 1)
            [ -n "$state" ] || state='OK'
            if [ "$state" != "$last_state" ]; then
                if [ "$state" = OK ]; then
                    [ -z "$last_state" ] || printf '%s | RECUPERADO: RPM validas.\n' "$(date '+%F %T')" >&2
                else
                    printf '%s | Estado de telemetría: %s\n' "$(date '+%F %T')" "$state" >&2
                    cat "$temp_error" >&2
                    if [ "$state" = CERO_SIN_VALIDAR ]; then
                        printf '%s\n' 'Las RPM no se han podido validar. Contrasta la temperatura y vuelve a muestrear; no se concluye que los ventiladores estén averiados.' >&2
                    fi
                fi
                last_state=$state
            fi
        else
            printf '%s | ERROR: muestra incompleta; se conserva la última muestra válida.\n' "$(date '+%F %T')" >&2
        fi
    else
        printf '%s | ERROR: falló omenctl; se conserva la última muestra válida.\n' "$(date '+%F %T')" >&2
        cat "$temp_error" >&2
    fi
    cleanup
    temp_status=''; temp_error=''
    sleep "$interval"
done
