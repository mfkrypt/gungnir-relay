#!/usr/bin/env python3
"""
Gungnir CT Log → Discord Webhook Relay

Reads JSONL from gungnir stdin, deduplicates domains, rate-limits, and POSTs
formatted embeds to a Discord webhook.

Config via environment variables:
  DISCORD_WEBHOOK_URL   - Discord webhook URL (required)
  DEDUP_TTL_SECONDS     - Seconds before a domain can re-alert (default: 86400 = 24h)
  RATE_LIMIT_SECONDS    - Minimum seconds between Discord POSTs (default: 2)
  BATCH_SIZE            - Max domains per embed when queueing (default: 5)
  LOG_FILE              - Log file path (default: stderr only)
"""

import json
import os
import sys
import time
import logging
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ── Config from env ──────────────────────────────────────────────────────────

WEBHOOK_URL = os.environ.get(
    "DISCORD_WEBHOOK_URL",
    "<PASTE_HERE>",
)

DEDUP_TTL = int(os.environ.get("DEDUP_TTL_SECONDS", "86400"))
RATE_LIMIT = float(os.environ.get("RATE_LIMIT_SECONDS", "2"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "5"))
LOG_FILE = os.environ.get("LOG_FILE", "")

# ── Logging ──────────────────────────────────────────────────────────────────

logger = logging.getLogger("gungnir-discord")
logger.setLevel(logging.INFO)
fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%dT%H:%M:%S")

# stderr handler
stderr_handler = logging.StreamHandler(sys.stderr)
stderr_handler.setFormatter(fmt)
logger.addHandler(stderr_handler)

# Optional file handler
if LOG_FILE:
    file_handler = logging.FileHandler(LOG_FILE)
    file_handler.setFormatter(fmt)
    logger.addHandler(file_handler)

# ── Dedup cache ──────────────────────────────────────────────────────────────

_seen: dict[str, float] = {}  # domain → expiry timestamp


def _purge_expired():
    """Remove expired entries from the dedup cache."""
    now = time.monotonic()
    expired = [d for d, exp in _seen.items() if exp <= now]
    for d in expired:
        del _seen[d]
    if expired:
        logger.debug("Purged %d expired entries from dedup cache", len(expired))


def is_new(domain: str) -> bool:
    """Return True if this domain hasn't been seen within DEDUP_TTL."""
    now = time.monotonic()
    if domain in _seen and _seen[domain] > now:
        return False
    _seen[domain] = now + DEDUP_TTL
    return True


# ── Discord embed builder ────────────────────────────────────────────────────

EMBED_COLOR = 0x00FF88  # green


def _strip_wildcard(domain: str) -> str:
    """Strip leading *. from wildcard domains for cleaner display."""
    if domain.startswith("*."):
        return domain[2:]
    return domain


def _make_embeds(batch: list[dict]) -> list[dict]:
    """Build one or more Discord embed objects from a batch of cert entries."""
    embeds = []
    for entry in batch:
        cn = entry.get("commonName", "unknown")
        org = entry.get("org") or "—"
        sans = entry.get("san", [])
        source = entry.get("source", "unknown")

        # Primary domain: first non-wildcard SAN, or fall back to CN
        cleaned = [_strip_wildcard(d) for d in sans]
        primary = cleaned[0] if cleaned else _strip_wildcard(cn)
        san_list = ", ".join(cleaned[:8])
        if len(cleaned) > 8:
            san_list += f" … (+{len(cleaned) - 8} more)"

        embed = {
            "title": f"🔔 {primary}",
            "color": EMBED_COLOR,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "fields": [
                {"name": "Common Name", "value": cn, "inline": True},
                {"name": "Source", "value": source, "inline": True},
                {"name": "SAN Count", "value": str(len(sans)), "inline": True},
                {"name": "Organization", "value": org, "inline": True},
                {"name": "SANs", "value": f"`{san_list}`", "inline": False},
            ],
        }
        embeds.append(embed)
    return embeds


