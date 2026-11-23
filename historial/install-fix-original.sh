#!/bin/bash
# One-time privileged installation of the ALC257 internal-mic fix.
set -e

SRC=/tmp/opencode

install -o root -g root -m 0755 /home/roger/bin/hda-verb /usr/local/sbin/hda-verb
install -o root -g root -m 0755 "$SRC/fix-internal-mic.sh" /usr/local/sbin/fix-internal-mic.sh
install -o root -g root -m 0644 "$SRC/fix-internal-mic.service" /etc/systemd/system/fix-internal-mic.service
install -d -o root -g root -m 0755 /usr/lib/systemd/system-sleep
install -o root -g root -m 0755 "$SRC/fix-internal-mic-sleep" /usr/lib/systemd/system-sleep/fix-internal-mic

cat > /etc/sudoers.d/fix-internal-mic <<'EOF'
roger ALL=(root) NOPASSWD: /usr/local/sbin/fix-internal-mic.sh
EOF
chown root:root /etc/sudoers.d/fix-internal-mic
chmod 0440 /etc/sudoers.d/fix-internal-mic
visudo -cf /etc/sudoers.d/fix-internal-mic

# Locate the codec for verification
DEV=""
for carddir in /proc/asound/card[0-9]*; do
    [ -d "$carddir" ] || continue
    cardnum=${carddir##*card}
    for codecfile in "$carddir"/codec#*; do
        [ -f "$codecfile" ] || continue
        if grep -q "Realtek ALC257" "$codecfile" 2>/dev/null; then
            addr=${codecfile##*codec#}
            DEV="/dev/snd/hwC${cardnum}D${addr}"
            CODEC=$codecfile
            break 2
        fi
    done
done

echo "== Before =="
[ -n "$DEV" ] && /usr/local/sbin/hda-verb "$DEV" 0x23 0xb00 0x0001 || true
[ -n "$DEV" ] && /usr/local/sbin/hda-verb "$DEV" 0x23 0xb00 0x0005 || true

systemctl daemon-reload
systemctl enable fix-internal-mic.service >/dev/null
systemctl start fix-internal-mic.service

echo "== After =="
[ -n "$DEV" ] && /usr/local/sbin/hda-verb "$DEV" 0x23 0xb00 0x0001 || true
[ -n "$DEV" ] && /usr/local/sbin/hda-verb "$DEV" 0x23 0xb00 0x0005 || true

echo "== Codec node 0x23 =="
if [ -n "$CODEC" ]; then
    awk '/^Node 0x23 /{f=1} f{print} f && /^Node / && !/^Node 0x23 /{exit}' "$CODEC" | grep -E "Amp-In vals|Connection:|0x1"
fi

echo "== Service =="
systemctl is-enabled fix-internal-mic.service
systemctl is-active fix-internal-mic.service
