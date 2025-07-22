#!/bin/bash
set -euo pipefail

# ==============================================================================
# 03-KUBERNETES MODULE SETUP SCRIPT
# ==============================================================================

# Source common functions library
source "$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")/lib/common.sh"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables
load_env "$SCRIPT_DIR/../.env"

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
    log_section "🚀 03-KUBERNETES Module Setup Starting"
    
    # Get all numbered scripts in order
    local scripts=()
    while IFS= read -r -d '' script; do
        scripts+=("$(basename "$script")")
    done < <(find "$SCRIPT_DIR" -name "[0-9][0-9]-*.sh" -type f -print0 | sort -z)
    
    if [[ ${#scripts[@]} -eq 0 ]]; then
        log_warning "No numbered scripts found in $SCRIPT_DIR"
        log_info "Please add scripts like: 01-prepare.sh, 02-install.sh, etc."
        exit 1
    fi
    
    local failed_scripts=()
    
    for script in "${scripts[@]}"; do
        if ! run_script "$script"; then
            failed_scripts+=("$script")
            
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
        log_info "🚀 03-KUBERNETES module is now configured"
    else
        log_error "The following scripts failed:"
        for script in "${failed_scripts[@]}"; do
            echo "  - $script"
        done
        exit 1
    fi
}

# Parse arguments
case "${1:-}" in
    -h|--help)
        echo "03-KUBERNETES Module Setup Script"
        echo "Usage: $0 [options]"
        echo ""
        echo "This script runs all numbered scripts in sequence."
        echo "Scripts are executed in order: 01-*.sh, 02-*.sh, etc."
        exit 0
        ;;
esac

main "$@"
