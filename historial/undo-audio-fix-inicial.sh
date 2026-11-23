#!/bin/bash
# Deshace por completo el arreglo del micrófono interno.
# Uso: sudo /home/roger/undo-audio-fix.sh
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Se necesitan privilegios de root."
    echo "Ejecuta: sudo $0"
    exit 1
fi

ROGER_UID=$(id -u roger)
RUN_USER=(runuser -u roger -- env HOME=/home/roger
    XDG_RUNTIME_DIR="/run/user/${ROGER_UID}"
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${ROGER_UID}/bus")

# 1. Restaurar el mixer original del códec ALC257:
#    entrada 1 (0x19, mic externo) sin mute; entrada 5 (0x12, interno) muteada.
if [ -x /usr/local/sbin/hda-verb ]; then
    for carddir in /proc/asound/card[0-9]*; do
        [ -d "$carddir" ] || continue
        cardnum=${carddir##*card}
        for codecfile in "$carddir"/codec#*; do
            [ -f "$codecfile" ] || continue
            grep -q "Realtek ALC257" "$codecfile" 2>/dev/null || continue
            addr=${codecfile##*codec#}
            dev="/dev/snd/hwC${cardnum}D${addr}"
            [ -e "$dev" ] || continue
            /usr/local/sbin/hda-verb "$dev" 0x23 0x300 0x7100 >/dev/null 2>&1 || true
            /usr/local/sbin/hda-verb "$dev" 0x23 0x300 0x7580 >/dev/null 2>&1 || true
        done
    done
fi

# 2. Servicio de usuario
"${RUN_USER[@]}" systemctl --user disable --now set-internal-mic.service >/dev/null 2>&1 || true
rm -f /home/roger/.config/systemd/user/set-internal-mic.service
"${RUN_USER[@]}" systemctl --user daemon-reload >/dev/null 2>&1 || true

# 3. Servicio de sistema y hook de suspensión
systemctl disable --now fix-internal-mic.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/fix-internal-mic.service
rm -f /usr/lib/systemd/system-sleep/fix-internal-mic
systemctl daemon-reload

# 4. Regla sudoers y binarios root
rm -f /etc/sudoers.d/fix-internal-mic
rm -f /usr/local/sbin/fix-internal-mic.sh
rm -f /usr/local/sbin/hda-verb

# 5. Override de disponibilidad de PulseAudio/PipeWire (creado por este arreglo)
rm -rf /home/roger/.config/alsa-card-profile

# 6. Script de usuario y utilidades
rm -f /home/roger/bin/set-internal-mic.sh
rm -f /home/roger/bin/hda-verb

# 7. Restaurar la fuente predeterminada original (si existe el backup)
if [ -f /home/roger/audio_default_source_backup.txt ] && [ -x /home/roger/restore_audio.sh ]; then
    "${RUN_USER[@]}" /home/roger/restore_audio.sh >/dev/null 2>&1 || true
fi

echo "Arreglo deshecho."
echo "Cierra y vuelve a abrir pavucontrol. Si hace falta, reinicia la sesión."
