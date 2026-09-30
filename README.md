## Overview

Portable setup for two independent target-change monitors that report to Discord:

**[Gungnir](https://github.com/g0ldencybersec/gungnir)** streams Certificate Transparency logs in real time. Its JSONL
output is piped into a relay that deduplicates, rate-limits, and POSTs new
certificate discoveries to a webhook. A systemd user service keeps it running
24/7 with auto-restart.

**js-watch** detects JavaScript changes on live hosts — new chunks, in-place
rebuilds, newly-exposed sourcemaps, removed chunks, and credential-shaped
strings that appear in a bundle for the first time. A systemd user timer runs it
daily. It catches what CT logs cannot: a deploy that ships new admin routes, a
build that starts leaking source maps, or a hardcoded API key pushed to prod.

Credits to @g0ldencybersec

```
┌──────────────┐     JSONL      ┌─────────────────┐    HTTP POST    ┌──────────┐
│   gungnir    │ ───────────────│  discord-relay  │ ─────────────── │ Discord  │
│  (CT logs)   │     stdout     │   (python)      │   webhook URL   │ channel  │
└──────┬───────┘                └─────────────────┘                 └──────────┘
       │
       │ reads every ~2s
       ▼
┌──────────────┐
│ domains.txt  │   root domains to filter on (one per line)
└──────────────┘

┌──────────────┐   daily timer  ┌─────────────────┐    HTTP POST    ┌──────────┐
│  js-watch    │ ───────────────│ js-watch-notify │ ─────────────── │ Discord  │
│ (live hosts) │     JSONL      │    (python)     │   webhook URL   │ channel  │
└──────┬───────┘                └─────────────────┘                 └──────────┘
       │
       ▼
┌──────────────┐
│  hosts.txt   │   origins to watch (one per line)
└──────────────┘
```

## Layout

```
~/.config/gungnir/
├── domains.txt          # CT-log root filter list
├── discord-relay.py     # the relay script
└── env                  # webhook (0600, created by setup.sh)

~/.config/js-watch/
├── hosts.txt            # origins to watch
├── public-cdns.txt      # CDNs whose .map files are public-by-design
└── env                  # webhook (0600, created by setup.sh)

~/.local/bin/
├── js-watch.sh
└── js-watch-notify.py

~/.local/state/js-watch/<host>/     # per-host baselines (survive reboot)
├── hashes.tsv / chunks.txt / sourcemaps.txt
├── secrets.tsv       # credentials already reported (dedup — one alert per secret, ever)
└── secrets.raw.tsv   # FULL unmasked values, mode 0600 — evidence, never posted

~/.config/systemd/user/
├── gungnir-discord.service
├── js-watch.service
└── js-watch.timer
```

## Setup Instructions

1. Clone the repository

```bash
git clone https://github.com/mfkrypt/gungnir-relay
cd gungnir-relay
```

2. Create the webhooks — `Discord Channel > Edit Channel > Integrations > New Webhook > Copy Webhook URL`.
   Use **two separate channels** if you want CT hits and JS changes kept apart; they are
   independent and rotate separately.

3. Run the setup script, passing the webhooks in (they are never written to the repo):

```bash
chmod +x setup.sh
GUNGNIR_WEBHOOK='https://discord.com/api/webhooks/...' \
JS_WATCH_WEBHOOK='https://discord.com/api/webhooks/...' \
./setup.sh
```

Omit either variable and you'll be prompted for it instead — or press Enter to skip
and configure it later by re-running.

4. Add your targets. Both files are watched live; no restart needed.

```bash
echo 'example.com'             >> ~/.config/gungnir/domains.txt
echo 'https://app.example.com' >> ~/.config/js-watch/hosts.txt
```

5. The install seeds JS baselines automatically — the first run adopts what it sees
   *without* alerting, so it posts nothing. From the next run on, only changes alert.

### Options

| Flag | Effect |
|---|---|
| `--force` | Replace existing installed files with the bundle versions (timestamped `.bak` each) |
| `--no-seed` | Skip the initial baseline sweep |
| `--help` | Usage |

Environment overrides: `GUNGNIR_BIN`, `JS_WATCH_BIN_DIR`, `GUNGNIR_WEBHOOK`, `JS_WATCH_WEBHOOK`.

Re-running is safe: existing files are kept, never clobbered, and an already-configured
webhook is reused rather than re-prompted.

## What js-watch reports

| Signal | Meaning | Worth |
|---|---|---|
| `secret-hit` | a credential-shaped string **new for this host** | **reportable on sight** — hardcoded key in shipped JS |
| `new-chunk` | a chunk filename not seen before | new code shipped — often a new route or feature |
| `changed-bundle` | same URL, different content hash | in-place redeploy |
| `new-sourcemap` | a `.map` is now retrievable | **reportable** — source leak, `hunt-source-leak` territory |
| `chunk-gone` | a known chunk vanished | removed route/feature |


Which 25 get fetched is **ranked, not alphabetical**: bundles whose filename is new
come first (a deploy today would otherwise lose its slot to a chunk unchanged for
months), then bundles already known to expose a `.map`, then first-party-looking
paths, then everything else. The new-filename tier costs nothing — that diff is
already computed for the `new-chunk` alert — and it is empty on a steady-state host,
so the order is unchanged when nothing has shipped.

A sweep is capped at 25 bundles per host plus one range-GET `.map` probe each —
roughly 300 requests across six hosts, about 85 seconds. Raise the cap with
`MAX_FETCH=50 ~/.local/bin/js-watch.sh` for a target you're actively working.

Run it by hand any time:

```bash
~/.local/bin/js-watch.sh --host https://app.example.com   # one host, verbose to stderr
~/.local/bin/js-watch.sh                                  # all hosts, silent unless changed
~/.local/bin/js-watch.sh --no-secrets                      # skip the credential sweep
MAX_SECRET_HITS=50 ~/.local/bin/js-watch.sh                # name more hits per alert
SHOW_SECRETS=1 ~/.local/bin/js-watch.sh                    # full values in the alert
systemctl --user start js-watch.service                   # what the timer runs
journalctl --user -u js-watch.service -n 40               # last run's output
```

To reset a baseline, delete its state dir — the next run re-seeds silently:

```bash
rm -rf ~/.local/state/js-watch/app.example.com
```
