# Clash Smart Proxy Group - One-Click Setup

> One command to set up automatic proxy failover for any Clash-based client.

## What does it do?

Creates a **fallback proxy group** that automatically switches between your selected proxy groups:
- Uses the first group by priority
- Health-checks every N seconds
- If it's down → switches to the next one
- Next one also down → keeps switching
- Recovers → switches back

**Zero manual intervention.**

## Quick Start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/anthropics-inc/clash-smart-group/main/setup.sh)
```

Or clone and run:

```bash
git clone https://github.com/anthropics-inc/clash-smart-group.git
cd clash-smart-group
bash setup.sh
```

Follow the interactive prompts: pick client → pick proxy groups → set interval → confirm → done.

## Features

| Feature | Details |
|---------|---------|
| **Cross-platform** | macOS / Linux / Windows (Git Bash / WSL) |
| **Multi-client** | FlClash, ClashX Pro, Clash Verge Rev, Clash Verge, Clash for Windows, mihomo |
| **Auto-detection** | Finds config path automatically, identifies the main selector group regardless of its name |
| **Safe writes** | Backup → in-memory edit → write → 5-point validation → auto-rollback on failure |
| **Zero dependencies** | Only needs Python 3 (pre-installed on macOS / most Linux) |
| **Idempotent** | Safe to run multiple times, no duplicates |

## Safety Mechanism

```
Confirm → Backup → Modify (in memory) → Write → Validate (5 checks)
                                                      │
                                         ┌────────────┤
                                         │            │
                                       Pass         Fail
                                         │            │
                                    Show success  Auto-rollback
                                                 + Show error reason
```

**Validation checks:**
1. Valid YAML syntax (strict parsing with PyYAML if available, regex fallback otherwise)
2. New fallback group exists with correct type / interval / proxies
3. New group is first in the main selector (if opted in)
4. All original groups are intact
5. No side effects from repeated runs

## What is `fallback`?

A native Clash proxy group type:

| Type | Behavior | Best for |
|------|----------|----------|
| `select` | Manual selection | Fixed node usage |
| `url-test` | Auto-pick lowest latency | Speed |
| **`fallback`** | **Pick first available by priority** | **Stability & auto-failover** |

## Parameters

| Parameter | Purpose | Default |
|-----------|---------|---------|
| Interval | Health check frequency | 20s |
| Timeout | Unresponsive threshold | 5s |
| Lazy | Stop checking when idle | false |
| URL | Health check endpoint | `https://www.gstatic.com/generate_204` |

## FAQ

**Q: Will subscription updates overwrite the config?**
A: Yes. Re-run the script after updating — takes 30 seconds.

**Q: Does it use much bandwidth?**
A: Minimal. ~600 bytes per check. At 20s interval with 3 groups ≈ 7.5 MB/day.

**Q: Supported systems?**
A: macOS / Linux / Windows (Git Bash or WSL). Requires Python 3 and any Clash-based client.

## Requirements

- Python 3 (pre-installed on macOS / most Linux)
- Any Clash-based proxy client

## License

MIT

---

[中文版](./README.md)
