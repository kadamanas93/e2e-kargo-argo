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

REGISTRY_NAME="registry.localhost"
REGISTRY_CONFIG_FILE="$PROJECT_ROOT/registries.yaml"

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

# Check if k3d registry exists
registry_exists() {
    local registry_name=$1
    k3d registry get "$registry_name" >/dev/null 2>&1
}

# ==========================================
# USAGE
# ==========================================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help     Show this help message"
    echo ""
    echo "This script will:"
    echo "  1. Delete the k3d registry: k3d-${REGISTRY_NAME}"
    echo "  2. Optionally remove the registry config file"
    echo ""
    echo "Warning: This will delete all cached images in the registry!"
}

# ==========================================
# CLEANUP FUNCTIONS
# ==========================================

cleanup_registry() {
    echo -e "${GREEN}================================================${NC}"
    log_info "Deleting k3d registry..."
    echo -e "${GREEN}================================================${NC}"
    
    if registry_exists "k3d-${REGISTRY_NAME}"; then
        log_info "Deleting registry: k3d-${REGISTRY_NAME}"
        if k3d registry delete "k3d-${REGISTRY_NAME}" >/dev/null 2>&1; then
            log_success "Deleted registry: k3d-${REGISTRY_NAME}"
        else
            log_error "Failed to delete registry: k3d-${REGISTRY_NAME}"
            return 1
        fi
    else
        log_info "Registry 'k3d-${REGISTRY_NAME}' does not exist, skipping..."
    fi
}

cleanup_registry_config() {
    echo -e "${GREEN}================================================${NC}"
    log_info "Cleaning up registry config file..."
    echo -e "${GREEN}================================================${NC}"
    
    if [ -f "$REGISTRY_CONFIG_FILE" ]; then
        log_info "Removing: $REGISTRY_CONFIG_FILE"
        rm -f "$REGISTRY_CONFIG_FILE"
        log_success "Removed registry config file"
    else
        log_info "Registry config file does not exist, skipping..."
    fi
}

# ==========================================
# MAIN
# ==========================================

# Parse arguments
REMOVE_CONFIG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --remove-config)
            REMOVE_CONFIG=true
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

# Confirm deletion
log_warn "This will delete the registry and all cached images!"
read -p "Are you sure you want to continue? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log_info "Aborted by user"
    exit 0
fi

# Run cleanup
cleanup_registry

if [ "$REMOVE_CONFIG" = true ]; then
    cleanup_registry_config
fi

echo -e "${GREEN}================================================${NC}"
log_success "REGISTRY CLEANUP COMPLETE"
echo -e "${GREEN}================================================${NC}"

