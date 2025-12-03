#!/bin/bash
# setup-kargo-shards.sh
# Creates kubeconfig secrets for distributed Kargo controllers
#
# This script creates the Secret that allows shard controllers to "phone home"
# to the centralized Kargo control plane in the infra cluster.
#
# Prerequisites:
# 1. Kargo must be deployed to the infra cluster first (creates ServiceAccount)
# 2. All k3d clusters must be running on the shared Docker network
#
# The control plane resources (ServiceAccount, ClusterRole, ClusterRoleBinding)
# are created by the Kargo Helm chart in the infra cluster.

set -euo pipefail

# Configuration
CONTROL_PLANE_CLUSTER="infra"
SHARD_CLUSTERS=("test" "dev" "staging" "prod-us" "prod-eu" "prod-au")
KARGO_NAMESPACE="kargo"
SA_NAME="kargo-shard-controller"
SECRET_NAME="kargo-control-plane-kubeconfig"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

switch_context() {
    kubectl config use-context "k3d-$1" > /dev/null 2>&1
}

get_api_server_address() {
    # For k3d clusters on shared Docker network
    echo "https://k3d-$1-server-0:6443"
}

ensure_namespace() {
    if ! kubectl get namespace "$1" > /dev/null 2>&1; then
        log_info "Creating namespace: $1"
        kubectl create namespace "$1"
    fi
}

# Generate kubeconfig for connecting to control plane
generate_kubeconfig() {
    switch_context "$CONTROL_PLANE_CLUSTER"
    
    local token_secret="${SA_NAME}-token"
    
    # Check if token secret exists
    if ! kubectl get secret "$token_secret" -n "$KARGO_NAMESPACE" > /dev/null 2>&1; then
        log_error "Token secret '${token_secret}' not found in ${KARGO_NAMESPACE} namespace"
        log_error "Make sure Kargo is deployed to the infra cluster first."
        log_error "The Helm chart creates the ServiceAccount and token Secret."
        exit 1
    fi
    
    # Get credentials
    local api_server=$(get_api_server_address "$CONTROL_PLANE_CLUSTER")
    local ca_cert=$(kubectl get secret "$token_secret" -n "$KARGO_NAMESPACE" -o jsonpath='{.data.ca\.crt}')
    local token=$(kubectl get secret "$token_secret" -n "$KARGO_NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
    
    if [ -z "$ca_cert" ] || [ -z "$token" ]; then
        log_error "Failed to retrieve credentials from token secret"
        exit 1
    fi
    
    cat <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${ca_cert}
    server: ${api_server}
  name: kargo-control-plane
contexts:
- context:
    cluster: kargo-control-plane
    user: kargo-shard-controller
  name: kargo-control-plane
current-context: kargo-control-plane
users:
- name: kargo-shard-controller
  user:
    token: ${token}
EOF
}

# Create kubeconfig secret in a shard cluster
setup_shard() {
    local cluster=$1
    
    log_info "Setting up shard: ${cluster}"
    
    # First, switch to shard cluster and ensure namespace exists
    switch_context "$cluster"
    ensure_namespace "$KARGO_NAMESPACE"
    
    # Generate kubeconfig (this switches to control plane internally)
    local kubeconfig=$(generate_kubeconfig)
    
    # IMPORTANT: Switch back to shard cluster before creating secret
    switch_context "$cluster"
    
    kubectl create secret generic "$SECRET_NAME" \
        --namespace "$KARGO_NAMESPACE" \
        --from-literal=kubeconfig.yaml="$kubeconfig" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "✓ Created kubeconfig secret in ${cluster}"
}

# Verify setup
verify() {
    log_info "Verifying setup..."
    
    for cluster in "${SHARD_CLUSTERS[@]}"; do
        switch_context "$cluster"
        if kubectl get secret "$SECRET_NAME" -n "$KARGO_NAMESPACE" > /dev/null 2>&1; then
            log_info "✓ ${cluster}: kubeconfig secret exists"
        else
            log_warn "✗ ${cluster}: kubeconfig secret not found"
        fi
    done
}

# Cleanup
cleanup() {
    log_info "Cleaning up kubeconfig secrets from shard clusters..."
    
    for cluster in "${SHARD_CLUSTERS[@]}"; do
        switch_context "$cluster"
        kubectl delete secret "$SECRET_NAME" -n "$KARGO_NAMESPACE" --ignore-not-found=true
        log_info "✓ Cleaned up ${cluster}"
    done
}

# Main
main() {
    local action="${1:-setup}"
    
    case "$action" in
        setup)
            log_info "=== Setting up Kargo Shard Controllers ==="
            log_info "This creates kubeconfig secrets for distributed controllers"
            echo ""
            
            for cluster in "${SHARD_CLUSTERS[@]}"; do
                setup_shard "$cluster"
            done
            
            echo ""
            verify
            
            echo ""
            log_info "=== Setup Complete! ==="
            log_info ""
            log_info "Each shard cluster now has a '${SECRET_NAME}' secret in the '${KARGO_NAMESPACE}' namespace."
            log_info "The Kargo controllers will use this to connect to the control plane."
            log_info ""
            log_info "Next steps:"
            log_info "  1. Commit and push changes to trigger ArgoCD sync"
            log_info "  2. ArgoCD will deploy Kargo with the distributed configuration"
            ;;
        cleanup)
            cleanup
            ;;
        verify)
            verify
            ;;
        *)
            echo "Usage: $0 [setup|cleanup|verify]"
            echo ""
            echo "Commands:"
            echo "  setup    - Create kubeconfig secrets in all shard clusters (default)"
            echo "  cleanup  - Remove kubeconfig secrets from shard clusters"
            echo "  verify   - Check if kubeconfig secrets exist"
            echo ""
            echo "Prerequisites:"
            echo "  - Kargo must be deployed to the infra cluster first"
            echo "  - Run: ./setup-scripts/bootstrap.sh (deploys ArgoCD and infra apps)"
            exit 1
            ;;
    esac
}

main "$@"

