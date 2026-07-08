# forwardproxy (naive) — Per-User Traffic Statistics

This is a modified fork of [klzgrad/forwardproxy](https://github.com/klzgrad/forwardproxy) (naive branch) that adds **per-user real traffic byte counting** for NaiveProxy.

## What It Does

When multiple NaiveProxy users share the same port (443) with `basic_auth`, the original Caddy access logs only record the CONNECT handshake (~a few KB), not the actual tunneled data. This modification:

1. **Captures the authenticated username** from the HTTP Basic Auth credentials in `checkCredentials` and passes it through `context.Context`.
2. **Counts actual forwarded bytes** (both upload and download) in `dualStream` / `flushingIoCopy` — the functions that already compute byte counts but previously discarded them.
3. **Accumulates per-user totals** in a concurrent-safe `sync.Map` with `atomic.AddInt64`.
4. **Persists to JSON** every 30 seconds (configurable) using an atomic write (write to `.tmp` then `rename`) so the file is never half-written.
5. **Survives restarts** by loading the existing JSON on startup, preserving cumulative totals.

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
   ./view_stats.sh
   ```

## Configuration

### Caddyfile

Add `traffic_stats_path` and `traffic_stats_interval` directives inside the `forward_proxy` block:

```caddyfile
:443, example.com {
    tls your@email.com

    forward_proxy {
        basic_auth user1 password1
        basic_auth user2 password2

        hide_ip
        hide_via
        probe_resistance secret.example.com

        # Optional: custom stats file path (default: /var/log/caddy/traffic_by_user.json)
        traffic_stats_path /var/log/caddy/traffic_by_user.json

        # Optional: write interval (default: 30s)
        traffic_stats_interval 30s
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
              "traffic_stats_interval": "30s"
            }]
          }]
        }
      }
    }
  }
}
```

## Viewing Stats

```bash
# With jq (recommended)
./view_stats.sh

# Without jq
./view_stats.sh /path/to/traffic_by_user.json

# Raw JSON
cat /var/log/caddy/traffic_by_user.json
```

## Known Limitations

| Limitation | Detail |
|---|---|
| **Padding overhead** | Upload direction (client → target, `AddPadding`) includes 3-byte framing header + random padding bytes. The counted bytes slightly exceed real user data. This is acceptable for billing/monitoring purposes. |
| **Write delay** | Stats are written to disk every `traffic_stats_interval` (default 30s). A crash may lose up to one interval of data. |
| **Process restart** | On restart, cumulative totals are loaded from the last written JSON. Any data between the last write and the crash is lost. |
| **Single writer** | Only one stats writer goroutine runs per process (via `sync.Once`). If multiple `forward_proxy` handlers are configured, the first one's path/interval settings are used. |
| **HTTP/1.1 CONNECT** | The `serveHijack` path (HTTP/1.1) is also instrumented, but NaiveProxy clients default to HTTP/2 or HTTP/3, so this path sees minimal traffic. |

## Source Changes Summary

| File | Change |
|---|---|
| `traffic_stats.go` | **New**: context key type, `sync.Map` counter, `addTrafficForUser`, `loadTrafficStats`, `startTrafficStatsWriter`, `sync.Once` |
| `forwardproxy.go` | Handler struct: added `TrafficStatsPath`, `TrafficStatsInterval` fields. `Provision`: start writer once. `checkCredentials`: propagate username via `context.WithValue`. `dualStream`: accept `username` param, call `addTrafficForUser`. `serveHijack`: accept `username` param. Both call sites updated. |
| `caddyfile.go` | Added `traffic_stats_path` and `traffic_stats_interval` Caddyfile directives |

## License

Same as the original forwardproxy: Apache License 2.0.