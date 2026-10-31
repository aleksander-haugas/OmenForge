# Validación pendiente — OMEN Panel v0.4.16

1. Ejecutar `sh ./omen-verify-package.sh` para validar los archivos y los componentes C++ independientes de Qt.
2. Compilar e instalar en FreeBSD 15.1 con `sh ./install-full-kde.sh`.
3. Ejecutar `sudo sh ./omen-diagnostics.sh` y revisar el informe antes de compartirlo.
4. Confirmar interfaz, scroll, daemon, cliente y colector.
5. Probar Eco, Balanced y Performance manualmente y observar temperatura, FFFS, HPCM y RPM.
6. Comprobar lecturas 0 RPM con temperaturas bajas y altas sin asumir una causa por la RPM sola.
7. Mantener `omen_power_auto` desactivado hasta validar selección de perfiles, sensores y conexión/desconexión de AC.
8. Verificar copias de seguridad y procedimiento de reversión.

## Límites

- No activar FAN MAX ni automatización térmica durante las pruebas estáticas.
- El diagnóstico no modifica servicios, `/etc/rc.conf`, perfiles ni registros del firmware.
- La validación real requiere el HP OMEN físico.
