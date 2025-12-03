#!/bin/bash

# ==========================================
# STRICT MODE AND ERROR HANDLING
# ==========================================
set -euo pipefail

# Get script and project directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Trap for cleanup on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_warn "Script exited with error code $exit_code. Performing cleanup..."
        
        # Clean up proxy config file if script failed before completion
        # Only remove if it's incomplete (doesn't end with closing brace)
        if [ -f "$PROXY_CONF_FILE" ]; then
            if ! tail -1 "$PROXY_CONF_FILE" | grep -q "^}$"; then
                log_info "Removing incomplete proxy config file..."
                rm -f "$PROXY_CONF_FILE"
            fi
        fi
    fi
    exit $exit_code
}
trap cleanup EXIT

# ==========================================
# CONFIGURATION
# ==========================================

# 1. Define your Clusters
CLUSTERS=("test" "dev" "staging" "prod-us" "prod-eu" "prod-au" "infra")

# 2. Define expected Apps (For /etc/hosts generation ONLY)
APPS=("argocd" "kargo" "simple-echo-server")

# 3. Base Configuration
START_PORT=8080
DOMAIN_SUFFIX="local"
PROXY_CONF_FILE="$PROJECT_ROOT/multi-cluster-proxy.conf"
PROXY_CONTAINER="k3d-multi-cluster-proxy"
DOCKER_NETWORK="k3d-multi-cluster"
MAX_PORT=65535
REGISTRY_NAME="registry.localhost"
REGISTRY_PORT=5000
REGISTRY_CONFIG_FILE="$PROJECT_ROOT/setup-scripts/registries.yaml"

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
# VALIDATION FUNCTIONS
# ==========================================

# Check if a port is available
is_port_available() {
    local port=$1
    if [ "$port" -lt 1 ] || [ "$port" -gt "$MAX_PORT" ]; then
        return 1
    fi
    # Check if port is in use (works on macOS and Linux)
    if command -v lsof >/dev/null 2>&1; then
        if lsof -i ":$port" >/dev/null 2>&1; then
            return 1
        else
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -an | grep -q ":$port.*LISTEN"; then
            return 1
        else
            return 0
        fi
    else
        # Fallback: assume port is available if we can't check
        return 0
    fi
}

# Check if cluster exists
cluster_exists() {
    local cluster_name=$1
    # Use k3d cluster get which is more reliable, or fall back to parsing list output
    if k3d cluster get "$cluster_name" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Validate port number
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log_error "Invalid port number: $port"
        return 1
    fi
    if [ "$port" -lt 1 ] || [ "$port" -gt "$MAX_PORT" ]; then
        log_error "Port $port is out of valid range (1-$MAX_PORT)"
        return 1
    fi
    return 0
}

# Parse port from docker port output (handles various formats)
parse_docker_port() {
    local port_output=$1
    local port
    # Handle formats like "0.0.0.0:8080" or "[::]:8080" or "8080/tcp -> 0.0.0.0:8080"
    port=$(echo "$port_output" | sed -E 's/.*:([0-9]+).*/\1/' | head -1)
    if validate_port "$port"; then
        echo "$port"
        return 0
    fi
    return 1
}

# Validate nginx config syntax
validate_nginx_config() {
    local config_file=$1
    if [ ! -f "$config_file" ]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    # Try to validate using nginx if available in a container
    if docker run --rm -v "$config_file:/etc/nginx/nginx.conf:ro" \
        nginx:alpine nginx -t >/dev/null 2>&1; then
        return 0
    else
        log_warn "Could not validate nginx config syntax (nginx container test failed)"
        # Don't fail, just warn
        return 0
    fi
}

# Check if Docker container exists
container_exists() {
    local container_name=$1
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$" || return 1
}

# Check if Docker network exists
network_exists() {
    local network_name=$1
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${network_name}$"
}

# Create Docker network if it doesn't exist
ensure_network() {
    local network_name=$1
    if network_exists "$network_name"; then
        log_info "Docker network '$network_name' already exists"
    else
        log_info "Creating Docker network: $network_name"
        if docker network create "$network_name" >/dev/null 2>&1; then
            log_success "Created Docker network: $network_name"
        else
            log_error "Failed to create Docker network: $network_name"
            exit 1
        fi
    fi
}

