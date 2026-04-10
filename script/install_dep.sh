#!/usr/bin/env bash
# Install kubectl and helm into ./script directory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
esac

# kubectl
KUBECTL="$SCRIPT_DIR/kubectl"
if [[ -x "$KUBECTL" ]]; then
  echo "kubectl already installed: $("$KUBECTL" version --client 2>/dev/null | head -1)"
else
  VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  echo "Downloading kubectl ${VERSION} (${ARCH})..."
  curl -fsSL -o "$KUBECTL" "https://dl.k8s.io/release/${VERSION}/bin/linux/${ARCH}/kubectl"
  chmod +x "$KUBECTL"
  echo "Installed: $KUBECTL"
fi

# helm
HELM="$SCRIPT_DIR/helm"
if [[ -x "$HELM" ]]; then
  echo "helm already installed: $("$HELM" version --short 2>/dev/null)"
else
  echo "Downloading helm..."
  TMP=$(mktemp -d)
  curl -fsSL "https://get.helm.sh/helm-$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | grep tag_name | cut -d'"' -f4)-linux-${ARCH}.tar.gz" | tar xz -C "$TMP"
  mv "$TMP/linux-${ARCH}/helm" "$HELM"
  chmod +x "$HELM"
  rm -rf "$TMP"
  echo "Installed: $HELM"
fi

echo ""
"$KUBECTL" version --client
"$HELM" version --short

# gitleaks
GITLEAKS="$SCRIPT_DIR/gitleaks"
if [[ -x "$GITLEAKS" ]]; then
  echo "gitleaks already installed: $("$GITLEAKS" version 2>/dev/null)"
else
  GITLEAKS_VER=$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | grep tag_name | cut -d'"' -f4)
  GL_ARCH="$ARCH"; [[ "$GL_ARCH" == "amd64" ]] && GL_ARCH="x64"
  echo "Downloading gitleaks ${GITLEAKS_VER} (${GL_ARCH})..."
  TMP=$(mktemp -d)
  curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VER}/gitleaks_${GITLEAKS_VER#v}_linux_${GL_ARCH}.tar.gz" | tar xz -C "$TMP"
  mv "$TMP/gitleaks" "$GITLEAKS"
  chmod +x "$GITLEAKS"
  rm -rf "$TMP"
  echo "Installed: $GITLEAKS"
fi

# trufflehog
TRUFFLEHOG="$SCRIPT_DIR/trufflehog"
if [[ -x "$TRUFFLEHOG" ]]; then
  echo "trufflehog already installed: $("$TRUFFLEHOG" --version 2>/dev/null)"
else
  TRUFFLEHOG_VER=$(curl -fsSL https://api.github.com/repos/trufflesecurity/trufflehog/releases/latest | grep tag_name | cut -d'"' -f4)
  echo "Downloading trufflehog ${TRUFFLEHOG_VER} (${ARCH})..."
  TMP=$(mktemp -d)
  curl -fsSL "https://github.com/trufflesecurity/trufflehog/releases/download/${TRUFFLEHOG_VER}/trufflehog_${TRUFFLEHOG_VER#v}_linux_${ARCH}.tar.gz" | tar xz -C "$TMP"
  mv "$TMP/trufflehog" "$TRUFFLEHOG"
  chmod +x "$TRUFFLEHOG"
  rm -rf "$TMP"
  echo "Installed: $TRUFFLEHOG"
fi

# pre-commit hooks
if command -v pre-commit &>/dev/null; then
  echo "pre-commit already installed"
else
  echo "Installing pre-commit..."
  pip3 install --quiet pre-commit
fi

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$REPO_ROOT/.pre-commit-config.yaml" ]]; then
  echo "Installing git hooks..."
  cd "$REPO_ROOT"
  pre-commit install
  pre-commit install --hook-type pre-push
  echo "Git hooks installed (gitleaks on commit, trufflehog on push)"
fi
