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
    if [[ -f "$env_file" ]]; then
        set -a
        source "$env_file"
        set +a
        log_info "Environment variables loaded from .env"
    else
        log_warning "No .env file found - continuing without environment variables"
    fi
}

# Enhanced render function with smart backup and cleanup
render_template() {
    local template="$1"
    local target="$2"
    local backup_enabled="${3:-true}"  # Optional: default to true
    
    local template_path="$SCRIPT_DIR/templates/$template"
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template not found: $template_path"
        exit 1
    fi
    
    # Create target directory
    sudo mkdir -p "$(dirname "$target")"
    
    # Backup existing file if it exists and backup is enabled
    if [[ "$backup_enabled" == "true" && -f "$target" ]]; then
        # Create timestamped backup
        local timestamp=$(date +%Y%m%d-%H%M%S)
        local backup="$target.backup.$timestamp"
        
        log_info "Backing up existing $target to $backup"
        if sudo cp "$target" "$backup"; then
            log_success "Backup created: $backup"
            
            # Cleanup old backups (keep last 5)
            cleanup_old_backups "$target"
        else
            log_error "Failed to create backup"
            exit 1
        fi
    fi
    
    # Render template
    log_info "Rendering templates/$template -> $target"
    
    # Create temporary file first (atomic operation)
    local temp_file="${target}.tmp.$$"
    
    if envsubst < "$template_path" | sudo tee "$temp_file" > /dev/null; then
        # Move temp file to final location (atomic)
        if sudo mv "$temp_file" "$target"; then
            log_success "Successfully deployed $target"
            
            # Show which variables were substituted (for debugging)
            local vars_found
            vars_found=$(grep -o '\${[^}]*}' "$template_path" 2>/dev/null | sort -u || true)
            if [[ -n "$vars_found" ]]; then
                log_info "Variables substituted: $(echo "$vars_found" | tr '\n' ' ')"
            fi
        else
            sudo rm -f "$temp_file"
            log_error "Failed to move $temp_file to $target"
            exit 1
        fi
    else
        sudo rm -f "$temp_file"
        log_error "Failed to render template $template"
        exit 1
    fi
}

# User-specific render function (no sudo needed)
render_user_template() {
    local template="$1"
    local target="$2"
    local backup_enabled="${3:-true}"  # Optional: default to true
    
    local template_path="$SCRIPT_DIR/templates/$template"
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template not found: $template_path"
        exit 1
    fi
    
    # Create target directory
    mkdir -p "$(dirname "$target")"
    
    # Backup existing file if it exists and backup is enabled
    if [[ "$backup_enabled" == "true" && -f "$target" ]]; then
        # Create timestamped backup
        local timestamp=$(date +%Y%m%d-%H%M%S)
        local backup="$target.backup.$timestamp"
        
        log_info "Backing up existing $target to $backup"
        if cp "$target" "$backup"; then
            log_success "Backup created: $backup"
        else
            log_error "Failed to create backup"
            exit 1
        fi
    fi
    
    # Render template
    log_info "Rendering templates/$template -> $target"
    
    # Create temporary file first (atomic operation)
    local temp_file="${target}.tmp.$$"
    
    if envsubst < "$template_path" > "$temp_file"; then
        # Move temp file to final location (atomic)
        if mv "$temp_file" "$target"; then
            log_success "Successfully deployed $target"
            
            # Show which variables were substituted (for debugging)
            local vars_found
            vars_found=$(grep -o '\${[^}]*}' "$template_path" 2>/dev/null | sort -u || true)
            if [[ -n "$vars_found" ]]; then
                log_info "Variables substituted: $(echo "$vars_found" | tr '\n' ' ')"
            fi
        else
            rm -f "$temp_file"
            log_error "Failed to move $temp_file to $target"
            exit 1
        fi
    else
        rm -f "$temp_file"
        log_error "Failed to render template $template"
        exit 1
    fi
}

# Cleanup old backup files (keep only the 5 most recent)
cleanup_old_backups() {
    local target="$1"
    
    # Find backup files and sort by modification time
    local backup_files
    backup_files=$(find "$(dirname "$target")" -name "$(basename "$target").backup.*" -type f 2>/dev/null | sort -t. -k3 || true)
    
    if [[ -n "$backup_files" ]]; then
        local backup_count
        backup_count=$(echo "$backup_files" | wc -l)
        
        if [[ $backup_count -gt 5 ]]; then
            local files_to_remove
            files_to_remove=$(echo "$backup_files" | head -n $((backup_count - 5)))
            
            log_info "Cleaning up old backups (keeping 5 most recent)"
            echo "$files_to_remove" | while read -r file; do
                if [[ -n "$file" ]]; then
                    sudo rm -f "$file"
                    log_info "Removed old backup: $file"
                fi
            done
        fi
    fi
}

# Configure Podman registries
configure_registries() {
    log_section "Container Registries Configuration"
    
    # Create config directories if they don't exist
    mkdir -p ~/.config/containers
    
    # Render registries configuration
    render_user_template "registries.conf" "$HOME/.config/containers/registries.conf"
}