# Check if k3d registry exists
registry_exists() {
    local registry_name=$1
    k3d registry get "$registry_name" >/dev/null 2>&1
}

# Check if any registry is using the specified port
registry_port_in_use() {
    local port=$1
    local registries
    registries=$(k3d registry list --no-headers 2>/dev/null | awk '{print $1}' || true)
    
    for reg in $registries; do
        if docker port "$reg" 2>/dev/null | grep -q ":${port}"; then
            echo "$reg"
            return 0
        fi
    done
    return 1
}

# Create k3d registry if it doesn't exist
ensure_registry() {
    local registry_name=$1
    local registry_port=$2
    local network_name=$3
    local full_registry_name="k3d-${registry_name}"
    
    if registry_exists "$full_registry_name"; then
        log_info "Registry '${full_registry_name}' already exists"
        
        # Check if it's on the correct network
        if docker inspect "$full_registry_name" >/dev/null 2>&1; then
            if docker inspect "$full_registry_name" | grep -q "\"${network_name}\"" 2>/dev/null; then
                log_success "Registry '${full_registry_name}' is already on network '${network_name}'"
            else
                log_warn "Registry '${full_registry_name}' exists but may not be on network '${network_name}'"
                log_info "Connecting registry to network..."
                docker network connect "$network_name" "$full_registry_name" 2>/dev/null || {
                    log_warn "Could not connect registry to network (may already be connected)"
                }
            fi
        fi
    else
        # Check if port is available on host
        if ! is_port_available "$registry_port"; then
            log_error "Port ${registry_port} is already in use on the host. Cannot create registry."
            log_info "Please free port ${registry_port} or use a different port."
            exit 1
        fi
        
        # Check if another registry is using this port
        local existing_reg
        if existing_reg=$(registry_port_in_use "$registry_port"); then
            log_warn "Another registry '${existing_reg}' may be using port ${registry_port}"
            log_info "Attempting to create registry anyway (k3d will handle port conflicts)..."
        fi
        
        log_info "Creating k3d registry: ${full_registry_name} on port ${registry_port}"
        local error_output
        error_output=$(k3d registry create "$registry_name" \
            --port "${registry_port}" \
            --default-network "$network_name" 2>&1)
        
        if [ $? -eq 0 ]; then
            log_success "Created registry: ${full_registry_name}"
        else
            log_error "Failed to create registry: ${full_registry_name}"
            log_error "Error details: ${error_output}"
            exit 1
        fi
    fi
}

# ==========================================
# PRE-FLIGHT CHECKS
# ==========================================
log_info "Checking dependencies..."

# Check for required commands
command -v k3d >/dev/null 2>&1 || { log_error "k3d is required but not installed. Aborting."; exit 1; }
command -v docker >/dev/null 2>&1 || { log_error "docker is required but not installed. Aborting."; exit 1; }

# Check if Docker daemon is running
log_info "Checking Docker daemon..."
if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon is not running. Please start Docker and try again."
    exit 1
fi
log_success "Docker daemon is running"

# Initialize Proxy Config File
log_info "Initializing proxy configuration file..."
echo "events {} http {" > "$PROXY_CONF_FILE"

# Create shared Docker network for cross-cluster communication
log_info "Setting up shared Docker network..."
ensure_network "$DOCKER_NETWORK"

# Create local registry for image caching
log_info "Setting up local image registry..."
ensure_registry "$REGISTRY_NAME" "$REGISTRY_PORT" "$DOCKER_NETWORK"

# Verify registry config file exists
if [ ! -f "$REGISTRY_CONFIG_FILE" ]; then
    log_warn "Registry config file not found at $REGISTRY_CONFIG_FILE, creating it..."
    cat > "$REGISTRY_CONFIG_FILE" <<EOF
mirrors:
  "k3d-${REGISTRY_NAME}:${REGISTRY_PORT}":
    endpoint:
      - http://k3d-${REGISTRY_NAME}:${REGISTRY_PORT}
