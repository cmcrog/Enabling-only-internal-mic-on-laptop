#!/bin/bash
# ============================================================================
#  solucion-mic-interno.sh
#
#  Deja el micrófono interno del portátil (Realtek ALC257) como entrada
#  predeterminada SIEMPRE, aunque haya auriculares/micrófono externo puestos.
#
#  Uso:
#      sudo ./solucion-mic-interno.sh                 # instalar
#      sudo ./solucion-mic-interno.sh --desinstalar   # deshacer todo
#      ./solucion-mic-interno.sh --estado             # solo verificar
#      ./solucion-mic-interno.sh --ayuda
#
#  Qué hace:
#    1. Corrige el mezclador interno del códec (nodo 0x23) para que capte
#       del pin interno 0x12 y no del externo 0x19. Ese mezclador NO tiene
#       control ALSA, por eso hay que escribir registros HDA directamente.
#    2. Instala un servicio de sistema que reaplica el arreglo al arrancar
#       y un hook que lo reaplica al volver de suspensión.
#    3. Marca el puerto "Internal Microphone" como disponible aunque el jack
#       externo esté detectado (override de ALSA Card Profile).
#    4. Instala un servicio de usuario que deja la fuente predeterminada,
#       el puerto interno, el mute quitado y una ganancia segura (30 %).
#
#  Requisitos: PipeWire + WirePlumber, pactl, wpctl, systemd, gcc/cc.
#  Probado en Debian forky/sid, kernel 7.3.x, WirePlumber 0.5.19.
# ============================================================================
set -eu

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

ACTION="install"
case "${1:-}" in
    ""|--instalar|install)      ACTION="install" ;;
    -u|--desinstalar|uninstall) ACTION="uninstall" ;;
    -e|--estado|status)         ACTION="status" ;;
    -h|--ayuda|--help)          ACTION="help" ;;
    *)
        echo "Opción desconocida: $1" >&2
        ACTION="help"
        ;;
esac

usage() {
    cat <<'TXT'
Uso: sudo ./solucion-mic-interno.sh [opción]

  (sin opción)        Instala y aplica el arreglo del micrófono interno.
  -u, --desinstalar   Deshace el arreglo y restaura el mixer original.
  -e, --estado       Muestra el estado actual (no cambia nada).
  -h, --ayuda        Muestra esta ayuda.

El script detecta la tarjeta y el códec Realtek ALC257 automáticamente.
Tiene que ejecutarse como root para escribir los registros del códec.
TXT
}

if [ "$ACTION" = "help" ]; then
    usage
    exit 0
fi

