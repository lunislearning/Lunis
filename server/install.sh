#!/usr/bin/env bash
# =====================================================================
#  Lunis - one-command SERVER installer (Ubuntu / Debian)
#
#  Run this ON your own Linux box (the machine that will BE the server).
#  It installs and auto-starts everything Lunis needs:
#    - the Lunis web app            (port 8090)
#    - llama.cpp + Qwen2.5-3B model    (port 8080)  the AI tutor
#    - LibreTranslate                  (port 5000)  offline translation
#  ...all as auto-restarting services that come back on reboot.
#
#  Usage:
#    git clone https://github.com/lunislearning/Lunis.git ~/lunis
#    cd ~/lunis && bash server/install.sh
#
#  Safe to re-run: it skips anything already installed.
#
#  It also makes the box broadcast its own Wi-Fi ("Lunis") at every boot, so
#  students' phones and tablets connect with no router and no internet:
#  they join "Lunis" and open http://10.42.0.1:8090.
#    LUNIS_HOTSPOT=0                 skip the hotspot (use a router instead)
#    LUNIS_HOTSPOT_SSID=<name>       Wi-Fi name        (default: Lunis)
#    LUNIS_HOTSPOT_PASSWORD=<pass>   8+ characters     (default: generated, shown at the end)
#
#  NO INTERNET? Set LUNIS_OFFLINE_DIR to the "offline" folder of a Lunis offline
#  bundle (SD card / USB, built by packaging/build_offline.py). Everything that is
#  normally downloaded - the AI engine, the model, a Python for the translator, its
#  packages and the language models - then comes from that folder, and no system
#  packages are installed. lunis-installer-ubuntu.run sets it automatically.
# =====================================================================
set -euo pipefail

# --- where things live -------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
APP="$REPO/app"

MODEL_DIR="$HOME/models"
MODEL_FILE="qwen2.5-3b-instruct-q4_k_m.gguf"
MODEL_URL="${LUNIS_MODEL_URL:-https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf?download=true}"
LLAMA_DIR="$HOME/llama.cpp"
LT_VENV="$HOME/libretranslate-venv"
UNIT_DIR="$HOME/.config/systemd/user"