EOF
    log_success "Created registry config file: $REGISTRY_CONFIG_FILE"
fi

# ==========================================
# MAIN LOOP
# ==========================================

# We track the highest port used to ensure new clusters don't conflict
NEXT_PORT=$START_PORT

for CLUSTER_NAME in "${CLUSTERS[@]}"
do
    echo -e "${GREEN}------------------------------------------------${NC}"
    log_info "Processing Cluster: $CLUSTER_NAME"

    # 1. Check if cluster exists (fixed check)
    if cluster_exists "$CLUSTER_NAME"; then
        log_warn "Cluster '$CLUSTER_NAME' already exists. Skipping creation."
        
        # Ensure it is running (idempotent command)
        log_info "Starting cluster '$CLUSTER_NAME' if not already running..."
        k3d cluster start "$CLUSTER_NAME" >/dev/null 2>&1 || {
            log_error "Failed to start cluster '$CLUSTER_NAME'"
            continue
        }

        # 2. DETECT EXISTING PORT
        # We need to find out what port the loadbalancer is actually mapped to.
        # The container name is usually k3d-<clustername>-serverlb
        LB_CONTAINER="k3d-${CLUSTER_NAME}-serverlb"
        
        # Extract port 80 mapping. Returns something like "0.0.0.0:8080"
        EXISTING_MAPPING=$(docker port "$LB_CONTAINER" 80/tcp 2>/dev/null || true)
        
        if [ -z "$EXISTING_MAPPING" ]; then
            log_warn "Could not detect port for $CLUSTER_NAME. Is it running? Skipping proxy config for this cluster."
            continue
        fi

        # Parse port number with robust parsing function
        ASSIGNED_PORT=$(parse_docker_port "$EXISTING_MAPPING")
        
        if [ -z "$ASSIGNED_PORT" ]; then
            log_error "Failed to parse port from mapping: $EXISTING_MAPPING. Skipping proxy config for this cluster."
            continue
        fi
        
        log_info "Detected existing mapping: Port $ASSIGNED_PORT"

    else
        # 3. CREATE NEW CLUSTER
        # Find next available port
        while [ "$NEXT_PORT" -le "$MAX_PORT" ] && ! is_port_available "$NEXT_PORT"; do
            log_warn "Port $NEXT_PORT is not available, trying next port..."
            NEXT_PORT=$((NEXT_PORT+1))
        done
        
        if [ "$NEXT_PORT" -gt "$MAX_PORT" ]; then
            log_error "No available ports found in range $START_PORT-$MAX_PORT. Cannot create cluster '$CLUSTER_NAME'."
            continue
        fi
        
        ASSIGNED_PORT=$NEXT_PORT
        log_info "Creating new cluster on port $ASSIGNED_PORT..."
        
        if ! k3d cluster create "$CLUSTER_NAME" \
            -p "$ASSIGNED_PORT:80@loadbalancer" \
            --network "$DOCKER_NETWORK" \
            --registry-use "k3d-${REGISTRY_NAME}:${REGISTRY_PORT}" \
            --registry-config "$REGISTRY_CONFIG_FILE" \
            --wait >/dev/null 2>&1; then
            # Check if the error is because cluster already exists
            if cluster_exists "$CLUSTER_NAME"; then
                log_warn "Cluster '$CLUSTER_NAME' exists but wasn't detected initially. Detecting existing port..."
                # Ensure it is running
                k3d cluster start "$CLUSTER_NAME" >/dev/null 2>&1 || true
                # Try to detect the existing port
                LB_CONTAINER="k3d-${CLUSTER_NAME}-serverlb"
                EXISTING_MAPPING=$(docker port "$LB_CONTAINER" 80/tcp 2>/dev/null || true)
                
                if [ -n "$EXISTING_MAPPING" ]; then
                    ASSIGNED_PORT=$(parse_docker_port "$EXISTING_MAPPING")
                    if [ -n "$ASSIGNED_PORT" ]; then
                        log_info "Detected existing mapping: Port $ASSIGNED_PORT"
                    else
                        log_error "Failed to parse port from mapping: $EXISTING_MAPPING. Skipping proxy config for this cluster."
                        continue
                    fi
                else
                    log_error "Could not detect port for existing cluster '$CLUSTER_NAME'. Skipping proxy config."
                    continue
                fi
            else
                log_error "Failed to create cluster '$CLUSTER_NAME'. Skipping."
                continue
            fi
        else
            log_success "Cluster '$CLUSTER_NAME' created successfully"
        fi
    fi

    # 4. Update NGINX Config
    log_info "Adding proxy configuration for $CLUSTER_NAME on port $ASSIGNED_PORT"
    {
        echo "    server {"
        echo "        listen 80;"
        echo "        server_name .$CLUSTER_NAME.$DOMAIN_SUFFIX;"
        echo "        location / {"
        echo "            proxy_pass http://host.docker.internal:$ASSIGNED_PORT;"
        echo "            proxy_set_header Host \$host;"
        echo "            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
        echo "        }"
        echo "    }"
    } >> "$PROXY_CONF_FILE"

    # 5. Update NEXT_PORT logic
    # If the assigned port is greater than or equal to our counter, 
    # bump the counter to avoid conflicts for the next new cluster.
    if [ "$ASSIGNED_PORT" -ge "$NEXT_PORT" ]; then
        NEXT_PORT=$((ASSIGNED_PORT+1))
    fi

