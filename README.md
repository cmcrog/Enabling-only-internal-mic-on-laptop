# Micrófono interno del portátil — diagnóstico y solución

**Equipo de referencia:** portátil con códec **Realtek ALC257**, tarjeta HDA
`pci-0000_06_00.6` (Apollo/Ryzen HD Audio Controller), Debian forky/sid,
kernel `7.3.4+deb14-amd64`, PipeWire + WirePlumber 0.5.19.

**Resultado:** el micrófono interno queda como entrada predeterminada siempre,
aunque haya auriculares o micrófono externo conectados. Se aplica solo al
arrancar, al iniciar sesión y al volver de suspensión.

---

## Índice

1. [El síntoma](#1-el-síntoma)
2. [Cómo se diagnosticó](#2-cómo-se-diagnosticó)
3. [Las dos causas reales](#3-las-dos-causas-reales)
4. [Qué hace la solución](#4-qué-hace-la-solución)
5. [Ganancia: por qué 30 % y no 100 %](#5-ganancia-por-qué-30--y-no-100-)
6. [¿Es permanente o hay que repetirlo?](#6-es-permanente-o-hay-que-repetirlo)
7. [Instalar en una instalación nueva de Linux](#7-instalar-en-una-instalación-nueva-de-linux)
8. [Verificar que funciona](#8-verificar-que-funciona)
9. [Uso diario y soluciones rápidas](#9-uso-diario-y-soluciones-rápidas)
10. [Desinstalar y volver atrás](#10-desinstalar-y-volver-atrás)
11. [Contenido de esta carpeta](#11-contenido-de-esta-carpeta)
12. [Evidencia y notas técnicas](#12-evidencia-y-notas-técnicas)

---

## 1. El síntoma

- En **pavucontrol → Dispositivos de entrada**, el puerto
  **“Internal Microphone”** aparecía como **“(unplugged)”**.
- El micrófono interno no captaba nada, aunque se seleccionara a mano.
- Con auriculares conectados, PipeWire elegía el micrófono del jack externo.
- Ajustar volumen, mute o “perfil” en pavucontrol no cambiaba nada.

El usuario quería que el micrófono **interno** fuera siempre el predeterminado.

---

## 2. Cómo se diagnosticó

### 2.1. Descartar lo obvio

```bash
pactl info
pactl list sources short
pactl list cards
amixer -c 1 controls
```

La fuente existía:

```
alsa_input.pci-0000_06_00.6.analog-stereo
```

y la tarjeta tenía perfil dúplex, pero el puerto interno figuraba como no
disponible. Los controles ALSA visibles (`Capture Volume`, `Internal Mic Boost`,
`Capture Switch`, `Auto-Mute Mode`) estaban bien; ninguno explicaba el silencio.

### 2.2. Inspeccionar el códec HDA directamente

El códec expone su topología en `/proc/asound/card1/codec#0`. Ahí se vio que
el ADC que captura es el nodo `0x08` y que se alimenta del **Audio Mixer
`0x23`**:

```
Node 0x23 [Audio Mixer] wcaps 0x20010b: Stereo Amp-In
  Amp-In vals:  [0x80 0x80] [0x00 0x00] [0x80 0x80] [0x80 0x80] [0x80 0x80] [0x80 0x80]
  Connection: 6
     0x18 0x19 0x1a 0x1b 0x1d 0x12
```

Cada `Amp-In vals` corresponde a una conexión, en el mismo orden:

| Índice | Nodo | Significado | Estado encontrado |
|---|---|---|---|
| 0 | `0x18` | entrada auxiliar | muteado (`0x80`) |
| 1 | `0x19` | **micrófono externo (jack)** | **abierto (`0x00`)** |
| 2 | `0x1a` | entrada auxiliar | muteado |
| 3 | `0x1b` | entrada auxiliar | muteado |
| 4 | `0x1d` | entrada auxiliar | muteado |
| 5 | `0x12` | **micrófono interno** | **muteado (`0x80`)** |

Los pines lo confirman:

```
Node 0x12: Pin Default 0x90a60120: [Fixed] Mic at Int N/A   ← interno
Node 0x19: Pin Default 0x04a11030: [Jack]  Mic at Ext Right ← externo
```

Y el selector del ADC (`0x24`) ya apuntaba al interno:

```
Node 0x24 [Audio Selector]
  Connection: 2
     0x12* 0x13
```

**Conclusión:** el hardware estaba capturando del pin externo (`0x19`) y el
micrófono interno (`0x12`) estaba silenciado en el mezclador.

### 2.3. Por qué amixer y pavucontrol no lo arreglaban

Ese mezclador **no tiene ningún control ALSA expuesto**. No aparece en
`amixer -c 1 controls`, así que ningún programa “normal” podía abrirlo. Hay que
escribir el registro HDA directamente en el dispositivo `hwdep`
(`/dev/snd/hwC1D0`).

Para eso se compiló un `hda-verb` mínimo (incluido en `scripts/hda-verb.c`).
Abrir ese dispositivo requiere `CAP_SYS_RAWIO`; pertenecer al grupo `audio` no
basta, por eso el arreglo necesita root.

### 2.4. La segunda causa: el perfil marcaba “unplugged”

El archivo de ALSA Card Profile
`analog-input-internal-mic.conf` trae:

```ini
[Jack Mic]
state.plugged = no
state.unplugged = unknown
```

Es decir: **si el jack de micrófono externo está conectado, el puerto interno se
considera no disponible**. Como el jack combinado de auriculares comparte
detección con el micrófono, el puerto interno aparecía como “unplugged” aunque
el micrófono interno exista y funcione.

La solución es un override de usuario que cambia esa línea a `unknown`.

---

## 3. Las dos causas reales

| # | Causa | Efecto |
|---|---|---|
| 1 | Mezclador `0x23` del ALC257 con `0x19` (externo) abierto y `0x12` (interno) muteado | El códec captaba del jack externo; el interno estaba en silencio |
| 2 | `[Jack Mic] state.plugged = no` en el perfil ACP | pavucontrol mostraba “Internal Microphone (unplugged)” y no dejaba elegirlo |

Las dos había que corregirlas: la primera para que **haya señal**, la segunda
para que el puerto **aparezca disponible y seleccionable**.

---

## 4. Qué hace la solución

```
Arranque / reanudación
        │
        ▼
fix-internal-mic.service  (root)
        │  escribe registros HDA en el códec:
        │    · mutea 0x18 0x19 0x1a 0x1b 0x1d
        │    · abre 0x12 (micrófono interno)
        │    · selector 0x24 -> 0x12
        ▼
Códec ALC257 captando del micrófono interno
        ▲
        │ reaplica tras suspensión
/usr/lib/systemd/system-sleep/fix-internal-mic

Inicio de sesión
        │
        ▼
set-internal-mic.service  (usuario)
        │  · fuente predeterminada = fuente con puerto interno
        │  · puerto = analog-input-internal-mic
        │  · mute = no
        │  · volumen = 30 %
        │  · ruta de WirePlumber = Internal Microphone
        ▼
PipeWire / WirePlumber usando el micrófono interno

Uso (captura)
        │
        ▼
mic-watch.service  (usuario, reactivo)
        │  detecta eventos de PipeWire (source-output nuevo,
        │  fuente a RUNNING, cambio de tarjeta) y reaplica
        │  el mezclador SOLO cuando hace falta
        ▼
Sin tocar ahorro de energía: el códec se suspende y despierta solo
```

Componentes:

| Componente | Ruta | Función |
|---|---|---|
| `hda-verb` | `/usr/local/sbin/hda-verb` | Envía verbos HDA al códec (root) |
| Helper | `/usr/local/sbin/fix-internal-mic.sh` | Corrige el mezclador `0x23` y el selector `0x24` |
| Servicio de sistema | `/etc/systemd/system/fix-internal-mic.service` | Aplica el arreglo al arrancar |
| Hook de suspensión | `/usr/lib/systemd/system-sleep/fix-internal-mic` | Lo reaplica al volver de suspensión |
| Regla sudoers | `/etc/sudoers.d/fix-internal-mic` | Permite al usuario ejecutar **solo** el helper sin contraseña |
| Override ACP | `~/.config/alsa-card-profile/mixer/paths/analog-input-internal-mic.conf` | Evita el “unplugged” del puerto interno |
| Script de usuario | `~/bin/set-internal-mic.sh` | Deja fuente, puerto, mute, volumen y ruta |
| Servicio de usuario | `~/.config/systemd/user/set-internal-mic.service` | Ejecuta el script al iniciar sesión |
| Vigilante de PipeWire | `~/.config/systemd/user/mic-watch.service` | Reaplica el mezclador cuando PipeWire despierta el códec |

La regla sudoers es deliberadamente mínima:

```
<usuario> ALL=(root) NOPASSWD: /usr/local/sbin/fix-internal-mic.sh
```

No da sudo general. Además, el helper es propiedad de root y no es escribible
por el usuario, así que no se puede modificar para escalar privilegios.

---

## 5. Ganancia: por qué 30 % y no 100 %

En este códec, el volumen de PipeWire **no** controla linealmente el
`Capture Volume`. Primero mueve el **Internal Mic Boost** en pasos de +10 dB y
solo después ajusta el `Capture Volume`:

| Volumen PipeWire | Internal Mic Boost | Capture Volume |
|---|---|---|
| 0–45 % | 0 dB | 0–63 |
| 50–65 % | +10 dB | 63 |
| 70–95 % | +20 dB | 63 |
| 100 % | **+30 dB** | 63 |

Por eso ponerlo al 100 % saturaba: RMS ≈ −3 dBFS y decenas de miles de muestras
recortadas.

Mediciones con `parec` (48 kHz, s16le, estéreo, ambiente silencioso):

| Volumen | Boost | Capture | RMS | Pico | Clipping |
|---|---|---|---|---|---|
| 25 % | 0 dB | 54 | −42.2 dBFS | −27.1 dBFS | no |
| **30 %** | **0 dB** | **61** | **−39.2 dBFS** | **−24.9 dBFS** | **no** |
| 35 % | 0 dB | 63 | −29.6 dBFS | −1.3 dBFS | no |

**Ajuste final: 30 %.** Deja margen suficiente para voz sin acercarse al
límite. Si hiciera falta más nivel, subir como máximo a **35 %**; nunca al
100 %. Los detalles están en `evidencia/pruebas-ganancia.txt`.

---

## 6. ¿Es permanente o hay que repetirlo?

**La configuración es permanente. Lo que es volátil es el estado del hardware.**

Los registros del códec (`0x23`, `0x24`) se reinician al apagar, al arrancar y
al volver de suspensión: es el driver quien vuelve a su estado por defecto. Por
eso hay un servicio que los reaplica. Es el mismo concepto que el volumen: el
hardware arranca en un estado concreto y el sistema lo restaura.

Además, cuando el códec entra en ahorro de energía (`power_save=10`), el driver
reaplica su estado por defecto al despertar. **La solución no desactiva el
ahorro de energía** (se respeta `power_save=10` y `control=auto`): en su lugar
usa un vigilante de PipeWire (`mic-watch.service`) que detecta el instante en
que se va a usar el micrófono y reaplica el mezclador entonces. El códec sigue
suspendiéndose cuando está inactivo.

Lo que queda guardado en disco:

- el helper y el binario `hda-verb`;
- las unidades de systemd y el hook de suspensión;
- la regla sudoers;
- el override del perfil de audio;
- el script de usuario, su servicio y el vigilante `mic-watch.service`.

**No hay que ejecutar nada en cada inicio de sesión.** Todo se aplica solo.

---

## 7. Instalar en una instalación nueva de Linux

El script **`solucion-mic-interno.sh`** es autocontenido: lleva dentro el código
de `hda-verb`, el helper, las unidades de systemd, el override del perfil y el
script de usuario. No depende de `/tmp` ni de esta carpeta.

### 7.1. Antes de empezar

- Debe ser **el mismo modelo de portátil** (Realtek ALC257). En otro códec los
  nodos HDA pueden ser distintos; el script **se niega a aplicarlo** si no
  encuentra un ALC257, para no dejar el equipo sin micrófono.
- Debe haber una sesión gráfica con **PipeWire + WirePlumber**.
- Hacen falta `pactl`, `wpctl`, `systemd`, `visudo` y un compilador `cc`/`gcc`.
  Si falta algo, el script muestra el comando de instalación según la distro.

Ejemplos:

```bash
# Debian / Ubuntu
sudo apt install pipewire pipewire-pulse wireplumber pulseaudio-utils alsa-utils gcc

# Arch / Manjaro
sudo pacman -S pipewire pipewire-pulse wireplumber libpulse alsa-utils gcc
```

### 7.2. Instalar

Copia la carpeta (o solo el script) a la instalación nueva y ejecuta:

```bash
chmod +x solucion-mic-interno.sh
sudo ./solucion-mic-interno.sh
```

Si el script no es ejecutable, también sirve:

```bash
sudo bash solucion-mic-interno.sh
```

El script hace todo esto:

1. comprueba dependencias y detecta el ALC257 (tarjeta y codec pueden tener
   otro número; los busca por nombre);
2. compila e instala `hda-verb`;
3. instala el helper root, el servicio de sistema y el hook de suspensión;
4. crea la regla sudoers limitada para el usuario real;
5. copia los perfiles de audio del sistema al usuario, crea una copia de
   seguridad si ya había configuración y parchea `[Jack Mic]`;
6. instala el script y el servicio de usuario;
7. activa todo, reinicia WirePlumber y aplica el arreglo;
8. muestra una verificación del mezclador y de PipeWire.

Al terminar, **cierra la sesión y vuelve a entrar** (o reinicia) para probar el
flujo real de inicio de sesión.

> La carpeta incluye también **`deshacer-cambios.sh`**, un script de rollback
> autocontenido. Guárdalo junto al instalador: permite revertir todo aunque
> elimines `solucion-mic-interno.sh`.

### 7.3. Verificar el estado en cualquier momento

```bash
./solucion-mic-interno.sh --estado
```

No necesita root ni cambia nada. Debe mostrar:

```
Mezclador 0x23: entrada interna (idx 5 / 0x12) ABIERTA.
Fuente predeterminada: alsa_input.<tarjeta>.analog-stereo
Active Port: analog-input-internal-mic
```

### 7.4. Alternativa: instalar desde la carpeta por piezas

Si prefieres el método “clásico” con los archivos separados:

```bash
sudo ./scripts/instalar.sh
```

Ese atajo llama al mismo script todo-en-uno, así que el resultado es idéntico.

### 7.5. Qué hace exactamente el instalador con el usuario

- Usa el usuario que invocó `sudo` (`SUDO_USER`). Si no existe, elige el primer
  usuario humano (UID ≥ 1000).
- Instala en **su** `$HOME`, no en `/root`.
- Si `~/.config/alsa-card-profile` ya tenía contenido, guarda una copia en
  `~/.config/alsa-card-profile.backup-<fecha>` antes de tocar nada.

### 7.6. Script para deshacer los cambios

**`deshacer-cambios.sh`** es independiente del instalador y hace el rollback
completo:

```bash
sudo ./deshacer-cambios.sh
```

También existe el atajo:

```bash
sudo ./scripts/desinstalar.sh
```

Y el instalador tiene la misma acción:

```bash
sudo ./solucion-mic-interno.sh --desinstalar
```

Los tres caminos hacen lo mismo. El script `deshacer-cambios.sh` está pensado
para copiarse solo (por ejemplo, a un USB) junto con el instalador, de modo que
siempre haya una forma de revertir.

---

## 8. Verificar que funciona

### 8.1. Estado técnico

```bash
./solucion-mic-interno.sh --estado
```

También se puede comprobar a mano:

```bash
# Mezclador: la última entrada debe ser [0x00 0x00] (interna abierta)
awk '/^Node 0x23 /{f=1} f{print} f && /^Node / && !/^Node 0x23 /{exit}' \
    /proc/asound/card1/codec#0 | grep "Amp-In vals"

# Fuente y puerto
pactl get-default-source
pactl list sources | grep -E "Mute:|Volume:|Active Port"
```

### 8.2. pavucontrol

1. Abre **pavucontrol**.
2. Ve a **Dispositivos de entrada**.
3. Debe aparecer **“Internal Microphone”** seleccionado y **sin
   “(unplugged)”**.
4. Habla al micrófono del portátil: la barra de nivel debe moverse.
5. En Discord/Brave/OBS elige **“Internal Microphone”** o **“Predeterminado”**.

La captura de referencia está en
`evidencia/pavucontrol-internal-mic.png`.

### 8.3. Prueba después de reiniciar

La prueba definitiva es reiniciar el equipo:

```bash
sudo reboot
```

Después del arranque y del inicio de sesión:

```bash
./solucion-mic-interno.sh --estado
```

Debe seguir mostrando el mezclador correcto, la fuente predeterminada y el
puerto interno. Si eso ocurre, la persistencia funciona.

### 8.4. Prueba después de suspender

Suspende el equipo, vuelve a entrar y repite `--estado`. El hook
`system-sleep` reaplica el mezclador al recibir `post`.

---

## 9. Uso diario y soluciones rápidas

- **No cambies el volumen del micrófono por encima de 30–35 %.** A partir de
  ahí el códec aplica +10/+20/+30 dB de boost y satura.
- Si una aplicación ya estaba abierta cuando se aplicó el arreglo, **reiníciala**
  para que vuelva a enumerar los dispositivos.
- **No hace falta ejecutar nada** al iniciar sesión.

### Si algo falla

| Síntoma | Qué comprobar |
|---|---|
| Sigue apareciendo “unplugged” | `systemctl --user restart wireplumber` y vuelve a abrir pavucontrol. Comprueba el override ACP. |
| No hay señal | `./solucion-mic-interno.sh --estado`. Si el mezclador no está bien: `sudo /usr/local/sbin/fix-internal-mic.sh`. |
| La captura está muda | `pactl set-source-mute @DEFAULT_SOURCE@ 0`, y revisa la tecla de mute del portátil. |
| Suena saturado | Baja el volumen de la fuente a 30 %. |
| Tras una actualización cambió el número de tarjeta | Los scripts detectan el códec y la fuente por nombre; no dependen de `card1`. |
| El servicio de usuario no arrancó | `systemctl --user status set-internal-mic.service` y `journalctl --user -u set-internal-mic.service`. |
| El servicio de sistema falló | `systemctl status fix-internal-mic.service` y `journalctl -u fix-internal-mic.service`. |

Reaplicar a mano:

```bash
~/bin/set-internal-mic.sh
```

Logs útiles:

```bash
journalctl -u fix-internal-mic.service -b
journalctl --user -u set-internal-mic.service -b
```

---

## 10. Desinstalar y volver atrás

La forma recomendada es el script de rollback incluido:

```bash
sudo ./deshacer-cambios.sh
```

Alternativas equivalentes:

```bash
sudo ./scripts/desinstalar.sh                    # atajo de la carpeta
sudo ./solucion-mic-interno.sh --desinstalar     # acción del instalador
sudo ~/undo-audio-fix.sh                         # acceso directo del usuario
```

`deshacer-cambios.sh` es **autocontenido**: no depende del instalador ni de los
demás archivos de la carpeta. Por eso conviene conservarlo junto al instalador
(y copiarlo también a la instalación nueva).

El desinstalador:

1. restaura el mezclador original (micrófono externo `0x19` abierto, interno
   `0x12` muteado);
2. desactiva y elimina el servicio de sistema, el de usuario y el hook de
   suspensión;
3. elimina la regla sudoers, el helper y `hda-verb`;
4. elimina el override del perfil de audio y, si el instalador había guardado
   una copia de la configuración previa, **la restaura**;
5. elimina el script de usuario;
6. reinicia WirePlumber para que vuelva a detectar los dispositivos.

Después, cierra y vuelve a abrir pavucontrol (o reinicia la sesión). Ten en
cuenta que el estado original del hardware capta del **micrófono externo**, no
del interno; es el comportamiento de fábrica del driver.

---

## 11. Contenido de esta carpeta

```
audio-mic-fix/
├── README.md                        ← este documento
├── solucion-mic-interno.sh          ← INSTALADOR TODO-EN-UNO (nuevo Linux)
├── deshacer-cambios.sh              ← ROLLBACK TODO-EN-UNO (autocontenido)
├── scripts/
│   ├── instalar.sh                  ← atajo que llama al instalador
│   ├── desinstalar.sh               ← atajo que llama al rollback
│   ├── fix-internal-mic.sh          ← helper root (copia de referencia)
│   ├── set-internal-mic.sh          ← script de usuario (copia de referencia)
│   └── hda-verb.c                   ← fuente del binario hda-verb
├── systemd/
│   ├── fix-internal-mic.service     ← servicio de sistema
│   ├── fix-internal-mic-sleep       ← hook de suspensión
│   ├── set-internal-mic.service     ← servicio de usuario
│   └── mic-watch.service            ← vigilante reactivo de PipeWire
├── config/
│   ├── analog-input-internal-mic.conf   ← override ACP de referencia
│   └── sudoers-fix-internal-mic         ← plantilla de la regla sudoers
├── evidencia/
│   ├── estado-actual.txt            ← volcado del estado verificado
│   ├── codec-antes-despues.txt      ← mezclador 0x23 antes y después
│   ├── pruebas-ganancia.txt         ← medidas de volumen y clipping
│   └── pavucontrol-internal-mic.png ← captura de pavucontrol
└── historial/
    ├── AudioPlan-inicial.md         ← plan original del diagnóstico
    ├── install-fix-original.sh      ← primer instalador usado
    └── undo-audio-fix-inicial.sh    ← primer script de rollback
```

> Los archivos de `scripts/`, `systemd/` y `config/` son copias de referencia
> de lo que instala el script. El instalador y el rollback **no** los necesitan:
> llevan todo embebido. Sirven para leer, auditar o reinstalar a mano.
>
> Para llevar la solución a otro equipo bastan dos archivos:
> `solucion-mic-interno.sh` y `deshacer-cambios.sh`.

---

## 12. Evidencia y notas técnicas

### Codificación de los verbos HDA usados

Para `SET_AMP_GAIN_MUTE` en un amp de entrada:

```
0x4000  amp de entrada (input amp)
0x2000  canal izquierdo
0x1000  canal derecho
(index << 8)
0x80    mute
g     ganancia en los bits 6:0
```

Ejemplos:

| Verbo | Significado |
|---|---|
| `0x23 0x300 0x7180` | mezclador `0x23`, índice 1 (`0x19`, externo), mute |
| `0x23 0x300 0x7500` | mezclador `0x23`, índice 5 (`0x12`, interno), sin mute, ganancia 0 |
| `0x23 0xb00 0x0005` | lee el amp del índice 5 |
| `0x24 0x701 0x0` | selector `0x24`, entrada 0 (`0x12`) |

El binario `hda-verb` abre `/dev/snd/hwC<tarjeta>D<codec>` y usa
`HDA_IOCTL_VERB_WRITE`. Requiere `CAP_SYS_RAWIO`; por eso el helper se ejecuta
como root.

### Por qué un servicio y no un simple `amixer`

Porque el mezclador `0x23` **no está expuesto** como control ALSA. `amixer`
solo ve `Capture Volume`, `Internal Mic Boost`, `Capture Switch` y `Auto-Mute
Mode`; ninguno de ellos enruta la entrada correcta. La corrección real solo se
puede hacer escribiendo el registro HDA.

### Por qué el hook de suspensión

Al suspender, el driver `snd-hda-intel` puede reinicializar el códec y devolver
el mezclador a su estado por defecto. El hook de `systemd-sleep` se ejecuta con
el argumento `post` al volver y reaplica los verbos.

### Comprobaciones realizadas

- `GET 0x23 idx1` antes: `0x0` (externo abierto); después: `0x80` (muteado).
- `GET 0x23 idx5` antes: `0x80` (interno muteado); después: `0x0` (abierto).
- Volcado del códec: solo la entrada 5 queda en `0x00 0x00`.
- `pactl`: fuente predeterminada correcta, `Mute: no`, `Active Port:
  analog-input-internal-mic`.
- `wpctl`: ruta `0 [INPUT] Internal Microphone`.
- pavucontrol: puerto “Internal Microphone”, sin “(unplugged)”, medidor activo.
- Grabación con `parec`: señal sin clipping a 30 %.

Los detalles completos están en `evidencia/`.

---

### Resumen en una línea

> El códec capturaba del jack externo porque el mezclador interno del ALC257
> estaba mal configurado y ese mezclador no tiene control ALSA; se corrige
> escribiendo registros HDA con un servicio root, y se evita el “unplugged” con
> un override del perfil de audio. Todo se reaplica solo al arrancar, iniciar
> sesión y volver de suspensión.
