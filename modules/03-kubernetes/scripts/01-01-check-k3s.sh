#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if .env file exists
check_env_file() {
    local env_file="$SCRIPT_DIR/.env"
    
    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found at $env_file"
        echo ""
        log_info "Please create .env file with required variables:"
        echo "K3S_VERSION=v1.28.5+k3s1"
        echo "K3S_NODE_NAME=k3s-master"
        echo "K3S_CLUSTER_DOMAIN=cluster.local"
        echo "K3S_SERVICE_CIDR=10.43.0.0/16"
        echo "K3S_CLUSTER_CIDR=10.42.0.0/16"
        echo "PUBLIC_IP=your.public.ip.address"
        echo "EMAIL=your@email.com"
        echo "SSH_USER=your_ssh_user"
        exit 1
    fi
    
    log_success ".env file found"
    
    # Load and validate variables
    set -a
    source "$env_file"
    set +a
    
    local missing_vars=()
    [[ -z "${K3S_VERSION:-}" ]] && missing_vars+=("K3S_VERSION")
    [[ -z "${K3S_NODE_NAME:-}" ]] && missing_vars+=("K3S_NODE_NAME")
    [[ -z "${PUBLIC_IP:-}" ]] && missing_vars+=("PUBLIC_IP")
    [[ -z "${EMAIL:-}" ]] && missing_vars+=("EMAIL")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required variables in .env:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        exit 1
    fi
    
    log_info "Environment variables loaded:"
    echo "  K3S_VERSION=$K3S_VERSION"
    echo "  K3S_NODE_NAME=$K3S_NODE_NAME"
    echo "  PUBLIC_IP=$PUBLIC_IP"
    echo "  EMAIL=$EMAIL"
}

# Check template files
check_templates() {
    log_info "Checking for required template files..."
    
    local templates=(
        "config.yaml"         # K3s main config (can use ${EMAIL}, ${PUBLIC_IP})
        "audit-policy.yaml"   # K3s audit policy (can use ${EMAIL})
        "psa-config.yaml"     # K3s Pod Security Admission config
        "k3s-audit"           # K3s audit log rotation
        "network-policy.yaml" # K3s network policy (can use ${PUBLIC_IP})
        "99-k3s.conf"         # Kernel parameters (new)
    )
    
    local missing_templates=()
    for template in "${templates[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/templates/$template" ]]; then
            missing_templates+=("$template")
        fi
    done
    
    if [[ ${#missing_templates[@]} -gt 0 ]]; then
        log_error "Missing required template files in templates/ directory:"
        for template in "${missing_templates[@]}"; do
            echo "  - templates/$template"
        done
        exit 1
    fi
    
    log_success "All template files found in templates/ directory"
}

# Check system requirements
check_system() {
    log_info "Checking system requirements..."
    
    # Check OS
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "  OS: $NAME $VERSION"
        
        if [[ "$ID" != "ubuntu" ]]; then
            log_warning "This script is optimized for Ubuntu"
            log_warning "Current system: $NAME $VERSION"
        fi
    fi
    
    # Check architecture
    local arch=$(uname -m)
    echo "  Architecture: $arch"
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        log_warning "Unsupported architecture: $arch"
    fi
    
    # Check memory (K3s needs at least 512MB)
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_mb=$((mem_kb / 1024))
    echo "  Memory: ${mem_mb}MB"
    
    if [[ $mem_mb -lt 512 ]]; then
        log_error "Insufficient memory. K3s requires at least 512MB"
        exit 1
    elif [[ $mem_mb -lt 1024 ]]; then
        log_warning "Low memory (${mem_mb}MB). Consider 1GB+ for production"
    fi
    
    # Check disk space
    local disk_avail=$(df / | tail -1 | awk '{print $4}')
    local disk_gb=$((disk_avail / 1024 / 1024))
    echo "  Available disk space: ${disk_gb}GB"
    
    if [[ $disk_gb -lt 2 ]]; then
        log_error "Insufficient disk space. K3s requires at least 2GB"
        exit 1
    fi
}

# Check existing K3s installation
check_existing_k3s() {
    log_info "Checking for existing K3s installation..."
    
    if command -v k3s &>/dev/null; then
        log_warning "K3s is already installed"
        
        # Show current version and status
        local version=$(k3s --version | head -1)
        log_info "Current version: $version"
        
        if systemctl is-active --quiet k3s 2>/dev/null; then
            log_info "K3s service is currently running"
            
            # Show cluster info if available
            if kubectl get nodes &>/dev/null; then
                local nodes=$(kubectl get nodes --no-headers | wc -l)
                log_info "Current cluster has $nodes node(s)"
            fi
        else
            log_info "K3s service is not running"
        fi
        
        echo ""
        log_warning "Do you want to uninstall the existing K3s installation?"
        log_warning "This will remove all cluster data and workloads!"
        read -p "Uninstall existing K3s? (y/N): " -r
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            remove_k3s
        else
            log_info "Keeping existing K3s installation"
            log_warning "Note: This may cause conflicts with the new installation"
            
            echo ""
            read -p "Are you sure you want to continue? (y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Setup cancelled by user"
                exit 1
            fi
        fi
    else
        log_success "K3s is not installed - ready for fresh installation"
    fi
}

# Remove existing K3s installation
remove_k3s() {
    log_info "Removing existing K3s installation..."
    
    # Stop the service first
    if systemctl is-active --quiet k3s 2>/dev/null; then
        log_info "Stopping K3s service..."
        sudo systemctl stop k3s || true
    fi
    
    # Run uninstall script if it exists
    if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        log_info "Running K3s uninstall script..."
        sudo /usr/local/bin/k3s-uninstall.sh || true
        sudo rm -rf ~/.kube
    else
        log_warning "K3s uninstall script not found, manual cleanup required"
        
        # Manual cleanup
        log_info "Performing manual cleanup..."
        sudo systemctl stop k3s 2>/dev/null || true
        sudo systemctl disable k3s 2>/dev/null || true
        sudo rm -f /etc/systemd/system/k3s.service
        sudo rm -f /usr/local/bin/k3s
        sudo rm -rf /etc/rancher/k3s
        sudo rm -rf /var/lib/rancher/k3s
        sudo rm -rf ~/.kube
        sudo systemctl daemon-reload
    fi
    
    # Clean up kubectl config
    local real_user="${SUDO_USER:-$USER}"
    local real_home=$(getent passwd "$real_user" | cut -d: -f6)
    
    if [[ -f "$real_home/.kube/config" ]]; then
        log_info "Backing up existing kubectl config..."
        mv "$real_home/.kube/config" "$real_home/.kube/config.backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    fi
    
    log_success "K3s removal completed"
}

# Main execution
main() {
    log_info "🔍 Checking K3s prerequisites and existing installation..."
    
    check_env_file
    check_templates
    check_system
    check_existing_k3s
    
    log_success "System check completed - ready for K3s installation"
}

main "$@"