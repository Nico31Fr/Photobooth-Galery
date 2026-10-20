# Photobooth-Gallery

Galerie photo locale pour un photomaton fonctionnant avec deux Raspberry Pi.
Le Raspberry Pi « photomaton » envoie automatiquement les photos au Raspberry Pi
« galerie », qui crée un point d’accès Wi-Fi et les affiche dans une galerie web.

This project provides a local photo gallery for a photobooth using two Raspberry
Pis. The « photobooth » Raspberry Pi automatically sends photos to the « gallery »
Raspberry Pi, which creates a Wi-Fi access point and displays them in a web gallery.

## Fonctionnement / How it works

```text
[Photomaton] -- Ethernet -- [Galerie] -- Wi-Fi -- [Téléphones]
  pibooth                  point d'accès + portail + galerie web
  rsync/SSH  ------------> /srv/galerie/photos
```

| Équipement / Device | Interface | Adresse / Address | Fonction / Role |
|---|---|---|---|
| Galerie / Gallery | `eth0` | `192.168.50.1/24` | Liaison avec le photomaton / photobooth link |
| Galerie / Gallery | `wlan0` | `192.168.4.1/24` | Point d'accès Wi-Fi / Wi-Fi access point |
| Photomaton / Photobooth | `eth0` | `192.168.50.2/24` | Liaison avec la galerie / gallery link |

Le transfert est à sens unique, par SSH et `rsync`. Seules les images situées
à la racine du dossier surveillé sont envoyées ; les sous-dossiers sont ignorés.
La galerie génère automatiquement des miniatures et une version d'affichage.

Transfer is one-way, using SSH and `rsync`. Only images directly inside the
watched directory are sent; subdirectories are ignored. The gallery automatically
generates thumbnails and display-sized images.

## Contenu / Contents

- `install-galerie.sh` : installe le point d'accès Wi-Fi, le portail captif,
  nginx et la galerie FastAPI sur le Raspberry Pi galerie.
- `install-photomaton.sh` : configure la liaison Ethernet et le service de
  synchronisation des photos sur le Raspberry Pi photomaton.

## Prérequis / Requirements

- Deux Raspberry Pi reliés directement par Ethernet.
- Raspberry Pi OS Bookworm ou version compatible avec NetworkManager.
- Un utilisateur local avec les droits `sudo` sur chaque Pi.
- Le photomaton doit déjà produire des fichiers `.jpg`, `.jpeg` ou `.png`.
- Les scripts doivent être lancés avec `sudo` depuis un compte utilisateur normal
  (et non depuis une session directement ouverte en `root`).

You need two Raspberry Pis connected directly with Ethernet, Raspberry Pi OS
Bookworm (or a NetworkManager-compatible version), a local `sudo` user on each
Pi, and a photobooth that already creates `.jpg`, `.jpeg`, or `.png` files.
Run the scripts with `sudo` from a regular user account, not from a root login.

## Installation / Installation

Clone the repository or copy the two scripts to both Raspberry Pis:

```bash
git clone https://github.com/Nico31Fr/Photobooth-Galery.git
cd Photobooth-Galery
chmod +x install-galerie.sh install-photomaton.sh
```

### 1. Raspberry Pi galerie / Gallery Raspberry Pi

Run this on the Pi that will host the gallery:

```bash
sudo SSID="Photomaton" ./install-galerie.sh
```

For a protected Wi-Fi network:

```bash
sudo SSID="Photomaton" WIFI_PASS="choisir-un-mot-de-passe" ./install-galerie.sh
```

At the end, `wlan0` becomes an access point and `eth0` receives the fixed
address `192.168.50.1`. An SSH connection made through the old Ethernet
configuration will normally be disconnected; this is expected. Reconnect over
the new Wi-Fi at `http://192.168.4.1/` or through SSH at:

```bash
ssh <utilisateur-galerie>@192.168.4.1
```

The gallery stores received photos in `/srv/galerie/photos`.

### 2. Raspberry Pi photomaton / Photobooth Raspberry Pi

Connect the Ethernet cable, then run this on the photobooth Pi. Replace the
placeholders with the local account used on the gallery and the actual directory
containing the final photos:

```bash
sudo GALERIE_USER="<utilisateur-galerie>" \
  PHOTO_DIR="/chemin/vers/les/photos" \
  ./install-photomaton.sh
```

Optional network parameters are available:

```bash
sudo GALERIE_USER="<utilisateur-galerie>" \
  GALERIE_HOST="192.168.50.1" \
  P2P_IP="192.168.50.2/24" \
  PHOTO_DIR="/chemin/vers/les/photos" \
  ./install-photomaton.sh
```

The script creates a dedicated SSH key at `~/.ssh/id_galerie`. The gallery
user's password is requested once by `ssh-copy-id`; subsequent transfers do not
need a password.

## Utilisation / Usage

1. Connect phones to the Wi-Fi network defined by `SSID`.
2. Open `http://192.168.4.1/` if the captive portal does not open automatically.
3. Take photos with the photobooth. They should appear in the gallery after the
   transfer and thumbnail generation, usually within a few seconds.

The `photo-sync` service synchronizes at startup, when a file is completed, and
at least every 30 seconds. It does not delete files from the gallery.

La galerie est locale : le Pi galerie n'a normalement pas besoin d'un accès
Internet. Avec un réseau Wi-Fi ouvert, toute personne à portée peut consulter
les photos ; utilisez `WIFI_PASS` si elles doivent rester privées.

## Vérifications et dépannage / Checks and troubleshooting

On the photobooth Pi:

```bash
systemctl is-active photo-sync
journalctl -u photo-sync -f
ip -br addr show eth0
ping -c3 192.168.50.1
cat /etc/photo-sync.conf
```

On the gallery Pi:

```bash
systemctl status galerie nginx --no-pager
journalctl -u galerie -n 30 --no-pager
nmcli con show --active
ip -br addr show eth0 wlan0
ls -lt /srv/galerie/photos | head
curl -sI http://192.168.4.1/ | head -1
```

If no photo is synchronized, check that `PHOTO_DIR` exists and that the image
files are directly in that directory. If the service is active but the gallery
is empty, check `journalctl -u galerie` and confirm that the files are present in
`/srv/galerie/photos`.

Si le portail ne s'ouvre pas automatiquement, connectez-vous manuellement à
`http://192.168.4.1/`. Les sites HTTPS ne peuvent pas être redirigés par un
portail captif, ce qui est normal.

## Désinstallation / Uninstallation

The scripts do not provide an automatic uninstall command. To stop the main
services:

```bash
# Sur le Pi galerie / On the gallery Pi
sudo systemctl disable --now galerie nginx
sudo nmcli con delete hotspot
sudo nmcli con delete p2p-photomaton

# Sur le Pi photomaton / On the photobooth Pi
sudo systemctl disable --now photo-sync
sudo nmcli con delete p2p-galerie
```

Review the NetworkManager profiles before deleting them if the Pis use another
network configuration.

## Licence / License

Aucune licence spécifique n'est déclarée pour le moment.

No specific license has been declared yet.
