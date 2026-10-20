#!/usr/bin/env bash
# Photobooth Pi: automatically sends photos to the gallery Pi (rsync/SSH over eth0)
#
# Usage:  sudo GALERIE_USER=<gallery Pi user> ./install-photobooth_En.sh
# Options: PHOTO_DIR=/path/to/final/photos   (default: ~/Pictures/pibooth)
#          GALERIE_HOST=192.168.50.1  P2P_IP=192.168.50.2/24
#
# Example: sudo GALERIE_USER=<gallery-user> PHOTO_DIR=/path/to/photos ./install-photobooth_En.sh
# Requirement: the gallery Pi must be installed (install_galery_En.sh) and connected by Ethernet.
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run this script with sudo"; exit 1; }
ME="${SUDO_USER:?Run this script with sudo from a regular user account}"
HOME_DIR="$(getent passwd "$ME" | cut -d: -f6)"
GALERIE_USER="${GALERIE_USER:?Set GALERIE_USER=<gallery Pi user>}"
GALERIE_HOST="${GALERIE_HOST:-192.168.50.1}"
P2P_IP="${P2P_IP:-192.168.50.2/24}"
PHOTO_DIR="${PHOTO_DIR:-$HOME_DIR/Pictures/pibooth}"
KEY="$HOME_DIR/.ssh/id_galerie"

echo "==> Packages"
apt-get update
apt-get install -y rsync inotify-tools openssh-client

echo "==> Ethernet: static IP profile $P2P_IP (gallery link, without DHCP; Internet remains on Wi-Fi)"
nmcli con delete p2p-galerie 2>/dev/null || true
nmcli con add type ethernet ifname eth0 con-name p2p-galerie \
    ipv4.method manual ipv4.addresses "$P2P_IP" ipv4.never-default yes \
    ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 100
nmcli con up p2p-galerie || true

echo "==> Waiting for the gallery ($GALERIE_HOST)"
for _ in $(seq 1 15); do ping -c1 -W1 "$GALERIE_HOST" >/dev/null 2>&1 && break; sleep 1; done
ping -c1 -W1 "$GALERIE_HOST" >/dev/null 2>&1 || echo "!! The gallery does not respond to ping: is the cable connected and the gallery powered on?"

echo "==> Dedicated SSH key"
sudo -u "$ME" mkdir -p "$HOME_DIR/.ssh"
sudo -u "$ME" chmod 700 "$HOME_DIR/.ssh"
[ -f "$KEY" ] || sudo -u "$ME" ssh-keygen -t ed25519 -N "" -f "$KEY" -C "photobooth"

echo "==> Copying the key to $GALERIE_USER@$GALERIE_HOST (password requested once)"
if ! sudo -u "$ME" ssh-copy-id -i "$KEY.pub" -o StrictHostKeyChecking=accept-new \
        "$GALERIE_USER@$GALERIE_HOST"; then
    echo "!! ssh-copy-id failed (is the cable connected and the gallery installed?)."
    echo "   Run the command again later or add this key to ~/.ssh/authorized_keys on the gallery Pi:"
    cat "$KEY.pub"
fi

echo "==> Synchronization service"
cat > /etc/photo-sync.conf <<EOF
PHOTO_DIR="$PHOTO_DIR"
REMOTE="$GALERIE_USER@$GALERIE_HOST"
REMOTE_DIR="/srv/galerie/photos/"
KEY="$KEY"
EOF

cat > /usr/local/bin/photo-sync.sh <<'SHEOF'
#!/usr/bin/env bash
# Loop: rsync at startup, whenever a new photo is completed, and at least every 30 seconds.
# One-way transfer; nothing is deleted and subdirectories are not scanned.
# Only images directly inside PHOTO_DIR are synchronized.
. /etc/photo-sync.conf
while true; do
    if [ -d "$PHOTO_DIR" ]; then
        rsync -td \
            --include='*.[jJ][pP][gG]' --include='*.[jJ][pP][eE][gG]' --include='*.[pP][nN][gG]' \
            --exclude='*' \
            -e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=5" \
            "$PHOTO_DIR/" "$REMOTE:$REMOTE_DIR" || sleep 5
        inotifywait -qq -t 30 -e close_write -e moved_to "$PHOTO_DIR" || true
        sleep 1
    else
        sleep 5
    fi
done
SHEOF
chmod +x /usr/local/bin/photo-sync.sh

cat > /etc/systemd/system/photo-sync.service <<EOF
[Unit]
Description=Photo synchronization to the gallery
After=network-online.target

[Service]
User=$ME
ExecStart=/usr/local/bin/photo-sync.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now photo-sync.service

cat <<MSG

Completed.
  - Watched directory: $PHOTO_DIR
  - Destination:      $GALERIE_USER@$GALERIE_HOST:/srv/galerie/photos/

Checks:
  ping -c2 $GALERIE_HOST
  journalctl -u photo-sync -f
MSG
