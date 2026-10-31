#!/bin/sh
# Verificación local sin instalar servicios ni modificar el firmware.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

for cmd in sh c++; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Falta el comando requerido: $cmd" >&2; exit 1; }
done

printf '%s\n' '== Sintaxis de scripts =='
for f in ./*.sh ./rc.d/*; do
    [ -f "$f" ] || continue
    sh -n "$f"
done
printf '%s\n' 'OK: sintaxis Shell.'

printf '%s\n' '== Recursos Qt =='
if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import pathlib, xml.etree.ElementTree as ET
root = pathlib.Path.cwd()
tree = ET.parse(root / 'assets.qrc')
missing = []
for node in tree.findall('.//file'):
    path = root / (node.text or '').strip()
    if not path.is_file():
        missing.append(str(path.relative_to(root)))
if missing:
    raise SystemExit('Faltan recursos: ' + ', '.join(missing))
print('OK: XML válido y todos los recursos existen.')
PY
else
    echo 'AVISO: python3 no está disponible; se omite la validación XML.'
fi

printf '%s\n' '== Compilación aislada del daemon y cliente =='
tmp=$(/usr/bin/mktemp -d /tmp/omen-verify.XXXXXX)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Wpedantic omen-control-daemon.cpp -o "$tmp/omen-control-daemon"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Wpedantic omen-control-client.cpp -o "$tmp/omen-control-client"
printf '%s\n' 'OK: daemon y cliente compilan. No se han instalado ni ejecutado.'
printf '%s\n' 'Nota: la GUI Qt6 debe compilarse con install-full-kde.sh en FreeBSD.'
