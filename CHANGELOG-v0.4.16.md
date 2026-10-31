# Cambios — OMEN Panel v0.4.16

- Limpieza de documentación histórica duplicada y del archivo de muestra que no consume ningún componente.
- Eliminado un include de Qt sin uso en `main.cpp`.
- Normalizado el formato de `assets.qrc` para facilitar su revisión.
- Uniformados los mensajes de versión y el texto de inicio del colector.
- Añadida una verificación reproducible del paquete: sintaxis Shell, XML de recursos y compilación independiente del daemon/cliente C++.
- Sin cambios en los umbrales térmicos, perfiles, escrituras EC/WMI ni política de ventiladores.

## Validación

La verificación del paquete no sustituye la compilación Qt6 ni las pruebas de hardware en FreeBSD. La interfaz debe compilarse en el portátil objetivo y el supervisor automático debe permanecer desactivado hasta completar las pruebas térmicas.
