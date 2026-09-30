#!/usr/bin/env bash
# Target-change monitoring bundle — portable setup script
#
# Installs two independent monitors:
#   1. gungnir   — CT-log watcher  → Discord   (long-running service)
#   2. js-watch  — JS chunk/sourcemap watcher → Discord   (daily timer)
#
# Bundle (keep together in one directory):
#   setup.sh            this script
#   discord-relay.py    gungnir's relay (single source of truth — copied, not embedded)
#   js-watch.sh         the JS watcher     (single source of truth — copied)
#   js-watch-notify.py  its Discord notifier
#   public-cdns.txt     default CDN suppression list for js-watch
#   domains.txt         OPTIONAL — gungnir roots; a starter is created if absent
#   hosts.txt           OPTIONAL — js-watch hosts;  a starter is created if absent
#
# NO WEBHOOK IS EVER STORED IN THIS REPO — it is public. Each monitor's webhook
# is collected at install time (flag or prompt) and written to that monitor's
# env file with mode 0600; the generated unit reads it via EnvironmentFile=.
#
# Idempotent: safe to re-run. Existing files are kept, never clobbered — use
# --force to replace them with the bundle versions (old ones get a timestamped
# .bak). If the machine has no user systemd, gungnir falls back to a nohup
# pipeline and js-watch is installed but unscheduled — add it to crontab.
#
# Usage: ./setup.sh [--force] [--no-seed] [--help]
#        GUNGNIR_BIN=/custom/path ./setup.sh
#        JS_WATCH_WEBHOOK='https://discord.com/api/webhooks/...' ./setup.sh
#        JS_WATCH_BIN_DIR=~/.local/bin ./setup.sh

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XDG_CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$XDG_CFG/gungnir"
JS_CONFIG_DIR="$XDG_CFG/js-watch"
UNIT_DIR="$XDG_CFG/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/js-watch"

RELAY="$BUNDLE_DIR/discord-relay.py"
DOMAINS="$BUNDLE_DIR/domains.txt"
JS_WATCH="$BUNDLE_DIR/js-watch.sh"
JS_NOTIFY="$BUNDLE_DIR/js-watch-notify.py"
JS_CDNS="$BUNDLE_DIR/public-cdns.txt"
JS_HOSTS="$BUNDLE_DIR/hosts.txt"

GUNGNIR_BIN="${GUNGNIR_BIN:-$HOME/go/bin/gungnir}"
JS_WATCH_BIN_DIR="${JS_WATCH_BIN_DIR:-$HOME/.local/bin}"

FORCE=0
SEED=1
for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=1;;
        --no-seed) SEED=0;;
        --help|-h)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2;;
    esac
done

echo "== Target-change monitoring setup =="
echo "Bundle dir:  $BUNDLE_DIR"
echo

# ── 1. Bundle integrity ─────────────────────────────────────────────────────

missing=0
for f in "$RELAY" "$JS_WATCH" "$JS_NOTIFY" "$JS_CDNS"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing bundle file $f" >&2
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo "       Keep setup.sh and the scripts together in one directory." >&2
    exit 1
fi

# install_file <src> <dest> <mode> <label>
# Copy-once semantics: never clobber an existing file unless --force, and always
# leave a timestamped backup when replacing. A source already in place (same
# inode) is a no-op so re-running from the installed config dir is safe.
install_file() {
    local src="$1" dest="$2" mode="$3" label="$4"
    if [ -f "$dest" ] && [ "$src" -ef "$dest" ]; then
        echo "  $label already in place"
    elif [ -f "$dest" ] && [ "$FORCE" -eq 0 ]; then
        echo "  keeping existing $label (use --force to replace)"
    else
        if [ -f "$dest" ]; then
            local bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
            cp -a "$dest" "$bak"
            echo "  backed up existing $label → $(basename "$bak")"
        fi
        install -m "$mode" "$src" "$dest"
        echo "  installed $label"
    fi
}

