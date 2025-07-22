#!/bin/bash
# ==============================================================================
# COMMON FUNCTIONS LIBRARY - lib/common.sh
# ==============================================================================

# Prevent multiple sourcing
if [[ "${COMMON_FUNCTIONS_LOADED:-}" == "true" ]]; then
    return 0
fi
export COMMON_FUNCTIONS_LOADED=true

# Colors
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# Logging functions
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

# Environment loading
# Environment loading with smart path detection
load_env() {
    local env_file="$1"
    
    # If no file specified, auto-detect based on calling script location
    if [[ -z "$env_file" ]]; then
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        
        # If calling script is in a 'scripts' subdirectory, go up one level
        if [[ "$(basename "$script_dir")" == "scripts" ]]; then
            env_file="$(dirname "$script_dir")/.env"
        else
            env_file="$script_dir/.env"
        fi
    fi
    
    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found at $env_file"
        return 1
    fi
    
    # Enhanced syntax checking with better error message
    if ! bash -n "$env_file" 2>/dev/null; then
        log_error ".env file has syntax errors"
        log_info "Check your .env file for syntax issues (quotes, spaces, special characters, etc.)"
        log_info "Common issues: unquoted values with spaces, missing quotes, invalid variable names"
        return 1
    fi
    
    set -a
    source "$env_file"
    set +a
    
    log_success "Environment variables loaded from $env_file"
    return 0
}

# Template rendering
render_template() {
    local template="$1"
    local target="$2"
    local backup_enabled="${3:-true}"
    
    if [[ ! -f "$template" ]]; then
        log_error "Template not found: $template"
        return 1
    fi
    
    if [[ "$backup_enabled" == "true" && -f "$target" ]]; then
        local backup="${target}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "$target" "$backup"
        log_info "Backed up $target to $backup"
    fi
    
    mkdir -p "$(dirname "$target")"
    
    if envsubst < "$template" > "$target"; then
        log_success "Template rendered: $template -> $target"
        return 0
    else
        log_error "Failed to render template: $template"
        return 1
    fi
}

export -f log_info log_success log_warning log_error log_section
export -f load_env render_template
