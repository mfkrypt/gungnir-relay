# Gungnir + Discord Webhook

## Overview

Gungnir streams Certificate Transparency logs in real-time. We pipe its JSONL
output into a relay script that deduplicates, rate-limits, and POSTs new
certificate discoveries to a Discord webhook. A systemd user service keeps the
whole pipeline running 24/7 with auto-restart.

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
```

## Components

### 1. Domain List (`~/.config/gungnir/domains.txt`)

One root domain per line. Gungnir filters CT entries to only those whose SAN
or CN contains any of these domains.

```
target.com
target.org
target.net
```

### 2. Discord Relay Script (`~/.config/gungnir/discord-relay.py`)