# collect_webhook <ENV_VAR_NAME> <dest_file> <label>
# Resolves a Discord webhook without EVER writing it into this bundle — the repo
# is public. Order: explicit env var → existing config file → interactive prompt.
# Sets WEBHOOK_OUT to the value (empty if none). Returns 1 if a supplied value
# was malformed, so callers can report rather than silently dropping it.
WEBHOOK_OUT=""
collect_webhook() {
    local var="$1" dest="$2" label="$3" url="${!1:-}"
    WEBHOOK_OUT=""

    if [ -z "$url" ] && [ -f "$dest" ]; then
        url="$(grep -oP '(?<=^DISCORD_WEBHOOK_URL=).*' "$dest" 2>/dev/null | head -1 || true)"
        [ -n "$url" ] && { echo "  reusing $label webhook already in $dest"; WEBHOOK_OUT="$url"; return 0; }
    fi

    if [ -z "$url" ] && [ -t 0 ] && [ -t 2 ]; then
        printf '  %s Discord webhook URL (blank to skip): ' "$label" >&2
        read -rs url || true
        printf '\n' >&2
    fi

    [ -n "$url" ] || return 0

    if ! printf '%s' "$url" | grep -qE '^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$'; then
        echo "  ERROR: $label webhook does not look like a Discord webhook URL — skipped." >&2
        echo "         Expected https://discord.com/api/webhooks/<id>/<token>" >&2
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    umask 077
    cat > "$dest" <<EOF
# $label Discord webhook. Mode 0600 — anyone with this URL can post to the
# channel. Deliberately NOT stored in the setup repo, which is public.
DISCORD_WEBHOOK_URL=$url
EOF
    chmod 0600 "$dest"
    echo "  wrote $dest (mode 0600)"
    WEBHOOK_OUT="$url"
    return 0
}

# ── 2. gungnir (CT-log → Discord) ───────────────────────────────────────────

echo "[1/2] gungnir CT-log monitor"

if [ ! -x "$GUNGNIR_BIN" ]; then
    if command -v go >/dev/null 2>&1; then
        echo "  gungnir not found at $GUNGNIR_BIN — installing via go install..."
        go install github.com/g0ldencybersec/gungnir/cmd/gungnir@latest
    else
        echo "  ERROR: gungnir not found and Go is not installed." >&2
        echo "         Install Go, or set GUNGNIR_BIN=/path/to/gungnir and re-run." >&2
        exit 1
    fi
fi
echo "  using $GUNGNIR_BIN"

mkdir -p "$CONFIG_DIR"
install_file "$RELAY" "$CONFIG_DIR/discord-relay.py" 0644 "discord-relay.py"

# domains.txt: created if missing; replaced only when --force AND the bundle
# carries a real copy — a generated starter never clobbers an existing list.
dest="$CONFIG_DIR/domains.txt"
if [ -f "$dest" ]; then
    if [ "$FORCE" -eq 1 ] && [ -f "$DOMAINS" ] && [ ! "$DOMAINS" -ef "$dest" ]; then
        bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$dest" "$bak"
        install -m 0644 "$DOMAINS" "$dest"
        echo "  replaced domains.txt from bundle (backup: $(basename "$bak"))"
    else
        echo "  keeping existing domains.txt"
    fi
elif [ -f "$DOMAINS" ]; then
    install -m 0644 "$DOMAINS" "$dest"
    echo "  installed domains.txt from bundle"
else
    printf 'test.com\n' > "$dest"
    echo "  created starter domains.txt — edit it to add your targets"
fi

# Webhook: prefer an env file over pasting into discord-relay.py, which is a
# TRACKED file in a PUBLIC repo. The relay already reads DISCORD_WEBHOOK_URL
# from the environment and only uses its hardcoded default as a fallback, so
# this is purely additive — an existing pasted-in deployment keeps working.
collect_webhook GUNGNIR_WEBHOOK "$CONFIG_DIR/env" gungnir || true

