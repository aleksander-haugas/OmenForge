#!/bin/sh
# HP OMEN v0.4.7 - root supervisor for automatic Power Mode (NOT manual fans)
# Reads CPU load (kern.cp_time), temperature, AC power, optional NVIDIA utilization.
# Whitelist Power Mode transitions only via the already tested omenctl-control.
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin; export PATH
BACKEND=/usr/local/libexec/omenctl-control
CLIENT=/usr/local/bin/omen-control-client
STATE=/var/run/omen-power-thermal.state
CONFIG=/usr/local/etc/omen-power-auto.conf
ACPI=/usr/local/sbin/acpi_call
EC='\_SB.PCI0.SBRG.EC0'
LOG(){ printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
INTERVAL=10; CONFIRM_SAMPLES=3; DWELL_SECONDS=120
ECO_CPU_MAX=18; PERFORMANCE_CPU_MIN=75; GPU_ECO_MAX=15; GPU_PERF_MIN=75
ECO_TEMP_MAX=55; ECO_TEMP_RELEASE=60; PERFORMANCE_TEMP_MAX=65
if [ -f "$CONFIG" ]; then
    [ "$(stat -f '%u' "$CONFIG")" -eq 0 ] || fail 'Config no pertenece a root'
    mode=$(stat -f '%Lp' "$CONFIG")
    case "${mode#?}" in *[2367]*) fail 'Config escribible por grupo/otros';; esac
    . "$CONFIG"
fi
for k in INTERVAL CONFIRM_SAMPLES DWELL_SECONDS ECO_CPU_MAX PERFORMANCE_CPU_MIN GPU_ECO_MAX GPU_PERF_MIN ECO_TEMP_MAX ECO_TEMP_RELEASE PERFORMANCE_TEMP_MAX;do
    eval "v=\${$k}"
    case "$v" in ''|*[!0-9]*) fail "Config invalida: $k";; esac
