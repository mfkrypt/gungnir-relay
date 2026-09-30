#!/usr/bin/env python3
"""
js-watch-notify.py — JSONL alert stream → Discord webhook.

Sibling of gungnir's discord-relay.py. It does NOT reuse that script because
the relay's parser is cert-shaped (commonName / san / org) and building fake
certificates to carry JS alerts would produce embeds labelled "Common Name"
and "SAN Count" over chunk filenames. Same webhook, same channel, honest
field names.

Reads one JSON object per line on stdin, as emitted by js-watch.sh:

  {"type":"new-chunk","host":"example.com","detail":"main.a3f2b1.js","url":"..."}

Groups by host and posts ONE embed per host per run — a run that finds nine
new chunks should be one notification, not nine.

Config via environment (matches discord-relay.py where the option overlaps):
  DISCORD_WEBHOOK_URL   - webhook (required unless --stdout)
  RATE_LIMIT_SECONDS    - min seconds between POSTs (default 2)
  STATE_FILE            - dedup state; suppress a repeat alert for 7 days
                          (default ~/.local/state/js-watch/.notify-dedup.json)
  DEDUP_TTL_SECONDS     - how long a posted alert stays suppressed (default 604800)

Options:
  --stdout    print the embeds instead of posting (for testing)
  --no-dedup  post even if an identical alert was posted recently
"""

import json
import os
import sys
import time
import hashlib
import urllib.request
import urllib.error
from datetime import datetime, timezone

WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
RATE_LIMIT = float(os.environ.get("RATE_LIMIT_SECONDS", "2"))
DEDUP_TTL = int(os.environ.get("DEDUP_TTL_SECONDS", str(7 * 86400)))
STATE_FILE = os.path.expanduser(
    os.environ.get("STATE_FILE", "~/.local/state/js-watch/.notify-dedup.json")
)

# One colour per signal so the channel is scannable at a glance.
COLORS = {
    "new-chunk": 0x00C8FF,      # cyan   — new code shipped
    "changed-bundle": 0xFFAA00,  # amber  — in-place redeploy
    "new-sourcemap": 0xFF3355,   # red    — source-leak regression
    "secret-hit": 0x9C27FF,     # violet — credential-shaped string, new for this host
    "chunk-gone": 0x777777,      # grey   — route/feature removed
}
LABELS = {
    "new-chunk": "🆕 New chunks",
    "changed-bundle": "♻️ Changed in place",
    "new-sourcemap": "🚨 New sourcemap exposure",
    "secret-hit": "🔑 Credential-shaped strings",
    "chunk-gone": "🗑️ Chunks gone",
}
# A secret is the one signal that is reportable without further work, so it
# leads. Values arrive already masked by js-watch.sh — the footer names the
# local file holding the full ones.
ORDER = ["secret-hit", "new-sourcemap", "new-chunk", "changed-bundle", "chunk-gone"]

MAX_FIELD = 1000  # Discord caps field values at 1024


def log(msg):
    print(f"[js-watch-notify] {msg}", file=sys.stderr)


# ── dedup ────────────────────────────────────────────────────────────────────

def load_state():
    try:
        with open(STATE_FILE) as f:
            return {k: float(v) for k, v in json.load(f).items()}
    except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError):
        return {}


def save_state(state, dirty):
    if not dirty:
        return
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_FILE)
    except OSError as e:
        log(f"could not save dedup state: {e}")


# ── embed building ───────────────────────────────────────────────────────────

def build_embed(host, alerts):
    """One embed per host. Returns None if every alert was deduped."""
    fields = []
    for kind in ORDER:
        items = [a["detail"] for a in alerts if a["type"] == kind]
        if not items:
            continue
        shown = items[:20]
        value = "\n".join(f"`{i}`" for i in shown)
        if len(items) > len(shown):
            value += f"\n… (+{len(items) - len(shown)} more)"
        if len(value) > MAX_FIELD:
            value = value[:MAX_FIELD - 20] + "\n… (truncated)"
        fields.append({
            "name": f"{LABELS[kind]} ({len(items)})",
            "value": value,
            "inline": False,
        })

    if not fields:
        return None

    # First match in ORDER wins, so this tracks the priority list above.
    primary = next((k for k in ORDER if any(a["type"] == k for a in alerts)),
                   alerts[0]["type"])

    embed = {
        "title": f"📦 JS change — {host}",
        "color": COLORS.get(primary, 0x00C8FF),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "fields": fields[:25],
    }

    # Secret hits arrive masked. Name the local file that holds the full values
    # in the alert itself — otherwise the first thing the reader does is go
    # hunting for it, or worse, treat the masked prefix as the whole finding.
    evidence = next((a.get("evidence") for a in alerts
                     if a["type"] == "secret-hit" and a.get("evidence")), None)
    if evidence:
        embed["footer"] = {"text": f"full values: {evidence}"}

    return embed


def post(embed):
    payload = json.dumps({"embeds": [embed]}).encode()
    req = urllib.request.Request(
        WEBHOOK_URL, data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "js-watch/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return 200 <= r.status < 300
    except urllib.error.HTTPError as e:
        log(f"webhook HTTP {e.code}: {e.read()[:200]!r}")
    except (urllib.error.URLError, OSError) as e:
        log(f"webhook error: {e}")
    return False


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    to_stdout = "--stdout" in sys.argv
    no_dedup = "--no-dedup" in sys.argv

    if not WEBHOOK_URL and not to_stdout:
        log("DISCORD_WEBHOOK_URL not set — use --stdout to preview, or set the env var")
        return 1

    by_host = {}
    bad = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            a = json.loads(line)
        except json.JSONDecodeError:
            bad += 1
            continue
        by_host.setdefault(a.get("host", "unknown"), []).append(a)

    if bad:
        log(f"skipped {bad} malformed line(s)")

    if not by_host:
        return 0  # silent when nothing changed — this is the normal case

    state = {} if no_dedup else load_state()
    now = time.time()
    dirty = False
    posted = 0

    for host, alerts in sorted(by_host.items()):
        if not no_dedup:
            fresh = []
            for a in alerts:
                key = hashlib.sha1(
                    f"{a['type']}|{host}|{a['detail']}".encode()
                ).hexdigest()
                if state.get(key, 0) > now:
                    continue
                state[key] = now + DEDUP_TTL
                dirty = True
                fresh.append(a)
            alerts = fresh
            if not alerts:
                continue

        embed = build_embed(host, alerts)
        if embed is None:
            continue

        if to_stdout:
            print(json.dumps(embed, indent=2))
        else:
            if posted:
                time.sleep(RATE_LIMIT)
            if post(embed):
                log(f"posted {len(alerts)} alert(s) for {host}")
                posted += 1
            else:
                log(f"FAILED to post for {host}")
                # do not persist dedup for a failed post
                dirty = False

    save_state(state, dirty)
    return 0


if __name__ == "__main__":
    sys.exit(main())
