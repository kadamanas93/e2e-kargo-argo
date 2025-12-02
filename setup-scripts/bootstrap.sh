#!/bin/bash

# ==========================================
# STRICT MODE AND ERROR HANDLING
# ==========================================
set -euo pipefail

# Get script and project directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ==========================================
# CONFIGURATION (must match setup-local-k8s-clusters.sh)
# ==========================================

# Clusters to bootstrap
CLUSTERS=("test" "dev" "staging" "prod-us" "prod-eu" "prod-au" "infra")

# ArgoCD chart path (relative to project root)
ARGOCD_CHART_PATH="$PROJECT_ROOT/apps/infra/argocd"

# Local credentials file (git-ignored, in project root)
CREDENTIALS_FILE="$PROJECT_ROOT/values-credentials.yaml"
CREDENTIALS_TEMPLATE="$PROJECT_ROOT/values-credentials.yaml.template"

# Git repository URL - can be set via --repo-url, env var, or credentials file
GIT_REPO_URL="${GIT_REPO_URL:-}"

# Namespace for ArgoCD
ARGOCD_NAMESPACE="argocd"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ==========================================
# LOGGING FUNCTIONS
# ==========================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# ==========================================
# HELPER FUNCTIONS
# ==========================================

# Check if cluster context exists
context_exists() {
    local cluster_name=$1
    kubectl config get-contexts "k3d-${cluster_name}" >/dev/null 2>&1
}

# Switch to cluster context
switch_context() {
    local cluster_name=$1
    log_info "Switching to context: k3d-${cluster_name}"
    kubectl config use-context "k3d-${cluster_name}" >/dev/null 2>&1
}

# Wait for ArgoCD to be ready
wait_for_argocd() {
    local timeout=300
    local interval=10
    local elapsed=0
    
    log_info "Waiting for ArgoCD to be ready..."
    
    while [ $elapsed -lt $timeout ]; do
        if kubectl -n "$ARGOCD_NAMESPACE" get deployment argocd-server >/dev/null 2>&1; then
            if kubectl -n "$ARGOCD_NAMESPACE" rollout status deployment/argocd-server --timeout=10s >/dev/null 2>&1; then
                log_success "ArgoCD is ready"
                return 0
            fi
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        log_info "Still waiting... ($elapsed/${timeout}s)"
    done
    
    log_error "Timeout waiting for ArgoCD to be ready"
    return 1
}

# ==========================================
# USAGE
# ==========================================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --repo-url URL    Git repository URL for ApplicationSets"
    echo "  --cluster NAME    Bootstrap only the specified cluster"
    echo "  --skip-deps       Skip Helm dependency update"
    echo "  --help            Show this help message"
    echo ""
    echo "Credentials:"
    echo "  Create values-credentials.yaml from the template for Git credentials:"
    echo "    cp values-credentials.yaml.template values-credentials.yaml"
    echo "    # Edit values-credentials.yaml with your Git URL and credentials"
    echo ""
    echo "  This file is git-ignored and automatically used if present."
    echo ""
    echo "Environment variables:"
    echo "  GIT_REPO_URL      Git repository URL (alternative to --repo-url)"
    echo ""
    echo "Example:"
    echo "  # Using credentials file (recommended):"
    echo "  cp values-credentials.yaml.template values-credentials.yaml"
    echo "  # Edit values-credentials.yaml"
    echo "  $0"
    echo ""
    echo "  # Or using command line:"
    echo "  $0 --repo-url https://github.com/myorg/e2e-kargo-argo.git"
}

# ==========================================
# MAIN
# ==========================================

# Parse arguments
SINGLE_CLUSTER=""
SKIP_DEPS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --repo-url)
            GIT_REPO_URL="$2"
            shift 2
            ;;
        --cluster)
            SINGLE_CLUSTER="$2"
            shift 2
            ;;
        --skip-deps)
            SKIP_DEPS=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Pre-flight checks
