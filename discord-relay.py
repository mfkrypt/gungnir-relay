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
  DEDUP_STATE_FILE      - File persisting dedup state across restarts
                          (default: ~/.config/gungnir/dedup_state.json)
  LIVENESS_CHECK        - Pre-post check: dns (default) | http | none
  LIVENESS_TIMEOUT      - Seconds before a liveness probe gives up (default: 3)
"""

import json
import os
import sys
import time
import logging
import socket
import concurrent.futures as futures
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ── Config from env ──────────────────────────────────────────────────────────

WEBHOOK_URL = os.environ.get(
    "DISCORD_WEBHOOK_URL",
    "",
)

DEDUP_TTL = int(os.environ.get("DEDUP_TTL_SECONDS", "86400"))
RATE_LIMIT = float(os.environ.get("RATE_LIMIT_SECONDS", "2"))
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "5"))
LOG_FILE = os.environ.get("LOG_FILE", "")
DEDUP_STATE_FILE = os.environ.get(
    "DEDUP_STATE_FILE",
    os.path.expanduser("~/.config/gungnir/dedup_state.json"),
)
DEAD_LETTER_FILE = os.environ.get(
    "DEAD_LETTER_FILE",
    os.path.expanduser("~/.config/gungnir/failed_alerts.jsonl"),
)
LIVENESS_CHECK = os.environ.get("LIVENESS_CHECK", "dns").lower()
LIVENESS_TIMEOUT = float(os.environ.get("LIVENESS_TIMEOUT", "3"))

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

_seen: dict[str, float] = {}  # domain → wall-clock expiry timestamp (DELIVERED)
_pending: set[str] = set()  # queued but not yet accepted by Discord
_state_dirty = False


def _load_state():
    """Load dedup state from disk so restarts don't re-alert everything."""
    global _seen
    try:
        with open(DEDUP_STATE_FILE) as f:
            data = json.load(f)
        _seen = {d: float(exp) for d, exp in data.items()}
        _purge_expired()
        logger.info("Loaded %d domain(s) from dedup state", len(_seen))
    except FileNotFoundError:
        _seen = {}
    except (json.JSONDecodeError, OSError, ValueError) as e:
        logger.warning("Could not load dedup state (%s) — starting fresh", e)
        _seen = {}


def _save_state():
    """Persist dedup state to disk (atomic replace, called on each new add)."""
    global _state_dirty
    if not _state_dirty:
        return
    try:
        tmp = DEDUP_STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_seen, f)
        os.replace(tmp, DEDUP_STATE_FILE)
        _state_dirty = False
    except OSError as e:
        logger.warning("Could not save dedup state: %s", e)


def _purge_expired():
    """Remove expired entries from the dedup cache."""
    now = time.time()
    expired = [d for d, exp in _seen.items() if exp <= now]
    for d in expired:
        del _seen[d]
    if expired:
        logger.debug("Purged %d expired entries from dedup cache", len(expired))


def is_new(domain: str) -> bool:
    """Return True if this domain is neither delivered nor already queued.

    Does NOT mutate `_seen`. A domain is written to the dedup state only once
    Discord has ACCEPTED it (see `_commit`). The old code marked it here, which
    is what turned a rejected post into permanent loss: the 400 path dropped
    the message while the domain was already recorded as alerted, so it could
    never be retried and would not be re-alerted when the cert reappeared.
    """
    now = time.time()
    if domain in _seen and _seen[domain] > now:
        return False
    return domain not in _pending


def _claim(domains) -> None:
    """Mark domains as queued so a second cert can't double-queue them."""
    _pending.update(domains)


def _commit(domains) -> None:
    """Record delivery. Only call once Discord has accepted the message."""
    global _state_dirty
    now = time.time()
    for d in domains:
        _seen[d] = now + DEDUP_TTL
        _pending.discard(d)
    if domains:
        _state_dirty = True
        _save_state()


def _release(domains) -> None:
    """Un-queue domains whose delivery failed, so a later cert can re-alert."""
    for d in domains:
        _pending.discard(d)


def _dead_letter(batch: list[dict], domains: list[str]) -> None:
    """Append an undeliverable batch to disk so it can be replayed later."""
    try:
        with open(DEAD_LETTER_FILE, "a") as f:
            f.write(json.dumps({
                "ts": datetime.now(timezone.utc).isoformat(),
                "domains": domains,
                "entries": batch,
            }, default=str) + "\n")
        logger.info("Wrote %d undeliverable domain(s) to %s", len(domains), DEAD_LETTER_FILE)
    except OSError as e:
        logger.error("Could not write dead-letter file: %s", e)


# ── Discord embed builder ────────────────────────────────────────────────────

EMBED_COLOR = 0x00FF88  # green


def _strip_wildcard(domain: str) -> str:
    """Strip leading *. from wildcard domains for cleaner display."""
    if domain.startswith("*."):
        return domain[2:]
    return domain


