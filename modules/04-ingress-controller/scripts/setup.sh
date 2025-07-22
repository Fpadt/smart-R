#!/bin/bash
set -euo pipefail

# ==============================================================================
# Ingress Controller MODULE SCRIPT
# ==============================================================================

# Source common functions library
source "$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")/lib/common.sh"


# Colors for output






# Function to run script with error handling
run_script() {
    local script_name="$1"
    local script_path="$SCRIPT_DIR/$script_name"
    
    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        return 1
    fi
    
    if [[ ! -x "$script_path" ]]; then
        log_info "Making $script_name executable..."
        chmod +x "$script_path"
    fi
    
    log_section "Running $script_name"
    if bash "$script_path"; then
        log_success "$script_name completed successfully"
        return 0
    else
        log_error "$script_name failed with exit code $?"
        return 1
    fi
}

# Main setup function
main() {
    log_section "🚀 Traefik Ingress Controller Setup Process Starting"
    
    local scripts=(
        "01-prepare-traefik.sh"
        "02-install-traefik.sh" 
        "03-configure-traefik.sh"
        "04-verify-traefik.sh"
    )
    
    local failed_scripts=()
    
    for script in "${scripts[@]}"; do
        if ! run_script "$script"; then
            failed_scripts+=("$script")
            
            # Ask user if they want to continue
            echo ""
            read -p "Do you want to continue with the next script? (y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_error "Setup aborted by user"
                exit 1
            fi
        fi
        echo ""
    done
    
    # Summary
    log_section "📋 Setup Summary"
    if [[ ${#failed_scripts[@]} -eq 0 ]]; then
        log_success "All scripts completed successfully!"
        log_info "🚀 Your Traefik ingress controller is now installed and configured"
        echo ""
        log_info "🎯 What's been set up:"
        echo "  ✅ Traefik deployed with Let's Encrypt SSL"
        echo "  ✅ Cloudflare DNS challenge configured"
        echo "  ✅ Security middlewares applied"
        echo "  ✅ HTTP to HTTPS redirect enabled"
        echo "  ✅ Dashboard configured (if enabled)"
        echo "  ✅ LoadBalancer service with external IP"
        echo ""
        log_info "🔄 Next steps:"
        echo "  • Configure DNS records to point to your LoadBalancer IP"
        echo "  • Deploy applications with ingress resources"
        echo "  • Use ./05-manage-traefik.sh for ongoing management"
        echo ""
        log_info "📋 Management commands:"
        echo "  • Status: ./05-manage-traefik.sh status"
        echo "  • Logs: ./05-manage-traefik.sh logs-follow"
        echo "  • Test: ./05-manage-traefik.sh test your-domain.com"
        echo "  • Backup: ./05-manage-traefik.sh backup"
    else
        log_error "The following scripts failed:"
        for script in "${failed_scripts[@]}"; do
            echo "  - $script"
        done
        echo ""
        log_info "You can:"
        echo "  • Fix the issues and re-run individual scripts"
        echo "  • Use ./05-manage-traefik.sh for troubleshooting"
        exit 1
    fi
}

# Parse arguments
case "${1:-}" in
    -h|--help)
        echo "Traefik Ingress Controller Setup Script"
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  -h, --help    Show this help message"
        echo ""
        echo "This script runs the following in sequence:"
        echo "  1. 01-prepare-traefik.sh    - Verify prerequisites and prepare environment"
        echo "  2. 02-install-traefik.sh    - Install Traefik via Helm with SSL config"
        echo "  3. 03-configure-traefik.sh  - Configure security middlewares and ingress"
        echo "  4. 04-verify-traefik.sh     - Verify installation and functionality"
        echo ""
        echo "Required files:"
        echo "  - .env                      - Environment variables"
        echo "  - templates/traefik-values.yaml - Helm values template"
        echo ""
        echo "Prerequisites:"
        echo "  • K3s cluster running and accessible"
        echo "  • Helm 3.x installed"
        echo "  • kubectl configured"
        echo "  • Cloudflare API token (for DNS challenge)"
        echo "  • Domain names configured in .env"
        echo ""
        echo "Post-installation management:"
        echo "  • Use ./05-manage-traefik.sh for ongoing operations"
        echo "  • Monitor with: kubectl logs -n traefik -l app.kubernetes.io/name=traefik -f"
        exit 0
        ;;
esac