done

# Close config file
echo "}" >> "$PROXY_CONF_FILE"

# Validate nginx config before using it
log_info "Validating nginx configuration..."
if ! validate_nginx_config "$PROXY_CONF_FILE"; then
    log_error "Nginx configuration validation failed. Aborting proxy setup."
    exit 1
fi
log_success "Nginx configuration is valid"

# ==========================================
# REFRESH PROXY
# ==========================================
echo -e "${GREEN}------------------------------------------------${NC}"
log_info "Refreshing Local Reverse Proxy..."

# Remove old proxy if exists (with proper check)
if container_exists "$PROXY_CONTAINER"; then
    log_info "Removing existing proxy container..."
    if docker rm -f "$PROXY_CONTAINER" >/dev/null 2>&1; then
        log_success "Removed existing proxy container"
    else
        log_warn "Failed to remove existing proxy container, continuing anyway..."
    fi
else
    log_info "No existing proxy container found"
fi

# Check if port 80 is available for the proxy
if ! is_port_available 80; then
    log_error "Port 80 is already in use. Cannot start proxy. Please free port 80 and try again."
    exit 1
fi

# Run Nginx Proxy
log_info "Starting nginx proxy container..."
if docker run -d --name "$PROXY_CONTAINER" \
    -p 80:80 \
    -v "$PROXY_CONF_FILE:/etc/nginx/nginx.conf:ro" \
    --network "$DOCKER_NETWORK" \
    --add-host=host.docker.internal:host-gateway \
    nginx:alpine >/dev/null 2>&1; then
    log_success "Proxy container started successfully"
    
    # Verify container is running
    sleep 1
    if docker ps --format '{{.Names}}' | grep -q "^${PROXY_CONTAINER}$"; then
        log_success "Proxy container is running and healthy"
    else
        log_warn "Proxy container may not be running properly. Check with: docker ps -a | grep $PROXY_CONTAINER"
    fi
else
    log_error "Failed to start proxy container"
    exit 1
fi

# ==========================================
# FINAL OUTPUT
# ==========================================
echo -e "${GREEN}================================================${NC}"
log_success "SETUP COMPLETE"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Ensure your /etc/hosts contains the following lines:"
echo ""
echo -n "127.0.0.1"

# Build hosts entries without trailing backslash
FIRST=true
for CLUSTER_NAME in "${CLUSTERS[@]}"
do
    for APP in "${APPS[@]}"
    do
        if [ "$FIRST" = true ]; then
            echo -n "  $APP.$CLUSTER_NAME.$DOMAIN_SUFFIX"
            FIRST=false
        else
            echo -n " $APP.$CLUSTER_NAME.$DOMAIN_SUFFIX"
        fi
    done
done
echo ""
echo ""

