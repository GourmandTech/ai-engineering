#!/bin/zsh
set -euo pipefail

echo "=== AI Engineering Dev Setup ==="

# Install Python tools
pip install --upgrade pip --quiet
pip install mcp-contextforge-gateway httpx jq --quiet 2>/dev/null || true

# Install helm-diff plugin (safe to re-run)
helm plugin install https://github.com/databus23/helm-diff 2>/dev/null || true

# Install Azure CLI Bicep extension
az bicep install 2>/dev/null || true

# kubectx/kubens — installed via brew in bootstrap-mac.sh
# (skipped here to avoid overwriting the brew-managed binaries)

echo "✓ Setup complete. Run 'make help' to see available commands."
