# ==============================================================================
# SCRIPT 2: 02-install-podman.sh
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

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

main() {
    log_info "🔧 Installing Podman..."
    
    # Detect OS
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi
    
    log_info "Detected OS: $OS $VERSION"
    
    case $OS in
        ubuntu|debian)
            log_info "Installing Podman on Ubuntu/Debian..."
            sudo apt update
            sudo apt install -y podman
            ;;
        fedora)
            log_info "Installing Podman on Fedora..."
            sudo dnf install -y podman
            ;;
        centos|rhel)
            log_info "Installing Podman on CentOS/RHEL..."
            sudo yum install -y podman
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
    
    # Verify installation
    if command -v podman &>/dev/null; then
        local version=$(podman --version)
        log_success "Podman installed successfully: $version"
    else
        log_error "Podman installation failed"
        exit 1
    fi
}

main "$@"