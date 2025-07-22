#!/bin/bash
set -euo pipefail

# Source common functions library
source "../../../lib/common.sh"

# Get directories using common functions
SCRIPT_DIR=$(get_script_dir)
MODULE_DIR=$(get_module_dir)

# Check K3s cluster health
check_k3s_cluster() {
    log_section "K3s Cluster Health Check"
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found - ensure K3s is installed"
        exit 1
    fi
    
    # Check cluster connectivity
    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to K3s cluster"
        log_info "Ensure K3s is running: sudo systemctl status k3s"
        exit 1
    fi
    
    # Check node status
    local node_status
    node_status=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    
    if [[ "$node_status" != "True" ]]; then
        log_error "K3s node is not ready"
        kubectl get nodes
        exit 1
    fi
    
    local node_name
    node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    log_success "K3s cluster is healthy (node: $node_name)"
    
    # Check system pods
    log_info "Checking system pods..."
    local system_pods_ready
    system_pods_ready=$(kubectl get pods -n kube-system --no-headers | grep -v Completed | grep "1/1\|2/2\|3/3" | wc -l)
    local total_system_pods
    total_system_pods=$(kubectl get pods -n kube-system --no-headers | grep -v Completed | wc -l)
    
    if [[ $system_pods_ready -eq $total_system_pods ]]; then
        log_success "All system pods are ready ($system_pods_ready/$total_system_pods)"
    else
        log_warning "Some system pods are not ready ($system_pods_ready/$total_system_pods)"
        kubectl get pods -n kube-system | grep -v Completed
    fi
}

# Check Helm prerequisites
check_helm() {
    log_section "Helm Prerequisites"
    
    # Check if Helm is installed
    if ! command -v helm &> /dev/null; then
        log_error "Helm not found - ensure Helm is installed"
        log_info "Install with: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        exit 1
    fi
    
    # Check Helm version
    local helm_version
    helm_version=$(helm version --short)
    log_success "Helm is available ($helm_version)"
    
    # Test Helm connectivity (should work immediately)
    log_info "Testing Helm connectivity to K3s cluster..."
    if helm list -A &> /dev/null; then
        log_success "Helm can connect to K3s cluster"
    else
        log_error "Helm cannot connect to K3s cluster"
        log_error "This indicates kubectl/Helm was not properly configured during K3s installation"
        log_info "Current kubeconfig status:"
        ls -la ~/.kube/config 2>/dev/null || echo "  ❌ ~/.kube/config not found"
        log_info "Possible fixes:"
        echo "  1. Re-run K3s installation with proper kubectl setup"
        echo "  2. Or manually fix: sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown \$USER:\$USER ~/.kube/config"
        exit 1
    fi
}

# Verify Cloudflare credentials
verify_cloudflare() {
    log_section "Cloudflare Credentials Verification"
    
    # Check required environment variables
    if [[ -z "${CF_DNS_API_TOKEN:-}" ]]; then
        log_error "CF_DNS_API_TOKEN not set in .env file"
        exit 1
    fi
    
    if [[ -z "${CF_ZONEID_PRIMARY:-}" ]]; then
        log_error "CF_ZONEID_PRIMARY not set in .env file"
        exit 1
    fi
    
    log_info "Testing Cloudflare DNS API token..."
    
    # Test token validity
    local token_test
    if token_test=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $CF_DNS_API_TOKEN" \
        -H "Content-Type: application/json"); then
        
        local token_valid
        token_valid=$(echo "$token_test" | jq -r '.success // false')
        
        if [[ "$token_valid" == "true" ]]; then
            log_success "Cloudflare DNS API token is valid"
        else
            log_error "Cloudflare DNS API token is invalid"
            log_info "Token test response: $token_test"
            exit 1
        fi
    else
        log_error "Failed to test Cloudflare API token"
        exit 1
    fi
    
    # Test zone access
    log_info "Testing access to primary domain zone..."
    local zone_test
    if zone_test=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONEID_PRIMARY" \
        -H "Authorization: Bearer $CF_DNS_API_TOKEN" \
        -H "Content-Type: application/json"); then
        
        local zone_name
        zone_name=$(echo "$zone_test" | jq -r '.result.name // "unknown"')
        
        if [[ "$zone_name" == "$DOMAIN_PRIMARY" ]]; then
            log_success "Can access $DOMAIN_PRIMARY zone"
        else
            log_error "Cannot access $DOMAIN_PRIMARY zone or zone ID mismatch"
            log_info "Expected: $DOMAIN_PRIMARY, Got: $zone_name"
            exit 1
        fi
    else
        log_error "Failed to access Cloudflare zone"
        exit 1
    fi
}

