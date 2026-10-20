#!/usr/bin/env bash
# Pi "galerie" : point d'accès wifi + portail captif + galerie photo dynamique
# Testé pour Raspberry Pi OS Bookworm (NetworkManager).
#
# Usage :  sudo SSID="Photomaton" ./install-galerie.sh
#          (ajouter WIFI_PASS="motdepasse8car+" pour un wifi protégé, sinon réseau ouvert)
#
# ATTENTION : en fin de script, wlan0 devient un point d'accès et eth0 passe en IP fixe
# (sans DHCP). Ta session SSH sera donc coupée à la toute fin : c'est normal, tout est
# déjà installé. Reconnecte-toi ensuite via le wifi « Photomaton » (ssh <user>@192.168.4.1)
# ou depuis le photomaton (ssh <user>@192.168.50.1).
set -euo pipefail
trap '' HUP   # le script va au bout même si la session SSH est coupée

[ "$EUID" -eq 0 ] || { echo "Lance ce script avec sudo"; exit 1; }
ADMIN="${SUDO_USER:?Lance-le avec sudo depuis ton utilisateur normal}"
SSID="${SSID:-Photomaton}"
WIFI_PASS="${WIFI_PASS:-}"
AP_IP="192.168.4.1"          # IP de la galerie côté wifi (portail)
P2P_IP="192.168.50.1/24"     # IP ajoutée sur eth0 pour la liaison point à point
ROOT="/srv/galerie"
APP="/opt/galerie"

echo "==> Paquets"
apt-get update
apt-get install -y nginx rsync python3-venv dnsmasq-base network-manager

echo "==> Dossiers"
install -d -o "$ADMIN" -g "$ADMIN" "$ROOT" "$ROOT/photos" "$ROOT/thumbs" "$ROOT/views" "$APP"

echo "==> Application web (FastAPI)"
sudo -u "$ADMIN" python3 -m venv "$APP/venv"
sudo -u "$ADMIN" "$APP/venv/bin/pip" install --quiet fastapi uvicorn pillow

cat > "$APP/app.py" <<'PYEOF'
import os
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from PIL import Image, ImageOps

ROOT = Path(os.environ.get("GALERIE_ROOT", "/srv/galerie"))
PHOTOS, THUMBS, VIEWS = ROOT / "photos", ROOT / "thumbs", ROOT / "views"
EXT = {".jpg", ".jpeg", ".png"}
index = {}  # nom du fichier original -> mtime


def make(src, dst, size, quality):
    with Image.open(src) as im:
        im = ImageOps.exif_transpose(im).convert("RGB")
        im.thumbnail((size, size))
        tmp = dst.with_name("." + dst.name)
        im.save(tmp, "JPEG", quality=quality)
        tmp.replace(dst)


def mtime(f):
    try:
        return f.stat().st_mtime
    except OSError:
        return 0


def scanner():
    while True:
        try:
            seen = set()
            # Plus récentes d'abord ; chaque photo apparaît dans la galerie dès qu'elle est prête
            for f in sorted(os.scandir(PHOTOS), key=mtime, reverse=True):
                if f.name.startswith(".") or Path(f.name).suffix.lower() not in EXT:
                    continue
                stem = Path(f.name).stem
                t, v = THUMBS / f"{stem}.jpg", VIEWS / f"{stem}.jpg"
                try:
                    if not t.exists():
                        make(f.path, t, 480, 80)
                    if not v.exists():
                        make(f.path, v, 1600, 85)
                    index[f.name] = f.stat().st_mtime
                    seen.add(f.name)
                except Exception as e:  # fichier incomplet ou illisible : on réessaie au prochain tour
                    print("skip", f.name, e, flush=True)
            for name in set(index) - seen:
                index.pop(name, None)
        except Exception as e:
            print("scan error", e, flush=True)
        time.sleep(2)


@asynccontextmanager
async def lifespan(app):
    for d in (PHOTOS, THUMBS, VIEWS):
        d.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=scanner, daemon=True).start()
    yield


app = FastAPI(lifespan=lifespan)

PAGE = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Photomaton</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#111;color:#eee;font-family:system-ui,sans-serif}
h1{font-size:1.1rem;text-align:center;padding:14px;margin:0}
#grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:4px;padding:4px}
#grid img{width:100%;aspect-ratio:1;object-fit:cover;display:block;background:#222}
#lb{position:fixed;inset:0;background:rgba(0,0,0,.92);display:none;flex-direction:column;
    align-items:center;justify-content:center;gap:12px;padding:10px}
#lb img{max-width:100%;max-height:80vh}
#lb a,#lb button{color:#fff;background:#333;border:0;border-radius:8px;padding:10px 18px;
    font-size:1rem;text-decoration:none}
</style></head><body>
<h1>Photomaton</h1>
<div id="grid"></div>
<div id="lb"><img id="big">
  <div><a id="dl">Télécharger</a> <button id="x">Fermer</button></div></div>
