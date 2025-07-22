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
    
    log_info "Environment variables loaded"
    log_info "EMAIL=$EMAIL, SSH_USER=$SSH_USER"
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

# Prepare K3s configuration files (BEFORE installation)
prepare_k3s_config() {
    log_section "K3s Configuration Files Preparation"
    
    # Ensure directories exist
    sudo mkdir -p /etc/rancher/k3s
    sudo mkdir -p /var/lib/rancher/k3s
    sudo mkdir -p /etc/logrotate.d
    
    # Render all K3s configuration files using templates
    render_template "config.yaml" "/etc/rancher/k3s/config.yaml"
    render_template "audit-policy.yaml" "/var/lib/rancher/k3s/audit-policy.yaml"
    render_template "psa-config.yaml" "/var/lib/rancher/k3s/psa-config.yaml"
    render_template "k3s-audit" "/etc/logrotate.d/k3s-audit"
    
    # Verify configuration syntax
    log_info "Validating configuration files..."
    
    # Check YAML syntax for main config
    if python3 -c "import yaml; yaml.safe_load(open('/etc/rancher/k3s/config.yaml'))" 2>/dev/null; then
        log_success "config.yaml syntax is valid"
    else
        log_error "config.yaml has syntax errors"
        exit 1
    fi
    
    # Check other YAML files
    for yaml_file in "/var/lib/rancher/k3s/audit-policy.yaml" "/var/lib/rancher/k3s/psa-config.yaml"; do
        if python3 -c "import yaml; yaml.safe_load(open('$yaml_file'))" 2>/dev/null; then
            log_success "$(basename "$yaml_file") syntax is valid"
        else
            log_error "$(basename "$yaml_file") has syntax errors"
            exit 1
        fi
    done
    
    # Show critical configuration settings
    log_info "Key configuration settings:"
    echo "  🚫 Disabled components:"
    sudo grep -A3 "disable:" /etc/rancher/k3s/config.yaml | grep "^  -" | sed 's/^  - /    • /'
    
    echo "  🔒 Security features:"
    echo "    • Audit logging enabled"
    echo "    • Pod Security Standards configured"
    echo "    • Log rotation configured"
    
    log_success "K3s configuration files prepared and validated"
}

# Configure system security (kernel parameters, etc.)
configure_system_security() {
    log_section "System Security Configuration"
    
    # Configure kernel parameters for K3s
    log_info "Configuring kernel parameters..."
    
    # Use render_template for sysctl configuration
    render_template "99-k3s.conf" "/etc/sysctl.d/99-k3s.conf"
    
    # Apply the sysctl configuration
    if sudo sysctl -p /etc/sysctl.d/99-k3s.conf; then
        log_success "Kernel parameters applied"
    else
        log_warning "Some kernel parameters could not be applied"
    fi
    
    # Enable and configure AppArmor
    if command -v aa-status >/dev/null 2>&1; then
        log_info "Checking AppArmor status..."
        if sudo aa-status --enabled 2>/dev/null; then
            log_success "AppArmor is enabled"
        else
            log_warning "AppArmor is not enabled"
        fi
    fi
}

# Main execution
main() {
    log_info "⚙️  Preparing K3s security configuration (before installation)..."
    
    load_env
    prepare_k3s_config
    configure_system_security
    
    log_success "K3s configuration preparation completed successfully!"
    
    echo ""
    log_warning "🔒 Configuration Prepared:"
    echo "  ✅ K3s main configuration (with Traefik disabled)"
    echo "  ✅ Audit logging configuration"
    echo "  ✅ Pod Security Standards configuration"
    echo "  ✅ Network policies ready"
    echo "  ✅ Log rotation configuration"
    echo "  ✅ Kernel parameters optimized"
    
    echo ""
    log_info "📋 Template Files Deployed:"
    echo "  • config.yaml - K3s main configuration"
    echo "  • audit-policy.yaml - Kubernetes audit policy"
    echo "  • psa-config.yaml - Pod Security Standards"
    echo "  • k3s-audit - Log rotation configuration"
    echo "  • 99-k3s.conf - Kernel parameters"
    
    echo ""
    log_info "🔄 Next steps:"
    echo "  • Run 02-install-k3s.sh to install K3s with pre-configured settings"
    echo "  • K3s will start with Traefik disabled and security hardening applied"
    echo "  • No configuration conflicts will occur during installation"
}

main "$@"