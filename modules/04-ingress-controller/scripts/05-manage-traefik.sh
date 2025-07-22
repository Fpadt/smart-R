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
    if [[ -f "$env_file" ]]; then
        set -a
        source "$env_file"
        set +a
        log_info "Environment loaded"
    else
        log_warning "Could not load .env file"
        TRAEFIK_NAMESPACE="traefik"
    fi
}

# Show current Traefik status
show_status() {
    log_section "Traefik Status Overview"
    
    # Check if Traefik is installed
    if ! helm list -n "$TRAEFIK_NAMESPACE" | grep -q traefik; then
        log_error "Traefik is not installed"
        return 1
    fi
    
    # Helm release info
    log_info "Helm Release Information:"
    helm list -n "$TRAEFIK_NAMESPACE"
    echo ""
    
    # Deployment status
    log_info "Deployment Status:"
    kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o wide
    echo ""
    
    # Service status
    log_info "Service Status:"
    kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o wide
    echo ""
    
    # Pod status
    log_info "Pod Status:"
    kubectl get pods -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik -o wide
    echo ""
    
    # Ingress status
    log_info "Ingress Resources:"
    kubectl get ingress -A | grep -v "No resources found" || echo "No ingress resources found"
    echo ""
    
    # Middleware status
    log_info "Middleware Resources:"
    kubectl get middleware -n "$TRAEFIK_NAMESPACE" 2>/dev/null || echo "No middleware resources found"
}

# Show Traefik logs
show_logs() {
    local lines="${1:-50}"
    local follow="${2:-false}"
    
    log_section "Traefik Logs"
    
    if [[ "$follow" == "true" ]]; then
        log_info "Following Traefik logs (Ctrl+C to exit)..."
        kubectl logs -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik -f --tail="$lines"
    else
        log_info "Showing last $lines lines of Traefik logs:"
        kubectl logs -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik --tail="$lines"
    fi
}

