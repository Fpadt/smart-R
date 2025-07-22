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
    
    # Set defaults for missing variables
    TRAEFIK_API_DEBUG="${TRAEFIK_API_DEBUG:-false}"
    TRAEFIK_API_INSECURE="${TRAEFIK_API_INSECURE:-false}"
    TRAEFIK_CPU_REQUEST="${TRAEFIK_CPU_REQUEST:-100m}"
    TRAEFIK_CPU_LIMIT="${TRAEFIK_CPU_LIMIT:-200m}"
    TRAEFIK_MEMORY_REQUEST="${TRAEFIK_MEMORY_REQUEST:-128Mi}"
    TRAEFIK_MEMORY_LIMIT="${TRAEFIK_MEMORY_LIMIT:-256Mi}"
    
    log_info "Environment variables loaded"
    log_info "Primary domain: $DOMAIN_PRIMARY"
    log_info "Traefik namespace: $TRAEFIK_NAMESPACE"
    log_info "Public IP: $PUBLIC_IP"
}

# Enhanced render function
render_template() {
    local template="$1"
    local target="$2"
    local backup_enabled="${3:-true}"
    
    local template_path="$SCRIPT_DIR/templates/$template"
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template not found: $template_path"
        exit 1
    fi
    
    # Create target directory
    mkdir -p "$(dirname "$target")" 2>/dev/null || sudo mkdir -p "$(dirname "$target")"
    
    # Backup existing file if it exists and backup is enabled
    if [[ "$backup_enabled" == "true" && -f "$target" ]]; then
        local timestamp=$(date +%Y%m%d-%H%M%S)
        local backup="$target.backup.$timestamp"
        log_info "Backing up existing $target to $backup"
        cp "$target" "$backup" 2>/dev/null || sudo cp "$target" "$backup"
    fi
    
    # Render template
    log_info "Rendering templates/$template -> $target"
    
    if envsubst < "$template_path" > "$target"; then
        log_success "Successfully deployed $target"
        
        # Show which variables were substituted
        local vars_found
        vars_found=$(grep -o '\${[^}]*}' "$template_path" 2>/dev/null | sort -u || true)
        if [[ -n "$vars_found" ]]; then
            log_info "Variables substituted: $(echo "$vars_found" | tr '\n' ' ')"
        fi
    else
        log_error "Failed to render template $template"
        exit 1
    fi
}

