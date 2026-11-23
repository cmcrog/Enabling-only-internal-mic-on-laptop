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