<script>
const grid=document.getElementById('grid'), lb=document.getElementById('lb'),
      big=document.getElementById('big'), dl=document.getElementById('dl');
const known=new Set();
function add(p){
  const im=new Image();
  im.src='/thumbs/'+encodeURIComponent(p.s)+'.jpg';
  im.onclick=()=>{
    big.src='/views/'+encodeURIComponent(p.s)+'.jpg';
    dl.href='/photos/'+encodeURIComponent(p.n);
    dl.setAttribute('download',p.n);
    lb.style.display='flex';
  };
  grid.prepend(im);
}
async function poll(){
  try{
    const list=await (await fetch('/api/photos')).json();
    list.slice().reverse().forEach(p=>{ if(!known.has(p.n)){ known.add(p.n); add(p); } });
  }catch(e){}
}
document.getElementById('x').onclick=()=>{ lb.style.display='none'; big.src=''; };
poll(); setInterval(poll,3000);
</script></body></html>"""


@app.get("/", response_class=HTMLResponse)
def home():
    return PAGE


@app.get("/api/photos")
def photos():
    items = sorted(list(index.items()), key=lambda kv: kv[1], reverse=True)
    return [{"n": n, "s": Path(n).stem, "t": t} for n, t in items]
PYEOF
chown "$ADMIN":"$ADMIN" "$APP/app.py"

cat > /etc/systemd/system/galerie.service <<EOF
[Unit]
Description=Galerie photo (FastAPI)
After=network.target

[Service]
User=$ADMIN
WorkingDirectory=$APP
ExecStart=$APP/venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --no-access-log
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "==> nginx (portail captif + fichiers statiques)"
cat > /etc/nginx/sites-available/galerie <<'NGEOF'
# Si la requête arrive par le wifi (IP serveur 192.168.4.1) avec un Host différent
# de 192.168.4.1 (connectivitycheck.gstatic.com, captive.apple.com...), on redirige
# vers le portail : c'est ce qui déclenche l'ouverture automatique de la page.
map "$server_addr:$host" $portal_redirect {
    default                    0;
    "192.168.4.1:192.168.4.1"  0;
    ~^192\.168\.4\.1:          1;
}

server {
    listen 80 default_server;
    server_name _;

    if ($portal_redirect) { return 302 http://192.168.4.1/; }

    location /photos/ { alias /srv/galerie/photos/; }
    location /thumbs/ { alias /srv/galerie/thumbs/; expires 1h; }
    location /views/  { alias /srv/galerie/views/;  expires 1h; }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
    }
}
NGEOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/galerie /etc/nginx/sites-enabled/galerie
nginx -t

systemctl daemon-reload
systemctl enable --now galerie.service
systemctl enable nginx
systemctl restart nginx

echo "==> Wifi : pays FR + point d'accès « $SSID »"
raspi-config nonint do_wifi_country FR || true
rfkill unblock wifi || true

# Empêche d'éventuels profils wifi « client » de reprendre wlan0
nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-11-wireless" && $1!="hotspot"{print $1}' |
while read -r c; do nmcli con mod "$c" connection.autoconnect no || true; done

nmcli con delete hotspot 2>/dev/null || true
nmcli con add type wifi ifname wlan0 con-name hotspot autoconnect yes ssid "$SSID" \
    802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
    ipv4.method shared ipv4.addresses "$AP_IP/24" ipv6.method disabled
if [ -n "$WIFI_PASS" ]; then
    nmcli con modify hotspot wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS"
fi

# DNS du portail : tout nom de domaine résout vers la galerie
mkdir -p /etc/NetworkManager/dnsmasq-shared.d
echo "address=/#/$AP_IP" > /etc/NetworkManager/dnsmasq-shared.d/captive.conf

nmcli con up hotspot

echo "==> Ethernet : profil IP fixe $P2P_IP (liaison photomaton, sans DHCP)"
nmcli con delete p2p-photomaton 2>/dev/null || true
nmcli con add type ethernet ifname eth0 con-name p2p-photomaton \
    ipv4.method manual ipv4.addresses "$P2P_IP" ipv4.never-default yes \
    ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 100
# Dernière commande : une session SSH passée par eth0 (DHCP) est coupée ici.
nmcli con up p2p-photomaton || true

cat <<MSG

Terminé.
  - Wifi : « $SSID » (portail : http://$AP_IP/)
  - Photos reçues dans : $ROOT/photos
  - Liaison photomaton : eth0 = ${P2P_IP%/*}
  - SSH : via le wifi « $SSID » -> ssh $ADMIN@$AP_IP ; depuis le photomaton -> ssh $ADMIN@${P2P_IP%/*}

Vérifications :
  nmcli con show --active
  systemctl status galerie nginx --no-pager
  curl -sI http://$AP_IP/ | head -1
MSG