def _as_text(value, fallback: str = "—") -> str:
    """Coerce a gungnir JSON field into a Discord-safe string.

    Root cause of the recurring `HTTP 400 {"embeds": ["<index>"]}` drops:
    gungnir's certificate struct declares `Organization []string`, so `org`
    arrives as a LIST. Writing it straight into an embed field produced
    {"value": ["Acme"]}; Discord requires a string and rejects the whole
    message. Verified: array → 400, joined string → 200.
    """
    if value is None:
        return fallback
    if isinstance(value, (list, tuple, set)):
        joined = ", ".join(str(v) for v in value if v not in (None, ""))
        return joined or fallback
    if isinstance(value, bool):
        return str(value)
    text = str(value).strip()
    return text or fallback


def _clamp(text: str, limit: int) -> str:
    """Hard-truncate to a Discord content limit (title 256, field value 1024)."""
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


# Discord embed limits
_TITLE_MAX = 256
_FIELD_NAME_MAX = 256
_FIELD_VALUE_MAX = 1024
_MAX_EMBEDS = 10


def _make_embeds(batch: list[dict]) -> list[dict]:
    """Build one or more Discord embed objects from a batch of cert entries."""
    embeds = []
    for entry in batch[:_MAX_EMBEDS]:
        cn = _as_text(entry.get("commonName"), "unknown")
        org = _as_text(entry.get("org"))
        sans = entry.get("san") or []
        if not isinstance(sans, list):
            sans = [sans]
        source = _as_text(entry.get("source"), "unknown")

        # Primary domain: first non-wildcard SAN, or fall back to CN
        cleaned = [_strip_wildcard(_as_text(d, "")) for d in sans]
        cleaned = [d for d in cleaned if d]
        primary = cleaned[0] if cleaned else _strip_wildcard(cn)
        san_list = ", ".join(cleaned[:8])
        if len(cleaned) > 8:
            san_list += f" … (+{len(cleaned) - 8} more)"

        embed = {
            "title": _clamp(f"🔔 {primary}", _TITLE_MAX),
            "color": EMBED_COLOR,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "fields": [
                {"name": "Common Name", "value": _clamp(cn, _FIELD_VALUE_MAX), "inline": True},
                {"name": "Source", "value": _clamp(source, _FIELD_VALUE_MAX), "inline": True},
                {"name": "SAN Count", "value": str(len(sans)), "inline": True},
                {"name": "Organization", "value": _clamp(org, _FIELD_VALUE_MAX), "inline": True},
                {"name": "SANs", "value": _clamp(f"`{san_list}`", _FIELD_VALUE_MAX), "inline": False},
            ],
        }
        embeds.append(embed)
    return embeds


# ── Liveness check ──────────────────────────────────────────────────────────

def _domain_resolves(domain: str) -> bool:
    """True if the domain has at least one A/AAAA record (DNS liveness)."""
    try:
        with futures.ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(
                socket.getaddrinfo,
                domain, None, socket.AF_UNSPEC, socket.SOCK_STREAM,
            )
            fut.result(timeout=LIVENESS_TIMEOUT)
        return True
    except (socket.gaierror, futures.TimeoutError, OSError):
        return False


def _domain_answers_http(domain: str) -> bool:
    """True if the domain serves an HTTPS response (any status = up)."""
    import ssl
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        urllib.request.urlopen(f"https://{domain}/", timeout=LIVENESS_TIMEOUT, context=ctx)
        return True
    except urllib.error.HTTPError:
        return True  # 401/403/404… still means the service is up
    except (urllib.error.URLError, OSError):
        return False


def _is_live(domain: str) -> bool:
    """Apply the configured liveness check (dns | http | none)."""
    if LIVENESS_CHECK == "http":
        return _domain_answers_http(domain)
    if LIVENESS_CHECK == "dns":
        return _domain_resolves(domain)
    return True


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
            # Log the full body — Discord keys validation errors by embed index,
            # and the 200-char truncation hid which field was actually invalid.
            logger.warning("HTTP %d from Discord (attempt %d/3): %s", e.code, attempt, body[:1000])
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
    logger.info("Dedup TTL: %ds | Rate limit: %.1fs | Batch size: %d | Liveness: %s",
                DEDUP_TTL, RATE_LIMIT, BATCH_SIZE, LIVENESS_CHECK)
    _load_state()

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

        # Extract domains, filter for new ones, then check liveness
        domains = entry.get("domains", [])
        new_domains = []
        for d in domains:
            clean = _strip_wildcard(d)
            if not is_new(clean):
                continue
            if not _is_live(clean):
                logger.info("Dropped (no liveness): %s", clean)
                # Nothing to deliver, so there is no alert to lose — record it
                # now rather than probing the same dead name on every cert.
                _commit([clean])
                continue
            new_domains.append(clean)

        if new_domains:
            _claim(new_domains)
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

    _save_state()
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
        _commit(domains_alerted)
        logger.info("Posted %d domain(s): %s", len(domains_alerted), ", ".join(domains_alerted))
    else:
        # Do NOT mark these as seen: release them from the pending set and
        # persist the batch so the alert is recoverable instead of lost.
        _release(domains_alerted)
        _dead_letter(batch, domains_alerted)
        logger.warning("Failed to post %d domain(s): %s", len(domains_alerted), ", ".join(domains_alerted))


if __name__ == "__main__":
    main()