# ---------------------------------------------------------------------------
# Usuario real (aunque se ejecute con sudo)
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    if [ "$ACTION" = "install" ] || [ "$ACTION" = "uninstall" ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Se necesitan privilegios de root. Ejecuta el script como root." >&2
            exit 1
        fi
        exec sudo env MIC_USER="$(id -un)" bash "$SCRIPT_PATH" "$@"
    fi
    USER_NAME="$(id -un)"
else
    USER_NAME="${MIC_USER:-${SUDO_USER:-}}"
    if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; then
        USER_NAME="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1; exit }')"
    fi
fi

if [ -z "${USER_NAME:-}" ] || ! getent passwd "$USER_NAME" >/dev/null 2>&1; then
    echo "No se pudo determinar el usuario de escritorio. Usa: sudo MIC_USER=tuusuario $0" >&2
    exit 1
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_UID="$(id -u "$USER_NAME")"
USER_GROUP="$(id -gn "$USER_NAME")"
[ -n "$USER_HOME" ] || USER_HOME="/home/$USER_NAME"

# ---------------------------------------------------------------------------
# Rutas
# ---------------------------------------------------------------------------
HELPER="/usr/local/sbin/fix-internal-mic.sh"
HDA_VERB="/usr/local/sbin/hda-verb"
SYSTEM_UNIT="/etc/systemd/system/fix-internal-mic.service"
SLEEP_HOOK="/usr/lib/systemd/system-sleep/fix-internal-mic"
SUDOERS_FILE="/etc/sudoers.d/fix-internal-mic"
USER_SCRIPT="$USER_HOME/bin/set-internal-mic.sh"
USER_UNIT_DIR="$USER_HOME/.config/systemd/user"
USER_UNIT="$USER_UNIT_DIR/set-internal-mic.service"

as_user() {
    if [ "$(id -u)" -eq 0 ]; then
        runuser -u "$USER_NAME" -- env \
            HOME="$USER_HOME" \
            XDG_RUNTIME_DIR="/run/user/$USER_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
            "$@"
    else
        "$@"
    fi
}

session_bus_ready() {
    [ -S "/run/user/$USER_UID/bus" ]
}

# ---------------------------------------------------------------------------
# Detección del códec Realtek ALC257
# ---------------------------------------------------------------------------
CODEC=""
CARD=""
CODEC_ADDR=""
DEV=""

detect_codec() {
    CODEC=""; CARD=""; CODEC_ADDR=""; DEV=""
    for carddir in /proc/asound/card[0-9]*; do
        [ -d "$carddir" ] || continue
        for codecfile in "$carddir"/codec#*; do
            [ -f "$codecfile" ] || continue
            if grep -q "Realtek ALC257" "$codecfile" 2>/dev/null; then
                CARD="${carddir##*card}"
                CODEC_ADDR="${codecfile##*codec#}"
                CODEC="$codecfile"
                DEV="/dev/snd/hwC${CARD}D${CODEC_ADDR}"
                return 0
            fi
        done
    done
    return 1
}

codec_mixer_line() {
    [ -n "$CODEC" ] || return 1
    awk '/^Node 0x23 /{f=1} f{print} f && /^Node / && !/^Node 0x23 /{exit}' "$CODEC" \
        | grep "Amp-In vals"
}

# ---------------------------------------------------------------------------
# Comprobación de dependencias
# ---------------------------------------------------------------------------
missing_deps() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0
    echo "Faltan comandos: ${missing[*]}" >&2
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu|linuxmint|pop)
                echo "Instálalos con: sudo apt install pipewire pipewire-pulse wireplumber pulseaudio-utils alsa-utils gcc" >&2 ;;
            arch|manjaro|endeavouros)
                echo "Instálalos con: sudo pacman -S pipewire pipewire-pulse wireplumber libpulse alsa-utils gcc" >&2 ;;
            fedora)
                echo "Instálalos con: sudo dnf install pipewire pipewire-pulseaudio wireplumber pulseaudio-utils alsa-utils gcc" >&2 ;;
            opensuse*)
                echo "Instálalos con: sudo zypper install pipewire-pulseaudio wireplumber pulseaudio-utils alsa-utils gcc" >&2 ;;
            *)
                echo "Instala PipeWire, WirePlumber, pulseaudio-utils, alsa-utils y gcc." >&2 ;;
        esac
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Verificación
# ---------------------------------------------------------------------------
print_status() {
    local mixer
    echo "== Códec =="
    if detect_codec; then
        echo "Realtek ALC257 en tarjeta $CARD, codec#$CODEC_ADDR ($DEV)"
        mixer="$(codec_mixer_line || true)"
        if [ -n "$mixer" ]; then
            echo "$mixer"
            if printf '%s' "$mixer" | grep -q '\[0x00 0x00\]$'; then
                echo "Mezclador 0x23: entrada interna (idx 5 / 0x12) ABIERTA."
            else
                echo "Mezclador 0x23: la entrada interna NO está abierta."
            fi
        fi
    else
        echo "No se encontró un códec Realtek ALC257 en este equipo."
    fi

    echo
    echo "== Servicios =="
    echo "fix-internal-mic.service : $(systemctl is-enabled fix-internal-mic.service 2>/dev/null || echo no-instalado)/$(systemctl is-active fix-internal-mic.service 2>/dev/null || echo inactivo)"
    if session_bus_ready; then
        echo "set-internal-mic.service  : $(as_user systemctl --user is-enabled set-internal-mic.service 2>/dev/null || echo no-instalado)/$(as_user systemctl --user is-active set-internal-mic.service 2>/dev/null || echo inactivo)"
    fi

    echo
    echo "== PipeWire =="
    if ! as_user pactl info >/dev/null 2>&1; then
        echo "No hay sesión de PipeWire/PulseAudio accesible para $USER_NAME."
        return 0
    fi
    echo "Fuente predeterminada: $(as_user pactl get-default-source 2>/dev/null || echo desconocida)"
    as_user pactl list sources 2>/dev/null | awk '
        /^Source #[0-9]+/ {
            if (block != "" && block ~ /analog-input-internal-mic:/) printf "%s", block
            block = ""
        }
        { block = block $0 "\n" }
        END { if (block != "" && block ~ /analog-input-internal-mic:/) printf "%s", block }
    ' | grep -E "^[[:space:]]*Name: alsa_input|Mute:|Volume:|Active Port:" | head -20 || true

    echo
    echo "== Ganancia recomendada =="
    echo "Volumen de la fuente: 30 % (boost 0 dB, Capture Volume 61, sin saturación)."
    echo "No lo subas al 100 %: este códec aplica +30 dB de boost y satura."
}

