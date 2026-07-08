#!/usr/bin/env bash
# Pretty-print per-user traffic statistics from the JSON file.
# Usage: ./view_stats.sh [path-to-json]
# Default path: /var/log/caddy/traffic_by_user.json

STATS_FILE="${1:-/var/log/caddy/traffic_by_user.json}"

if [ ! -f "$STATS_FILE" ]; then
    echo "Stats file not found: $STATS_FILE"
    echo "Caddy may not have written it yet (wait at least one stats interval, default 30s)."
    exit 1
fi

# Try jq first for nice formatting
if command -v jq &>/dev/null; then
    jq -r '
        to_entries |
        sort_by(-.value) |
        .[] |
        "\(.key): \(.value) bytes (\(.value / 1048576 | floor) MB)"
    ' "$STATS_FILE"
else
    # Fallback: parse with python or just cat
    echo "Tip: install 'jq' for prettier output."
    echo ""
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
data = json.load(open('$STATS_FILE'))
for user, bytes_val in sorted(data.items(), key=lambda x: -x[1]):
    mb = bytes_val / (1024*1024)
    gb = bytes_val / (1024*1024*1024)
    print(f'{user}: {bytes_val} bytes ({mb:.1f} MB / {gb:.2f} GB)')
"
    else
        cat "$STATS_FILE"
    fi
fi