log_info "Checking dependencies..."
command -v helm >/dev/null 2>&1 || { log_error "helm is required but not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { log_error "kubectl is required but not installed. Aborting."; exit 1; }

# Verify chart exists
if [ ! -f "$ARGOCD_CHART_PATH/Chart.yaml" ]; then
    log_error "ArgoCD chart not found at $ARGOCD_CHART_PATH"
    exit 1
fi

# Check for local credentials file
USE_CREDENTIALS_FILE=false
if [ -f "$CREDENTIALS_FILE" ]; then
    log_success "Found local credentials file: $CREDENTIALS_FILE"
    USE_CREDENTIALS_FILE=true
else
    log_info "No local credentials file found (optional: $CREDENTIALS_FILE)"
    if [ -f "$CREDENTIALS_TEMPLATE" ]; then
        log_info "To set up credentials: cp $CREDENTIALS_TEMPLATE $CREDENTIALS_FILE"
    fi
fi

# Validate configuration
if [ "$USE_CREDENTIALS_FILE" = false ] && [ -z "$GIT_REPO_URL" ]; then
    log_warn "No Git repository URL configured."
    log_warn "ApplicationSets will not work until you either:"
    log_warn "  1. Create values-credentials.yaml from template, OR"
    log_warn "  2. Re-run with --repo-url <url>"
fi

# Add Helm repos
echo -e "${GREEN}================================================${NC}"
log_info "Adding Helm repositories..."
echo -e "${GREEN}================================================${NC}"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

# Update dependencies
if [ "$SKIP_DEPS" = false ]; then
    echo -e "${GREEN}================================================${NC}"
    log_info "Updating Helm dependencies..."
    echo -e "${GREEN}================================================${NC}"
    
    cd "$ARGOCD_CHART_PATH"
    helm dependency update
    cd "$PROJECT_ROOT"
fi

# Determine which clusters to bootstrap
if [ -n "$SINGLE_CLUSTER" ]; then
    CLUSTERS_TO_BOOTSTRAP=("$SINGLE_CLUSTER")
else
    CLUSTERS_TO_BOOTSTRAP=("${CLUSTERS[@]}")
fi

# Bootstrap each cluster
for CLUSTER_NAME in "${CLUSTERS_TO_BOOTSTRAP[@]}"; do
    echo -e "${GREEN}================================================${NC}"
    log_info "Bootstrapping cluster: $CLUSTER_NAME"
    echo -e "${GREEN}================================================${NC}"
    
    # Check if context exists
    if ! context_exists "$CLUSTER_NAME"; then
        log_error "Context k3d-${CLUSTER_NAME} not found. Is the cluster running?"
        log_warn "Skipping cluster: $CLUSTER_NAME"
        continue
    fi
    
    # Switch context
    switch_context "$CLUSTER_NAME"
    
    # Check if values file exists
    VALUES_FILE="$ARGOCD_CHART_PATH/values-${CLUSTER_NAME}.yaml"
    if [ ! -f "$VALUES_FILE" ]; then
        log_error "Values file not found: $VALUES_FILE"
        log_warn "Skipping cluster: $CLUSTER_NAME"
        continue
    fi
    
    # Create namespace if not exists
    kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Build Helm values arguments
    # Order: base values -> cluster values -> credentials (credentials override all)
    HELM_VALUES_ARGS="-f $ARGOCD_CHART_PATH/values.yaml -f $VALUES_FILE"
    
    # Add local credentials file if it exists (contains Git URL and credentials)
    if [ "$USE_CREDENTIALS_FILE" = true ]; then
        HELM_VALUES_ARGS="$HELM_VALUES_ARGS -f $CREDENTIALS_FILE"
    fi
    
    # Command-line Git repo URL overrides everything
    if [ -n "$GIT_REPO_URL" ]; then
        HELM_VALUES_ARGS="$HELM_VALUES_ARGS --set gitRepo.url=$GIT_REPO_URL"
    fi
    
    # Install/upgrade ArgoCD
    log_info "Installing ArgoCD in cluster: $CLUSTER_NAME"
    
    if helm upgrade --install argocd "$ARGOCD_CHART_PATH" \
        --namespace "$ARGOCD_NAMESPACE" \
        $HELM_VALUES_ARGS \
        --wait \
        --timeout 10m; then
        log_success "ArgoCD installed in cluster: $CLUSTER_NAME"
    else
        log_error "Failed to install ArgoCD in cluster: $CLUSTER_NAME"
        continue
    fi
    
    # Wait for ArgoCD to be ready
    wait_for_argocd
    
    # Get ArgoCD admin password
    ARGOCD_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")
    
    if [ -n "$ARGOCD_PASSWORD" ]; then
        log_info "ArgoCD admin password for $CLUSTER_NAME: $ARGOCD_PASSWORD"
    fi
    
    echo ""
done

# Final summary
echo -e "${GREEN}================================================${NC}"
log_success "BOOTSTRAP COMPLETE"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "ArgoCD has been installed in the following clusters:"
for CLUSTER_NAME in "${CLUSTERS_TO_BOOTSTRAP[@]}"; do
    if context_exists "$CLUSTER_NAME"; then
        echo "  - $CLUSTER_NAME: https://argocd.${CLUSTER_NAME}.local"
    fi
done
echo ""

if [ "$USE_CREDENTIALS_FILE" = true ]; then
    echo "Configuration loaded from: $CREDENTIALS_FILE"
    echo ""
    echo "ArgoCD will now automatically:"
    echo "  1. Sync itself (self-management)"
    echo "  2. Deploy Kargo (controller in infra, agents in other clusters)"
    echo "  3. Deploy workloads from apps/workloads/"
elif [ -n "$GIT_REPO_URL" ]; then
    echo "ApplicationSets are configured to sync from:"
    echo "  Repository: $GIT_REPO_URL"
    echo ""
    echo "ArgoCD will now automatically:"
    echo "  1. Sync itself (self-management)"
    echo "  2. Deploy Kargo (controller in infra, agents in other clusters)"
    echo "  3. Deploy workloads from apps/workloads/"
    echo ""
    echo "NOTE: Git credentials not configured. For private repos, create:"
    echo "  cp values-credentials.yaml.template values-credentials.yaml"
else
    echo "WARNING: Git repository URL was not provided."
    echo "ApplicationSets will not create any Applications until you either:"
    echo "  1. Create values-credentials.yaml: cp values-credentials.yaml.template values-credentials.yaml"
    echo "  2. Or re-run with: $0 --repo-url <your-repo-url>"
fi
echo ""
echo "Access ArgoCD UI (after adding entries to /etc/hosts):"
echo "  URL: http://argocd.<cluster>.local"
echo "  Username: admin"
echo "  Password: (shown above or run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

