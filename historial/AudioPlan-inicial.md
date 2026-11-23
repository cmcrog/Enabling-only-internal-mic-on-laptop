# Micrófono interno del portátil (Realtek ALC257) — Solución aplicada

## Diagnóstico real

Había **dos problemas independientes**:

### 1. El códec capturaba del micrófono equivocado
El mixer interno del códec (nodo `0x23`, que alimenta el ADC `0x08`) tenía:

```
Node 0x23 [Audio Mixer]
  Amp-In vals: [0x80 0x80] [0x00 0x00] [0x80 0x80] [0x80 0x80] [0x80 0x80] [0x80 0x80]
  Connection:   0x18       0x19       0x1a       0x1b       0x1d       0x12
                mute      ABIERTO     mute       mute       mute       mute
```

- `0x19` = jack de micrófono externo → **abierto**
- `0x12` = micrófono interno → **muteado**

El driver elegía el pin externo porque el jack combinado de auriculares
(que comparte detección con el micrófono) se detecta como "conectado".
Ese mixer **no tiene control ALSA expuesto**, por eso ningún ajuste de
pavucontrol/amixer lo cambiaba.

### 2. El puerto interno se marcaba como "unplugged"
El archivo de perfil de PulseAudio/PipeWire
`analog-input-internal-mic.conf` contiene:

```
[Jack Mic]
state.plugged = no
```

Es decir: si el jack de micrófono externo está conectado, el puerto interno
se considera **no disponible**. Eso producía el texto "(unplugged)" en
pavucontrol, aunque el micrófono sí existe.

## Solución implementada

### A. Enrutado del códec (root)
- `hda-verb` mínimo compilado e instalado como `/usr/local/sbin/hda-verb`.
- `/usr/local/sbin/fix-internal-mic.sh`:
  - mutea las entradas `0x18, 0x19, 0x1a, 0x1b, 0x1d` del mixer `0x23`;
  - desmutea la entrada `0x12` (micrófono interno);
  - selecciona `0x12` en el selector `0x24`.
- Servicio de sistema `fix-internal-mic.service` (se ejecuta al arrancar).
- Hook `/usr/lib/systemd/system-sleep/fix-internal-mic` (reaplica al volver de suspensión).
- Regla sudoers `/etc/sudoers.d/fix-internal-mic` que permite a `roger`
  ejecutar **solo** `/usr/local/sbin/fix-internal-mic.sh` sin contraseña
  (el script es propiedad de root y no es escribible por el usuario).

### B. Disponibilidad del puerto (usuario)
- Override en `~/.config/alsa-card-profile/mixer/paths/analog-input-internal-mic.conf`:
  `[Jack Mic] state.plugged = unknown`
- Así el puerto "Internal Microphone" queda disponible aunque el jack
  externo esté detectado. PipeWire ACP lee esta ruta de usuario antes que
  la del sistema.

### C. Selección automática al iniciar sesión
- `~/bin/set-internal-mic.sh`:
  - espera a que exista la fuente;
  - reaplica el helper root (`sudo -n`);
  - pone la fuente predeterminada;
  - quita el mute;
  - volumen `30%` (equivale a **Internal Mic Boost 0 dB + Capture Volume 61**);
  - selecciona el puerto `analog-input-internal-mic`;
  - fuerza la ruta 0 de WirePlumber.
- Servicio de usuario `~/.config/systemd/user/set-internal-mic.service`
  (habilitado, se ejecuta al iniciar sesión).

## Estado actual verificado

```
Fuente predeterminada : alsa_input.pci-0000_06_00.6.analog-stereo
Puerto activo         : analog-input-internal-mic
Mute                  : no
Volumen               : 30 %
Ruta WirePlumber      : * 0 [INPUT] Internal Microphone [unknown] prio=8900
Mixer 0x23            : idx 5 (0x12) = 0x00 (abierto), resto muteado
```

Grabación de prueba: señal real, sin clipping (ambiente ≈ -43 dBFS con
margen suficiente para voz).

## Importante: ganancia

El volumen de PipeWire controla el **Internal Mic Boost** por tramos:

| Volumen PipeWire | Boost | Capture Volume |
|---|---|---|
| 0–45 % | 0 dB | hasta 63 |
| 50–65 % | +10 dB | 63 |
| 70–95 % | +20 dB | 63 |
| 100 % | +30 dB | 63 |

Con `30 %` se obtiene boost 0 dB y captura 61: **nivel seguro, sin
saturación**. Si se sube a 100 % se satura (eso era lo que pasaba antes).
Si hace falta más ganancia, subir como máximo al 30–35 %.

## Cómo probar

1. Cerrar y volver a abrir **pavucontrol** (para que relea el estado).
2. Ir a **Dispositivos de entrada**.
3. Debe aparecer **"Internal Microphone"** seleccionado y **sin "(unplugged)"**.
4. Hablar al micrófono del portátil: la barra de nivel debe moverse.
5. En la aplicación de turno, elegir "Internal Microphone" o "Predeterminado".

Si la aplicación ya estaba abierta, reiniciarla para que tome la nueva fuente.

## Reaplicar manualmente

```bash
~/bin/set-internal-mic.sh
```

## Deshacer todo

```bash
sudo ~/undo-audio-fix.sh
```

Elimina servicios, regla sudoers, helper root, override de ACP, scripts y
restaura el mixer original (mic externo abierto, interno muteado).

## Archivos implicados

- `/usr/local/sbin/hda-verb`
- `/usr/local/sbin/fix-internal-mic.sh`
- `/etc/systemd/system/fix-internal-mic.service`
- `/usr/lib/systemd/system-sleep/fix-internal-mic`
- `/etc/sudoers.d/fix-internal-mic`
- `~/.config/alsa-card-profile/mixer/paths/analog-input-internal-mic.conf`
- `~/bin/set-internal-mic.sh`
- `~/.config/systemd/user/set-internal-mic.service`
- `~/undo-audio-fix.sh`