# Verify prerequisites
verify_prerequisites() {
    log_section "Prerequisites Verification"
    
    # Check if we're in the right directory
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        log_error "Not in Traefik directory or .env file missing"
        exit 1
    fi
    
    # Check if 01-prepare-traefik.sh was run
    if ! helm repo list | grep -q traefik; then
        log_error "Traefik Helm repository not found"
        log_info "Please run ./01-prepare-traefik.sh first"
        exit 1
    fi
    
    # Check if namespace exists
    if ! kubectl get namespace "$TRAEFIK_NAMESPACE" >/dev/null 2>&1; then
        log_error "Namespace $TRAEFIK_NAMESPACE not found"
        log_info "Please run ./01-prepare-traefik.sh first"
        exit 1
    fi
    
    # Check for port conflicts (ignore ClusterIP services)
    local conflicting_services
    conflicting_services=$(kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer" or .spec.type == "NodePort") | select(.spec.ports[]?.port == 80 or .spec.ports[]?.port == 443) | "\(.metadata.namespace)/\(.metadata.name): \(.spec.ports[].port)"' 2>/dev/null || true)
    
    if [[ -n "$conflicting_services" ]]; then
        log_warning "Found LoadBalancer/NodePort services using ports 80/443:"
        echo "$conflicting_services"
        
        read -p "Continue with installation anyway? (y/N): " -r response
        if [[ ! $response =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
    else
        log_success "No conflicting LoadBalancer services on ports 80/443"
    fi
    
    # Verify Cloudflare credentials
    log_info "Verifying Cloudflare credentials..."
    if [[ -z "${CF_DNS_API_TOKEN:-}" ]]; then
        log_error "CF_DNS_API_TOKEN not set in .env file"
        exit 1
    fi
    
    # Test Cloudflare API
    if curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $CF_DNS_API_TOKEN" \
        -H "Content-Type: application/json" | grep -q '"success":true'; then
        log_success "Cloudflare DNS API token is valid"
    else
        log_error "Cloudflare DNS API token is invalid or expired"
        exit 1
    fi
    
    log_success "All prerequisites verified"
}

# Render Helm values
prepare_helm_values() {
    log_section "Helm Values Preparation"
    
    local values_file="/tmp/traefik-values.yaml"
    
    # Render the Helm values template
    render_template "traefik-values.yaml" "$values_file" false
    
    # Validate YAML syntax
    if python3 -c "import yaml; yaml.safe_load(open('$values_file'))" 2>/dev/null; then
        log_success "Helm values YAML syntax is valid"
    else
        log_error "Helm values YAML has syntax errors"
        log_info "Check the rendered file: $values_file"
        exit 1
    fi
    
    # Show key configuration
    log_info "Key Traefik configuration:"
    echo "  🌐 Load Balancer IP: $PUBLIC_IP"
    echo "  📧 Let's Encrypt Email: $LETSENCRYPT_EMAIL"
    echo "  🏷️  Primary Domain: $DOMAIN_PRIMARY"
    echo "  📊 Dashboard Enabled: $TRAEFIK_DASHBOARD_ENABLED"
    echo "  🔒 Challenge Type: $ACME_CHALLENGE_TYPE"
    
    # Return just the file path
    echo "$values_file"
}

# Install Traefik
install_traefik() {
    log_section "Traefik Installation"
    
    local values_file="$1"
    
    if [[ ! -f "$values_file" ]]; then
        log_error "Values file not found: $values_file"
        exit 1
    fi
    
    log_info "Installing Traefik with Helm..."
    log_info "Chart: traefik/traefik"
    log_info "Version: $TRAEFIK_VERSION"
    log_info "Namespace: $TRAEFIK_NAMESPACE"
    log_info "Values file: $values_file"
    
    # Build helm command step by step
    local helm_args=(
        "upgrade"
        "--install"
        "traefik"
        "traefik/traefik"
        "--namespace"
        "$TRAEFIK_NAMESPACE"
        "--values"
        "$values_file"
        "--timeout"
        "10m"
        "--wait"
    )
    
    # Add version if not latest
    if [[ "$TRAEFIK_VERSION" != "latest" ]]; then
        helm_args+=("--version" "$TRAEFIK_VERSION")
    fi
    
    log_info "Executing: helm ${helm_args[*]}"
    
    if helm "${helm_args[@]}"; then
        log_success "Traefik installation completed"
    else
        log_error "Traefik installation failed"
        log_info "Check Helm status: helm status traefik -n $TRAEFIK_NAMESPACE"
        log_info "Check values file: cat $values_file"
        exit 1
    fi
}

# Wait for Traefik to be ready
wait_for_traefik() {
    log_section "Deployment Verification"
    
    log_info "Waiting for Traefik deployment to be ready..."
    
    # Wait for deployment to be available
    local retries=30
    while [[ $retries -gt 0 ]]; do
        local ready_replicas
        ready_replicas=$(kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired_replicas
        desired_replicas=$(kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        
        if [[ "$ready_replicas" == "$desired_replicas" && "$ready_replicas" != "0" ]]; then
            log_success "Traefik deployment is ready ($ready_replicas/$desired_replicas replicas)"
            break
        fi
        
        log_info "Waiting for Traefik deployment... ($ready_replicas/$desired_replicas ready, $retries retries left)"
        sleep 10
        ((retries--))
    done
    
    if [[ $retries -eq 0 ]]; then
        log_error "Traefik deployment did not become ready in time"
        log_info "Check deployment status:"
        kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o wide
        kubectl describe deployment traefik -n "$TRAEFIK_NAMESPACE"
        exit 1
    fi
    
    # Wait for LoadBalancer to get an external IP
    log_info "Waiting for LoadBalancer to get external IP..."
    
    retries=20
    while [[ $retries -gt 0 ]]; do
        local external_ip
        external_ip=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "$external_ip" && "$external_ip" != "<none>" ]]; then
            log_success "LoadBalancer assigned external IP: $external_ip"
            break
        fi
        
        log_info "Waiting for external IP assignment... ($retries retries left)"
        sleep 10
        ((retries--))
    done
    
    if [[ $retries -eq 0 ]]; then
        log_warning "LoadBalancer did not get external IP in expected time"
        log_info "This might be normal depending on your cloud provider"
    fi
}

# Show installation status
show_status() {
    log_section "Installation Status"
    
    # Show deployment status
    log_info "Traefik deployment status:"
    kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o wide
    
    # Show service status
    log_info "Traefik service status:"
    kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o wide
    
    # Show pods
    log_info "Traefik pods:"
    kubectl get pods -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik -o wide
    
    # Show Helm release info
    log_info "Helm release status:"
    helm status traefik -n "$TRAEFIK_NAMESPACE"
    
    # Check if dashboard is accessible (if enabled)
    if [[ "${TRAEFIK_DASHBOARD_ENABLED}" == "true" ]]; then
        log_info "Dashboard access (if configured):"
        echo "  🌐 Dashboard URL: https://$TRAEFIK_DASHBOARD_DOMAIN"
        echo "  ℹ️  Note: You need to configure DNS and ingress for dashboard access"
    fi
}

# Clean up temporary files
cleanup() {
    log_info "Cleaning up temporary files..."
    rm -f /tmp/traefik-values.yaml 2>/dev/null || true
    log_success "Cleanup completed"
}

# Main execution
main() {
    log_info "🚀 Installing Traefik ingress controller..."
    
    load_env
    verify_prerequisites
    
    # Prepare values file first
    local values_file
    values_file=$(prepare_helm_values)
    
    # Then install with the values file
    install_traefik "$values_file"
    wait_for_traefik
    show_status
    cleanup
    
    log_success "Traefik installation completed successfully!"
    
    echo ""
    log_warning "🎯 Installation Summary:"
    echo "  ✅ Traefik deployed in namespace: $TRAEFIK_NAMESPACE"
    echo "  ✅ LoadBalancer service created"
    echo "  ✅ Let's Encrypt configured for: $DOMAIN_PRIMARY"
    echo "  ✅ Cloudflare DNS challenge configured"
    echo "  ✅ Dashboard enabled: $TRAEFIK_DASHBOARD_ENABLED"
    
    echo ""
    log_info "🔄 Next steps:"
    echo "  • Run ./03-configure-traefik.sh to set up ingress and SSL"
    echo "  • Configure DNS records to point to your LoadBalancer IP"
    echo "  • Deploy test applications to verify ingress functionality"
    echo "  • Check Traefik logs: kubectl logs -n $TRAEFIK_NAMESPACE -l app.kubernetes.io/name=traefik"
    
    echo ""
    log_warning "📋 Important notes:"
    echo "  • DNS propagation may take a few minutes"
    echo "  • Let's Encrypt certificates will be requested automatically"
    echo "  • Monitor certificate status in Traefik dashboard"
}

main "$@"