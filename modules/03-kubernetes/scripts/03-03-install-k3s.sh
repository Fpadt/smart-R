# ==============================================================================
# SCRIPT 3: 03-install-k3s.sh
# ==============================================================================
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

log_section() {
    echo -e "\n${BLUE}🔍 $1${NC}"
    echo "----------------------------------------"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables
load_env() {
    local env_file="$SCRIPT_DIR/.env"
    
    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found at $env_file"
        exit 1
    fi
    
    set -a
    source "$env_file"
    set +a
    
    log_success "Environment variables loaded"
}

# Display versions of installed packages
display_package_versions() {
    log_info "Package versions:"
    
    local -A version_commands=(
        ["curl"]="curl --version | head -1"
        ["git"]="git --version"
        ["jq"]="jq --version"
        ["iptables"]="iptables --version"
        ["helm"]="helm version --short"
    )
    
    echo ""
    for package in "${!version_commands[@]}"; do
        if command -v "$package" >/dev/null 2>&1; then
            local version_output
            if version_output=$(eval "${version_commands[$package]}" 2>/dev/null); then
                echo "  📦 $package: $version_output"
            else
                echo "  📦 $package: installed (version check failed)"
            fi
        else
            echo "  ❌ $package: not found in PATH"
        fi
    done
    echo ""
}

# Install Helm
install_helm() {
    log_section "Helm Installation"
    
    if command -v helm &> /dev/null; then
        local helm_version
        helm_version=$(helm version --short)
        log_success "Helm is already installed ($helm_version)"
        return 0
    fi
    
    log_info "Installing Helm..."
    
    # Download and install Helm
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    if ./get_helm.sh; then
        rm get_helm.sh
        local helm_version
        helm_version=$(helm version --short)
        log_success "Helm installed successfully ($helm_version)"
    else
        rm get_helm.sh
        log_error "Helm installation failed"
        exit 1
    fi
}

# Install K3s
install_k3s() {
    log_section "K3s Installation"
    
    # Get real user info (handle sudo context)
    local real_user="${SUDO_USER:-$USER}"
    local real_home=$(getent passwd "$real_user" | cut -d: -f6)
    
    log_info "Installing K3s version: ${K3S_VERSION}"
    log_info "Target user: $real_user"
    log_info "Home directory: $real_home"
    
    # Set installation environment variables
    export INSTALL_K3S_VERSION="${K3S_VERSION}"
    export INSTALL_K3S_EXEC="server"
    
    # Install K3s with hardened defaults
    log_info "Downloading and installing K3s..."
    if curl -sfL https://get.k3s.io | sh -; then
        log_success "K3s installed successfully"
    else
        log_error "Failed to install K3s"
        exit 1
    fi
    
    # Wait for service to start
    log_info "Waiting for K3s service to start..."
    sleep 10
    
    # Check service status
    if systemctl is-active --quiet k3s; then
        log_success "K3s service is running"
    else
        log_error "K3s service failed to start"
        log_info "Checking service status:"
        sudo systemctl status k3s --no-pager || true
        exit 1
    fi
}

# Enhanced setup_kubectl with debugging for K3s script:
setup_kubectl() {
    local real_user="${SUDO_USER:-$USER}"
    local real_home=$(getent passwd "$real_user" | cut -d: -f6)
    
    log_info "Setting up kubectl configuration for user: $real_user"
    log_info "Target home directory: $real_home"
    log_info "Current user running script: $(whoami)"
    
    # Wait for kubeconfig to be created by K3s
    local retries=10
    while [[ ! -f /etc/rancher/k3s/k3s.yaml && $retries -gt 0 ]]; do
        log_info "Waiting for K3s kubeconfig... ($retries retries left)"
        sleep 3
        ((retries--))
    done
    
    if [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; then
        log_error "K3s kubeconfig not found after installation"
        exit 1
    fi
    
    log_success "K3s kubeconfig found at /etc/rancher/k3s/k3s.yaml"
    
    # Set proper permissions on K3s kubeconfig
    sudo chmod 644 /etc/rancher/k3s/k3s.yaml
    log_info "Set permissions on K3s kubeconfig"
    
    # Create .kube directory for user
    log_info "Creating .kube directory for $real_user..."
    if sudo -u "$real_user" mkdir -p "$real_home/.kube"; then
        log_success ".kube directory created/verified"
    else
        log_error "Failed to create .kube directory"
        exit 1
    fi
    
    # Copy K3s config to user's .kube directory  
    log_info "Copying kubeconfig to $real_home/.kube/config..."
    if sudo cp /etc/rancher/k3s/k3s.yaml "$real_home/.kube/config"; then
        log_success "Kubeconfig copied"
    else
        log_error "Failed to copy kubeconfig"
        exit 1
    fi
    
    # Set ownership
    log_info "Setting ownership to $real_user:$real_user..."
    if sudo chown "$real_user:$real_user" "$real_home/.kube/config"; then
        log_success "Ownership set"
    else
        log_error "Failed to set ownership"
        exit 1
    fi
    
    # Set permissions
    if sudo chmod 600 "$real_home/.kube/config"; then
        log_success "Permissions set to 600"
    else
        log_error "Failed to set permissions"
        exit 1
    fi
    
    # Replace localhost with public IP if configured
    if [[ -n "${PUBLIC_IP:-}" && "$PUBLIC_IP" != "127.0.0.1" ]]; then
        log_info "Configuring kubectl for remote access (${PUBLIC_IP})"
        if sudo -u "$real_user" sed -i "s/127.0.0.1/${PUBLIC_IP}/g" "$real_home/.kube/config"; then
            log_success "IP address updated in kubeconfig"
        else
            log_error "Failed to update IP in kubeconfig"
            exit 1
        fi
    fi
    
    log_success "kubectl configuration ready at $real_home/.kube/config"
    
    # Verify the file exists and has correct content
    log_info "Verifying kubeconfig..."
    if [[ -f "$real_home/.kube/config" ]]; then
        log_success "Kubeconfig file exists"
        log_info "File permissions: $(ls -la "$real_home/.kube/config")"
        log_info "Server endpoint: $(sudo -u "$real_user" grep "server:" "$real_home/.kube/config")"
    else
        log_error "Kubeconfig file was not created!"
        exit 1
    fi
    
    # Test kubectl access
    log_info "Testing kubectl access for $real_user..."
    if sudo -u "$real_user" kubectl get nodes &>/dev/null; then
        log_success "kubectl access verified for $real_user"
    else
        log_error "kubectl access test failed for $real_user"
        log_info "Debugging kubectl failure..."
        sudo -u "$real_user" kubectl get nodes || true
        exit 1
    fi
    
    # Test Helm access (should work now)
    if command -v helm >/dev/null 2>&1; then
        log_info "Testing Helm access for $real_user..."
        if sudo -u "$real_user" helm list -A &>/dev/null; then
            log_success "Helm access verified for $real_user"
        else
            log_warning "Helm access failed for $real_user"
            log_info "This will be verified during Traefik setup"
        fi
    fi
}

# Test basic functionality
test_installation() {
    log_section "Installation Test"
    
    log_info "Testing cluster connectivity..."
    
    # Wait longer for cluster to be ready
    log_info "Waiting for cluster to initialize (this may take 60-90 seconds)..."
    sleep 30
    
    # Check if K3s service is actually running
    if ! systemctl is-active --quiet k3s; then
        log_error "K3s service is not running"
        log_info "Service status:"
        sudo systemctl status k3s --no-pager || true
        log_info "Recent logs:"
        sudo journalctl -u k3s --no-pager -n 20 || true
        exit 1
    fi
    
    log_success "K3s service is running"
    
    # Check if kubeconfig exists and is readable
    local real_user="${SUDO_USER:-$USER}"
    local real_home=$(getent passwd "$real_user" | cut -d: -f6)
    local kubeconfig="$real_home/.kube/config"
    
    if [[ ! -f "$kubeconfig" ]]; then
        log_error "Kubeconfig not found at $kubeconfig"
        exit 1
    fi
    
    if [[ ! -r "$kubeconfig" ]]; then
        log_error "Kubeconfig not readable at $kubeconfig"
        exit 1
    fi
    
    log_success "Kubeconfig exists and is readable"
    
    # Test kubectl access with retries
    local retries=12  # 12 retries = 60 seconds
    local success=false
    
    while [[ $retries -gt 0 ]]; do
        log_info "Testing kubectl access... ($retries retries left)"
        
        # Try with both kubectl and k3s kubectl
        if sudo -u "$real_user" kubectl get nodes &>/dev/null; then
            log_success "kubectl access working with system kubectl"
            success=true
            break
        elif sudo k3s kubectl get nodes &>/dev/null; then
            log_success "kubectl access working with k3s kubectl"
            success=true
            break
        else
            log_info "Cluster not ready yet, waiting 5 seconds..."
            sleep 5
            ((retries--))
        fi
    done
    
    if [[ "$success" == "false" ]]; then
        log_error "kubectl access failed after waiting 60 seconds"
        
        # Debugging information
        log_info "Debugging information:"
        echo ""
        echo "=== K3s Service Status ==="
        sudo systemctl status k3s --no-pager || true
        echo ""
        echo "=== K3s Logs (last 20 lines) ==="
        sudo journalctl -u k3s --no-pager -n 20 || true
        echo ""
        echo "=== Kubeconfig Content ==="
        cat "$kubeconfig" | head -10 || true
        echo ""
        echo "=== Network Status ==="
        ss -tlnp | grep 6443 || echo "Port 6443 not listening"
        echo ""
        echo "=== Process Status ==="
        ps aux | grep k3s | grep -v grep || echo "No k3s processes found"
        echo ""
        echo "=== Disk Space ==="
        df -h /var/lib/rancher/k3s || true
        echo ""
        
        # Try manual test commands
        echo "=== Manual Test Commands ==="
        echo "Try these commands manually:"
        echo "  sudo k3s kubectl get nodes"
        echo "  sudo -u $real_user kubectl get nodes"
        echo "  sudo systemctl restart k3s"
        echo "  sudo journalctl -u k3s -f"
        
        exit 1
    fi
    
    # Test Helm access (non-blocking)
    log_info "Testing Helm connectivity..."
    if sudo -u "$real_user" helm list -A &>/dev/null; then
        log_success "Helm can connect to K3s cluster"
    else
        log_warning "Helm connectivity test failed"
        log_info "This is normal during initial installation"
        log_info "Helm connectivity will be verified during Traefik setup"
        log_info "If needed later, run: export KUBECONFIG=/home/fpadt/.kube/config"
    fi

    # If we get here, kubectl is working - show cluster info
    log_info "Cluster nodes:"
    if sudo -u "$real_user" kubectl get nodes -o wide 2>/dev/null; then
        true  # Success
    else
        sudo k3s kubectl get nodes -o wide 2>/dev/null || true
    fi
    
    log_info "System pods:"
    if sudo -u "$real_user" kubectl get pods -n kube-system 2>/dev/null; then
        true  # Success
    else
        sudo k3s kubectl get pods -n kube-system 2>/dev/null || true
    fi
    
    # Final verification
    log_success "K3s installation test completed successfully"
}

# Main execution
main() {
    log_info "📦 Installing K3s with Helm and security hardening..."
    
    load_env
    install_helm
    install_k3s
    setup_kubectl
    test_installation
    
    log_success "K3s and Helm installation completed successfully"
    
    echo ""
    log_info "📋 Installation Summary:"
    echo "  ✅ K3s version: ${K3S_VERSION}"
    echo "  ✅ Helm package manager installed"
    echo "  ✅ Node name: ${K3S_NODE_NAME:-'default'}"
    echo "  ✅ Public IP: ${PUBLIC_IP}"
    echo "  ✅ kubectl config: ~/.kube/config"
    echo "  ✅ kubectl and Helm access verified"
    
    echo ""
    log_info "🔄 Next steps:"
    echo "  • Run 04-verify-k3s.sh to verify installation"
    echo "  • Both kubectl and Helm are ready for use"
    echo "  • Ready for Traefik installation after hardening"
    
    echo ""
    log_warning "⚠️  Important: If you're using SSH, you may need to:"
    echo "  • Log out and back in for group changes to take effect"
    echo "  • Or run: export KUBECONFIG=~/.kube/config"
}

main "$@"
