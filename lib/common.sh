#!/bin/bash
# ==============================================================================
# COMMON FUNCTIONS LIBRARY - lib/common.sh
# ==============================================================================

# Prevent multiple sourcing
if [[ "${COMMON_FUNCTIONS_LOADED:-}" == "true" ]]; then
    return 0
fi
export COMMON_FUNCTIONS_LOADED=true

# ==============================================================================
# DIRECTORY DETECTION AND PATHS
# ==============================================================================

get_project_root() {
    local current_dir="${BASH_SOURCE[1]}"
    while [[ "$current_dir" != "/" ]]; do
        current_dir="$(dirname "$current_dir")"
        if [[ -f "$current_dir/setup.sh" && -d "$current_dir/lib" && -d "$current_dir/modules" ]]; then
            echo "$current_dir"
            return 0
        fi
    done
    echo "$(cd "$(dirname "$(dirname "${BASH_SOURCE[1]}")")" && pwd)"
}

get_script_dir() {
    local calling_script="${BASH_SOURCE[1]}"
    echo "$(cd "$(dirname "${calling_script}")" && pwd)"
}

get_module_dir() {
    local script_dir
    script_dir=$(get_script_dir)
    if [[ "$(basename "$script_dir")" == "scripts" ]]; then
        echo "$(dirname "$script_dir")"
    else
        echo "$script_dir"
    fi
}

get_module_name() {
    local module_dir
    module_dir=$(get_module_dir)
    basename "$module_dir" | sed 's/^[0-9]*-//'
}

# Set up global paths
export PROJECT_ROOT
PROJECT_ROOT=$(get_project_root)
export LIB_DIR="$PROJECT_ROOT/lib"
export CONFIG_DIR="$PROJECT_ROOT/config"
export TOOLS_DIR="$PROJECT_ROOT/tools"
export LOGS_DIR="$PROJECT_ROOT/logs"
export BACKUPS_DIR="$PROJECT_ROOT/backups"

mkdir -p "$LOGS_DIR" "$BACKUPS_DIR" 2>/dev/null || true

# ==============================================================================
# COLOR DEFINITIONS
# ==============================================================================
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export PURPLE='\033[0;35m'
export CYAN='\033[0;36m'
export WHITE='\033[1;37m'
export NC='\033[0m'

# ==============================================================================
# LOGGING FUNCTIONS
# ==============================================================================

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

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${PURPLE}🐛 DEBUG: $1${NC}"
    fi
}

log_fatal() {
    echo -e "${RED}💀 FATAL: $1${NC}"
    exit 1
}

# ==============================================================================
# ENVIRONMENT LOADING FUNCTIONS
# ==============================================================================

load_env() {
    local env_file="${1:-$(get_module_dir)/.env}"
    
    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found at $env_file"
        return 1
    fi
    
    if ! bash -n "$env_file" 2>/dev/null; then
        log_error ".env file has syntax errors"
        return 1
    fi
    
    set -a
    source "$env_file" 2>/dev/null
    set +a
    
    log_success "Environment variables loaded from $env_file"
    return 0
}

load_env_with_validation() {
    local env_file="${1:-$(get_module_dir)/.env}"
    shift
    local required_vars=("$@")
    
    if ! load_env "$env_file"; then
        return 1
    fi
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required variables in .env:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        return 1
    fi
    
    log_success "All required environment variables validated"
    return 0
}

# ==============================================================================
# TEMPLATE RENDERING FUNCTIONS
# ==============================================================================

render_template() {
    local template="$1"
    local target="$2"
    local backup_enabled="${3:-true}"
    local use_sudo="${4:-auto}"
    local module_dir="${5:-$(get_module_dir)}"
    
    local template_path="$module_dir/templates/$template"
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template not found: $template_path"
        return 1
    fi
    
    if [[ "$use_sudo" == "auto" ]]; then
        if [[ ! -w "$(dirname "$target")" ]] || [[ -f "$target" && ! -w "$target" ]]; then
            use_sudo="true"
        else
            use_sudo="false"
        fi
    fi
    
    if [[ "$use_sudo" == "true" ]]; then
        sudo mkdir -p "$(dirname "$target")"
    else
        mkdir -p "$(dirname "$target")"
    fi
    
    if [[ "$backup_enabled" == "true" && -f "$target" ]]; then
        local backup_dir="$BACKUPS_DIR/$(get_module_name)"
        mkdir -p "$backup_dir"
        
        local timestamp=$(date +%Y%m%d-%H%M%S)
        local backup_file="$backup_dir/$(basename "$target").backup.$timestamp"
        
        log_info "Backing up $target to $backup_file"
        if [[ "$use_sudo" == "true" ]]; then
            sudo cp "$target" "$backup_file"
        else
            cp "$target" "$backup_file"
        fi
    fi
    
    log_info "Rendering $template -> $target"
    
    local temp_file="${target}.tmp.$$"
    
    if [[ "$use_sudo" == "true" ]]; then
        if envsubst < "$template_path" | sudo tee "$temp_file" > /dev/null; then
            sudo mv "$temp_file" "$target"
            log_success "Template deployed: $target"
        else
            sudo rm -f "$temp_file"
            log_error "Failed to render template: $template"
            return 1
        fi
    else
        if envsubst < "$template_path" > "$temp_file"; then
            mv "$temp_file" "$target"
            log_success "Template deployed: $target"
        else
            rm -f "$temp_file"
            log_error "Failed to render template: $template"
            return 1
        fi
    fi
    
    return 0
}

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_root() {
    [[ $EUID -eq 0 ]]
}

confirm() {
    local message="${1:-Are you sure?}"
    local default="${2:-N}"
    
    if [[ "$default" =~ ^[Yy]$ ]]; then
        read -p "$message (Y/n): " -r response
        [[ -z "$response" || "$response" =~ ^[Yy]$ ]]
    else
        read -p "$message (y/N): " -r response
        [[ "$response" =~ ^[Yy]$ ]]
    fi
}

validate_yaml() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi
    
    if python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
        log_success "YAML syntax is valid: $file"
        return 0
    else
        log_error "YAML syntax error in: $file"
        return 1
    fi
}

wait_for_condition() {
    local condition="$1"
    local timeout="${2:-30}"
    local interval="${3:-5}"
    local message="${4:-Waiting for condition}"
    
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition"; then
            return 0
        fi
        
        log_info "$message... ($((timeout - elapsed)) seconds remaining)"
        sleep "$interval"
        ((elapsed += interval))
    done
    
    log_error "Timeout waiting for condition: $condition"
    return 1
}

# ==============================================================================
# INITIALIZATION
# ==============================================================================

log_debug "Common functions library loaded successfully"

export -f log_info log_success log_warning log_error log_section log_debug log_fatal
export -f load_env load_env_with_validation
export -f render_template
export -f get_project_root get_script_dir get_module_dir get_module_name
export -f command_exists check_root confirm validate_yaml wait_for_condition