say()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[1;32m[ok]\033[0m $*"; }
warn() { echo -e "    \033[1;33m[!]\033[0m $*"; }

echo   "======================================="
echo   "  Lunis server installer"
echo   "======================================="
echo   "  Repo:  $REPO"
echo   "  App :  $APP"

OFFLINE="${LUNIS_OFFLINE_DIR:-}"
if [ -n "$OFFLINE" ]; then
    [ -d "$OFFLINE/linux" ] || { echo "LUNIS_OFFLINE_DIR=$OFFLINE is not a Lunis offline bundle (no linux/ folder)"; exit 1; }
    OFFLINE="$(cd "$OFFLINE" && pwd)"
    echo "  Offline install from: $OFFLINE"
fi

# --- 1. system packages ------------------------------------------------
if [ -n "$OFFLINE" ]; then
    say "System packages: skipped (offline install - nothing to download)"
    command -v python3 >/dev/null || { echo "python3 is missing - every Ubuntu has it; install it first"; exit 1; }
    sudo -v        # ask for the password once, up front (hotspot setup needs it)
else
    say "Installing system packages (needs sudo)"
    sudo apt-get update -y
    sudo apt-get install -y python3 python3-venv git curl build-essential cmake iw
    # hotspot pieces, only where NetworkManager runs (desktop Ubuntu); never install it on a server that doesn't use it
    command -v nmcli >/dev/null 2>&1 && sudo apt-get install -y dnsmasq-base
    ok "packages installed"
fi

# --- 2. build llama.cpp (the AI engine) --------------------------------
if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    ok "llama.cpp already built"
elif [ -n "$OFFLINE" ]; then
    # the official prebuilt Linux CPU release: picks the best kernel for this CPU at run time
    say "Installing the AI engine (llama.cpp) from the bundle"
    TGZ=$(ls "$OFFLINE"/linux/llama-*-bin-ubuntu-x64.tar.gz 2>/dev/null | head -1)
    [ -n "$TGZ" ] || { echo "the offline bundle has no llama-*-bin-ubuntu-x64.tar.gz"; exit 1; }
    TMPX=$(mktemp -d)
    tar -xzf "$TGZ" -C "$TMPX"
    SRV=$(find "$TMPX" -name llama-server -type f | head -1)
    mkdir -p "$LLAMA_DIR/build/bin"
    cp -a "$(dirname "$SRV")"/. "$LLAMA_DIR/build/bin/"
    rm -rf "$TMPX"
    "$LLAMA_DIR/build/bin/llama-server" --version >/dev/null 2>&1 && ok "llama.cpp installed" || warn "llama-server installed but would not run - check: $LLAMA_DIR/build/bin/llama-server --version"
else
    say "Building llama.cpp (a few minutes on a CPU box)"
    if [ -d "$LLAMA_DIR/.git" ]; then (cd "$LLAMA_DIR" && git pull --ff-only || true)
    else git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"; fi
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$LLAMA_DIR/build" -j "$(nproc)" --config Release
    ok "llama.cpp built"
fi

# --- 3. download the model (~1.9 GB, one time) -------------------------
mkdir -p "$MODEL_DIR"
if [ -f "$MODEL_DIR/$MODEL_FILE" ]; then
    ok "model already present ($MODEL_FILE)"
elif [ -n "$OFFLINE" ]; then
    say "Copying the Qwen2.5-3B model from the bundle (~1.9 GB)"
    [ -f "$OFFLINE/models/$MODEL_FILE" ] || { echo "the offline bundle has no models/$MODEL_FILE"; exit 1; }
    cp "$OFFLINE/models/$MODEL_FILE" "$MODEL_DIR/$MODEL_FILE.part"
    mv "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_DIR/$MODEL_FILE"
    ok "model copied"
else
    say "Downloading the Qwen2.5-3B model (~1.9 GB - this can take a while)"
    curl -L --fail -C - -o "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_URL"
    mv "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_DIR/$MODEL_FILE"
    ok "model downloaded"
fi

# --- 4. LibreTranslate (offline translation) ---------------------------
if [ -x "$LT_VENV/bin/libretranslate" ]; then
    ok "LibreTranslate already installed"
elif [ -n "$OFFLINE" ]; then
    # The bundle's packages are built for Python 3.12, and a fresh Ubuntu may have a
    # different python3 and no python3-venv. So it carries its own small Python.
    say "Installing LibreTranslate from the bundle"
    PYTGZ=$(ls "$OFFLINE"/linux/cpython-3.12*-x86_64-unknown-linux-gnu-install_only.tar.gz 2>/dev/null | head -1)
    [ -n "$PYTGZ" ] || { echo "the offline bundle has no cpython-3.12 tarball"; exit 1; }
    LT_PYHOME="$HOME/.local/share/lunis/python"
    rm -rf "$LT_PYHOME"; mkdir -p "$LT_PYHOME"
    tar -xzf "$PYTGZ" -C "$LT_PYHOME" --strip-components=1
    "$LT_PYHOME/bin/python3" -m venv "$LT_VENV"
    "$LT_VENV/bin/python" -m pip install --disable-pip-version-check --no-index \
        --find-links "$OFFLINE/linux/wheels" libretranslate
    ok "LibreTranslate installed"
else
    say "Installing LibreTranslate in its own virtualenv"
    python3 -m venv "$LT_VENV"
    "$LT_VENV/bin/pip" install --upgrade pip
    "$LT_VENV/bin/pip" install libretranslate
    ok "LibreTranslate installed"
fi
# Language models (+ the sentence-splitting models): now, not on first start - the
# classroom box may never see the internet again.
if [ -n "$OFFLINE" ]; then
    mkdir -p "$HOME/.local/share/argos-translate"
    cp -a "$OFFLINE/argos-translate/." "$HOME/.local/share/argos-translate/"
    "$LT_VENV/bin/python" "$SCRIPT_DIR/lt_models.py" --check en fr es de && ok "language models ready"         || warn "some language models are missing from the bundle"
else
    "$LT_VENV/bin/python" "$SCRIPT_DIR/lt_models.py" en fr es de && ok "language models ready"         || warn "language models not all installed - LibreTranslate will retry on first start (needs internet then)"
fi

# --- 5. lesson videos + the transcripts the tutor reads ----------------
# The videos are not in the git repo (CC BY-NC-SA, ~570 MB; see NOTICE.md).
# They are published as a release asset and fetched here, so one command gets
# both the code and the content. If the download fails the install continues:
# everything except the video lessons works without them.
if [ -n "$OFFLINE" ]; then
    warn "offline install - lesson videos not downloaded"
    warn "copy the content bundle from a USB stick later:"
    warn "  LUNIS_CONTENT_URL=file:///media/usb/lunis-content.tar.gz python3 scripts/fetch_content.py --download"
elif say "Downloading lesson videos (~570 MB, one time)" && ( cd "$REPO" && python3 scripts/fetch_content.py --download ); then
    ok "lesson videos ready"
else
    warn "could not download the lesson videos"
    warn "everything else (Reading Hub, Homework Helper, dashboard) still works"
    warn "to retry later:  python3 scripts/fetch_content.py --download"
fi

say "Preparing lesson transcripts"
if [ -d "$REPO/content" ] && ls "$REPO/content"/*.srt >/dev/null 2>&1; then
    ( cd "$REPO" && python3 app/prep.py ) || warn "prep.py had a hiccup (non-fatal)"
else
    warn "no lesson videos present - skipping transcripts"
fi

# --- 6. create the auto-start services ---------------------------------
say "Creating auto-start services (systemd --user)"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/lunis-llama.service" <<EOF
[Unit]
Description=llama.cpp (Qwen2.5-3B) for Lunis
After=network.target
[Service]
Type=simple
ExecStart=$LLAMA_DIR/build/bin/llama-server -m $MODEL_DIR/$MODEL_FILE --host 127.0.0.1 --port 8080 -c 4096 -t $(nproc)
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/lunis-translate.service" <<EOF
[Unit]
Description=LibreTranslate for Lunis
After=network.target
[Service]
Type=simple
ExecStart=$LT_VENV/bin/libretranslate --host 127.0.0.1 --port 5000 --load-only en,fr,es,de
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/lunis.service" <<EOF
[Unit]
Description=Lunis math tutor web app
After=network.target lunis-llama.service lunis-translate.service
[Service]
Type=simple
WorkingDirectory=$APP
ExecStart=/usr/bin/python3 $APP/server.py
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
EOF
ok "service files written to $UNIT_DIR"

# --- 7. enable + start -------------------------------------------------
say "Enabling and starting everything"
loginctl enable-linger "$USER" >/dev/null 2>&1 || warn "could not enable linger (services still start while you're logged in)"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload
systemctl --user enable --now lunis-llama lunis-translate lunis
ok "services enabled (they now start on boot)"

# --- 8. classroom Wi-Fi hotspot ---------------------------------------
# A persistent NetworkManager access point: comes up at every boot without anyone
# logging in. NetworkManager's "shared" mode makes the box a small router - DHCP and
# DNS for the students' devices, and NAT out of the wired port when that has
# internet. Students open http://lunis.lan (or http://10.42.0.1:8090).
# With a single Wi-Fi card the box can't be a hotspot AND join another Wi-Fi; the
# hotspot gets the higher priority at boot. For updates over home Wi-Fi run
#   sudo nmcli connection down Lunis-Hotspot     (it comes back at the next boot)
#
#   LUNIS_HOTSPOT_IFACE=wlx...   which Wi-Fi card to use (default: the first one;
#                                pick a USB adapter if the built-in card has a weak
#                                or missing antenna)
HOTSPOT_ON=0
HS_CON="Lunis-Hotspot"
HS_SSID="${LUNIS_HOTSPOT_SSID:-Lunis}"
HS_PASS=""
HS_FILE="$HOME/.local/share/lunis/hotspot.json"
if [ "${LUNIS_HOTSPOT:-1}" = "0" ]; then
    warn "hotspot skipped (LUNIS_HOTSPOT=0) - students need a Wi-Fi router"
elif ! command -v nmcli >/dev/null 2>&1; then
    warn "NetworkManager (nmcli) not found - no hotspot. Students need a Wi-Fi router."
else
    say "Classroom Wi-Fi hotspot"
    # An access point set up earlier (by this installer or by hand) is kept as it is.
    EXISTING=""
    while IFS=: read -r name type; do
        [ "$type" = "802-11-wireless" ] || continue
        if [ "$(nmcli -g 802-11-wireless.mode connection show "$name" 2>/dev/null)" = "ap" ]; then EXISTING="$name"; break; fi
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)

    if [ -n "$EXISTING" ] && [ -z "${LUNIS_HOTSPOT_SSID:-}${LUNIS_HOTSPOT_PASSWORD:-}" ]; then
        HS_CON="$EXISTING"
        HS_SSID=$(nmcli -g 802-11-wireless.ssid connection show "$HS_CON")
        HS_PASS=$(sudo nmcli -s -g 802-11-wireless-security.psk connection show "$HS_CON" 2>/dev/null || true)
        ok "keeping the existing hotspot '$HS_CON' (Wi-Fi \"$HS_SSID\")"
        HOTSPOT_ON=1
    else
        WIFI_DEV="${LUNIS_HOTSPOT_IFACE:-}"
        [ -z "$WIFI_DEV" ] && WIFI_DEV=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
        if [ -z "$WIFI_DEV" ]; then
            warn "no Wi-Fi card managed by NetworkManager - skipping. Students need a Wi-Fi router."
        elif nmcli -t -f DEVICE,STATE device | grep -q "^$WIFI_DEV:unmanaged"; then
            warn "$WIFI_DEV is not managed by NetworkManager (common on Ubuntu Server: netplan uses networkd)."
            warn "Set 'renderer: NetworkManager' in /etc/netplan/*.yaml, run 'sudo netplan apply', then re-run this installer."
        elif command -v iw >/dev/null 2>&1 && ! iw list 2>/dev/null | grep -q '^[[:space:]]*\* AP$'; then
            warn "the Wi-Fi card ($WIFI_DEV) can't act as an access point - students need a Wi-Fi router."
        else
            HS_PASS="${LUNIS_HOTSPOT_PASSWORD:-}"
            if [ -z "$HS_PASS" ] && [ -f "$HS_FILE" ]; then
                HS_PASS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("password",""))' "$HS_FILE" 2>/dev/null || true)
            fi
            if [ ${#HS_PASS} -lt 8 ]; then
                [ -n "$HS_PASS" ] && warn "hotspot password must be 8+ characters - using a generated one"
                HS_PASS="lunis$(shuf -i 1000-9999 -n 1)"
            fi
            [ -n "$EXISTING" ] && sudo nmcli connection delete "$EXISTING" >/dev/null 2>&1 || true
            sudo nmcli connection delete "$HS_CON" >/dev/null 2>&1 || true
            # 2.4 GHz WPA2-AES: what the oldest, cheapest phones and tablets can join
            sudo nmcli connection add type wifi ifname "$WIFI_DEV" con-name "$HS_CON" ssid "$HS_SSID" \
                connection.autoconnect yes connection.autoconnect-priority 100 \
                802-11-wireless.mode ap 802-11-wireless.band bg \
                ipv4.method shared ipv4.addresses 10.42.0.1/24 ipv6.method disabled \
                wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp \
                wifi-sec.psk "$HS_PASS" >/dev/null
            ok "hotspot \"$HS_SSID\" on $WIFI_DEV saved - it starts at every boot"
            HOTSPOT_ON=1
        fi
    fi

    if [ "$HOTSPOT_ON" = "1" ]; then
        # Friendly address: lunis.lan resolves to the box, and port 80 is redirected
        # to the app, so students type http://lunis.lan - no IP, no :8090.
        printf 'address=/lunis.lan/10.42.0.1\naddress=/lunis.box/10.42.0.1\n' |
            sudo tee /etc/NetworkManager/dnsmasq-shared.d/lunis.conf >/dev/null
        sudo tee /etc/NetworkManager/dispatcher.d/90-lunis-port80 >/dev/null <<EOF
#!/bin/sh
# Lunis: students can type http://lunis.lan instead of http://10.42.0.1:8090
IFACE="\$1"; ACTION="\$2"
[ "\$CONNECTION_ID" = "$HS_CON" ] || exit 0
command -v iptables >/dev/null 2>&1 || exit 0
RULE="PREROUTING -i \$IFACE -p tcp --dport 80 -j REDIRECT --to-ports 8090"
case "\$ACTION" in
  up)   iptables -t nat -C \$RULE 2>/dev/null || iptables -t nat -A \$RULE ;;
  down) iptables -t nat -D \$RULE 2>/dev/null || true ;;
esac
exit 0
EOF
        sudo chmod 755 /etc/NetworkManager/dispatcher.d/90-lunis-port80
        mkdir -p "$(dirname "$HS_FILE")"
        printf '{\n  "enabled": true,\n  "ssid": "%s",\n  "password": "%s",\n  "connection": "%s"\n}\n' \
            "$HS_SSID" "$HS_PASS" "$HS_CON" > "$HS_FILE"
        # (Re)start it so the name and redirect take effect - unless that would cut
        # off the person running the installer over this same Wi-Fi card.
        HS_DEV=$(nmcli -g connection.interface-name connection show "$HS_CON" 2>/dev/null)
        DEV_CON=$(nmcli -t -f DEVICE,CONNECTION device 2>/dev/null | awk -F: -v d="$HS_DEV" '$1==d{print $2}')
        if [ -n "${SSH_CONNECTION:-}" ] && [ -n "$DEV_CON" ] && [ "$DEV_CON" != "$HS_CON" ]; then
            warn "you're on SSH and $HS_DEV is in use - the hotspot starts at the next reboot"
            warn "(or now: sudo nmcli connection up $HS_CON)"
        elif sudo nmcli connection up "$HS_CON" >/dev/null 2>&1; then
            ok "hotspot is on"
        else
            warn "could not start it now (it will try again at boot): sudo nmcli connection up $HS_CON"
        fi
    fi
fi

# --- 9. health check ---------------------------------------------------
say "Checking the app is up"
CODE=000
for i in $(seq 1 20); do
    CODE=$(python3 -c 'import urllib.request as u
try: print(u.urlopen("http://127.0.0.1:8090/", timeout=3).status)
except Exception: print("000")' 2>/dev/null || echo 000)
    [ "$CODE" = "200" ] && break
    sleep 1
done

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo "======================================="
if [ "$CODE" = "200" ]; then
    echo -e "  \033[1;32mLunis is RUNNING\033[0m"
else
    echo -e "  \033[1;33mApp not answering yet (HTTP $CODE)\033[0m"
    echo   "  Check: systemctl --user status lunis"
fi
echo   "======================================="
echo   "  Open it from this machine:   http://127.0.0.1:8090"
[ -n "${IP:-}" ] && [ "$IP" != "10.42.0.1" ] && echo "  From other devices on the LAN: http://$IP:8090"
if [ "$HOTSPOT_ON" = "1" ]; then
    echo
    echo -e "  \033[1;32mSTUDENTS:  join Wi-Fi  $HS_SSID\033[0m"
    echo -e "  \033[1;32m           password    $HS_PASS\033[0m"
    echo -e "  \033[1;32m           then open   http://lunis.lan   (or http://10.42.0.1:8090)\033[0m"
fi
echo
echo   "  Notes:"
echo   "   - The AI model and translator load in the background; the very first"
echo   "     AI answer (and first LibreTranslate start) can take a minute."
echo   "   - Manage services:  systemctl --user status|restart lunis"
echo   "                       systemctl --user status lunis-llama lunis-translate"
echo   "   - Logs:             journalctl --user -u lunis -n 50"
echo   "   - First time you open it, an on-screen wizard sets the teacher password."
if [ "$HOTSPOT_ON" = "1" ]; then
echo   "   - Hotspot on/off:   sudo nmcli connection up|down $HS_CON"
echo   "     (it always comes back at boot; remove it: sudo nmcli connection delete $HS_CON)"
else
echo   "   - Kids' Wi-Fi with no internet: a cheap Wi-Fi router, or re-run with a Wi-Fi card"
fi
echo
