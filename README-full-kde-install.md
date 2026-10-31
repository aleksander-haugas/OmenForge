# OMEN Panel v0.4.16 — extracción, build, instalación y refresco KDE (FreeBSD)

## 1. Dependencias

```sh
sudo pkg install cmake qt6-base
```

Asegúrate de que `sudo` funciona para tu usuario. No hace falta ejecutar el build como root.

## 2. Extraer el ZIP

Desde el directorio donde descargaste `omen-panel-qt6-v0.4.16-freebsd-kde.zip`:

```sh
cd ~/Downloads
unzip omen-panel-qt6-v0.4.16-freebsd-kde.zip
cd omen-panel-qt6-v0.4.16-freebsd-kde
```

Si tu ZIP tiene otro nombre o se extrajo a otra ruta, entra en la carpeta que contiene `CMakeLists.txt` y `install-full-kde.sh`.

## 3. Verificación previa opcional

```sh
sh ./omen-verify-package.sh
```

Comprueba scripts, XML de recursos y compila el daemon/cliente de forma aislada. No compila la interfaz Qt6.

## 4. Build + instalación completa

```sh
sh ./install-full-kde.sh
```

El script configura CMake en Release, compila, instala el parche de serialización con copias de seguridad, instala la aplicación Qt6, el `.desktop` y los iconos actualizados OMEN + daemon, y pide a KDE que reconstruya su caché. No modifica `/etc/rc.conf` ni arranca `omen_power_auto`.

## 5. Verificación

```sh
cmake --build build -j2
ls -l /usr/local/bin/omen-panel
ls -l /usr/local/share/applications/omen-panel.desktop
ls -l /usr/local/share/icons/hicolor/scalable/apps/omen-thermal-control.svg
ls -l /usr/local/share/icons/hicolor/256x256/apps/omen-thermal-control.png
sudo service omen_control_daemon status
sudo /usr/local/bin/omen-control-client status
```

Abre la app desde el menú de KDE buscando **HP OMEN Control**, o desde terminal:

```sh
/usr/local/bin/omen-panel
```

Si el icono antiguo sigue en el menú, ejecuta `kbuildsycoca6 --noincremental` como usuario de escritorio y cierra/abre sesión de Plasma.

## 6. Nota sobre el icono nuevo

El proyecto instala el icono desde `assets/omen-icon.svg` y `assets/omen-icon-256.png`, con el nombre de tema `omen-thermal-control`. Para incorporar un diseño nuevo, reemplaza esos dos archivos en la carpeta `assets/` antes de ejecutar el instalador. Mantén el nombre y el tamaño 256×256 para el PNG; el SVG debe ser válido. El archivo `assets.qrc` también incluye recursos de la app y puede contener el icono usado dentro de la ventana; si cambias el SVG, comprueba que `assets.qrc` apunta al archivo correcto y vuelve a compilar.

## 7. Resumen de cambios y pendientes

Lee [CHANGELOG-v0.4.16.md](CHANGELOG-v0.4.16.md) para los cambios de esta revisión y [PENDIENTES-v0.4.16.md](PENDIENTES-v0.4.16.md) para las validaciones todavía necesarias en el portátil real.

## 8. Seguridad y rollback

Se guardan copias con sufijo `.pre-full-kde-FECHA-HORA` para la GUI, el desktop y los iconos; el instalador de serialización crea sus propias copias `.pre-auto-serialization-FECHA-HORA` de daemon, cliente y scripts. El script no habilita el supervisor automático ni activa el experimento FAN MAX.
