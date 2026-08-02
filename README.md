## Overview

Uses [Gungnir](https://github.com/g0ldencybersec/gungnir) to stream Certificate Transparency logs in real-time. Pipe its JSONL
output into a relay script that deduplicates, rate-limits, and POSTs new
certificate discoveries to a Discord webhook. A systemd user service keeps the
whole pipeline running 24/7 with auto-restart.

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
```


## Layout

```
~/.config/gungnir/
├── domains.txt          # root domain filter list
├── discord-relay.py     # the relay script
```

```
~/.config/systemd/user/
└── gungnir-discord.service
```

## Setup Instructions


1. Clone the repository

```bash
git clone https://github.com/mfkrypt/gungnir-relay
```

2. `Discord Channel > Edit Channel > Integrations > New Webhook > Copy Webhook URL`
3. Paste Webhook URL in `relay_script.py`:

```python
WEBHOOK_URL = os.environ.get(
    "DISCORD_WEBHOOK_URL",
    "<PASTE_HERE>",
)
```

4. Run the script to create and start the service
 
```
chmod +x setup.sh
./setup.sh
```

5. Discord alert should appear for test domain

<img width="1009" height="864" alt="image" src="https://github.com/user-attachments/assets/92c7fa60-c9b3-4f17-89b6-74e53e331db3" />
