#!/usr/bin/env bash
# Gungnir CT-monitor → Discord relay — portable setup script
#
# Bundle (keep together in one directory):
#   setup.sh          this script
#   discord-relay.py  the relay (single source of truth — this script copies it)
#   domains.txt       OPTIONAL — if present it's installed; if absent a starter
#                     list is created in the config dir. Never auto-replaced.
#
# On a fresh machine it: installs the gungnir binary (via Go if needed),
# installs the relay and creates the domain list in ~/.config/gungnir/, writes
# a user systemd unit that pipes them together, and starts the service.
#
# Idempotent: safe to re-run. Existing files are kept, never clobbered —
# use --force to replace them with the bundle versions (old ones get a
# timestamped .bak). If the machine has no user systemd, it falls back to
# a plain nohup pipeline.
#
# Usage: ./setup.sh [--force]
#        GUNGNIR_BIN=/custom/path ./setup.sh   # binary location override

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gungnir"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/gungnir-discord.service"
RELAY="$BUNDLE_DIR/discord-relay.py"
DOMAINS="$BUNDLE_DIR/domains.txt"
GUNGNIR_BIN="${GUNGNIR_BIN:-$HOME/go/bin/gungnir}"

FORCE=0
if [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

echo "== Gungnir Discord relay setup =="
echo "Bundle dir:  $BUNDLE_DIR"
echo "Config dir:  $CONFIG_DIR"

# ── 1. Bundle integrity ─────────────────────────────────────────────────────

if [ ! -f "$RELAY" ]; then
    echo "ERROR: missing bundle file $RELAY — keep setup.sh and discord-relay.py" >&2
    echo "       together in one directory." >&2
    exit 1
fi

# ── 2. gungnir binary ───────────────────────────────────────────────────────

if [ ! -x "$GUNGNIR_BIN" ]; then
    if command -v go >/dev/null 2>&1; then
        echo "gungnir not found at $GUNGNIR_BIN — installing via go install..."
        go install github.com/g0ldencybersec/gungnir/cmd/gungnir@latest
    else
        echo "ERROR: gungnir not found at $GUNGNIR_BIN and Go is not installed." >&2
        echo "       Install Go, or set GUNGNIR_BIN=/path/to/gungnir and re-run." >&2
        exit 1
    fi
fi
echo "Using gungnir: $GUNGNIR_BIN"

# ── 3. Config files (keep existing unless --force) ───────────────────────────

mkdir -p "$CONFIG_DIR"

# Relay: copied from the bundle (single source of truth)
dest="$CONFIG_DIR/discord-relay.py"
if [ -f "$dest" ] && [ "$RELAY" -ef "$dest" ]; then
    echo "Bundle file already in place: $dest"
elif [ -f "$dest" ] && [ "$FORCE" -eq 0 ]; then
    echo "Keeping existing $dest (use --force to replace with bundle version)"
else
    if [ -f "$dest" ]; then
        bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$dest" "$bak"
        echo "Backed up existing file to $bak"
    fi
    install -m 0644 "$RELAY" "$dest"
    echo "Installed $dest"
fi

# domains.txt: created if missing; replaced only when --force AND the bundle
# carries a real copy — a generated starter never clobbers an existing list
dest="$CONFIG_DIR/domains.txt"
if [ -f "$dest" ]; then
    if [ "$FORCE" -eq 1 ] && [ -f "$DOMAINS" ] && [ ! "$DOMAINS" -ef "$dest" ]; then
        bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$dest" "$bak"
        install -m 0644 "$DOMAINS" "$dest"
        echo "Replaced $dest from bundle (backup: $bak)"
    else
        echo "Keeping existing $dest"
    fi
elif [ -f "$DOMAINS" ]; then
    install -m 0644 "$DOMAINS" "$dest"
    echo "Installed domains.txt from bundle"
else
    cat > "$dest" <<'TEMPLATE'
test.com
TEMPLATE
    echo "Created starter domains.txt in $CONFIG_DIR — edit it to add your targets."
fi

# ── 4. Systemd user unit ────────────────────────────────────────────────────

PYTHON="$(command -v python3 || echo /usr/bin/python3)"

if [ -f "$UNIT" ] && [ "$FORCE" -eq 0 ]; then
    echo "Keeping existing $UNIT (use --force to regenerate)"
else
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT" <<EOF
[Unit]
Description=Gungnir CT log monitor → Discord
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -c '$GUNGNIR_BIN -r $CONFIG_DIR/domains.txt -j -f | $PYTHON $CONFIG_DIR/discord-relay.py'
Restart=always
RestartSec=30

NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
EOF
    echo "Wrote $UNIT"
fi

# ── 5. Start / restart ───────────────────────────────────────────────────────

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now gungnir-discord.service
    echo "Service enabled and started."

    sleep 2
    if systemctl --user is-active --quiet gungnir-discord.service; then
        echo "STATUS: active ✔"
        journalctl --user -u gungnir-discord.service -n 3 --no-pager 2>/dev/null | tail -3 || true
    else
        echo "STATUS: NOT active — inspect with: journalctl --user -u gungnir-discord.service" >&2
        exit 1
    fi

    # Keep running after logout: user services die with the user manager
    # unless lingering is on. Enable it automatically; sudo hint as fallback.
    if loginctl show-user "$USER" 2>/dev/null | grep -q "^Linger=yes"; then
        echo "Linger already enabled — service survives logout."
    elif loginctl enable-linger "$USER" 2>/dev/null; then
        echo "Linger enabled — service survives logout."
    else
        echo "Could not enable linger — run 'sudo loginctl enable-linger $USER' once."
    fi
else
    echo "No systemctl found — starting as a background pipeline instead:"
    nohup bash -c "$GUNGNIR_BIN -r $CONFIG_DIR/domains.txt -j -f | $PYTHON $CONFIG_DIR/discord-relay.py" \
        > /tmp/gungnir.log 2>&1 &
    echo "PID $! — logs at /tmp/gungnir.log"
fi

echo "== Done. Edit $CONFIG_DIR/domains.txt to change monitored roots (the service watches it live). =="