# ── Discord sender ───────────────────────────────────────────────────────────

_last_post: float = 0.0  # monotonic timestamp of last POST


def _rate_limit_wait():
    """Sleep until RATE_LIMIT seconds have passed since the last POST."""
    global _last_post
    now = time.monotonic()
    wait = _last_post + RATE_LIMIT - now
    if wait > 0:
        time.sleep(wait)
    _last_post = time.monotonic()


def _post_to_discord(embeds: list[dict]) -> bool:
    """POST embeds to the Discord webhook. Returns True on success."""
    payload = json.dumps({"embeds": embeds}).encode("utf-8")
    req = urllib.request.Request(
        WEBHOOK_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "gungnir-discord-relay/1.0",
        },
        method="POST",
    )

    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                if resp.status == 204:
                    return True
                # Webhook sometimes returns 200 with body on errors
                body = resp.read().decode(errors="replace")
                logger.warning("Discord returned HTTP %d: %s", resp.status, body[:200])
                # Treat non-204 as transient
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            logger.warning("HTTP %d from Discord (attempt %d/3): %s", e.code, attempt, body[:200])
            if e.code == 429:
                # Respect Retry-After header
                retry_after = e.headers.get("Retry-After", "5")
                try:
                    wait = float(retry_after)
                except ValueError:
                    wait = 5
                logger.info("Rate limited — waiting %.1fs", wait)
                time.sleep(wait)
                continue
            if e.code in (400, 401, 403, 404):
                logger.error("Fatal HTTP %d — dropping message", e.code)
                return False
        except (urllib.error.URLError, OSError) as e:
            logger.warning("Network error (attempt %d/3): %s", attempt, e)

        if attempt < 3:
            backoff = 2 ** attempt
            logger.info("Retrying in %ds...", backoff)
            time.sleep(backoff)

    logger.error("Failed to post to Discord after 3 attempts")
    return False


# ── Main loop ────────────────────────────────────────────────────────────────

def main():
    logger.info("Gungnir Discord relay started")
    logger.info("Dedup TTL: %ds | Rate limit: %.1fs | Batch size: %d",
                DEDUP_TTL, RATE_LIMIT, BATCH_SIZE)

    queue: list[dict] = []
    total_alerts = 0

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        # Parse JSONL
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            logger.debug("Skipping non-JSON line: %s", line[:80])
            continue

        # Extract domains and filter for new ones
        domains = entry.get("domains", [])
        new_domains = []
        for d in domains:
            clean = _strip_wildcard(d)
            if is_new(clean):
                new_domains.append(clean)

        if new_domains:
            entry["_new_domains"] = new_domains
            queue.append(entry)
            logger.debug("Queued: %s", new_domains)

        # Periodically purge expired dedup entries (every 100 lines)
        if len(_seen) % 100 == 0:
            _purge_expired()

        # Flush queue when it reaches batch size
        if len(queue) >= BATCH_SIZE:
            _flush(queue, BATCH_SIZE)
            total_alerts += BATCH_SIZE
            queue.clear()

    # Flush remainder
    if queue:
        _flush(queue, len(queue))
        total_alerts += len(queue)

    logger.info("Stopping — %d total alerts sent", total_alerts)


_last_flush_time: float = 0.0


def _flush(queue: list[dict], count: int):
    """Take `count` entries from the front of queue and post them."""
    global _last_flush_time

    batch = queue[:count]

    # Enforce rate limit
    _rate_limit_wait()

    embeds = _make_embeds(batch)
    ok = _post_to_discord(embeds)

    domains_alerted = [d for e in batch for d in e.get("_new_domains", [])]
    if ok:
        logger.info("Posted %d domain(s): %s", len(domains_alerted), ", ".join(domains_alerted))
    else:
        logger.warning("Failed to post %d domain(s): %s", len(domains_alerted), ", ".join(domains_alerted))


if __name__ == "__main__":
    main()
