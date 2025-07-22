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
        echo "HOME_IP=your.home.ip.address"
        echo "EMAIL=your@email.com"
        echo "SSH_USER=your_ssh_user"
        echo "SSH_PORT=your_ssh_port"
        exit 1
    fi
    
    log_success ".env file found"
    
    # Load and validate variables
    set -a
    source "$env_file"
    set +a
    
    local missing_vars=()
    [[ -z "${HOME_IP:-}" ]] && missing_vars+=("HOME_IP")
    [[ -z "${EMAIL:-}" ]] && missing_vars+=("EMAIL")
    [[ -z "${SSH_USER:-}" ]] && missing_vars+=("SSH_USER")
    [[ -z "${SSH_PORT:-}" ]] && missing_vars+=("SSH_PORT")
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required variables in .env:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        exit 1
    fi
    
    log_info "Environment variables loaded:"
    echo "  HOME_IP=$HOME_IP"
    echo "  EMAIL=$EMAIL"
    echo "  SSH_USER=$SSH_USER"
    echo "  SSH_PORT=$SSH_PORT"
}

# Check template files
check_templates() {
    log_info "Checking for required template files..."
    
    local templates=(
        "nftables.conf"
        "fail2ban-jail.local"
        "sshd_config"
        "postfix-main.cf"
        "50unattended-upgrades"
        "20auto-upgrades"
        "99-system-overview"
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

# Check system information
check_system() {
    log_info "System information:"
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "  OS: $NAME $VERSION"
        
        if [[ "$ID" != "ubuntu" ]] || [[ ! "$VERSION_ID" =~ ^24\.04 ]]; then
            log_warning "This script is designed for Ubuntu 24.04 LTS"
            log_warning "Current system: $NAME $VERSION"
            echo ""
            read -p "Continue anyway? (y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    else
        log_warning "Cannot detect OS version"
    fi
    
    echo "  Kernel: $(uname -r)"
    echo "  Architecture: $(uname -m)"
    echo "  User: $(whoami)"
}

# Check existing configurations
check_existing_configs() {
    log_info "Checking existing configuration files..."
    
    local configs=(
        "/etc/nftables.conf"
        "/etc/fail2ban/jail.local"
        "/etc/ssh/sshd_config"
        "/etc/postfix/main.cf"
        "/etc/apt/apt.conf.d/50unattended-upgrades"
        "/etc/apt/apt.conf.d/20auto-upgrades"
        "/etc/update-motd.d/99-system-overview"
    )
    
    local existing_configs=()
    for config in "${configs[@]}"; do
        if [[ -f "$config" ]]; then
            existing_configs+=("$config")
        fi
    done
    
    if [[ ${#existing_configs[@]} -gt 0 ]]; then
        log_warning "Found existing configuration files:"
        for config in "${existing_configs[@]}"; do
            echo "  - $config"
        done
        
        echo ""
        log_warning "These files will be backed up and replaced during configuration"
        read -p "Continue with backup and replacement? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Setup cancelled by user"
            exit 1
        fi
    else
        log_success "No conflicting configuration files found"
    fi
}

# Main execution
main() {
    log_info "🔍 01 - Checking Ubuntu system state and prerequisites..."
    
    check_env_file
    check_templates
    check_system
    check_existing_configs
    
    log_success "System check completed - ready for hardening setup"
}

main "$@"