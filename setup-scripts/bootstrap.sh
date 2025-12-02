#!/bin/bash

# ==========================================
# TWO-PHASE ARGOCD BOOTSTRAP
# ==========================================
# Phase 1: Install vanilla ArgoCD (provides CRDs)
# Phase 2: Create Application pointing to custom chart
# Phase 3: Wait for sync, cleanup bootstrap release
# ==========================================

set -euo pipefail

# Get script and project directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ==========================================
# CONFIGURATION
# ==========================================

# Clusters to bootstrap
CLUSTERS=("test" "dev" "staging" "prod-us" "prod-eu" "prod-au" "infra")

# ArgoCD chart path (relative path for Application, absolute for validation)
ARGOCD_CHART_PATH_REL="apps/infra/argocd"
ARGOCD_CHART_PATH="$PROJECT_ROOT/$ARGOCD_CHART_PATH_REL"

# Local credentials file (git-ignored, in project root)
CREDENTIALS_FILE="$PROJECT_ROOT/values-credentials.yaml"
CREDENTIALS_TEMPLATE="$PROJECT_ROOT/values-credentials.yaml.template"

# Git repository URL - REQUIRED for two-phase bootstrap
GIT_REPO_URL="${GIT_REPO_URL:-}"

# Namespace for ArgoCD
ARGOCD_NAMESPACE="argocd"

# ArgoCD Helm chart version for vanilla bootstrap
ARGOCD_BOOTSTRAP_VERSION="9.1.5"

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