# Configure container security policy
configure_security_policy() {
    log_section "Container Security Policy"
    
    # Check if policy already exists
    if [[ ! -f /etc/containers/policy.json ]]; then
        log_info "Installing container security policy..."
        render_template "policy.json" "/etc/containers/policy.json"
    else
        log_info "Security policy already exists - updating..."
        render_template "policy.json" "/etc/containers/policy.json"
    fi
}

# Configure containers.conf for Docker compatibility
configure_containers_conf() {
    log_section "Containers Configuration"
    
    local user_containers_conf="$HOME/.config/containers/containers.conf"
    
    if [[ ! -f "$user_containers_conf" ]]; then
        log_info "Installing containers.conf for Docker compatibility..."
        render_user_template "containers.conf" "$user_containers_conf"
    else
        log_info "containers.conf already exists - updating..."
        render_user_template "containers.conf" "$user_containers_conf"
    fi
}

# Setup Podman socket and Docker compatibility
configure_podman_socket() {
    log_section "Podman Socket Configuration"
    
    # Enable lingering for rootless containers (if not root)
    if [[ $EUID -ne 0 ]]; then
        log_info "👤 Enabling user-level Podman service..."
        sudo loginctl enable-linger "$USER" || true
        systemctl --user enable --now podman.socket || true
        
        # Wait a moment for socket to start
        sleep 2
        
        # Confirm socket is listening
        echo -e "${GREEN}🔍 Checking Podman socket...${NC}"
        if ss -lx | grep podman >/dev/null 2>&1; then
            log_success "Podman socket is active and listening"
        else
            log_warning "Podman socket not active!"
            log_info "Attempting to start socket manually..."
            systemctl --user start podman.socket || true
        fi
        
        # Export the Docker-compatible socket
        local socket_path="/run/user/$(id -u)/podman/podman.sock"
        local docker_host="unix://$socket_path"
        
        log_info "📦 Setting up Docker-compatible socket..."
        if ! grep -q 'DOCKER_HOST=unix:///run/user/.*/podman/podman.sock' ~/.bashrc 2>/dev/null; then
            if ! grep -q 'export DOCKER_HOST=' ~/.bashrc 2>/dev/null; then
                echo "export DOCKER_HOST=$docker_host" >> ~/.bashrc
                log_success "Added DOCKER_HOST to ~/.bashrc"
            else
                log_info "DOCKER_HOST already exists in ~/.bashrc"
            fi
        else
            log_info "Podman DOCKER_HOST already configured in ~/.bashrc"
        fi
        
        # Export for current session
        export DOCKER_HOST="$docker_host"
        log_success "DOCKER_HOST exported for current session: $DOCKER_HOST"
        
        # Verify socket path exists
        if [[ -S "$socket_path" ]]; then
            log_success "Podman socket file exists: $socket_path"
        else
            log_warning "Socket file not found: $socket_path"
            log_info "You may need to start the socket manually with: systemctl --user start podman.socket"
        fi
        
    else
        # Root configuration
        log_info "Configuring Podman for root user..."
        sudo systemctl enable --now podman.socket 2>/dev/null || true
        
        # Wait a moment for socket to start
        sleep 2
        
        # Confirm socket is listening
        echo -e "${GREEN}🔍 Checking Podman socket...${NC}"
        if ss -lx | grep podman >/dev/null 2>&1; then
            log_success "Podman socket is active and listening"
        else
            log_warning "Podman socket not active!"
        fi
        
        # For root, socket is typically at /run/podman/podman.sock
        local docker_host="unix:///run/podman/podman.sock"
        export DOCKER_HOST="$docker_host"
        log_success "DOCKER_HOST exported for current session: $DOCKER_HOST"
    fi
}

# Setup Docker compatibility aliases
configure_docker_compatibility() {
    log_section "Docker Compatibility Setup"
    
    # Create docker alias if it doesn't exist
    if ! grep -q 'alias docker=' ~/.bashrc 2>/dev/null; then
        echo 'alias docker=podman' >> ~/.bashrc
        log_success "Added docker=podman alias to ~/.bashrc"
    else
        log_info "Docker alias already exists in ~/.bashrc"
    fi
    
    # Add other useful aliases
    if ! grep -q 'alias docker-compose=' ~/.bashrc 2>/dev/null; then
        echo 'alias docker-compose=podman-compose' >> ~/.bashrc
        log_success "Added docker-compose=podman-compose alias to ~/.bashrc"
    else
        log_info "Docker-compose alias already exists in ~/.bashrc"
    fi
}

# Main execution
main() {
    log_info "⚙️  Configuring Podman with template rendering..."
    
    load_env
    configure_registries
    configure_security_policy
    configure_containers_conf
    configure_podman_socket
    configure_docker_compatibility
    
    log_success "Podman configuration completed successfully!"
    
    echo ""
    log_info "📋 Configuration Summary:"
    echo "  ✅ Container registries configured"
    echo "  ✅ Security policy installed"
    echo "  ✅ Docker compatibility enabled"
    echo "  ✅ Podman socket configured"
    echo "  ✅ Shell aliases added"
    echo ""
    log_info "🔄 Next steps:"
    echo "  • Restart your shell or run: source ~/.bashrc"
    echo "  • Test with: podman --version"
    echo "  • Test Docker compatibility: docker --version"
    echo ""
    log_warning "💡 Note: All configuration files are now templated and can use environment variables"
}

main "$@"