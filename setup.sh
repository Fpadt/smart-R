#!/bin/bash
set -euo pipefail

# ==============================================================================
# VPS CONFIGURATION MAIN SETUP SCRIPT
# ==============================================================================

# Source common functions library
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Function to run module setup
run_module() {
    local module="$1"
    local module_path="modules/$module"
    
    if [[ ! -d "$module_path" ]]; then
        log_error "Module not found: $module_path"
        return 1
    fi
    
    local setup_script="$module_path/scripts/setup.sh"
    
    if [[ ! -f "$setup_script" ]]; then
        log_warning "No setup script found for $module"
        return 0
    fi
    
    log_section "Running Module: $module"
    
    if bash "$setup_script"; then
        log_success "Module $module completed successfully"
        return 0
    else
        log_error "Module $module failed"
        return 1
    fi
}

# Main setup function
main() {
    log_section "🚀 VPS Configuration Setup Starting"
    
    local modules=(
        "01-system-hardening"
        "02-container-runtime"
        "03-kubernetes"
        "04-ingress-controller"
        "05-monitoring"
        "06-backup"
        "07-applications"
    )
    
    local failed_modules=()
    
    for module in "${modules[@]}"; do
        if ! run_module "$module"; then
            failed_modules+=("$module")
            
            echo ""
            read -p "Do you want to continue with the next module? (y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_error "Setup aborted by user"
                exit 1
            fi
        fi
        echo ""
    done
    
    # Summary
    log_section "📋 Setup Summary"
    if [[ ${#failed_modules[@]} -eq 0 ]]; then
        log_success "All modules completed successfully!"
        log_info "🚀 Your VPS is now fully configured"
    else
        log_error "The following modules failed:"
        for module in "${failed_modules[@]}"; do
            echo "  - $module"
        done
        exit 1
    fi
}

# Parse arguments
case "${1:-}" in
    -h|--help)
        echo "VPS Configuration Main Setup Script"
        echo "Usage: $0 [options]"
        echo ""
        echo "This script runs all module setup scripts in sequence."
        exit 0
        ;;
esac

main "$@"