# Wait for Application to be synced and healthy
wait_for_app_sync() {
    local app_name=$1
    local timeout=600
    local interval=15
    local elapsed=0
    
    log_info "Waiting for Application '$app_name' to sync..."
    
    while [ $elapsed -lt $timeout ]; do
        local sync_status=$(kubectl -n "$ARGOCD_NAMESPACE" get application "$app_name" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
        local health_status=$(kubectl -n "$ARGOCD_NAMESPACE" get application "$app_name" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
        
        log_info "Status: sync=$sync_status, health=$health_status ($elapsed/${timeout}s)"
        
        if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
            log_success "Application '$app_name' is synced and healthy"
            return 0
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for Application '$app_name' to sync"
    return 1
}

# Extract Git repo URL from credentials file
get_repo_url_from_credentials() {
    if [ -f "$CREDENTIALS_FILE" ]; then
        # Try to extract gitRepo.url from the credentials file
        local url=$(grep -E '^\s*url:' "$CREDENTIALS_FILE" | head -1 | sed 's/.*url:\s*//' | tr -d '"' | tr -d "'" | xargs)
        if [ -n "$url" ] && [ "$url" != "url:" ]; then
            echo "$url"
            return 0
        fi
    fi
    return 1
}

# ==========================================
# USAGE
# ==========================================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Two-phase ArgoCD bootstrap for k3d clusters:"
    echo "  Phase 1: Install vanilla ArgoCD (provides CRDs)"
    echo "  Phase 2: Create Application pointing to custom chart"
    echo "  Phase 3: Wait for sync, cleanup bootstrap release"
    echo ""
    echo "Options:"
    echo "  --repo-url URL    Git repository URL (REQUIRED)"
    echo "  --cluster NAME    Bootstrap only the specified cluster"
    echo "  --help            Show this help message"
    echo ""
    echo "Credentials:"
    echo "  Create values-credentials.yaml from the template for Git credentials:"
    echo "    cp values-credentials.yaml.template values-credentials.yaml"
    echo "    # Edit values-credentials.yaml with your Git URL and credentials"
    echo ""
    echo "Environment variables:"
    echo "  GIT_REPO_URL      Git repository URL (alternative to --repo-url)"
    echo ""
    echo "Example:"
    echo "  $0 --repo-url https://github.com/myorg/e2e-kargo-argo.git"
}

# ==========================================
# MAIN
# ==========================================

# Parse arguments
SINGLE_CLUSTER=""

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

# Check for local credentials file and extract repo URL if not provided
USE_CREDENTIALS_FILE=false
if [ -f "$CREDENTIALS_FILE" ]; then
    log_success "Found local credentials file: $CREDENTIALS_FILE"
    USE_CREDENTIALS_FILE=true
    
    # Try to get repo URL from credentials if not already set
    if [ -z "$GIT_REPO_URL" ]; then
        EXTRACTED_URL=$(get_repo_url_from_credentials || echo "")
        if [ -n "$EXTRACTED_URL" ]; then
            GIT_REPO_URL="$EXTRACTED_URL"
            log_info "Using Git repo URL from credentials file: $GIT_REPO_URL"
        fi
    fi
else
    log_info "No local credentials file found (optional: $CREDENTIALS_FILE)"
    if [ -f "$CREDENTIALS_TEMPLATE" ]; then
        log_info "To set up credentials: cp $CREDENTIALS_TEMPLATE $CREDENTIALS_FILE"
    fi
fi

# Validate Git repo URL is set (REQUIRED for two-phase bootstrap)
if [ -z "$GIT_REPO_URL" ]; then
    log_error "Git repository URL is REQUIRED for two-phase bootstrap."
    log_error "Please provide it via:"
    log_error "  1. --repo-url <url>"
    log_error "  2. GIT_REPO_URL environment variable"
    log_error "  3. gitRepo.url in values-credentials.yaml"
    exit 1
fi

log_info "Git repository URL: $GIT_REPO_URL"

# Add Helm repos
echo -e "${GREEN}================================================${NC}"
log_info "Adding Helm repositories..."
echo -e "${GREEN}================================================${NC}"

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

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
    
    # ==========================================
    # PHASE 1: Install vanilla ArgoCD
    # ==========================================
    # NOTE: We use release name "argocd" (not "argocd-bootstrap") so that
    # resource names match what the Application will create/manage.
    # This allows the Application to adopt existing resources in place.
    echo -e "${BLUE}--- Phase 1: Installing vanilla ArgoCD ---${NC}"
    
    if helm upgrade --install argocd argo/argo-cd \
        --namespace "$ARGOCD_NAMESPACE" \
        --version "$ARGOCD_BOOTSTRAP_VERSION" \
        --set server.extraArgs[0]="--insecure" \
        --set configs.params."server\.insecure"=true \
        --wait \
        --timeout 10m; then
        log_success "Vanilla ArgoCD installed"
    else
        log_error "Failed to install vanilla ArgoCD in cluster: $CLUSTER_NAME"
        continue
    fi
    
    # Wait for ArgoCD to be ready
    wait_for_argocd
    
    # ==========================================
    # PHASE 2: Create bootstrap Application
    # ==========================================
    echo -e "${BLUE}--- Phase 2: Creating bootstrap Application ---${NC}"
    
    # Create the bootstrap Application pointing to custom ArgoCD chart
    cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: $ARGOCD_NAMESPACE
spec:
  project: default
  source:
    repoURL: $GIT_REPO_URL
    targetRevision: HEAD
    path: $ARGOCD_CHART_PATH_REL
    helm:
      valueFiles:
        - values.yaml
        - values-${CLUSTER_NAME}.yaml
      ignoreMissingValueFiles: true
  destination:
    server: https://kubernetes.default.svc
    namespace: $ARGOCD_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
    
    log_success "Bootstrap Application created"
    
    # ==========================================
    # PHASE 3: Wait for sync
    # ==========================================
    echo -e "${BLUE}--- Phase 3: Waiting for Application to sync ---${NC}"
    
    # Wait for the Application to sync
    if wait_for_app_sync "argocd"; then
        log_success "Custom ArgoCD deployed successfully"
        
        # NOTE: We intentionally do NOT uninstall the Helm release.
        # The Application now manages the resources. The Helm release metadata
        # (stored as secrets) is orphaned but harmless. Uninstalling would
        # delete the resources that the Application is managing.
        log_info "Helm release 'argocd' left in place (resources now managed by Application)"
        log_success "ArgoCD is now self-managed via the 'argocd' Application"
    else
        log_error "Failed to sync custom ArgoCD. Manual intervention may be required."
        log_warn "Bootstrap Application left in place for debugging."
    fi
    
    # Wait for ArgoCD to stabilize after the transition
    sleep 5
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
echo "ArgoCD has been bootstrapped in the following clusters:"
for CLUSTER_NAME in "${CLUSTERS_TO_BOOTSTRAP[@]}"; do
    if context_exists "$CLUSTER_NAME"; then
        echo "  - $CLUSTER_NAME: argocd.${CLUSTER_NAME}.local"
    fi
done
echo ""
echo "Repository: $GIT_REPO_URL"
echo ""
echo "ArgoCD is now self-managed via the 'argocd' Application and will:"
echo "  1. Keep itself in sync with $ARGOCD_CHART_PATH_REL"
echo "  2. Deploy infrastructure apps via ApplicationSets (kargo, etc.)"
echo "  3. Deploy workloads from apps/workloads/"
echo ""
echo "Access ArgoCD UI (after adding entries to /etc/hosts):"
echo "  URL: http://argocd.<cluster>.local"
echo "  Username: admin"
echo "  Password: (shown above or run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
