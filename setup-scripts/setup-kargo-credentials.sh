#!/bin/bash
# ==========================================
# KARGO GIT CREDENTIALS SETUP
# ==========================================
# This script creates a Kubernetes Secret containing SSH credentials
# for Kargo Warehouses to access Git repositories.
#
# The secret is created in the kargo-credentials namespace and is
# configured as a global credential that all Kargo projects can use.
#
# Prerequisites:
#   - kubectl configured with access to the infra cluster
#   - values-credentials.yaml with kargo.git section configured
#
# Usage: ./setup-scripts/setup-kargo-credentials.sh
# ==========================================

set -euo pipefail

# Get script and project directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
CREDENTIALS_FILE="$PROJECT_ROOT/values-credentials.yaml"
NAMESPACE="kargo-credentials"
SECRET_NAME="git-ssh-credentials"
CONTEXT="k3d-infra"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# Check dependencies
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed."; exit 1; }
command -v yq >/dev/null 2>&1 || { log_error "yq is required but not installed. Install with: brew install yq"; exit 1; }

# Check credentials file exists
if [ ! -f "$CREDENTIALS_FILE" ]; then
    log_error "Credentials file not found: $CREDENTIALS_FILE"
    log_error "Copy the template and fill in your credentials:"
    log_error "  cp values-credentials.yaml.template values-credentials.yaml"
    exit 1
fi

# Extract Kargo Git credentials
log_info "Reading Kargo Git credentials from $CREDENTIALS_FILE..."

REPO_URL=$(yq '.kargo.git.repoURL' "$CREDENTIALS_FILE")
SSH_KEY=$(yq '.kargo.git.sshPrivateKey' "$CREDENTIALS_FILE")

if [ -z "$REPO_URL" ] || [ "$REPO_URL" = "null" ]; then
    log_error "kargo.git.repoURL not found in $CREDENTIALS_FILE"
    exit 1
fi

if [ -z "$SSH_KEY" ] || [ "$SSH_KEY" = "null" ]; then
    log_error "kargo.git.sshPrivateKey not found in $CREDENTIALS_FILE"
    exit 1
fi

log_info "Git repo URL: $REPO_URL"

# Switch to infra context
log_info "Using context: $CONTEXT"
kubectl config use-context "$CONTEXT" >/dev/null 2>&1 || {
    log_error "Failed to switch to context $CONTEXT. Is the cluster running?"
    exit 1
}

# Create namespace if it doesn't exist
log_info "Ensuring namespace $NAMESPACE exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create the secret
log_info "Creating/updating secret $SECRET_NAME in namespace $NAMESPACE..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
  labels:
    kargo.akuity.io/cred-type: git
type: Opaque
stringData:
  repoURL: "$REPO_URL"
  sshPrivateKey: |
$(echo "$SSH_KEY" | sed 's/^/    /')
EOF

log_success "Kargo Git credentials configured!"
echo ""
log_info "The secret '$SECRET_NAME' has been created in namespace '$NAMESPACE'."
log_info "Kargo controller is configured to look for credentials in this namespace."
echo ""
log_info "Warehouses using SSH URLs matching '$REPO_URL' will automatically use these credentials."

