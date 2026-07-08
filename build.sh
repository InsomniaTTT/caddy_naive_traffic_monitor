#!/usr/bin/env bash
# Build Caddy with the modified forwardproxy (naive branch) plugin.
# Prerequisites: Go 1.21+ and xcaddy (go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest)
#
# Usage:
#   ./build.sh           # Build in current directory
#   ./build.sh /path     # Build and copy caddy binary to /path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FP_DIR="$SCRIPT_DIR/forwardproxy"

if [ ! -d "$FP_DIR" ]; then
    echo "Error: forwardproxy source directory not found at $FP_DIR"
    echo "Run: git clone --branch naive https://github.com/klzgrad/forwardproxy.git $FP_DIR"
    exit 1
fi

echo "Building Caddy with local forwardproxy (naive branch)..."
xcaddy build --with github.com/caddyserver/forwardproxy="$FP_DIR"

echo ""
echo "Build complete. Binary: ./caddy"
echo "Verify: ./caddy version"
echo ""

if [ -n "${1:-}" ]; then
    echo "Copying caddy binary to $1..."
    cp ./caddy "$1/caddy"
    echo "Done."
fi