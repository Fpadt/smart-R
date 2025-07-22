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
    log_info "HOME_IP=$HOME_IP, EMAIL=$EMAIL, SSH_USER=$SSH_USER, SSH_PORT=$SSH_PORT"
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

# Rollback function (bonus feature)
rollback_config() {
    local target="$1"
    
    # Find the most recent backup
    local latest_backup
    latest_backup=$(find "$(dirname "$target")" -name "$(basename "$target").backup.*" -type f 2>/dev/null | sort -t. -k3 | tail -n1)
    
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        log_info "Rolling back $target from $latest_backup"
        if sudo cp "$latest_backup" "$target"; then
            log_success "Rollback completed successfully"
        else
            log_error "Rollback failed"
            exit 1
        fi
    else
        log_error "No backup found for $target"
        exit 1
    fi
}

# Apply configurations
apply_configs() {
    log_section "Configuration Deployment"
    log_info "Applying hardening configurations..."
    
    # Network security
    render_template "nftables.conf" "/etc/nftables.conf"
    
    # Intrusion prevention
    render_template "fail2ban-jail.local" "/etc/fail2ban/jail.local"
    
    # SSH hardening
    render_template "sshd_config" "/etc/ssh/sshd_config"
    
    # Mail configuration
    render_template "postfix-main.cf" "/etc/postfix/main.cf"
    
    # Automatic updates
    render_template "50unattended-upgrades" "/etc/apt/apt.conf.d/50unattended-upgrades"
    render_template "20auto-upgrades" "/etc/apt/apt.conf.d/20auto-upgrades"
    
    # System monitoring
    render_template "99-system-overview" "/etc/update-motd.d/99-system-overview"
    
    # Make MOTD script executable
    sudo chmod +x /etc/update-motd.d/99-system-overview
    
    log_success "All configurations deployed"
}

# Restart services
restart_services() {
    log_section "Service Restart"
    log_info "Restarting services to apply configurations..."
    
    # Restart nftables
    if sudo systemctl restart nftables; then
        log_success "nftables restarted"
    else
        log_warning "Failed to restart nftables"
    fi
    
    # Restart fail2ban
    if sudo systemctl restart fail2ban; then
        log_success "fail2ban restarted"
    else
        log_warning "Failed to restart fail2ban"
    fi
    
    # Test SSH config before restarting
    if sudo sshd -t; then
        log_success "SSH configuration is valid"
        if sudo systemctl restart ssh; then
            log_success "SSH service restarted"
        else
            log_warning "Failed to restart SSH service"
        fi
    else
        log_error "SSH configuration is invalid!"
        log_warning "SSH service not restarted to prevent lockout"
        log_info "Check SSH configuration and run: sudo sshd -t"
    fi
    
    # Restart postfix
    if sudo systemctl restart postfix; then
        log_success "postfix restarted"
    else
        log_warning "Failed to restart postfix"
    fi
    
    # Restart unattended-upgrades
    if sudo systemctl restart unattended-upgrades; then
        log_success "unattended-upgrades restarted"
    else
        log_warning "Failed to restart unattended-upgrades"
    fi
}

# Verify configuration
verify_configs() {
    log_section "Configuration Verification"
    log_info "Verifying deployed configurations..."
    
    # Check nftables
    if sudo nft list ruleset >/dev/null 2>&1; then
        log_success "nftables configuration is valid"
    else
        log_error "nftables configuration has issues"
    fi
    
    # Check fail2ban
    if sudo fail2ban-client status >/dev/null 2>&1; then
        log_success "fail2ban is running"
    else
        log_warning "fail2ban is not running properly"
    fi
    
    # Check SSH
    if sudo sshd -t >/dev/null 2>&1; then
        log_success "SSH configuration is valid"
    else
        log_error "SSH configuration has issues"
    fi
    
    # Check postfix
    if sudo postfix check >/dev/null 2>&1; then
        log_success "postfix configuration is valid"
    else
        log_warning "postfix configuration has issues"
    fi
    
    log_info "Configuration verification completed"
}

# Main execution
main() {
    log_info "⚙️ 03 - Configuring Ubuntu system hardening..."
    
    load_env
    apply_configs
    restart_services
    verify_configs
    
    log_success "System configuration completed successfully!"
    
    echo ""
    log_warning "⚠️  IMPORTANT SECURITY NOTICE:"
    log_warning "SSH is now configured with custom settings (port $SSH_PORT)"
    log_warning "Make sure you can connect with: ssh -p $SSH_PORT $SSH_USER@your-server"
    log_warning "Do NOT close this session until you verify SSH access works!"
    echo ""
    log_info "🔄 Next steps:"
    echo "  • Test SSH connection from another terminal"
    echo "  • Verify firewall rules: sudo nft list ruleset"
    echo "  • Check fail2ban status: sudo fail2ban-client status"
}

main "$@"