# ── 3. js-watch (JS chunk/sourcemap → Discord) ──────────────────────────────

echo
echo "[2/2] js-watch JS chunk/sourcemap monitor"

mkdir -p "$JS_WATCH_BIN_DIR" "$JS_CONFIG_DIR" "$STATE_DIR"
install_file "$JS_WATCH"  "$JS_WATCH_BIN_DIR/js-watch.sh"        0755 "js-watch.sh"
install_file "$JS_NOTIFY" "$JS_WATCH_BIN_DIR/js-watch-notify.py" 0755 "js-watch-notify.py"
install_file "$JS_CDNS"   "$JS_CONFIG_DIR/public-cdns.txt"       0644 "public-cdns.txt"

# hosts.txt — same create-if-missing contract as domains.txt
dest="$JS_CONFIG_DIR/hosts.txt"
if [ -f "$dest" ]; then
    echo "  keeping existing hosts.txt"
elif [ -f "$JS_HOSTS" ]; then
    install -m 0644 "$JS_HOSTS" "$dest"
    echo "  installed hosts.txt from bundle"
else
    cat > "$dest" <<'TEMPLATE'
# js-watch host list — one origin per line. '#' comments allowed.
# https://example.com
TEMPLATE
    echo "  created starter hosts.txt — add targets or nothing will be watched"
fi

ENV_FILE="$JS_CONFIG_DIR/env"
collect_webhook JS_WATCH_WEBHOOK "$ENV_FILE" js-watch || true
if [ ! -f "$ENV_FILE" ]; then
    echo "  no webhook supplied — js-watch will install but cannot post."
    echo "         Re-run with:  JS_WATCH_WEBHOOK='https://discord.com/api/webhooks/...' ./setup.sh"
fi

# ── 4. systemd user units ───────────────────────────────────────────────────

PYTHON="$(command -v python3 || echo /usr/bin/python3)"
HAVE_SYSTEMD=0
command -v systemctl >/dev/null 2>&1 && HAVE_SYSTEMD=1

if [ "$HAVE_SYSTEMD" -eq 1 ]; then
    mkdir -p "$UNIT_DIR"

    # --- gungnir service (unchanged behaviour) ---
    UNIT="$UNIT_DIR/gungnir-discord.service"
    if [ -f "$UNIT" ] && [ "$FORCE" -eq 0 ]; then
        echo "keeping existing gungnir-discord.service (use --force to regenerate)"
    else
        cat > "$UNIT" <<EOF
[Unit]
Description=Gungnir CT log monitor → Discord
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

# Webhook, if one was supplied at install time (mode 0600, outside the repo).
# '-' keeps this optional: without it the relay falls back to the default built
# into discord-relay.py, so a pasted-in deployment still works.
EnvironmentFile=-$CONFIG_DIR/env

ExecStart=/bin/bash -c '$GUNGNIR_BIN -r $CONFIG_DIR/domains.txt -j -f | $PYTHON $CONFIG_DIR/discord-relay.py'
Restart=always
RestartSec=30

NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
EOF
        echo "wrote gungnir-discord.service"
    fi

    # --- js-watch service + timer ---
    JUNIT="$UNIT_DIR/js-watch.service"
    if [ -f "$JUNIT" ] && [ "$FORCE" -eq 0 ]; then
        echo "keeping existing js-watch.service (use --force to regenerate)"
    else
        cat > "$JUNIT" <<EOF
[Unit]
Description=JS chunk/sourcemap change watch → Discord
Documentation=file:$JS_WATCH_BIN_DIR/js-watch.sh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot

# Webhook lives here (mode 0600). '-' makes it optional so the unit still runs
# and logs, rather than failing, if the file is missing.
EnvironmentFile=-$ENV_FILE

