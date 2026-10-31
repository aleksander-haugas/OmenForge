# HP OMEN Panel v0.4.16 — FreeBSD 15.1 / KDE Plasma 6

Mantenimiento de la aplicación Qt6 y del control local para HP OMEN. Esta versión elimina documentación obsoleta, quita un include sin uso, normaliza los recursos y añade una verificación local del paquete. Una lectura de 0 RPM no se presenta como avería confirmada. El firmware puede detener los ventiladores cuando la refrigeración activa no es necesaria.

## Instalación

Consulta [README-full-kde-install.md](README-full-kde-install.md) y ejecuta `sh ./install-full-kde.sh` desde esta carpeta.

## Verificación previa

Ejecuta `sh ./omen-verify-package.sh` para comprobar la sintaxis de los scripts, los recursos y compilar el daemon/cliente en un directorio temporal. Esto no sustituye el build Qt6 ni las pruebas del portátil.

## Diagnóstico

Después de instalar, ejecuta `sudo sh ./omen-diagnostics.sh`. El informe es de solo lectura; revísalo antes de compartirlo.

## Seguridad y límites

- `omen_power_auto` no se habilita ni se inicia automáticamente.
- No se fuerza FAN MAX ni se cambia la política térmica.
- `0 RPM` se registra como dato de telemetría; por sí solo no demuestra una avería ni confirma que el firmware haya detenido físicamente los ventiladores.
- La validación final de perfiles y comportamiento térmico debe hacerse en el portátil real.
