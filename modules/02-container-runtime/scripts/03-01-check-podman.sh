# ==============================================================================
# SCRIPT 1: 01-check-podman.sh
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

# Function to safely remove Podman
remove_podman() {
    log_info "Starting Podman removal process..."
    
    # Stop and disable services first
    log_info "Stopping Podman services..."
    sudo systemctl stop podman.socket 2>/dev/null || true
    sudo systemctl disable podman.socket 2>/dev/null || true
    sudo systemctl stop podman-restart.service 2>/dev/null || true
    sudo systemctl disable podman-restart.service 2>/dev/null || true
    
    # Stop user services if running as non-root
    if [[ $EUID -ne 0 ]]; then
        systemctl --user stop podman.socket 2>/dev/null || true
        systemctl --user disable podman.socket 2>/dev/null || true
    fi
    
    # Show current data before asking what to do
    echo ""
    log_info "Current Podman data on this system:"
    local containers_count=$(podman ps -a --format "{{.Names}}" 2>/dev/null | wc -l || echo "0")
    local images_count=$(podman images --format "{{.Repository}}" 2>/dev/null | wc -l || echo "0") 
    local volumes_count=$(podman volume ls --format "{{.Name}}" 2>/dev/null | wc -l || echo "0")
    
    log_info "- Containers: $containers_count"
    log_info "- Images: $images_count" 
    log_info "- Volumes: $volumes_count"
    
    # Ask user what to do with existing data
    echo ""
    log_warning "What should we do with existing Podman data?"
    echo ""
    echo "  1) Keep everything (safest - only remove Podman software)"
    echo "  2) Remove containers only (keep images and volumes)"
    echo "  3) Remove containers and images (keep volumes with data)"
    echo "  4) Remove everything (DESTRUCTIVE - including data volumes)"
    echo ""
    read -p "Choose option (1-4, default is 1): " -r choice
    
    # Default to option 1 if no choice made
    choice=${choice:-1}
    
    case $choice in
        1)
            log_info "Keeping all Podman data (containers, images, volumes)"
            # Just stop running containers, don't remove anything
            log_info "Stopping running containers..."
            podman stop --all 2>/dev/null || true
            sudo podman stop --all 2>/dev/null || true
            ;;
        2)
            log_info "Removing containers but keeping images and volumes..."
            podman stop --all 2>/dev/null || true
            podman rm --all --force 2>/dev/null || true
            sudo podman stop --all 2>/dev/null || true
            sudo podman rm --all --force 2>/dev/null || true
            log_success "Containers removed, images and volumes preserved"
            ;;
        3)
            log_info "Removing containers and images but keeping volumes..."
            podman stop --all 2>/dev/null || true
            podman rm --all --force 2>/dev/null || true
            podman rmi --all --force 2>/dev/null || true
            sudo podman stop --all 2>/dev/null || true
            sudo podman rm --all --force 2>/dev/null || true
            sudo podman rmi --all --force 2>/dev/null || true
            log_success "Containers and images removed, volumes preserved"
            ;;
        4)
            echo ""
            log_error "⚠️  DESTRUCTIVE OPTION SELECTED ⚠️"
            log_warning "This will permanently delete:"
            log_warning "- All containers and their changes"
            log_warning "- All downloaded/built images"  
            log_warning "- All volumes (databases, app data, etc.)"
            log_warning "- All networks and pods"
            echo ""
            read -p "Type 'DELETE-EVERYTHING' to confirm: " -r confirm
            
            if [[ "$confirm" == "DELETE-EVERYTHING" ]]; then
                log_info "Performing complete Podman data reset..."
                sudo podman system reset --force 2>/dev/null || true
                podman system reset --force 2>/dev/null || true
                log_warning "All Podman data has been permanently deleted"
            else
                log_info "Confirmation failed - keeping all data (falling back to option 1)"
            fi
            ;;
        *)
            log_warning "Invalid choice - keeping all data (using option 1)"
            ;;
    esac
    
    # Remove package
    echo ""
    log_info "Removing Podman package..."
    if command -v apt &>/dev/null; then
        sudo apt remove -y podman podman-plugins 2>/dev/null || true
        sudo apt autoremove -y 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        sudo dnf remove -y podman 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        sudo yum remove -y podman 2>/dev/null || true
    else
        log_warning "Unknown package manager - manual removal may be required"
    fi
    
    # Ask about configuration directories (separate from data)
    echo ""
    log_warning "Remove Podman configuration directories?"
    log_info "This includes registry settings, container configs (not data volumes)"
    read -p "Remove configuration directories? (y/N): " -r
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing Podman configuration directories..."
        
        # System-wide config directories (not data)
        sudo rm -rf /etc/containers 2>/dev/null || true
        sudo rm -rf /usr/share/containers 2>/dev/null || true
        
        # User config directories (not data)  
        rm -rf ~/.config/containers 2>/dev/null || true
        rm -rf ~/.cache/containers 2>/dev/null || true
        
        # Only remove data directory if user chose option 4
        if [[ "$choice" == "4" && "$confirm" == "DELETE-EVERYTHING" ]]; then
            sudo rm -rf /var/lib/containers 2>/dev/null || true
            rm -rf ~/.local/share/containers 2>/dev/null || true
        fi
        
        log_success "Podman configuration removed"
    else
        log_info "Podman configuration preserved"
    fi
    
    log_success "Podman removal completed"
}

# Main execution
main() {
    log_info "🧹 Checking for existing Podman installation..."
    
    if command -v podman &>/dev/null; then
        echo ""
        log_warning "Podman is currently installed on this system"
        
        # Show current version
        local version=$(podman --version 2>/dev/null || echo "Unknown version")
        log_info "Current version: $version"
        
        # Show current containers and images
        local containers=$(podman ps -a --format "{{.Names}}" 2>/dev/null | wc -l)
        local images=$(podman images --format "{{.Repository}}" 2>/dev/null | wc -l)
        log_info "Current containers: $containers"
        log_info "Current images: $images"
        
        echo ""
        log_warning "Do you want to uninstall the existing Podman installation?"
        log_warning "This is recommended for a clean setup."
        read -p "Uninstall existing Podman? (y/N): " -r
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            remove_podman
        else
            log_info "Keeping existing Podman installation"
            log_warning "Note: This may cause conflicts with the new installation"
            
            echo ""
            read -p "Are you sure you want to continue? (y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Setup cancelled by user"
                exit 1
            fi
        fi
    else
        log_success "Podman is not installed - ready for fresh installation"
    fi
}

main "$@"