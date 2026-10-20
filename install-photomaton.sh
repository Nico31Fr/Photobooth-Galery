#!/usr/bin/env bash
# Pi "photomaton" : envoie automatiquement les photos vers le Pi galerie (rsync/SSH sur eth0)
#
# Usage :  sudo GALERIE_USER=<utilisateur du Pi galerie> ./install-photomaton.sh
# Options : PHOTO_DIR=/chemin/des/photos/finales   (défaut : ~/Pictures/pibooth)
#           GALERIE_HOST=192.168.50.1  P2P_IP=192.168.50.2/24
#
# Exemple : sudo GALERIE_USER=<utilisateur-galerie> PHOTO_DIR=/chemin/vers/les/photos ./install-photomaton.sh
# Pré-requis : le Pi galerie est installé (install-galerie.sh) et relié en ethernet.
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Lance ce script avec sudo"; exit 1; }
ME="${SUDO_USER:?Lance-le avec sudo depuis ton utilisateur normal}"
HOME_DIR="$(getent passwd "$ME" | cut -d: -f6)"
GALERIE_USER="${GALERIE_USER:?Précise GALERIE_USER=<utilisateur du Pi galerie>}"
GALERIE_HOST="${GALERIE_HOST:-192.168.50.1}"
P2P_IP="${P2P_IP:-192.168.50.2/24}"
PHOTO_DIR="${PHOTO_DIR:-$HOME_DIR/Pictures/pibooth}"
KEY="$HOME_DIR/.ssh/id_galerie"

echo "==> Paquets"
apt-get update
apt-get install -y rsync inotify-tools openssh-client

echo "==> Ethernet : profil IP fixe $P2P_IP (liaison galerie, sans DHCP ; internet reste sur le wifi)"
nmcli con delete p2p-galerie 2>/dev/null || true
nmcli con add type ethernet ifname eth0 con-name p2p-galerie \
    ipv4.method manual ipv4.addresses "$P2P_IP" ipv4.never-default yes \
    ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 100
nmcli con up p2p-galerie || true

echo "==> Attente de la galerie ($GALERIE_HOST)"
for _ in $(seq 1 15); do ping -c1 -W1 "$GALERIE_HOST" >/dev/null 2>&1 && break; sleep 1; done
ping -c1 -W1 "$GALERIE_HOST" >/dev/null 2>&1 || echo "!! La galerie ne répond pas au ping : câble branché, galerie allumée ?"

echo "==> Clé SSH dédiée"
sudo -u "$ME" mkdir -p "$HOME_DIR/.ssh"
sudo -u "$ME" chmod 700 "$HOME_DIR/.ssh"
[ -f "$KEY" ] || sudo -u "$ME" ssh-keygen -t ed25519 -N "" -f "$KEY" -C "photomaton"

echo "==> Copie de la clé sur $GALERIE_USER@$GALERIE_HOST (mot de passe demandé une fois)"
if ! sudo -u "$ME" ssh-copy-id -i "$KEY.pub" -o StrictHostKeyChecking=accept-new \
        "$GALERIE_USER@$GALERIE_HOST"; then
    echo "!! Échec de ssh-copy-id (câble branché ? galerie installée ?)."
    echo "   Relance la commande plus tard ou ajoute cette clé dans ~/.ssh/authorized_keys du Pi galerie :"
    cat "$KEY.pub"
fi

echo "==> Service de synchronisation"
cat > /etc/photo-sync.conf <<EOF
PHOTO_DIR="$PHOTO_DIR"
REMOTE="$GALERIE_USER@$GALERIE_HOST"
REMOTE_DIR="/srv/galerie/photos/"
KEY="$KEY"
EOF

cat > /usr/local/bin/photo-sync.sh <<'SHEOF'
#!/usr/bin/env bash
# Boucle : rsync au démarrage, à chaque nouvelle photo terminée, et au moins toutes les 30 s.
# Sens unique, ne supprime rien, pas de récursion (uniquement les images à la racine de PHOTO_DIR).
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
Description=Synchro des photos vers la galerie
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

Terminé.
  - Dossier surveillé : $PHOTO_DIR
  - Destination       : $GALERIE_USER@$GALERIE_HOST:/srv/galerie/photos/

Vérifications :
  ping -c2 $GALERIE_HOST
  journalctl -u photo-sync -f
MSG
