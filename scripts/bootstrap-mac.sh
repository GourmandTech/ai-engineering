#!/bin/zsh
# =============================================================================
# bootstrap-mac.sh — Fresh MacBook Pro M1 setup for AI Engineering project
#
# Run once on a new machine:
#   chmod +x scripts/bootstrap-mac.sh && ./scripts/bootstrap-mac.sh
#
# What this installs:
#   - Xcode CLI tools (required for Homebrew and git)
#   - Homebrew (package manager)
#   - Core CLI tools: git, jq, curl, make, gh
#   - Container/k8s stack: docker, minikube, kubectl, helm, k9s, kubectx
#   - Azure stack: azure-cli, bicep
#   - Python 3.12
#   - VSCode extensions (requires `code` CLI in PATH)
#
# After this script:
#   1. Launch Docker Desktop and accept the license
#   2. Run: make chart-fetch && make helm-install
# =============================================================================
set -euo pipefail
setopt pipefail 2>/dev/null || true   # enable pipefail in zsh (default shell on macOS)

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${BOLD}==> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }

# ── 1. Xcode Command Line Tools ───────────────────────────────────────────────
info "Checking Xcode CLI tools..."
if ! xcode-select -p &>/dev/null; then
  xcode-select --install
  echo "Xcode CLI tools install launched — complete the dialog then re-run this script."
  exit 0
fi
success "Xcode CLI tools present"

# ── 2. Homebrew ───────────────────────────────────────────────────────────────
info "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for Apple Silicon
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
  success "Homebrew installed"
else
  brew update --quiet
  success "Homebrew already installed (updated)"
fi

# ── 3. Core CLI tools ─────────────────────────────────────────────────────────
info "Installing core CLI tools..."
BREW_PACKAGES=(
  git          # version control
  jq           # JSON processing (used in Makefile smoke tests)
  curl         # HTTP client
  gh           # GitHub CLI — PRs, releases, auth
  watch        # repeat commands (kubectl watch etc.)
  tree         # directory visualisation
)
brew install "${BREW_PACKAGES[@]}" 2>/dev/null || true
success "Core CLI tools installed"

# ── 4. Container & Kubernetes stack ──────────────────────────────────────────
info "Installing container/k8s stack..."

# Docker Desktop (M1 native — must be launched manually to accept EULA)
if ! brew list --cask docker &>/dev/null; then
  brew install --cask docker
  warn "Docker Desktop installed but NOT started."
  warn "Launch Docker Desktop from Applications and accept the license before running 'make up'."
else
  success "Docker Desktop already installed"
fi

KUBE_PACKAGES=(
  minikube     # local k8s cluster (Phase 2)
  kubectl      # k8s CLI
  helm         # chart deployments
  k9s          # terminal k8s dashboard
  kubectx      # fast context/namespace switching (includes kubens)
  stern        # multi-pod log tailing
)
brew install "${KUBE_PACKAGES[@]}" 2>/dev/null || true
success "Container/k8s stack installed"

# ── 5. Azure stack ────────────────────────────────────────────────────────────
info "Installing Azure stack..."
brew install azure-cli 2>/dev/null || true
az bicep install 2>/dev/null || true
success "Azure CLI + Bicep installed"

# ── 6. Python 3.12 ───────────────────────────────────────────────────────────
info "Installing Python 3.12..."
brew install python@3.12 2>/dev/null || true
# Ensure pip is up to date
python3 -m pip install --upgrade pip --quiet
success "Python 3.12 installed"

# ── 7. Helm plugins ───────────────────────────────────────────────────────────
info "Installing Helm plugins..."
helm plugin install https://github.com/databus23/helm-diff 2>/dev/null || true
success "helm-diff plugin installed"

# ── 8. VSCode extensions ──────────────────────────────────────────────────────
info "Installing VSCode extensions..."
if ! command -v code &>/dev/null; then
  warn "'code' CLI not found — skipping extension install."
  warn "In VSCode: Cmd+Shift+P → 'Shell Command: Install code in PATH', then re-run this script."
else
  EXTENSIONS=(
    # Azure
    ms-azuretools.vscode-bicep
    ms-azuretools.vscode-azure-resourcegroups
    ms-azure-devops.azure-pipelines

    # Containers & Kubernetes
    ms-azuretools.vscode-docker
    ms-kubernetes-tools.vscode-kubernetes-tools
    ms-vscode-remote.remote-containers
    ms-vscode-remote.remote-wsl
    tim-koehler.helm-intellisense

    # GitHub & CI/CD
    GitHub.vscode-pull-request-github
    GitHub.vscode-github-actions
    GitHub.copilot-chat

    # AI / Claude Code
    anthropics.claude-code

    # Language support
    ms-python.python
    ms-python.vscode-pylance
    redhat.vscode-yaml
    timonwong.shellcheck
    foxundermoon.shell-format

    # Productivity
    eamodio.gitlens
    ms-vscode.makefile-tools
    bierner.markdown-mermaid
    streetsidesoftware.code-spell-checker
  )

  for ext in "${EXTENSIONS[@]}"; do
    code --install-extension "$ext" --force 2>/dev/null && echo "  ✓ $ext" || echo "  ⚠ skipped: $ext"
  done
  success "VSCode extensions installed"
fi

# ── 9. Shell completions ──────────────────────────────────────────────────────
info "Adding shell completions to ~/.zshrc..."
ZSHRC="$HOME/.zshrc"

add_if_missing() {
  grep -qF "$1" "$ZSHRC" 2>/dev/null || echo "$1" >> "$ZSHRC"
}

add_if_missing 'eval "$(/opt/homebrew/bin/brew shellenv)"'
add_if_missing 'source <(kubectl completion zsh)'
add_if_missing 'source <(minikube completion zsh)'
add_if_missing 'source <(helm completion zsh)'
add_if_missing 'source <(gh completion -s zsh)'
success "Shell completions added"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Bootstrap complete ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Restart your terminal (or run: source ~/.zshrc)"
echo "  2. Launch Docker Desktop and accept the license"
echo "  3. Authenticate Azure: make az-login"
echo "  4. Authenticate GitHub: gh auth login"
echo "  5. Start Phase 2:  make chart-fetch && minikube start --profile mcpgw"
echo ""
echo "  Run 'make help' to see all available commands."
