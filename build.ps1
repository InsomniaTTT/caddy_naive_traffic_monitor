# Build Caddy with the modified forwardproxy (naive branch) plugin.
# Prerequisites: Go 1.21+ and xcaddy (go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest)
#
# Usage:
#   .\build.ps1           # Build in current directory
#   .\build.ps1 D:\deploy # Build and copy caddy binary to D:\deploy

param(
    [string]$DeployPath = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$FPDir = Join-Path $ScriptDir "forwardproxy"

if (-not (Test-Path $FPDir)) {
    Write-Error "Error: forwardproxy source directory not found at $FPDir"
    Write-Error "Run: git clone --branch naive https://github.com/klzgrad/forwardproxy.git $FPDir"
    exit 1
}

Write-Host "Building Caddy with local forwardproxy (naive branch)..."
xcaddy build --with "github.com/caddyserver/forwardproxy=$FPDir"

Write-Host ""
Write-Host "Build complete. Binary: .\caddy"
Write-Host "Verify: .\caddy version"
Write-Host ""

if ($DeployPath -ne "") {
    Write-Host "Copying caddy binary to $DeployPath..."
    Copy-Item ".\caddy" (Join-Path $DeployPath "caddy") -Force
    Write-Host "Done."
}