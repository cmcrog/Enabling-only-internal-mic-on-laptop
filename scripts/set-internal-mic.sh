#!/bin/bash
# Fuerza el micrófono interno del portátil como fuente de audio predeterminada.
# Detecta la tarjeta y la fuente dinámicamente (no depende del número de tarjeta).
# Reaplica también el enrutado del códec ALC257 (helper root con sudo -n).

PORT="analog-input-internal-mic"

# Busca la fuente ALSA que tenga el puerto de micrófono interno.
find_internal_source() {
    pactl list sources 2>/dev/null | awk '
        /^Source #[0-9]+/ { if (name != "" && has_port) { print name; exit } name = ""; has_port = 0 }
        /^[[:space:]]*Name: alsa_input\./ { name = $2 }
        /analog-input-internal-mic:/ { has_port = 1 }
        END { if (name != "" && has_port) print name }
    '
}

# Busca la tarjeta que expone ese puerto (para activar el perfil dúplex si hace falta).
find_internal_card() {
    pactl list cards 2>/dev/null | awk '
        /^Card #[0-9]+/ { if (name != "" && has_port) { print name; exit } name = ""; has_port = 0 }
        /^[[:space:]]*Name: alsa_card\./ { name = $2 }
        /analog-input-internal-mic:/ { has_port = 1 }
        END { if (name != "" && has_port) print name }
    '
}

# 0. Esperar a que PipeWire/WirePlumber cree la fuente (máx. ~10 s)
INTERNAL_MIC=""
for _ in $(seq 1 20); do
    INTERNAL_MIC="$(find_internal_source)"
    [ -n "$INTERNAL_MIC" ] && break
    sleep 0.5
done

# 1. Si no existe, activar el perfil dúplex de la tarjeta y reintentar.
if [ -z "$INTERNAL_MIC" ]; then
    CARD_NAME="$(find_internal_card)"
    if [ -n "$CARD_NAME" ]; then
        pactl set-card-profile "$CARD_NAME" "output:analog-stereo+input:analog-stereo" 2>/dev/null || true
        sleep 2
        INTERNAL_MIC="$(find_internal_source)"
    fi
fi

if [ -z "$INTERNAL_MIC" ]; then
    logger "Micrófono interno: no se encontró ninguna fuente con el puerto ${PORT}"
    exit 0
fi

# 2. Reaplicar el mixer interno del códec (helper root con NOPASSWD)
sudo -n /usr/local/sbin/fix-internal-mic.sh 2>/dev/null || true

# 3. Fuente predeterminada, sin mute, puerto interno y ganancia segura.
#    30% => Internal Mic Boost 0 dB + Capture Volume 61 (sin saturación).
pactl set-default-source "$INTERNAL_MIC" 2>/dev/null || true
pactl set-source-mute "$INTERNAL_MIC" 0 2>/dev/null || true
pactl set-source-port "$INTERNAL_MIC" "$PORT" 2>/dev/null || true
pactl set-source-volume "$INTERNAL_MIC" 30% 2>/dev/null || true

# 4. Forzar la ruta de WirePlumber al micrófono interno (si se puede localizar).
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
