#!/bin/bash
# ============================================================================
#  deshacer-cambios.sh
#
#  Deshace POR COMPLETO el arreglo del micrófono interno (Realtek ALC257):
#    · restaura el mezclador original del códec;
#    · elimina el servicio de sistema y el hook de suspensión;
#    · elimina la regla sudoers, el helper y hda-verb;
#    · elimina el override del perfil de audio (o restaura la copia previa);
#    · elimina el script y el servicio de usuario;
#    · reinicia WirePlumber para recuperar la detección normal.
#
#  Uso:
#      sudo ./deshacer-cambios.sh
#
#  Es autocontenido: no necesita el instalador ni los archivos de la carpeta.
# ============================================================================
set -eu

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

case "${1:-}" in
    -h|--ayuda|--help)
        cat <<'TXT'
Uso: sudo ./deshacer-cambios.sh

Deshace el arreglo del micrófono interno y deja el audio como estaba antes.
No borra paquetes del sistema (PipeWire, WirePlumber, ALSA, etc.).
TXT
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Opción desconocida: $1" >&2
        echo "Uso: sudo $0" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Usuario real (aunque se ejecute con sudo)
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Se necesitan privilegios de root. Ejecuta el script como root." >&2
        exit 1
    fi
    exec sudo env MIC_USER="$(id -un)" bash "$SCRIPT_PATH"
fi

USER_NAME="${MIC_USER:-${SUDO_USER:-}}"
if [ -z "$USER_NAME" ] || [ "$USER_NAME" = "root" ]; then
    USER_NAME="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1; exit }')"
fi
if [ -z "$USER_NAME" ] || ! getent passwd "$USER_NAME" >/dev/null 2>&1; then
    echo "No se pudo determinar el usuario de escritorio. Usa: sudo MIC_USER=tuusuario $0" >&2
    exit 1
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_UID="$(id -u "$USER_NAME")"
USER_GROUP="$(id -gn "$USER_NAME")"
[ -n "$USER_HOME" ] || USER_HOME="/home/$USER_NAME"

HELPER="/usr/local/sbin/fix-internal-mic.sh"
HDA_VERB="/usr/local/sbin/hda-verb"
SYSTEM_UNIT="/etc/systemd/system/fix-internal-mic.service"
SLEEP_HOOK="/usr/lib/systemd/system-sleep/fix-internal-mic"
SUDOERS_FILE="/etc/sudoers.d/fix-internal-mic"
USER_SCRIPT="$USER_HOME/bin/set-internal-mic.sh"
USER_UNIT="$USER_HOME/.config/systemd/user/set-internal-mic.service"

as_user() {
    runuser -u "$USER_NAME" -- env \
        HOME="$USER_HOME" \
        XDG_RUNTIME_DIR="/run/user/$USER_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
        "$@"
}

session_bus_ready() {
    [ -S "/run/user/$USER_UID/bus" ]
}

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

echo "== 1/6 · Restaurando el mezclador original del códec =="
if detect_codec && [ -x "$HDA_VERB" ] && [ -e "$DEV" ]; then
    # Estado original del ALC257:
    #   · entrada 1 (0x19, micrófono externo): abierta, ganancia 0.
    #   · entrada 5 (0x12, micrófono interno): muteada.
    "$HDA_VERB" "$DEV" 0x23 0x300 0x7100 >/dev/null 2>&1 || true
    "$HDA_VERB" "$DEV" 0x23 0x300 0x7580 >/dev/null 2>&1 || true
    mixer="$(awk '/^Node 0x23 /{f=1} f{print} f && /^Node / && !/^Node 0x23 /{exit}' "$CODEC" \
        | grep "Amp-In vals" || true)"
    echo "Mezclador 0x23 restaurado:"
    [ -n "$mixer" ] && echo "  $mixer"
else
    echo "Aviso: no se pudo restaurar el mezclador (códec ALC257 o hda-verb no disponible)."
    echo "Se eliminarán igualmente los servicios y configuraciones del arreglo."