# pipefail so a watcher crash surfaces as a failed unit instead of a notifier
# that reports "nothing to send" on an empty stream.
ExecStart=/bin/bash -c 'set -o pipefail; $JS_WATCH_BIN_DIR/js-watch.sh | $PYTHON $JS_WATCH_BIN_DIR/js-watch-notify.py'

TimeoutStartSec=900
Nice=10
EOF
        echo "wrote js-watch.service"
    fi

    TUNIT="$UNIT_DIR/js-watch.timer"
    if [ -f "$TUNIT" ] && [ "$FORCE" -eq 0 ]; then
        echo "keeping existing js-watch.timer (use --force to regenerate)"
    else
        cat > "$TUNIT" <<'EOF'
[Unit]
Description=Daily JS chunk/sourcemap change watch

[Timer]
# Deliberately off the hour — a full sweep is ~300 outbound requests across all
# hosts, and every other cron-ish job on every box fires at :00.
OnCalendar=*-*-* 09:23:00
# Catch up after boot if the machine was asleep/off at 09:23.
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF
        echo "wrote js-watch.timer"
    fi

    systemctl --user daemon-reload
fi

# ── 5. Start / verify ───────────────────────────────────────────────────────

if [ "$HAVE_SYSTEMD" -eq 1 ]; then
    systemctl --user enable --now gungnir-discord.service
    echo
    echo "gungnir-discord.service enabled."
    sleep 2
    if systemctl --user is-active --quiet gungnir-discord.service; then
        echo "  STATUS: active ✔"
    else
        echo "  STATUS: NOT active — journalctl --user -u gungnir-discord.service" >&2
    fi

    systemctl --user enable --now js-watch.timer
    echo "js-watch.timer enabled."
    systemctl --user list-timers js-watch.timer --no-pager 2>/dev/null | head -2 || true

    # Seed baselines. The first run per host adopts what it sees WITHOUT
    # alerting, so this posts nothing to Discord — it just means tomorrow's run
    # diffs against reality instead of declaring the whole site new.
    if [ "$SEED" -eq 1 ] && [ -s "$JS_CONFIG_DIR/hosts.txt" ] \
       && grep -qvE '^\s*(#|$)' "$JS_CONFIG_DIR/hosts.txt"; then
        echo
        echo "Seeding JS baselines (first run is silent; ~1-2 min)..."
        if systemctl --user start js-watch.service; then
            echo "  seeded ✔ — baselines in $STATE_DIR"
        else
            echo "  seeding failed — journalctl --user -u js-watch.service" >&2
        fi
    fi

    # ${USER:-$(id -un)} — USER is unset under cron, many containers and some
    # SSH setups, and `set -u` turns that into a fatal error right at the end of
    # an otherwise successful install.
    LINGER_USER="${USER:-$(id -un)}"
    if loginctl show-user "$LINGER_USER" 2>/dev/null | grep -q "^Linger=yes"; then
        echo "Linger already enabled — services survive logout."
    elif loginctl enable-linger "$LINGER_USER" 2>/dev/null; then
        echo "Linger enabled — services survive logout."
    else
        echo "Could not enable linger — run 'sudo loginctl enable-linger $LINGER_USER' once."
    fi
else
    echo "No systemctl found — starting gungnir as a background pipeline:"
    nohup bash -c "$GUNGNIR_BIN -r $CONFIG_DIR/domains.txt -j -f | $PYTHON $CONFIG_DIR/discord-relay.py" \
        > /tmp/gungnir.log 2>&1 &
    echo "  PID $! — logs at /tmp/gungnir.log"
    echo "js-watch needs a scheduler: add to crontab if you want it here."
fi

echo
echo "== Done =="
echo "  gungnir roots : $CONFIG_DIR/domains.txt   (watched live — no restart needed)"
echo "  js-watch hosts: $JS_CONFIG_DIR/hosts.txt  (appended hosts picked up next run)"
echo "  js-watch state: $STATE_DIR"
