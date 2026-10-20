#!/usr/bin/env bash
# Gallery Pi: Wi-Fi access point + captive portal + dynamic photo gallery
# Tested with Raspberry Pi OS Bookworm (NetworkManager).
#
# Usage:  sudo SSID="Photobooth" GALERIE_PIN="1234" ./install_galery_En.sh
#         (add WIFI_PASS="password8chars+" for protected Wi-Fi, or leave empty for an open network)
#
# WARNING: at the end of this script, wlan0 becomes an access point and eth0 gets a
# static IP address (without DHCP). Your SSH session will be disconnected at the very
# end; this is expected because the installation is complete. Reconnect through the
# Wi-Fi network (ssh <user>@192.168.4.1), or from the photobooth (ssh <user>@192.168.50.1).
set -euo pipefail
trap '' HUP   # allow the script to finish even if the SSH session is disconnected

[ "$EUID" -eq 0 ] || { echo "Run this script with sudo"; exit 1; }
ADMIN="${SUDO_USER:?Run this script with sudo from a regular user account}"
SSID="${SSID:-Photobooth}"
WIFI_PASS="${WIFI_PASS:-}"
GALERIE_PIN="${GALERIE_PIN:-}"
[[ "$GALERIE_PIN" =~ ^[0-9]{4,}$ ]] || {
    echo "GALERIE_PIN must contain at least 4 digits" >&2
    exit 1
}
PIN_HASH="$(printf '%s' "$GALERIE_PIN" | sha256sum | awk '{print $1}')"
AP_IP="192.168.4.1"          # Gallery IP on Wi-Fi (captive portal)
P2P_IP="192.168.50.1/24"     # IP added to eth0 for the point-to-point link
ROOT="/srv/galerie"
APP="/opt/galerie"

echo "==> Packages"
apt-get update
apt-get install -y nginx rsync python3-venv dnsmasq-base network-manager

echo "==> Directories"
install -d -o "$ADMIN" -g "$ADMIN" "$ROOT" "$ROOT/photos" "$ROOT/thumbs" "$ROOT/views" "$APP"

echo "==> Web application (FastAPI)"
sudo -u "$ADMIN" python3 -m venv "$APP/venv"
sudo -u "$ADMIN" "$APP/venv/bin/pip" install --quiet fastapi uvicorn pillow python-multipart

cat > /etc/galerie.conf <<EOF
GALERIE_PIN_HASH=$PIN_HASH
EOF
chmod 600 /etc/galerie.conf

cat > "$APP/app.py" <<'PYEOF'
import hashlib
import os
import secrets
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Form
from fastapi.responses import HTMLResponse
from PIL import Image, ImageOps

ROOT = Path(os.environ.get("GALERIE_ROOT", "/srv/galerie"))
PHOTOS, THUMBS, VIEWS = ROOT / "photos", ROOT / "thumbs", ROOT / "views"
EXT = {".jpg", ".jpeg", ".png"}
index = {}  # original filename -> mtime
index_lock = threading.Lock()
PIN_HASH = os.environ.get("GALERIE_PIN_HASH", "")


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
            # Newest first; each photo appears in the gallery as soon as it is ready
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
                    with index_lock:
                        index[f.name] = f.stat().st_mtime
                    seen.add(f.name)
                except Exception as e:  # incomplete or unreadable file: retry on the next scan
                    print("skip", f.name, e, flush=True)
            with index_lock:
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


def clear_gallery():
    deleted = 0
    for directory in (PHOTOS, THUMBS, VIEWS):
        for item in directory.iterdir():
            if item.is_file():
                try:
                    item.unlink()
                    deleted += 1
                except FileNotFoundError:
                    pass
    with index_lock:
        index.clear()
    return deleted

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Photobooth</title>
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
<h1>Photobooth</h1>
<p style="text-align:center"><a href="/admin" style="color:#aaa">Administration</a></p>
<div id="grid"></div>
<div id="lb"><img id="big">
  <div><a id="dl">Download</a> <button id="x">Close</button></div></div>
<script>
const grid=document.getElementById('grid'), lb=document.getElementById('lb'),
      big=document.getElementById('big'), dl=document.getElementById('dl');