fi

echo "== 2/6 · Eliminando servicios de systemd =="
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

echo "== 3/6 · Eliminando regla sudoers y binarios root =="
rm -f "$SUDOERS_FILE" "$HELPER" "$HDA_VERB"

echo "== 4/6 · Restaurando el perfil de audio =="
paths_dst="$USER_HOME/.config/alsa-card-profile/mixer/paths"
marker="$USER_HOME/.config/alsa-card-profile/.solucion-mic-interno"
profile_dir="$USER_HOME/.config/alsa-card-profile"

src_paths=""
for candidate in /usr/share/alsa-card-profile/mixer/paths \
                 /usr/share/pulseaudio/alsa-mixer/paths; do
    if [ -f "$candidate/analog-input-internal-mic.conf" ]; then
        src_paths="$candidate"
        break
    fi
done

remove_override_files() {
    local ours="$paths_dst/analog-input-internal-mic.conf"
    local tmp f base removed=0

    if [ -f "$ours" ]; then
        if [ -n "$src_paths" ] && [ -f "$src_paths/analog-input-internal-mic.conf" ]; then
            # Solo lo borra si, al revertir la línea, queda idéntico al original.
            tmp="$(mktemp)"
            sed '/^\[Jack Mic\]/,/^\[/ s/^state\.plugged = unknown$/state.plugged = no/' \
                "$ours" > "$tmp"
            if cmp -s "$tmp" "$src_paths/analog-input-internal-mic.conf"; then
                rm -f "$ours"
                removed=1
            else
                echo "Aviso: $ours tiene cambios propios; no se ha borrado." >&2
            fi
            rm -f "$tmp"
        else
            echo "Aviso: no se encontró el perfil original del sistema para comparar." >&2
            echo "Revisa a mano: $ours" >&2
        fi
    fi

    # Elimina copias idénticas a las del sistema (las creó el instalador).
    if [ -n "$src_paths" ]; then
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
    rmdir "$profile_dir" 2>/dev/null || true

    if [ "$removed" -eq 1 ]; then
        echo "Override del perfil de audio eliminado."
    fi
}

if [ -f "$marker" ]; then
    backup_dir="$(cat "$marker" 2>/dev/null || true)"
    if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
        rm -rf "$profile_dir"
        mv "$backup_dir" "$profile_dir"
        chown -R "$USER_NAME:$USER_GROUP" "$profile_dir"
        echo "Configuración anterior restaurada desde: $backup_dir"
    else
        rm -f "$marker"
        remove_override_files
    fi
else
    # Compatibilidad con la primera instalación (no dejaba marcador).
    remove_override_files
fi

echo "== 5/6 · Eliminando scripts de usuario =="
if [ -f "$USER_SCRIPT" ] && grep -qE \
    "Fuerza el micrófono interno del portátil|Force internal laptop microphone" \
    "$USER_SCRIPT"; then
    rm -f "$USER_SCRIPT"
    echo "Eliminado: $USER_SCRIPT"
fi
# Copia local del binario que usaba la primera instalación.
if [ -f "$USER_HOME/bin/hda-verb" ]; then
    rm -f "$USER_HOME/bin/hda-verb"
    echo "Eliminado: $USER_HOME/bin/hda-verb"
fi

echo "== 6/6 · Reiniciando WirePlumber =="
if session_bus_ready; then
    as_user systemctl --user restart wireplumber.service >/dev/null 2>&1 || true
    sleep 2
fi

echo
echo "============================================================"
echo " Arreglo deshecho."
echo "============================================================"
echo "El mezclador vuelve al estado de fábrica: micrófono EXTERNO"
echo "abierto y micrófono INTERNO muteado."
echo
echo "Cierra y vuelve a abrir pavucontrol. Si hace falta, reinicia"
echo "la sesión para que las aplicaciones vuelvan a enumerar el audio."