done
[ "$INTERVAL" -ge 5 ] && [ "$INTERVAL" -le 60 ] || fail 'INTERVAL fuera de rango'
[ "$CONFIRM_SAMPLES" -ge 2 ] && [ "$CONFIRM_SAMPLES" -le 8 ] || fail 'CONFIRM_SAMPLES fuera de rango'
[ "$DWELL_SECONDS" -ge 90 ] && [ "$DWELL_SECONDS" -le 3600 ] || fail 'DWELL_SECONDS fuera de rango'
[ "$ECO_TEMP_RELEASE" -gt "$ECO_TEMP_MAX" ] && [ "$ECO_TEMP_RELEASE" -lt 75 ] || fail 'ECO_TEMP_RELEASE debe ser mayor que ECO_TEMP_MAX y menor que 75'
read_state_field(){
    [ -r "$STATE" ] || return
    # Only strictly whitelisted labels are returned; state never executed.
    sed -n "s/^$1=//p" "$STATE" | head -n 1
}
read_ec(){ "$ACPI" -p "$EC.$1" 2>/dev/null || printf 'N/D\n'; }
get_temp(){
    v=$(sysctl -n "$1" 2>/dev/null) || { printf 'N/D\n'; return; }
    v=${v%C}
    if printf '%s\n' "$v" | awk '/^[0-9]+([.][0-9]+)?$/ {x=1} END {exit !x}';then printf '%s\n' "$v"; else printf 'N/D\n';fi
}
get_gpu_load(){
    for p in /usr/local/bin/nvidia-smi /usr/local/sbin/nvidia-smi; do
        if [ -x "$p" ]; then
            v=$("$p" --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d ' \r') || v=''
            case "$v" in ''|*[!0-9]*) break;; *) [ "$v" -le 100 ] && { printf '%s\n' "$v";return; } ;; esac
            break
        fi
    done
    printf 'N/D\n'
}
get_cpu_time(){
    sysctl -n kern.cp_time 2>/dev/null | awk '{if(NF<5) exit 1; for(i=1;i<=5;i++) if($i !~ /^[0-9]+$/) exit 1; print $1+$2+$3+$4+$5,$5}'
}
usage_cpu(){
    a=$(get_cpu_time) || { printf 'N/D\n';return; }
    sleep 1
    b=$(get_cpu_time) || { printf 'N/D\n';return; }
    awk -v a="$a" -v b="$b" 'BEGIN {
      split(a,A," ");split(b,B," ");dt=B[1]-A[1];di=B[2]-A[2];
      if(dt<=0||di<0||di>dt) print "N/D";else printf "%.0f\n",100*(dt-di)/dt
    }'
}
current_profile(){ case "$(read_ec HPCM)" in 48) echo balanced;;49) echo performance;;80) echo eco;;*) echo unknown;;esac;}
choose_profile(){
    # Never select performance on battery or high temperature; if sensors fail, HOLD.
    if [ "$ac" = 1 ] && [ "$temp_ok" -eq 1 ] && [ "$cpu_load" -ge "$PERFORMANCE_CPU_MIN" -o "$gpu_load" -ge "$GPU_PERF_MIN" ] && \
       awk -v a="$cpu_temp" -v b="$acpi_temp" -v m="$PERFORMANCE_TEMP_MAX" 'BEGIN{exit !(a<m&&b<m)}';then
       echo performance
    elif [ "$temp_ok" -eq 1 ] && [ "$cpu_load" -le "$ECO_CPU_MAX" ] && [ "$gpu_load" -le "$GPU_ECO_MAX" ] && \
         awk -v a="$cpu_temp" -v b="$acpi_temp" -v m="$eco_limit" 'BEGIN{exit !(a<m&&b<m)}';then
       echo eco
    else echo balanced;fi
}
case "${1:-}" in
 check)
    printf 'Perfil firmware=%s | HPCM=%s | FFFS=%s\n' "$(current_profile)" "$(read_ec HPCM)" "$(read_ec FFFS)"
    printf 'Automatic: intervalo=%ss, confirmacion=%s, permanencia minima=%ss; GPU requerida para seleccionar Eco/Performance.\n' "$INTERVAL" "$CONFIRM_SAMPLES" "$DWELL_SECONDS"
    printf 'La comprobacion no escribe al firmware.\n';;
 run)
    [ "$(id -u)" -eq 0 ] || fail 'Solo root'
    [ -x "$BACKEND" ] || fail 'Backend ausente'
    [ -x "$CLIENT" ] || fail 'Falta omen-control-client actualizado para cambios serializados'
    [ "$(read_state_field mode)" = automatic ] || fail 'El modo seleccionado no es Automatic'
    request_id=$(read_state_field request_id)
    case "$request_id" in ''|*[!0-9]*) fail 'Automatic requiere request_id numerico; vuelve a seleccionar Automatic desde el panel' ;; esac
    [ "${#request_id}" -ge 12 ] && [ "${#request_id}" -le 20 ] || fail 'request_id de Automatic fuera de rango'
    now=$(date +%s); last_change=0; candidate=''; count=0
    LOG "AUTO iniciado. Eco (CPU<=${ECO_CPU_MAX}%, GPU<=${GPU_ECO_MAX}%, temperaturas<${ECO_TEMP_MAX}C), Performance (CPU>=${PERFORMANCE_CPU_MIN}% o GPU>=${GPU_PERF_MIN}%, CA, temperaturas<${PERFORMANCE_TEMP_MAX}C); otro Balanced."
    while :;do
        [ "$(read_state_field mode)" = automatic ] || { LOG 'Mode cambiado fuera de AUTO. Saliendo.'; exit 0; }
        [ "$(read_state_field request_id)" = "$request_id" ] || { LOG 'request_id cambiado; saliendo para no aplicar una solicitud obsoleta.'; exit 0; }
        ac=$(sysctl -n hw.acpi.acline 2>/dev/null || printf N/D)
        cpu_temp=$(get_temp dev.amdtemp.0.core0.sensor0)
        acpi_temp=$(get_temp hw.acpi.thermal.tz0.temperature)
        cpu_load=$(usage_cpu)
        gpu_load=$(get_gpu_load)
        fffs=$(read_ec FFFS)
        temp_ok=0
        if [ "$cpu_temp" != N/D ] && [ "$acpi_temp" != N/D ] && [ "$cpu_load" != N/D ] && [ "$gpu_load" != N/D ] && \
          awk -v a="$cpu_temp" -v b="$acpi_temp" 'BEGIN{exit !(a>=0&&a<75&&b>=0&&b<75)}';then temp_ok=1;fi
        reason=''
        [ "$ac" = 1 ] || reason="${reason}AC_POWER,"
        [ "$fffs" = 0 ] || reason="${reason}FFFS,"
        [ "$cpu_temp" != N/D ] && [ "$acpi_temp" != N/D ] || reason="${reason}TEMP_UNAVAILABLE,"
        [ "$cpu_load" != N/D ] || reason="${reason}CPU_LOAD_UNAVAILABLE,"
        [ "$gpu_load" != N/D ] || reason="${reason}GPU_LOAD_UNAVAILABLE,"
        [ "$temp_ok" -eq 1 ] || reason="${reason}SENSOR_INVALID_OR_TEMP_GE75,"
        if [ -n "$reason" ];then
            candidate=''; count=0
            LOG "HOLD reasons=${reason%,} AC=$ac TEMP_OK=$temp_ok CPU=${cpu_temp}C ACPI=${acpi_temp}C usage=${cpu_load}% GPU=${gpu_load}% FFFS=$fffs"
            sleep "$INTERVAL";continue
        fi
        actual=$(current_profile)
        eco_limit=$ECO_TEMP_MAX
        [ "$actual" = eco ] && eco_limit=$ECO_TEMP_RELEASE
        target=$(choose_profile)
        if [ "$actual" = unknown ];then LOG 'HOLD: HPCM desconocido';sleep "$INTERVAL";continue;fi
        if [ "$actual" = "$target" ];then candidate='';count=0
        else
            if [ "$candidate" = "$target" ];then count=$((count+1));else candidate=$target;count=1;fi
            now=$(date +%s)
            # Safety exit: if ECO is already hot, do not wait 3 samples or
            # the normal dwell. Only switch to the established Balanced profile.
            hot_exit=0
            if [ "$actual" = eco ] && [ "$target" = balanced ] && \
               awk -v a="$cpu_temp" -v b="$acpi_temp" -v m="$ECO_TEMP_RELEASE" 'BEGIN{exit !(a>=m||b>=m)}';then
                hot_exit=1
            fi
            if { [ "$hot_exit" -eq 1 ] || [ "$count" -ge "$CONFIRM_SAMPLES" ]; } && \
               { [ "$hot_exit" -eq 1 ] || [ "$last_change" -eq 0 ] || [ "$((now-last_change))" -ge "$DWELL_SECONDS" ]; };then
                [ "$hot_exit" -eq 0 ] || LOG "Thermal exit ECO -> Balanced (sin espera; >=${ECO_TEMP_RELEASE}C)"
                [ "$(read_state_field mode)" = automatic ] || exit 0
                [ "$(read_state_field request_id)" = "$request_id" ] || { LOG 'request_id cambiado antes de aplicar; cancelado.'; exit 0; }
                LOG "Decision: $actual -> $target (CPU=${cpu_load}% GPU=${gpu_load}% CPUtemp=${cpu_temp}C ACPI=${acpi_temp}C)"
                if "$CLIENT" auto-profile "$target" "$request_id";then
                    new=$(current_profile)
                    if [ "$new" = "$target" ] && [ "$(read_state_field mode)" = automatic ] && [ "$(read_state_field request_id)" = "$request_id" ];then
                        last_change=$(date +%s)
                        LOG "Confirmado $new; estado comprometido por daemon";candidate='';count=0
                    else LOG "HOLD: confirmacion/estado no coincide ($new); no se escribe estado desde supervisor";candidate='';count=0;last_change=$(date +%s);fi
                else LOG 'HOLD: daemon rechazo cambio o solicitud obsoleta; estado no escrito por supervisor';candidate='';count=0;last_change=$(date +%s);fi
            fi
        fi
        sleep "$INTERVAL"
    done
    ;;
 *) fail 'Uso: omen-power-auto check|run';;
esac