# Create Traefik namespace
create_namespace() {
    log_section "Namespace Preparation"
    
    # Check if namespace already exists
    if kubectl get namespace "$TRAEFIK_NAMESPACE" &> /dev/null; then
        log_success "Namespace $TRAEFIK_NAMESPACE already exists"
    else
        log_info "Creating namespace $TRAEFIK_NAMESPACE..."
        if kubectl create namespace "$TRAEFIK_NAMESPACE"; then
            log_success "Namespace $TRAEFIK_NAMESPACE created"
        else
            log_error "Failed to create namespace $TRAEFIK_NAMESPACE"
            exit 1
        fi
    fi
    
    # Label namespace for network policies (if applicable)
    if kubectl label namespace "$TRAEFIK_NAMESPACE" name="$TRAEFIK_NAMESPACE" --overwrite &> /dev/null; then
        log_success "Namespace labeled for network policies"
    else
        log_warning "Could not label namespace (non-critical)"
    fi
}

# Add Traefik Helm repository
setup_helm_repo() {
    log_section "Helm Repository Setup"
    
    # Add Traefik repository
    log_info "Adding Traefik Helm repository..."
    if helm repo add traefik https://traefik.github.io/charts; then
        log_success "Traefik Helm repository added"
    else
        log_error "Failed to add Traefik Helm repository"
        exit 1
    fi
    
    # Update repositories
    log_info "Updating Helm repositories..."
    if helm repo update; then
        log_success "Helm repositories updated"
    else
        log_warning "Failed to update Helm repositories"
    fi
    
    # Verify Traefik chart is available
    log_info "Verifying Traefik chart availability..."
    if helm search repo traefik/traefik &> /dev/null; then
        local chart_version
        chart_version=$(helm search repo traefik/traefik -o json | jq -r '.[0].version')
        log_success "Traefik chart available (version: $chart_version)"
    else
        log_error "Traefik chart not found in repository"
        exit 1
    fi
}

# Verify templates directory
check_templates() {
    log_section "Template Files Verification"
    
    local templates_dir="$MODULE_DIR/templates"
    
    if [[ ! -d "$templates_dir" ]]; then
        log_error "Templates directory not found: $templates_dir"
        exit 1
    fi
    
    # Check for required template files
    local required_templates=(
        "traefik-values.yaml"
    )
    
    for template in "${required_templates[@]}"; do
        if [[ -f "$templates_dir/$template" ]]; then
            log_success "Template found: $template"
        else
            log_warning "Template not found: $template (will be needed for installation)"
        fi
    done
}

# Check if Traefik is already installed
check_existing_traefik() {
    log_section "Existing Traefik Check"
    
    # Check for existing Traefik installation
    if helm list -n "$TRAEFIK_NAMESPACE" | grep -q traefik; then
        log_warning "Traefik appears to be already installed"
        helm list -n "$TRAEFIK_NAMESPACE"
        echo ""
        log_info "If you want to reinstall, run: helm uninstall traefik -n $TRAEFIK_NAMESPACE"
        
        read -p "Continue with existing installation? (Y/n): " -r response
        if [[ ${response:-y} =~ ^[Yy]$ ]]; then
            log_info "Continuing with existing Traefik installation"
        else
            log_info "Aborting - please remove existing installation first"
            exit 0
        fi
    else
        log_success "No existing Traefik installation found"
    fi
    
    # Check for conflicting services on ports 80/443
    local conflicting_services
    conflicting_services=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.ports[*].port}{"\n"}{end}' | grep -E "(^|\s)(80|443)(\s|$)" | grep -v "$TRAEFIK_NAMESPACE" || true)
    
    if [[ -n "$conflicting_services" ]]; then
        log_warning "Found services using ports 80/443:"
        echo "$conflicting_services"
        log_info "These may conflict with Traefik LoadBalancer"
    else
        log_success "No conflicting services found on ports 80/443"
    fi
}

# Main execution
main() {
    log_info "🚀 Preparing Traefik installation prerequisites..."
    
    load_env
    check_k3s_cluster
    check_helm
    verify_cloudflare
    create_namespace
    setup_helm_repo
    check_templates
    check_existing_traefik
    
    log_success "Traefik prerequisites check completed successfully!"
    
    echo ""
    log_info "📋 Prerequisites Summary:"
    echo "  ✅ K3s cluster is healthy and ready"
    echo "  ✅ Helm is installed and can connect to cluster"
    echo "  ✅ Cloudflare DNS API token is valid and working"
    echo "  ✅ Namespace '$TRAEFIK_NAMESPACE' is ready"
    echo "  ✅ Traefik Helm repository added and updated"
    echo "  ✅ No conflicting installations detected"
    
    echo ""
    log_info "🔄 Next steps:"
    echo "  • Ensure traefik-values.yaml template exists in templates/"
    echo "  • Run ./02-install-traefik.sh to install Traefik"
    echo "  • All prerequisites are ready for installation"
}

main "$@"