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

# Clusters to clean up
CLUSTERS=("test" "dev" "staging" "prod-us" "prod-eu" "prod-au" "infra")

# Infrastructure components
PROXY_CONF_FILE="$PROJECT_ROOT/multi-cluster-proxy.conf"
PROXY_CONTAINER="k3d-multi-cluster-proxy"
DOCKER_NETWORK="k3d-multi-cluster"
REGISTRY_NAME="registry.localhost"

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

# Check if cluster exists
cluster_exists() {
    local cluster_name=$1
    k3d cluster get "$cluster_name" >/dev/null 2>&1
}

# Check if Docker container exists
container_exists() {
    local container_name=$1
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"
}

# Check if Docker network exists
network_exists() {
    local network_name=$1
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${network_name}$"
}

# ==========================================
# USAGE
# ==========================================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --reset    Clean up everything and run setup script for fresh start"
    echo "  --help     Show this help message"
    echo ""
    echo "This script will:"
    echo "  1. Delete all k3d clusters: ${CLUSTERS[*]}"
    echo "  2. Remove the nginx proxy container"
    echo "  3. Remove the shared Docker network"
    echo "  4. Clean up generated config files"
    echo ""
    echo "Note: The local registry (k3d-${REGISTRY_NAME}) is NOT removed"
    echo "      to preserve cached images for cluster resets."
    echo "      Use cleanup-registry.sh to remove the registry separately."
}

# ==========================================
# CLEANUP FUNCTIONS
# ==========================================

cleanup_clusters() {
    echo -e "${GREEN}================================================${NC}"
    log_info "Deleting k3d clusters..."
    echo -e "${GREEN}================================================${NC}"
    
    local deleted_count=0
    local skipped_count=0
    
    for CLUSTER_NAME in "${CLUSTERS[@]}"; do
        echo -e "${GREEN}------------------------------------------------${NC}"
        if cluster_exists "$CLUSTER_NAME"; then
            log_info "Deleting cluster: $CLUSTER_NAME"
            if k3d cluster delete "$CLUSTER_NAME" >/dev/null 2>&1; then
                log_success "Deleted cluster: $CLUSTER_NAME"
                ((deleted_count++))
            else
                log_error "Failed to delete cluster: $CLUSTER_NAME"
            fi
        else
            log_info "Cluster '$CLUSTER_NAME' does not exist, skipping..."
            ((skipped_count++))
        fi
    done
    
    echo ""
    log_info "Clusters deleted: $deleted_count, skipped: $skipped_count"
}

cleanup_proxy() {
    echo -e "${GREEN}================================================${NC}"
    log_info "Removing nginx proxy container..."
    echo -e "${GREEN}================================================${NC}"
    
    if container_exists "$PROXY_CONTAINER"; then
        log_info "Stopping and removing container: $PROXY_CONTAINER"
        if docker rm -f "$PROXY_CONTAINER" >/dev/null 2>&1; then
            log_success "Removed proxy container"
        else
            log_error "Failed to remove proxy container"
        fi
    else
        log_info "Proxy container '$PROXY_CONTAINER' does not exist, skipping..."
    fi
}

cleanup_network() {
    echo -e "${GREEN}================================================${NC}"
    log_info "Removing shared Docker network..."
    echo -e "${GREEN}================================================${NC}"
    
    if network_exists "$DOCKER_NETWORK"; then
        log_info "Removing network: $DOCKER_NETWORK"
        if docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1; then
            log_success "Removed Docker network: $DOCKER_NETWORK"
        else
            log_warn "Failed to remove network (may still have connected containers)"
        fi
    else
        log_info "Docker network '$DOCKER_NETWORK' does not exist, skipping..."
    fi
}

cleanup_files() {
    echo -e "${GREEN}================================================${NC}"
    log_info "Cleaning up generated files..."
    echo -e "${GREEN}================================================${NC}"
    
    if [ -f "$PROXY_CONF_FILE" ]; then
        log_info "Removing: $PROXY_CONF_FILE"
        rm -f "$PROXY_CONF_FILE"
        log_success "Removed proxy config file"
    else
        log_info "Proxy config file does not exist, skipping..."
    fi
}

# ==========================================
# MAIN
# ==========================================

# Parse arguments
RESET_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --reset)
            RESET_MODE=true
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
command -v k3d >/dev/null 2>&1 || { log_error "k3d is required but not installed. Aborting."; exit 1; }
command -v docker >/dev/null 2>&1 || { log_error "docker is required but not installed. Aborting."; exit 1; }

if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon is not running. Please start Docker and try again."
    exit 1
fi

# Run cleanup
cleanup_proxy
cleanup_clusters
cleanup_network
cleanup_files

echo -e "${GREEN}================================================${NC}"
log_success "CLEANUP COMPLETE"
echo -e "${GREEN}================================================${NC}"

# If reset mode, run setup script
if [ "$RESET_MODE" = true ]; then
    echo ""
    log_info "Reset mode enabled. Running setup script..."
    echo ""
    
    SETUP_SCRIPT="$SCRIPT_DIR/setup-local-k8s-clusters.sh"
    
    if [ -f "$SETUP_SCRIPT" ]; then
        exec "$SETUP_SCRIPT"
    else
        log_error "Setup script not found at: $SETUP_SCRIPT"
        exit 1
    fi
fi