const known=new Set();
function add(p){
  const im=new Image();
  im.dataset.name=p.n;
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
    const current=new Set(list.map(p=>p.n));
    [...known].forEach(n=>{
      if(!current.has(n)){
        [...grid.querySelectorAll('img')].filter(im=>im.dataset.name===n).forEach(im=>im.remove());
        known.delete(n);
      }
    });
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
    with index_lock:
        items = sorted(list(index.items()), key=lambda kv: kv[1], reverse=True)
    return [{"n": n, "s": Path(n).stem, "t": t} for n, t in items]


ADMIN_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Administration - Photobooth</title>
<style>body{margin:0;background:#111;color:#eee;font-family:system-ui,sans-serif;text-align:center;padding:24px}
form{max-width:360px;margin:30px auto;padding:20px;background:#222;border-radius:10px}
input,button{font-size:1rem;padding:10px;border-radius:8px;border:0;margin:5px}
button{color:#fff;background:#a22}a{color:#aaa}</style></head><body>
<h1>Administration</h1>
<p>Delete the photos, thumbnails, and display versions from the gallery.</p>
<form method="post" action="/admin/clear" onsubmit="return confirm('Delete all photos from the gallery?')">
  <label>PIN: <input name="pin" type="password" inputmode="numeric" required></label><br>
  <button type="submit">Empty gallery</button>
</form>
<p><a href="/">Back to gallery</a></p>
</body></html>"""


@app.get("/admin", response_class=HTMLResponse)
def admin():
    return ADMIN_PAGE


@app.post("/admin/clear", response_class=HTMLResponse)
def clear(pin: str = Form("")):
    supplied_hash = hashlib.sha256(pin.encode()).hexdigest()
    if not PIN_HASH or not secrets.compare_digest(supplied_hash, PIN_HASH):
        return HTMLResponse("<h1>Incorrect PIN</h1><p><a href='/admin'>Try again</a></p>", status_code=403)
    deleted = clear_gallery()
    return HTMLResponse(
        f"<h1>Gallery emptied</h1><p>{deleted} file(s) deleted.</p>"
        "<p><a href='/'>Back to gallery</a></p>"
    )
PYEOF
chown "$ADMIN":"$ADMIN" "$APP/app.py"

cat > /etc/systemd/system/galerie.service <<EOF
[Unit]
Description=Photo gallery (FastAPI)
After=network.target

[Service]
User=$ADMIN
WorkingDirectory=$APP
EnvironmentFile=/etc/galerie.conf
ExecStart=$APP/venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --no-access-log
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "==> nginx (captive portal + static files)"
cat > /etc/nginx/sites-available/galerie <<'NGEOF'
# If a request arrives through Wi-Fi (server IP 192.168.4.1) with a Host different
# from 192.168.4.1 (connectivitycheck.gstatic.com, captive.apple.com, etc.), redirect
# it to the portal. This triggers the automatic opening of the portal page.
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
systemctl enable galerie.service
systemctl restart galerie.service
systemctl enable nginx
systemctl restart nginx

echo "==> Wi-Fi: country FR + access point '$SSID'"
raspi-config nonint do_wifi_country FR || true
rfkill unblock wifi || true

# Prevent possible Wi-Fi client profiles from taking over wlan0
nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-11-wireless" && $1!="hotspot"{print $1}' |
while read -r c; do nmcli con mod "$c" connection.autoconnect no || true; done

nmcli con delete hotspot 2>/dev/null || true
nmcli con add type wifi ifname wlan0 con-name hotspot autoconnect yes ssid "$SSID" \
    802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6 \
    ipv4.method shared ipv4.addresses "$AP_IP/24" ipv6.method disabled
if [ -n "$WIFI_PASS" ]; then
    nmcli con modify hotspot wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS"
fi

# Captive portal DNS: resolve every domain name to the gallery
mkdir -p /etc/NetworkManager/dnsmasq-shared.d
echo "address=/#/$AP_IP" > /etc/NetworkManager/dnsmasq-shared.d/captive.conf

nmcli con up hotspot

echo "==> Ethernet: static IP profile $P2P_IP (photobooth link, without DHCP)"
nmcli con delete p2p-photomaton 2>/dev/null || true
nmcli con add type ethernet ifname eth0 con-name p2p-photomaton \
    ipv4.method manual ipv4.addresses "$P2P_IP" ipv4.never-default yes \
    ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 100
# The next command disconnects any SSH session using eth0 through DHCP.
nmcli con up p2p-photomaton || true

cat <<MSG

Completed.
  - Wi-Fi: '$SSID' (portal: http://$AP_IP/)
  - Received photos: $ROOT/photos
  - Administration: http://$AP_IP/admin (PIN required)
  - Photobooth link: eth0 = ${P2P_IP%/*}
  - SSH: through Wi-Fi '$SSID' -> ssh $ADMIN@$AP_IP; from the photobooth -> ssh $ADMIN@${P2P_IP%/*}

Checks:
  nmcli con show --active
  systemctl status galerie nginx --no-pager
  curl -sI http://$AP_IP/ | head -1
MSG