# Show SSL certificate status
show_certificates() {
    log_section "SSL Certificate Status"
    
    # Check ACME storage
    log_info "ACME Storage Status:"
    kubectl get pvc -n "$TRAEFIK_NAMESPACE" | grep traefik || echo "No ACME storage found"
    echo ""
    
    # Check certificate secrets
    log_info "Certificate Secrets:"
    kubectl get secrets -n "$TRAEFIK_NAMESPACE" | grep -E "(tls|cert)" || echo "No certificate secrets found"
    echo ""
    
    # If we have access to the ACME file, show certificate info
    log_info "Checking ACME certificates..."
    local pod_name
    pod_name=$(kubectl get pods -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$pod_name" ]]; then
        kubectl exec -n "$TRAEFIK_NAMESPACE" "$pod_name" -- ls -la /data/ 2>/dev/null || echo "Could not access ACME data directory"
    fi
}

# Restart Traefik deployment
restart_traefik() {
    log_section "Restarting Traefik"
    
    log_warning "This will restart all Traefik pods"
    read -p "Are you sure you want to restart Traefik? (y/N): " -r
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Restarting Traefik deployment..."
        if kubectl rollout restart deployment traefik -n "$TRAEFIK_NAMESPACE"; then
            log_success "Restart initiated"
            
            log_info "Waiting for rollout to complete..."
            if kubectl rollout status deployment traefik -n "$TRAEFIK_NAMESPACE" --timeout=300s; then
                log_success "Traefik restarted successfully"
            else
                log_error "Restart timed out or failed"
            fi
        else
            log_error "Failed to restart Traefik"
        fi
    else
        log_info "Restart cancelled"
    fi
}

# Scale Traefik deployment
scale_traefik() {
    local replicas="$1"
    
    if [[ ! "$replicas" =~ ^[0-9]+$ ]]; then
        log_error "Invalid replica count: $replicas"
        return 1
    fi
    
    log_section "Scaling Traefik"
    
    local current_replicas
    current_replicas=$(kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.spec.replicas}')
    
    log_info "Current replicas: $current_replicas"
    log_info "Target replicas: $replicas"
    
    if [[ "$current_replicas" == "$replicas" ]]; then
        log_info "Traefik is already scaled to $replicas replicas"
        return 0
    fi
    
    read -p "Scale Traefik to $replicas replicas? (y/N): " -r
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Scaling Traefik to $replicas replicas..."
        if kubectl scale deployment traefik -n "$TRAEFIK_NAMESPACE" --replicas="$replicas"; then
            log_success "Scaling initiated"
            
            log_info "Waiting for scaling to complete..."
            if kubectl rollout status deployment traefik -n "$TRAEFIK_NAMESPACE" --timeout=300s; then
                log_success "Traefik scaled successfully to $replicas replicas"
            else
                log_error "Scaling timed out or failed"
            fi
        else
            log_error "Failed to scale Traefik"
        fi
    else
        log_info "Scaling cancelled"
    fi
}

# Update Traefik
update_traefik() {
    local version="${1:-latest}"
    
    log_section "Updating Traefik"
    
    log_info "Current Traefik version:"
    helm list -n "$TRAEFIK_NAMESPACE" | grep traefik
    
    log_warning "This will update Traefik to version: $version"
    read -p "Continue with update? (y/N): " -r
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Updating Helm repository..."
        helm repo update
        
        log_info "Updating Traefik..."
        local helm_args=(
            "upgrade"
            "traefik"
            "traefik/traefik"
            "--namespace"
            "$TRAEFIK_NAMESPACE"
            "--reuse-values"
            "--timeout"
            "10m"
            "--wait"
        )
        
        if [[ "$version" != "latest" ]]; then
            helm_args+=("--version" "$version")
        fi
        
        if helm "${helm_args[@]}"; then
            log_success "Traefik updated successfully"
            
            # Show new status
            log_info "New version:"
            helm list -n "$TRAEFIK_NAMESPACE" | grep traefik
        else
            log_error "Traefik update failed"
        fi
    else
        log_info "Update cancelled"
    fi
}

# Backup Traefik configuration
backup_traefik() {
    local backup_dir="${1:-./traefik-backup-$(date +%Y%m%d-%H%M%S)}"
    
    log_section "Backing Up Traefik Configuration"
    
    log_info "Creating backup directory: $backup_dir"
    mkdir -p "$backup_dir"
    
    # Backup Helm values
    log_info "Backing up Helm values..."
    helm get values traefik -n "$TRAEFIK_NAMESPACE" > "$backup_dir/helm-values.yaml"
    
    # Backup Helm manifest
    log_info "Backing up Helm manifest..."
    helm get manifest traefik -n "$TRAEFIK_NAMESPACE" > "$backup_dir/helm-manifest.yaml"
    
    # Backup custom resources
    log_info "Backing up custom resources..."
    kubectl get middleware -n "$TRAEFIK_NAMESPACE" -o yaml > "$backup_dir/middlewares.yaml" 2>/dev/null || true
    kubectl get ingress -A -o yaml > "$backup_dir/ingresses.yaml" 2>/dev/null || true
    kubectl get ingressroute -A -o yaml > "$backup_dir/ingressroutes.yaml" 2>/dev/null || true
    
    # Backup ACME certificates if possible
    log_info "Backing up ACME certificates..."
    local pod_name
    pod_name=$(kubectl get pods -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$pod_name" ]]; then
        kubectl cp -n "$TRAEFIK_NAMESPACE" "$pod_name:/data/acme.json" "$backup_dir/acme.json" 2>/dev/null || echo "Could not backup ACME certificates"
    fi
    
    # Create backup info
    cat > "$backup_dir/backup-info.txt" << EOF
Traefik Backup Information
==========================
Date: $(date)
Server: $(hostname -f)
Namespace: $TRAEFIK_NAMESPACE
Helm Release: $(helm list -n "$TRAEFIK_NAMESPACE" | grep traefik | awk '{print $1}')
Chart Version: $(helm list -n "$TRAEFIK_NAMESPACE" | grep traefik | awk '{print $9}')
App Version: $(helm list -n "$TRAEFIK_NAMESPACE" | grep traefik | awk '{print $10}')

Files included:
- helm-values.yaml: Helm values used for deployment
- helm-manifest.yaml: Complete Kubernetes manifest
- middlewares.yaml: Custom middleware configurations
- ingresses.yaml: All ingress resources
- ingressroutes.yaml: All IngressRoute resources  
- acme.json: ACME certificates (if accessible)
EOF
    
    log_success "Backup completed: $backup_dir"
    log_info "Backup contents:"
    ls -la "$backup_dir"
}

# Uninstall Traefik
uninstall_traefik() {
    log_section "Uninstalling Traefik"
    
    log_error "⚠️  WARNING: This will completely remove Traefik!"
    log_warning "This will:"
    echo "  • Remove the Helm release"
    echo "  • Delete all Traefik pods and services"
    echo "  • Remove SSL certificates"
    echo "  • Make all ingress resources non-functional"
    echo ""
    
    read -p "Type 'UNINSTALL' to confirm complete removal: " -r confirm
    
    if [[ "$confirm" == "UNINSTALL" ]]; then
        # Create backup first
        log_info "Creating backup before uninstall..."
        backup_traefik "./traefik-backup-before-uninstall-$(date +%Y%m%d-%H%M%S)"
        
        log_info "Uninstalling Traefik Helm release..."
        if helm uninstall traefik -n "$TRAEFIK_NAMESPACE"; then
            log_success "Helm release uninstalled"
        else
            log_error "Failed to uninstall Helm release"
        fi
        
        # Clean up custom resources
        log_info "Cleaning up custom resources..."
        kubectl delete middleware --all -n "$TRAEFIK_NAMESPACE" 2>/dev/null || true
        kubectl delete ingressroute --all -n "$TRAEFIK_NAMESPACE" 2>/dev/null || true
        
        # Ask about namespace removal
        read -p "Remove namespace $TRAEFIK_NAMESPACE? (y/N): " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete namespace "$TRAEFIK_NAMESPACE" || true
        fi
        
        log_success "Traefik uninstallation completed"
        log_warning "Remember to update DNS records and redeploy ingress resources"
    else
        log_info "Uninstall cancelled"
    fi
}

# Test ingress connectivity
test_connectivity() {
    local domain="${1:-}"
    
    log_section "Testing Ingress Connectivity"
    
    if [[ -z "$domain" ]]; then
        domain="${DOMAIN_PRIMARY:-}"
    fi
    
    if [[ -z "$domain" ]]; then
        log_error "No domain specified and DOMAIN_PRIMARY not set"
        log_info "Usage: $0 test <domain.com>"
        return 1
    fi
    
    log_info "Testing connectivity to: $domain"
    
    # Test DNS resolution
    log_info "Testing DNS resolution..."
    if resolved_ip=$(dig +short "$domain" 2>/dev/null | tail -1); then
        if [[ -n "$resolved_ip" ]]; then
            log_success "Domain resolves to: $resolved_ip"
        else
            log_error "Domain does not resolve"
            return 1
        fi
    else
        log_error "DNS lookup failed"
        return 1
    fi
    
    # Test HTTP connection
    log_info "Testing HTTP connection..."
    if http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://$domain" 2>/dev/null); then
        log_info "HTTP response code: $http_code"
        if [[ "$http_code" == "301" || "$http_code" == "308" ]]; then
            log_success "HTTP to HTTPS redirect working"
        fi
    else
        log_warning "HTTP connection failed"
    fi
    
    # Test HTTPS connection
    log_info "Testing HTTPS connection..."
    if https_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://$domain" 2>/dev/null); then
        log_success "HTTPS response code: $https_code"
    else
        log_warning "HTTPS connection failed"
    fi
    
    # Test SSL certificate
    log_info "Testing SSL certificate..."
    if openssl s_client -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
        log_success "SSL certificate is valid"
        
        # Show certificate details
        cert_info=$(openssl s_client -connect "$domain:443" -servername "$domain" </dev/null 2>/dev/null | openssl x509 -noout -dates -subject -issuer 2>/dev/null)
        echo "$cert_info"
    else
        log_warning "SSL certificate validation failed"
    fi
}

# Show help
show_help() {
    echo "Traefik Management Script"
    echo "========================"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status              Show Traefik status overview"
    echo "  logs [lines]        Show Traefik logs (default: 50 lines)"
    echo "  logs-follow [lines] Follow Traefik logs in real-time"
    echo "  certs               Show SSL certificate status"
    echo "  restart             Restart Traefik deployment"
    echo "  scale <replicas>    Scale Traefik to N replicas"
    echo "  update [version]    Update Traefik (default: latest)"
    echo "  backup [directory]  Backup Traefik configuration"
    echo "  uninstall           Completely remove Traefik"
    echo "  test [domain]       Test ingress connectivity"
    echo ""
    echo "Examples:"
    echo "  $0 status                    # Show current status"
    echo "  $0 logs 100                  # Show last 100 log lines"
    echo "  $0 logs-follow               # Follow logs in real-time"
    echo "  $0 scale 3                   # Scale to 3 replicas"
    echo "  $0 update v3.0.0            # Update to specific version"
    echo "  $0 backup /tmp/traefik-bak   # Backup to specific directory"
    echo "  $0 test example.com          # Test connectivity to domain"
}

# Main execution
main() {
    local command="${1:-}"
    
    if [[ -z "$command" ]]; then
        show_help
        exit 0
    fi
    
    load_env
    
    case "$command" in
        status)
            show_status
            ;;
        logs)
            show_logs "${2:-50}" false
            ;;
        logs-follow)
            show_logs "${2:-50}" true
            ;;
        certs|certificates)
            show_certificates
            ;;
        restart)
            restart_traefik
            ;;
        scale)
            if [[ -z "${2:-}" ]]; then
                log_error "Replica count required"
                echo "Usage: $0 scale <replicas>"
                exit 1
            fi
            scale_traefik "$2"
            ;;
        update)
            update_traefik "${2:-latest}"
            ;;
        backup)
            backup_traefik "${2:-}"
            ;;
        uninstall)
            uninstall_traefik
            ;;
        test)
            test_connectivity "${2:-}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"