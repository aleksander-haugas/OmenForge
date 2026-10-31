#!/bin/sh
# Muestreador de integridad FAN MAX, solo lectura. No escribe WMI ni reactiva ventiladores.
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/sbin:/usr/local/bin; export PATH
interval=${1:-2}; samples=${2:-180}
case "$interval" in 2|3|5|10) : ;; *) echo 'Intervalo permitido: 2, 3, 5 o 10 segundos.' >&2; exit 64 ;; esac
case "$samples" in ''|*[!0-9]*) echo 'El número de muestras debe ser un entero.' >&2; exit 64 ;; esac
[ "$samples" -ge 1 ] && [ "$samples" -le 3600 ] || { echo 'Muestras permitidas: 1..3600.' >&2; exit 64; }
[ "$(id -u)" -eq 0 ] || { echo 'Ejecuta el diagnóstico con sudo.' >&2; exit 77; }
EC='\_SB.PCI0.SBRG.EC0'
read_ec() { /usr/local/sbin/acpi_call -p "$EC.$1" 2>/dev/null || printf unknown; }
state=/var/run/omen-power-thermal.state
log=/var/log/omen-fan-max-integrity.log
prev=''
i=0
while [ "$i" -lt "$samples" ]; do
    fffs=$(read_ec FFFS)
    hpcm=$(read_ec HPCM)
    mode=unknown
    if [ -r "$state" ]; then mode=$(sed -n 's/^mode=//p' "$state" | head -n 1); fi
    event=sample
    [ -z "$prev" ] || [ "$prev" = "$fffs" ] || event="FFFS_CHANGE_${prev}_TO_${fffs}"
    # FFFS=0 describe el estado solicitado al firmware; no demuestra un fallo
    # ni permite deducir las RPM físicas. Registrar el dato sin etiquetarlo como avería.
    if [ "$mode" = maximum ] && [ "$fffs" = 0 ]; then event="${event}_MAXIMUM_FFFS_OFF"; fi
    line="$(date '+%Y-%m-%dT%H:%M:%S%z') event=$event mode=$mode FFFS=$fffs HPCM=$hpcm"
    printf '%s\n' "$line" | tee -a "$log"
    prev=$fffs
    i=$((i+1))
    [ "$i" -eq "$samples" ] || sleep "$interval"
done
