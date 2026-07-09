# forwardproxy (naive) — Per-User Traffic Statistics

This is a modified fork of [klzgrad/forwardproxy](https://github.com/klzgrad/forwardproxy) (naive branch) that adds **per-user real traffic byte counting**, **per-user traffic quotas**, and **optional monthly auto-reset** for NaiveProxy.

## What It Does

When multiple NaiveProxy users share the same port (443) with `basic_auth`, the original Caddy access logs only record the CONNECT handshake (~a few KB), not the actual tunneled data. This modification:

1. **Captures the authenticated username** from the HTTP Basic Auth credentials in `checkCredentials` and passes it through `context.Context`.
2. **Counts actual forwarded bytes** (both upload and download) in `dualStream` / `flushingIoCopy` — the functions that already compute byte counts but previously discarded them.
3. **Accumulates per-user totals** in a concurrent-safe `sync.Map` with `atomic.AddInt64`.
4. **Persists to JSON** every 30 seconds (configurable) using an atomic write (write to `.tmp` then `rename`) so the file is never half-written.
5. **Survives restarts** by loading the existing JSON on startup, preserving cumulative totals.
6. **Per-user traffic quotas** — reject new CONNECT requests from users who exceed their configured byte limit. Existing connections are not terminated (see Known Limitations).
7. **Monthly auto-reset** — optionally archive and zero-out traffic counters on a configurable day of the month, matching your VPS provider's billing cycle.

Output example (`/var/log/caddy/traffic_by_user.json`):

```json
{
  "user1": 15728640,
  "user2": 83920512,
  "user3": 1024000
}
```

Values are in bytes. Use `view_stats.sh` to convert to human-readable units.

## Building

### Prerequisites

- Go 1.21+
- [xcaddy](https://github.com/caddyserver/xcaddy): `go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest`

### Build

```bash
# Linux/macOS
./build.sh

# Windows PowerShell
.\build.ps1
```

This runs `xcaddy build --with github.com/caddyserver/forwardproxy=<local-path>` under the hood.

## Deployment

1. **Backup** the existing Caddy binary on your VPS:
   ```bash
   cp /root/caddy /root/caddy.bak
   ```

2. **Replace** with the new binary:
   ```bash
   scp ./caddy root@your-vps:/root/caddy
   ```

3. **Create the stats directory** (if using the default path):
   ```bash
   mkdir -p /var/log/caddy
   chown caddy:caddy /var/log/caddy   # or whichever user runs caddy
   ```

4. **Restart** Caddy (binary change requires full restart, not reload):
   ```bash
   systemctl restart caddy
   ```

5. **Verify**: After producing some traffic, check:
   ```bash
   cat /var/log/caddy/traffic_by_user.json
   # or use the viewer:
   ./proxy_monitor.sh
   ```

## Configuration

### Caddyfile

Add directives inside the `forward_proxy` block:

```caddyfile
:443, example.com {
    tls your@email.com

    forward_proxy {
        basic_auth user1 password1
        basic_auth user2 password2
        basic_auth user3 password3

        hide_ip
        hide_via
        probe_resistance secret.example.com

        # Optional: custom stats file path (default: /var/log/caddy/traffic_by_user.json)
        traffic_stats_path /var/log/caddy/traffic_by_user.json

        # Optional: write interval (default: 30s)
        traffic_stats_interval 30s

        # Optional: per-user traffic quota. Users not listed here have unlimited traffic.
        # Supports B, KB, MB, GB, TB suffixes (case-insensitive) or plain byte numbers.
        traffic_quota {
            user2  50GB
            user3  20GB
        }
        # user1 is not listed → unlimited traffic

        # Optional: day of month (1-28) to auto-archive and reset traffic stats.
        # Set this to match your VPS provider's billing cycle reset date.
        # For example, if your VPS resets traffic on the 15th of each month, set this to 15.
        # If your reset date is the 29th-31st, use 28 (max allowed value,
        # to avoid months with fewer days).
        # Default: 0 (disabled — stats accumulate forever, never reset).
        traffic_reset_day 15

        # Optional: directory for archived snapshots before reset.
        # Default: <traffic_stats_path dir>/traffic_archive
        # Each reset creates a file like traffic_2026-07-15.json in this directory.
        traffic_archive_dir /var/log/caddy/traffic_archive
    }
}
```

If omitted, defaults are used. The stats writer starts once (even if multiple `forward_proxy` blocks exist) and uses the first block's configuration.

### JSON config

```json
{
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "routes": [{
            "handle": [{
              "handler": "forward_proxy",
              "auth_credentials": ["dXNlcjE6cGFzczE="],
              "traffic_stats_path": "/var/log/caddy/traffic_by_user.json",
              "traffic_stats_interval": "30s",
              "traffic_quota": {
                "user2": 53687091200,
                "user3": 21474836480
              },
              "traffic_reset_day": 15,
              "traffic_archive_dir": "/var/log/caddy/traffic_archive"
            }]
          }]
        }
      }
    }
  }
}
```

### Per-User Traffic Quotas

The `traffic_quota` directive sets a per-user byte limit. When a user's cumulative traffic exceeds their quota, **new CONNECT requests from that user are rejected** (the proxy returns `407 Proxy Authentication Required`, the same response as an invalid password — this is intentional to maintain probe resistance).

**Important**: Existing in-progress connections are **not** terminated mid-stream. A user who has exceeded their quota can continue using an already-established connection until it closes naturally. The quota is only checked when a new connection is established.

Users not listed in `traffic_quota` have **unlimited** traffic.

### Monthly Auto-Reset

The `traffic_reset_day` directive configures automatic monthly archiving and zeroing of traffic counters. This is useful for matching your VPS provider's billing cycle.

**Key details:**

- The value must be between **1 and 28** (or 0 to disable). It represents the day of the month when stats are archived and reset. Values above 28 are not supported because some months have fewer than 31 days (e.g., February has only 28/29 days). If your VPS billing cycle resets on the 29th, 30th, or 31st, configure `28`.
- **Set this to your VPS provider's actual reset date**, not a fixed "1st of the month". Different providers have different billing cycle start dates depending on when you purchased the plan.
- When the configured day arrives, the current traffic snapshot is archived to `traffic_archive_dir` as `traffic_YYYY-MM-DD.json`, and all in-memory counters are reset to zero.
- **Default is 0 (disabled)**: stats accumulate forever and are never automatically reset. This matches the behavior before this feature was added.
- If Caddy restarts on the reset day, the reset for that month may be skipped (the process intentionally avoids resetting on first startup to prevent accidental data loss after a restart). You can manually reset using the existing `--archive` script if needed.

## Viewing Stats

```bash
# With jq (recommended)
./view_stats.sh

# Without jq
./view_stats.sh /path/to/traffic_by_user.json

# Raw JSON
cat /var/log/caddy/traffic_by_user.json

# Archived snapshots (if monthly reset is enabled)
ls /var/log/caddy/traffic_archive/
cat /var/log/caddy/traffic_archive/traffic_2026-07-15.json
```

## Known Limitations

| Limitation | Detail |
|---|---|
| **Quota is connect-time only** | Traffic quotas only block **new** CONNECT requests when the user has exceeded their limit. Existing connections are not terminated mid-stream. A user slightly over quota can continue using an already-established connection. |
| **Padding overhead** | Upload direction (client → target, `AddPadding`) includes 3-byte framing header + random padding bytes. The counted bytes slightly exceed real user data. This is acceptable for billing/monitoring purposes. |
| **Write delay** | Stats are written to disk every `traffic_stats_interval` (default 30s). A crash may lose up to one interval of data. |
| **Process restart** | On restart, cumulative totals are loaded from the last written JSON. Any data between the last write and the crash is lost. |
| **Single writer** | Only one stats writer goroutine runs per process (via `sync.Once`). If multiple `forward_proxy` handlers are configured, the first one's path/interval/quota/reset settings are used. |
| **Reset day restart** | If Caddy restarts on the configured reset day, the monthly reset for that day may be skipped. This is a deliberate tradeoff: it's better to miss one reset than to accidentally zero data after an unplanned restart. |
| **HTTP/1.1 CONNECT** | The `serveHijack` path (HTTP/1.1) is also instrumented, but NaiveProxy clients default to HTTP/2 or HTTP/3, so this path sees minimal traffic. |

## Source Changes Summary

| File | Change |
|---|---|
| `traffic_stats.go` | Context key type, `sync.Map` counter, `addTrafficForUser`, `loadTrafficStats`, `startTrafficStatsWriter` (now accepts reset params), `checkAndPerformScheduledReset`, `lastResetDate` guard |
| `forwardproxy.go` | Handler struct: added `TrafficStatsPath`, `TrafficStatsInterval`, `TrafficQuota`, `TrafficResetDay`, `TrafficArchiveDir` fields. `Provision`: pass reset params to writer. `checkCredentials`: quota check after auth success (returns 407-style error if exceeded). |
| `caddyfile.go` | Added `traffic_stats_path`, `traffic_stats_interval`, `traffic_quota`, `traffic_reset_day`, `traffic_archive_dir` Caddyfile directives |
| `byte_size.go` | **New**: `parseByteSize` helper — parses human-friendly byte size strings (`50GB`, `100MB`, etc.) |

## License

Same as the original forwardproxy: Apache License 2.0.
