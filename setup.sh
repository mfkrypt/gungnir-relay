#!/usr/bin/env bash
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────
# Edit these before running
DOMAINS=("target.com")               # add more: ("target.com" "target.org")
GUNGNIR_BIN="$HOME/go/bin/gungnir"          # path to gungnir binary
CONFIG_DIR="$HOME/.config/gungnir"
SERVICE_NAME="gungnir-discord"

# ── Safety checks ────────────────────────────────────────────────────────────

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found in PATH"
    exit 1
fi

if [[ ! -x "$GUNGNIR_BIN" ]]; then
    echo "ERROR: gungnir not found at $GUNGNIR_BIN"
    echo "Install with: go install github.com/g0ldencybersec/gungnir/cmd/gungnir@latest"
    exit 1
fi

echo "[*] Gungnir: $GUNGNIR_BIN"
echo "[*] Config dir: $CONFIG_DIR"
echo "[*] Domains: ${DOMAINS[*]}"

# ── Create directories ───────────────────────────────────────────────────────

mkdir -p "$CONFIG_DIR"
mkdir -p "$HOME/.config/systemd/user"

# ── Domain list ──────────────────────────────────────────────────────────────

printf '%s\n' "${DOMAINS[@]}" > "$CONFIG_DIR/domains.txt"
echo "[+] Wrote $CONFIG_DIR/domains.txt"

# ── Relay script ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/discord-relay.py" ]]; then
    echo "ERROR: discord-relay.py not found next to this script"
    echo "Place it in: $SCRIPT_DIR/"
    exit 1
fi
cp "$SCRIPT_DIR/discord-relay.py" "$CONFIG_DIR/discord-relay.py"
chmod +x "$CONFIG_DIR/discord-relay.py"
echo "[+] Installed $CONFIG_DIR/discord-relay.py"

# ── systemd service ──────────────────────────────────────────────────────────

cat > "$HOME/.config/systemd/user/${SERVICE_NAME}.service" << UNITEOF
[Unit]
Description=Gungnir CT log monitor → Discord
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -c '${GUNGNIR_BIN} -r ${CONFIG_DIR}/domains.txt -j -f | /usr/bin/python3 ${CONFIG_DIR}/discord-relay.py'
Restart=always
RestartSec=30

NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
UNITEOF

echo "[+] Wrote $HOME/.config/systemd/user/${SERVICE_NAME}.service"

# ── Enable and start ─────────────────────────────────────────────────────────

systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME"
echo "[+] Service enabled and started"

# ── Enable linger ────────────────────────────────────────────────────────────

loginctl enable-linger "$USER"
echo "[+] Linger enabled for $USER — service survives logout"

# ── Test alert ────────────────────────────────────────────────────────────────

echo ""
echo "[*] Sending test alert..."
echo '{"commonName":"*.test.target.com","org":"Test Alert","san":["*.test.target.com","test.target.com"],"domains":["*.test.target.com","test.target.com"],"source":"setup-script"}' | /usr/bin/python3 "$CONFIG_DIR/discord-relay.py"
echo "[+] Test alert sent — check Discord"

# ── Status ───────────────────────────────────────────────────────────────────

echo ""
echo "── Done ────────────────────────────────────────────────────────"
systemctl --user status "$SERVICE_NAME" --no-pager --lines=8
echo ""
echo "Monitor logs:  journalctl --user -u ${SERVICE_NAME} -f"
echo "Add domains:   echo 'new-target.com' >> ${CONFIG_DIR}/domains.txt"
echo "Restart:       systemctl --user restart ${SERVICE_NAME}"