# ===========================================================================
# INSTALAR
# ===========================================================================
do_install() {
    local cc_bin work src_paths paths_dst marker backup_dir
    local patched

    echo "== 1/9 · Comprobando dependencias =="
    missing_deps pactl wpctl systemctl visudo || exit 1
    cc_bin="$(command -v cc || command -v gcc || true)"
    if [ -z "$cc_bin" ]; then
        echo "Falta un compilador de C (cc/gcc)." >&2
        exit 1
    fi

    echo "== 2/9 · Detectando el códec Realtek ALC257 =="
    if ! detect_codec; then
        cat >&2 <<'ERR'
No se encontró un códec Realtek ALC257.

Este arreglo usa los nodos concretos de ese códec (mezclador 0x23,
pin interno 0x12, pin externo 0x19). En otro modelo de portátil los
números pueden ser distintos y aplicarlo a ciegas podría dejar sin
micrófono al equipo. No se ha cambiado nada.
ERR
        exit 1
    fi
    echo "Encontrado en tarjeta $CARD, codec#$CODEC_ADDR: $DEV"
    if [ ! -e "$DEV" ]; then
        echo "Esperando el dispositivo $DEV…"
        for _ in $(seq 1 25); do
            [ -e "$DEV" ] && break
            sleep 0.2
        done
    fi
    if [ ! -e "$DEV" ]; then
        echo "No existe $DEV. ¿Está cargado snd-hda-intel?" >&2
        exit 1
    fi

    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT

    echo "== 3/9 · Compilando hda-verb =="
    cat > "$work/hda-verb.c" <<'HDA_VERB_C'
/* Minimal hda-verb for HD-audio hwdep device (no alsa-tools needed) */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

struct hda_verb_ioctl {
    uint32_t verb;
    uint32_t res;
};

#define HDA_IOCTL_PVERSION      _IOR('H', 0x10, int)
#define HDA_IOCTL_VERB_WRITE    _IOWR('H', 0x11, struct hda_verb_ioctl)
#define HDA_VERB(nid, verb, param) \
    ((uint32_t)(nid) << 24 | (uint32_t)(verb) << 8 | (uint32_t)(param))

int main(int argc, char **argv)
{
    struct hda_verb_ioctl val;
    int fd, ver = 0;
    unsigned int nid, verb, param;

    if (argc != 5) {
        fprintf(stderr, "usage: %s <hwdep-device> <nid> <verb> <param>\n", argv[0]);
        return 1;
    }
    nid = strtoul(argv[2], NULL, 0);
    verb = strtoul(argv[3], NULL, 0);
    param = strtoul(argv[4], NULL, 0);

    fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    if (ioctl(fd, HDA_IOCTL_PVERSION, &ver) < 0) {
        perror("ioctl(PVERSION)");
        close(fd);
        return 1;
    }
    if (ver < 0x10000) {
        fprintf(stderr, "unexpected hwdep version 0x%x\n", ver);
        close(fd);
        return 1;
    }

    val.verb = HDA_VERB(nid, verb, param);
    val.res = 0;
    if (ioctl(fd, HDA_IOCTL_VERB_WRITE, &val) < 0) {
        perror("ioctl(VERB_WRITE)");
        close(fd);
        return 1;
    }
    printf("0x%x\n", val.res);
    close(fd);
    return 0;
}
HDA_VERB_C
    "$cc_bin" -O2 -o "$work/hda-verb" "$work/hda-verb.c"
    install -o root -g root -m 0755 "$work/hda-verb" "$HDA_VERB"

    echo "== 4/9 · Instalando el helper root =="
    cat > "$work/fix-internal-mic.sh" <<'ROOT_HELPER'
#!/bin/bash
# Deja el Realtek ALC257 captando del micrófono interno (pin 0x12) y mutea
# el externo (pin 0x19). El mezclador 0x23 no tiene control ALSA, por eso se
# escriben registros HDA directamente.
#
# Uso:
#   fix-internal-mic.sh           aplica y verifica (arranque / suspensión)
#   fix-internal-mic.sh --quick    aplica sin verificar (reaplicación rápida)
#
# No toca el ahorro de energía: el códec se suspende cuando está inactivo y
# el vigilante de PipeWire reaplica esto en cuanto se abre el micrófono.
set -u

VERB=/usr/local/sbin/hda-verb
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

LOG_TAG="fix-internal-mic"
log() { logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }

[ -x "$VERB" ] || exit 0

DEV=""
CODEC=""

find_codec() {
    DEV=""
    CODEC=""
    for carddir in /proc/asound/card[0-9]*; do
        [ -d "$carddir" ] || continue
        cardnum=${carddir##*card}
        for codecfile in "$carddir"/codec#*; do
            [ -f "$codecfile" ] || continue
            if grep -q "Realtek ALC257" "$codecfile" 2>/dev/null; then
                addr=${codecfile##*codec#}
                DEV="/dev/snd/hwC${cardnum}D${addr}"
                CODEC="$codecfile"
                return 0
            fi
        done
    done
    return 1
}

# Espera hasta ~20 s a que existan el códec y el nodo hwdep (arranque/resume).
for _ in $(seq 1 100); do
    if find_codec && [ -e "$DEV" ]; then
        break
    fi
    sleep 0.2
done

[ -n "$DEV" ] && [ -e "$DEV" ] || exit 0

apply_mixer() {
    # Nodo 0x23: idx 0=0x18, idx 1=0x19 (mic externo), idx 2=0x1a,
    #            idx 3=0x1b, idx 4=0x1d, idx 5=0x12 (mic interno).
    # SET_AMP_GAIN_MUTE: 0x4000 amp de entrada | 0x2000 izq | 0x1000 der
    #                    | (índice << 8) | mute 0x80 | ganancia.
    "$VERB" "$DEV" 0x23 0x300 0x7080 >/dev/null 2>&1 || true  # mute 0x18
    "$VERB" "$DEV" 0x23 0x300 0x7180 >/dev/null 2>&1 || true  # mute 0x19 (externo)
    "$VERB" "$DEV" 0x23 0x300 0x7280 >/dev/null 2>&1 || true  # mute 0x1a
    "$VERB" "$DEV" 0x23 0x300 0x7380 >/dev/null 2>&1 || true  # mute 0x1b
    "$VERB" "$DEV" 0x23 0x300 0x7480 >/dev/null 2>&1 || true  # mute 0x1d
    "$VERB" "$DEV" 0x23 0x300 0x7500 >/dev/null 2>&1 || true  # abre 0x12 (interno)

    # Selector del ADC 0x24: entrada 0 = 0x12 (micrófono interno).
    "$VERB" "$DEV" 0x24 0x701 0x0 >/dev/null 2>&1 || true
}

if [ "$QUICK" = "1" ]; then
    apply_mixer
    exit 0
fi

mixer_is_correct() {
    local vals
    vals="$(awk '/^Node 0x23 /{f=1} f{print} f && /^Node / && !/^Node 0x23 /{exit}' "$CODEC" \
        | grep 'Amp-In vals' | grep -o '\[[^]]*\]' | tr '\n' ' ' | sed 's/ *$//')"
    [ "$vals" = "[0x80 0x80] [0x80 0x80] [0x80 0x80] [0x80 0x80] [0x80 0x80] [0x00 0x00]" ]
}

# Reintenta por si el códec se reinicializa justo después de escribir.
for _ in $(seq 1 15); do
    apply_mixer
    sleep 0.2
    mixer_is_correct && exit 0
done

log "aviso: no se pudo confirmar el estado del mezclador 0x23"
exit 0
ROOT_HELPER
    install -o root -g root -m 0755 "$work/fix-internal-mic.sh" "$HELPER"

    echo "== 5/9 · Servicio de sistema y hook de suspensión =="
    cat > "$work/fix-internal-mic.service" <<'SYSTEM_UNIT'
[Unit]
Description=Force ALC257 internal microphone routing
After=sound.target
Wants=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fix-internal-mic.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEM_UNIT
    install -o root -g root -m 0644 "$work/fix-internal-mic.service" "$SYSTEM_UNIT"

    cat > "$work/fix-internal-mic-sleep" <<'SLEEP_UNIT'
#!/bin/bash
# Reaplica el enrutado del micrófono interno al volver de suspensión.
# Con los verbos registrados en init_verbs el driver ya restaura el estado al
# despertar el códec; esto es una red de seguridad adicional y no toca el
# ahorro de energía.
case "$1" in
    post)
        /usr/local/sbin/fix-internal-mic.sh
        ;;
esac
exit 0
SLEEP_UNIT
    install -d -o root -g root -m 0755 /usr/lib/systemd/system-sleep
    install -o root -g root -m 0755 "$work/fix-internal-mic-sleep" "$SLEEP_HOOK"

    echo "== 6/9 · Regla sudoers limitada =="
    printf '%s ALL=(root) NOPASSWD: %s\n' "$USER_NAME" "$HELPER" > "$work/sudoers"
    visudo -cf "$work/sudoers" >/dev/null
    install -o root -g root -m 0440 "$work/sudoers" "$SUDOERS_FILE"

    echo "== 7/9 · Override del perfil de audio (quita «unplugged») =="
    src_paths=""
    for candidate in /usr/share/alsa-card-profile/mixer/paths \
                     /usr/share/pulseaudio/alsa-mixer/paths; do
        if [ -f "$candidate/analog-input-internal-mic.conf" ]; then
            src_paths="$candidate"
            break
        fi
    done
    if [ -z "$src_paths" ]; then
        echo "No se encontró analog-input-internal-mic.conf del sistema." >&2
        echo "Instala los perfiles de ALSA Card Profile (paquete pipewire o pulseaudio)." >&2
        exit 1
    fi

    paths_dst="$USER_HOME/.config/alsa-card-profile/mixer/paths"
    marker="$USER_HOME/.config/alsa-card-profile/.solucion-mic-interno"
    install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0755 \
        "$USER_HOME/.config" \
        "$USER_HOME/.config/alsa-card-profile" \
        "$USER_HOME/.config/alsa-card-profile/mixer" \
        "$paths_dst"
    if [ ! -f "$marker" ]; then
        backup_dir=""
        if [ -d "$USER_HOME/.config/alsa-card-profile" ] && \
           [ -n "$(find "$USER_HOME/.config/alsa-card-profile" -mindepth 1 -maxdepth 1 ! -name '.solucion-mic-interno' -print -quit)" ]; then
            backup_dir="$USER_HOME/.config/alsa-card-profile.backup-$(date +%Y%m%d-%H%M%S)"
            cp -a "$USER_HOME/.config/alsa-card-profile" "$backup_dir"
            echo "Copia de seguridad de la configuración previa: $backup_dir"
        fi
        printf '%s\n' "$backup_dir" > "$marker"
        chown "$USER_NAME:$USER_GROUP" "$marker"
    fi
    cp -f "$src_paths"/*.conf "$paths_dst"/
    install -o "$USER_NAME" -g "$USER_GROUP" -m 0644 \
        "$src_paths/analog-input-internal-mic.conf" \
        "$paths_dst/analog-input-internal-mic.conf"
    sed -i '/^\[Jack Mic\]/,/^\[/ s/^state\.plugged = no$/state.plugged = unknown/' \
        "$paths_dst/analog-input-internal-mic.conf"
    patched="$(sed -n '/^\[Jack Mic\]/,/^\[/p' "$paths_dst/analog-input-internal-mic.conf" | grep '^state.plugged' || true)"
    if [ "$patched" != "state.plugged = unknown" ]; then
        echo "Aviso: no se pudo parchear [Jack Mic] en el perfil de audio." >&2
        echo "Revisa $paths_dst/analog-input-internal-mic.conf" >&2
    fi
    chown -R "$USER_NAME:$USER_GROUP" "$USER_HOME/.config/alsa-card-profile"

    echo "== 8/9 · Script y servicio de usuario =="
    cat > "$work/set-internal-mic.sh" <<'USER_SCRIPT'
#!/bin/bash
# Fuerza el micrófono interno del portátil como fuente predeterminada.
# Detecta tarjeta y fuente dinámicamente (no depende del número de tarjeta).

PORT="analog-input-internal-mic"

find_internal_source() {
    pactl list sources 2>/dev/null | awk '
        /^Source #[0-9]+/ { if (name != "" && has_port) { print name; exit } name = ""; has_port = 0 }
        /^[[:space:]]*Name: alsa_input\./ { name = $2 }
        /analog-input-internal-mic:/ { has_port = 1 }
        END { if (name != "" && has_port) print name }
    '
}

find_internal_card() {
    pactl list cards 2>/dev/null | awk '
        /^Card #[0-9]+/ { if (name != "" && has_port) { print name; exit } name = ""; has_port = 0 }
        /^[[:space:]]*Name: alsa_card\./ { name = $2 }
        /analog-input-internal-mic:/ { has_port = 1 }
        END { if (name != "" && has_port) print name }
    '
}

# Espera a que PipeWire cree la fuente (máx. ~10 s).
INTERNAL_MIC=""
for _ in $(seq 1 20); do
    INTERNAL_MIC="$(find_internal_source)"
    [ -n "$INTERNAL_MIC" ] && break
    sleep 0.5
done

# Si no existe, activa el perfil dúplex y reintenta.
if [ -z "$INTERNAL_MIC" ]; then
    CARD_NAME="$(find_internal_card)"
    if [ -n "$CARD_NAME" ]; then
        pactl set-card-profile "$CARD_NAME" "output:analog-stereo+input:analog-stereo" 2>/dev/null || true
        sleep 2
        INTERNAL_MIC="$(find_internal_source)"
    fi
fi

if [ -z "$INTERNAL_MIC" ]; then
    logger "Micrófono interno: no se encontró una fuente con el puerto ${PORT}"
    exit 0
fi

# Reaplica el mixer del códec (helper root con NOPASSWD).
sudo -n /usr/local/sbin/fix-internal-mic.sh 2>/dev/null || true

# Fuente predeterminada, sin mute, puerto interno y ganancia segura.
pactl set-default-source "$INTERNAL_MIC" 2>/dev/null || true
pactl set-source-mute "$INTERNAL_MIC" 0 2>/dev/null || true
pactl set-source-port "$INTERNAL_MIC" "$PORT" 2>/dev/null || true
pactl set-source-volume "$INTERNAL_MIC" 30% 2>/dev/null || true

# Fuerza la ruta de WirePlumber al micrófono interno.
SOURCE_NODE=""
for id in $(wpctl status 2>/dev/null | awk '
        /Sources:/ { in_src = 1; next }
        /Filters:/ { in_src = 0 }
        in_src && /[0-9]+\./ { if (match($0, /[0-9]+\./)) print substr($0, RSTART, RLENGTH - 1) }'); do
    if wpctl inspect "$id" 2>/dev/null | grep -Fq "node.name = \"$INTERNAL_MIC\""; then
        SOURCE_NODE="$id"
        break
    fi
done

if [ -n "$SOURCE_NODE" ]; then
    ROUTE_INDEX=$(wpctl get-route "$SOURCE_NODE" 2>/dev/null | awk '
        /\[INPUT\].*Internal Microphone/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "[INPUT]") { print $(i - 1); exit }
            }
        }')
    if [ -n "$ROUTE_INDEX" ]; then
        wpctl set-route "$SOURCE_NODE" "$ROUTE_INDEX" 2>/dev/null || true
        logger "Micrófono interno: ruta $ROUTE_INDEX aplicada al nodo $SOURCE_NODE"
    fi
else
    logger "Micrófono interno: no se encontró el nodo de WirePlumber (se usó solo pactl)"
fi

logger "Micrófono interno configurado como fuente predeterminada ($INTERNAL_MIC)"
exit 0
USER_SCRIPT
    install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0755 "$USER_HOME/bin"
    install -o "$USER_NAME" -g "$USER_GROUP" -m 0755 \
        "$work/set-internal-mic.sh" "$USER_SCRIPT"
    bash -n "$USER_SCRIPT"

    # Vigilante reactivo (script de usuario)
    cat > "$work/mic-watch.sh" <<'WATCH_SCRIPT'
#!/bin/bash
# Reaplica el enrutado del micrófono interno cuando PipeWire va a usar la
# captura. No modifica el ahorro de energía: el códec sigue suspendiéndose
# cuando está inactivo y este vigilante solo actúa cuando hace falta.
#
# Funciona en dos fases:
#   - Al crearse un flujo de captura (source-output), despierta el códec y
#     aplica el arreglo de forma preventiva.
#   - Cuando la fuente interna pasa a RUNNING, lo reaplica por si el driver
#     reinicializó el mezclador durante el arranque del flujo.
set -u

HELPER=/usr/local/sbin/fix-internal-mic.sh
PORT=analog-input-internal-mic
DEBOUNCE=1

last_apply=0

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

apply() {
    local now
    now=$(date +%s)
    [ $((now - last_apply)) -ge "$DEBOUNCE" ] || return 0
    last_apply=$now
    log "reaplicando enrutado del micrófono interno"
    sudo -n "$HELPER" >/dev/null 2>&1 || log "aviso: no se pudo ejecutar $HELPER"
}

# ¿Hay una fuente con el puerto del micrófono interno en estado RUNNING?
internal_running() {
    pactl list sources 2>/dev/null | awk -v port="$PORT" '
        function flush() {
            if (blk != "" && blk ~ port && blk ~ /State: RUNNING/) found = 1
            blk = ""
        }
        /^Source #[0-9]+/ { flush() }
        { blk = blk $0 "\n" }
        END { flush(); exit(found ? 0 : 1) }
    '
}

# Aplica al arrancar el vigilante (p. ej. al iniciar sesión).
apply

while read -r event; do
    case "$event" in
        *"'new' on source-output #"*)
            # Un cliente empieza a capturar: adelanta el trabajo.
            apply
            ;;
        *"'change' on source #"*|*"'new' on source #"*|*"'change' on card #"*)
            if internal_running; then
                apply
            fi
            ;;
    esac
done < <(pactl subscribe 2>/dev/null)

log "pactl subscribe terminó; saliendo para que systemd lo reinicie"
exit 0
WATCH_SCRIPT
    install -o "$USER_NAME" -g "$USER_GROUP" -m 0755 \
        "$work/mic-watch.sh" "$USER_HOME/bin/mic-watch.sh"
    bash -n "$USER_HOME/bin/mic-watch.sh"

    cat > "$work/set-internal-mic.service" <<'USER_UNIT'
[Unit]
Description=Set Internal Microphone as Default
After=pipewire.service wireplumber.service

[Service]
Type=oneshot
ExecStart=%h/bin/set-internal-mic.sh
RemainAfterExit=yes

[Install]
WantedBy=default.target
USER_UNIT
    install -d -o "$USER_NAME" -g "$USER_GROUP" -m 0755 \
        "$USER_HOME/.config/systemd" "$USER_UNIT_DIR"
    install -o "$USER_NAME" -g "$USER_GROUP" -m 0644 \
        "$work/set-internal-mic.service" "$USER_UNIT"

    # Vigilante reactivo de PipeWire (mic-watch)
    cat > "$work/mic-watch.service" <<'WATCH_UNIT'
[Unit]
Description=Reapply internal microphone routing when PipeWire captures
After=pipewire.service wireplumber.service
Wants=pipewire.service wireplumber.service

[Service]
Type=simple
ExecStart=%h/bin/mic-watch.sh
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
WATCH_UNIT
    install -o "$USER_NAME" -g "$USER_GROUP" -m 0644 \
        "$work/mic-watch.service" "$USER_HOME/.config/systemd/user/mic-watch.service"

    echo "== 9/9 · Activando servicios =="
    systemctl daemon-reload
    systemctl enable fix-internal-mic.service >/dev/null
    systemctl restart fix-internal-mic.service

    if session_bus_ready; then
        as_user systemctl --user daemon-reload >/dev/null 2>&1 || true
        as_user systemctl --user enable set-internal-mic.service >/dev/null 2>&1 || true
        as_user systemctl --user enable mic-watch.service >/dev/null 2>&1 || true
        # Reiniciar WirePlumber hace que relea el override de ALSA Card Profile.
        as_user systemctl --user restart wireplumber.service >/dev/null 2>&1 || true
        sleep 3
        as_user systemctl --user restart set-internal-mic.service >/dev/null 2>&1 || true
        as_user systemctl --user restart mic-watch.service >/dev/null 2>&1 || true
        sleep 2
    else
        echo "Aviso: no hay sesión gráfica activa."
        echo "Los servicios de usuario se aplicarán automáticamente al iniciar sesión."
    fi

    echo
    echo "============================================================"
    echo " Arreglo instalado."
    echo "============================================================"
    print_status
    echo
    echo "Cierra y vuelve a abrir las aplicaciones que usen el micrófono."
    echo "Para deshacerlo: sudo $0 --desinstalar"
}

# ===========================================================================
# DESINSTALAR
# ===========================================================================
do_uninstall() {
    local paths_dst marker f base src_paths backup_dir

    echo "== 1/6 · Restaurando el mezclador original =="
    if detect_codec && [ -x "$HDA_VERB" ] && [ -e "$DEV" ]; then
        # Original: entrada externa (0x19) abierta con ganancia 0,
        # entrada interna (0x12) muteada.
        "$HDA_VERB" "$DEV" 0x23 0x300 0x7100 >/dev/null 2>&1 || true
        "$HDA_VERB" "$DEV" 0x23 0x300 0x7580 >/dev/null 2>&1 || true
        echo "Mezclador 0x23 restaurado."
    else
        echo "No se pudo restaurar el mixer (códec o hda-verb no disponible)."
    fi

    echo "== 2/6 · Servicios =="
    systemctl disable --now fix-internal-mic.service >/dev/null 2>&1 || true
    rm -f "$SYSTEM_UNIT" "$SLEEP_HOOK"
    systemctl daemon-reload

    if session_bus_ready; then
        as_user systemctl --user disable --now set-internal-mic.service >/dev/null 2>&1 || true
        as_user systemctl --user disable --now mic-watch.service >/dev/null 2>&1 || true
    fi
    rm -f "$USER_UNIT"
    rm -f "$USER_HOME/.config/systemd/user/mic-watch.service"
    if session_bus_ready; then
        as_user systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi

    echo "== 3/6 · Regla sudoers y binarios root =="
    rm -f "$SUDOERS_FILE"
    rm -f "$HELPER" "$HDA_VERB"

    echo "== 4/6 · Override del perfil de audio =="
    paths_dst="$USER_HOME/.config/alsa-card-profile/mixer/paths"
    marker="$USER_HOME/.config/alsa-card-profile/.solucion-mic-interno"
    if [ -f "$marker" ]; then
        backup_dir="$(cat "$marker" 2>/dev/null || true)"
        if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
            rm -rf "$USER_HOME/.config/alsa-card-profile"
            mv "$backup_dir" "$USER_HOME/.config/alsa-card-profile"
            chown -R "$USER_NAME:$USER_GROUP" "$USER_HOME/.config/alsa-card-profile"
            echo "Configuración previa restaurada desde $backup_dir."
        else
            for candidate in /usr/share/alsa-card-profile/mixer/paths \
                             /usr/share/pulseaudio/alsa-mixer/paths; do
                if [ -f "$candidate/analog-input-internal-mic.conf" ]; then
                    src_paths="$candidate"
                    break
                fi
            done
            rm -f "$paths_dst/analog-input-internal-mic.conf"
            # Borra solo las copias idénticas a las del sistema; respeta ajustes propios.
            if [ -n "${src_paths:-}" ]; then
                for f in "$paths_dst"/*.conf; do
                    [ -f "$f" ] || continue
                    base="${f##*/}"
                    if [ -f "$src_paths/$base" ] && cmp -s "$f" "$src_paths/$base"; then
                        rm -f "$f"
                    fi
                done
            fi
            rmdir "$paths_dst" 2>/dev/null || true
            rmdir "$USER_HOME/.config/alsa-card-profile/mixer" 2>/dev/null || true
            rmdir "$USER_HOME/.config/alsa-card-profile" 2>/dev/null || true
            echo "Override eliminado."
        fi
    else
        echo "No había override instalado por este script."
    fi

    echo "== 5/6 · Scripts de usuario =="
    if [ -f "$USER_SCRIPT" ] && grep -q "Fuerza el micrófono interno del portátil" "$USER_SCRIPT"; then
        rm -f "$USER_SCRIPT"
    fi

    echo "== 6/6 · Reaplicando el estado de audio =="
    if session_bus_ready; then
        as_user systemctl --user restart wireplumber.service >/dev/null 2>&1 || true
        sleep 2
    fi

    echo
    echo "Arreglo deshecho."
    echo "Si hace falta, cierra y vuelve a abrir pavucontrol o reinicia la sesión."
}

# ===========================================================================
# MAIN
# ===========================================================================
case "$ACTION" in
    install)
        if [ "$(id -u)" -ne 0 ]; then
            echo "Se necesitan privilegios de root." >&2
            exit 1
        fi
        do_install
        ;;
    uninstall)
        if [ "$(id -u)" -ne 0 ]; then
            echo "Se necesitan privilegios de root." >&2
            exit 1
        fi
        do_uninstall
        ;;
    status)
        print_status
        ;;
esac
