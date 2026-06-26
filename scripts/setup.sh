#!/usr/bin/env bash
set -euo pipefail

echo "=== AI Engineering Dev Setup ==="

# Install Python tools
pip install --upgrade pip --quiet
pip install mcp-contextforge-gateway httpx jq --quiet 2>/dev/null || true

# Install helm-diff plugin (safe to re-run)
helm plugin install https://github.com/databus23/helm-diff 2>/dev/null || true

# Install Azure CLI Bicep extension
az bicep install 2>/dev/null || true

# Install kubectx/kubens for quick context switching
if ! command -v kubectx &> /dev/null; then
  curl -sLo /usr/local/bin/kubectx \
    https://raw.githubusercontent.com/ahmetb/kubectx/master/kubectx \
    && chmod +x /usr/local/bin/kubectx || true
  curl -sLo /usr/local/bin/kubens \
    https://raw.githubusercontent.com/ahmetb/kubectx/master/kubens \
    && chmod +x /usr/local/bin/kubens || true
fi

echo "✓ Setup complete. Run 'make help' to see available commands."
