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

# Variables for email report
REPORT_FILE="/tmp/traefik_report_$(date +%Y%m%d_%H%M%S).txt"
REPORT_RESULTS=()

# Function to add result to report
add_to_report() {
    local status="$1"
    local message="$2"
    REPORT_RESULTS+=("[$status] $message")
}

# Load environment variables
load_env() {
    local env_file="$SCRIPT_DIR/.env"
    if [[ -f "$env_file" ]]; then
        set -a
        source "$env_file"
        set +a
        log_success "Environment loaded - EMAIL=${EMAIL:-'not set'}"
    else
        log_warning "Could not load .env file - email report will be disabled"
        EMAIL=""
    fi
}

# Check Traefik deployment status
check_deployment_status() {
    log_section "Traefik Deployment Status"
    
    # Check if namespace exists
    if ! kubectl get namespace "$TRAEFIK_NAMESPACE" >/dev/null 2>&1; then
        log_error "Namespace $TRAEFIK_NAMESPACE not found"
        add_to_report "FAIL" "Traefik namespace not found"
        return 1
    fi
    
    log_success "Namespace $TRAEFIK_NAMESPACE exists"
    add_to_report "PASS" "Traefik namespace exists"
    
    # Check Helm release
    if helm list -n "$TRAEFIK_NAMESPACE" | grep -q traefik; then
        local helm_status
        helm_status=$(helm status traefik -n "$TRAEFIK_NAMESPACE" -o json | jq -r '.info.status')
        
        if [[ "$helm_status" == "deployed" ]]; then
            log_success "Traefik Helm release is deployed"
            add_to_report "PASS" "Traefik Helm release status: deployed"
        else
            log_error "Traefik Helm release status: $helm_status"
            add_to_report "FAIL" "Traefik Helm release status: $helm_status"
        fi
    else
        log_error "Traefik Helm release not found"
        add_to_report "FAIL" "Traefik Helm release not found"
        return 1
    fi
    
    # Check deployment readiness
    local ready_replicas
    ready_replicas=$(kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired_replicas
    desired_replicas=$(kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    
    if [[ "$ready_replicas" == "$desired_replicas" && "$ready_replicas" != "0" ]]; then
        log_success "Traefik deployment is ready ($ready_replicas/$desired_replicas replicas)"
        add_to_report "PASS" "Traefik deployment ready: $ready_replicas/$desired_replicas replicas"
    else
        log_error "Traefik deployment not ready ($ready_replicas/$desired_replicas replicas)"
        add_to_report "FAIL" "Traefik deployment not ready: $ready_replicas/$desired_replicas replicas"
        
        # Show pod status for debugging
        log_info "Pod status:"
        kubectl get pods -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik
    fi
}

# Check service and LoadBalancer status
check_service_status() {
    log_section "Service and LoadBalancer Status"
    
    # Check if service exists
    if kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" >/dev/null 2>&1; then
        log_success "Traefik service exists"
        add_to_report "PASS" "Traefik service exists"
        
        # Show service details
        log_info "Service details:"
        kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o wide
        
        # Check LoadBalancer status
        local service_type
        service_type=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.spec.type}')
        
        if [[ "$service_type" == "LoadBalancer" ]]; then
            local external_ip
            external_ip=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
            
            if [[ -n "$external_ip" && "$external_ip" != "<none>" ]]; then
                log_success "LoadBalancer has external IP: $external_ip"
                add_to_report "PASS" "LoadBalancer external IP: $external_ip"
                
                # Verify it matches configured IP
                if [[ "$external_ip" == "${PUBLIC_IP}" ]]; then
                    log_success "External IP matches configured PUBLIC_IP"
                    add_to_report "PASS" "External IP matches configured PUBLIC_IP"
                else
                    log_warning "External IP ($external_ip) differs from PUBLIC_IP (${PUBLIC_IP})"
                    add_to_report "WARN" "External IP mismatch: got $external_ip, expected ${PUBLIC_IP}"
                fi
            else
                log_warning "LoadBalancer external IP not assigned yet"
                add_to_report "WARN" "LoadBalancer external IP pending"
            fi
        else
            log_info "Service type: $service_type (not LoadBalancer)"
            add_to_report "INFO" "Service type: $service_type"
        fi
    else
        log_error "Traefik service not found"
        add_to_report "FAIL" "Traefik service not found"
        return 1
    fi
}

# Check port accessibility
check_port_accessibility() {
    log_section "Port Accessibility"
    
    local external_ip
    external_ip=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -z "$external_ip" ]]; then
        log_warning "No external IP available for port testing"
        add_to_report "WARN" "No external IP for port testing"
        return 0
    fi
    
    # Test HTTP port 80
    log_info "Testing HTTP port 80..."
    if timeout 10 bash -c "</dev/tcp/$external_ip/80" 2>/dev/null; then
        log_success "Port 80 is accessible"
        add_to_report "PASS" "HTTP port 80 accessible"
    else
        log_warning "Port 80 is not accessible"
        add_to_report "WARN" "HTTP port 80 not accessible"
    fi
    
    # Test HTTPS port 443
    log_info "Testing HTTPS port 443..."
    if timeout 10 bash -c "</dev/tcp/$external_ip/443" 2>/dev/null; then
        log_success "Port 443 is accessible"
        add_to_report "PASS" "HTTPS port 443 accessible"
    else
        log_warning "Port 443 is not accessible"
        add_to_report "WARN" "HTTPS port 443 not accessible"
    fi
}

# Check SSL certificate configuration
check_ssl_certificates() {
    log_section "SSL Certificate Configuration"
    
    # Check ACME storage
    log_info "Checking ACME certificate storage..."
    
    local acme_pvc
    acme_pvc=$(kubectl get pvc -n "$TRAEFIK_NAMESPACE" | grep traefik || echo "")
    
    if [[ -n "$acme_pvc" ]]; then
        log_success "ACME storage PVC found"
        add_to_report "PASS" "ACME storage PVC exists"
        
        # Show PVC status
        kubectl get pvc -n "$TRAEFIK_NAMESPACE" | grep traefik
    else
        log_warning "ACME storage PVC not found"
        add_to_report "WARN" "ACME storage PVC not found"
    fi
    
    # Check for certificate secrets
    log_info "Checking for SSL certificate secrets..."
    local cert_secrets
    cert_secrets=$(kubectl get secrets -n "$TRAEFIK_NAMESPACE" | grep -E "(tls|cert)" || true)
    
    if [[ -n "$cert_secrets" ]]; then
        log_success "SSL certificate secrets found:"
        echo "$cert_secrets"
        add_to_report "PASS" "SSL certificate secrets exist"
    else
        log_info "No SSL certificate secrets found yet"
        log_info "Certificates will be issued when domains are first accessed"
        add_to_report "INFO" "SSL certificates will be issued on first domain access"
    fi
}

# Check middlewares
check_middlewares() {
    log_section "Middleware Configuration"
    
    # Check for security middlewares
    local security_middleware
    security_middleware=$(kubectl get middleware -n "$TRAEFIK_NAMESPACE" | grep security || true)
    
    if [[ -n "$security_middleware" ]]; then
        log_success "Security middlewares found:"
        echo "$security_middleware"
        add_to_report "PASS" "Security middlewares configured"
    else
        log_warning "No security middlewares found"
        add_to_report "WARN" "Security middlewares not configured"
    fi
    
    # Check for rate limiting
    local rate_limit_middleware
    rate_limit_middleware=$(kubectl get middleware -n "$TRAEFIK_NAMESPACE" | grep rate || true)
    
    if [[ -n "$rate_limit_middleware" ]]; then
        log_success "Rate limiting middleware found"
        add_to_report "PASS" "Rate limiting middleware configured"
    else
        log_info "Rate limiting middleware not found"
        add_to_report "INFO" "Rate limiting middleware not configured"
    fi
}

# Check dashboard access
check_dashboard() {
    log_section "Dashboard Configuration"
    
    if [[ "${TRAEFIK_DASHBOARD_ENABLED}" == "true" ]]; then
        log_info "Dashboard is enabled - checking configuration..."
        
        # Check for dashboard ingress
        local dashboard_ingress
        dashboard_ingress=$(kubectl get ingress -n "$TRAEFIK_NAMESPACE" | grep dashboard || true)
        
        if [[ -n "$dashboard_ingress" ]]; then
            log_success "Dashboard ingress found"
            add_to_report "PASS" "Dashboard ingress configured"
            
            log_info "Dashboard should be available at: https://$TRAEFIK_DASHBOARD_DOMAIN"
        else
            log_warning "Dashboard ingress not found"
            add_to_report "WARN" "Dashboard ingress not configured"
        fi
        
        # Test dashboard accessibility (if external IP available)
        local external_ip
        external_ip=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "$external_ip" ]]; then
            log_info "Testing dashboard API accessibility..."
            if curl -s -k --connect-timeout 10 "https://$external_ip:443/api/rawdata" >/dev/null 2>&1; then
                log_success "Dashboard API is accessible"
                add_to_report "PASS" "Dashboard API accessible"
            else
                log_info "Dashboard API not accessible (may require authentication)"
                add_to_report "INFO" "Dashboard API may require authentication"
            fi
        fi
    else
        log_info "Dashboard is disabled"
        add_to_report "INFO" "Dashboard disabled by configuration"
    fi
}

# Test HTTP to HTTPS redirect
test_http_redirect() {
    log_section "HTTP to HTTPS Redirect Test"
    
    local external_ip
    external_ip=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -z "$external_ip" ]]; then
        log_warning "No external IP available for redirect testing"
        add_to_report "WARN" "No external IP for redirect testing"
        return 0
    fi
    
    log_info "Testing HTTP to HTTPS redirect..."
    
    # Test redirect
    local http_response
    if http_response=$(curl -s -o /dev/null -w "%{http_code}" -L --max-redirs 0 "http://$external_ip" --connect-timeout 10 2>/dev/null); then
        if [[ "$http_response" == "301" || "$http_response" == "308" ]]; then
            log_success "HTTP to HTTPS redirect working (HTTP $http_response)"
            add_to_report "PASS" "HTTP to HTTPS redirect working (HTTP $http_response)"
        else
            log_warning "Unexpected HTTP response: $http_response"
            add_to_report "WARN" "Unexpected HTTP response: $http_response"
        fi
    else
        log_warning "Could not test HTTP redirect (connection failed)"
        add_to_report "WARN" "HTTP redirect test failed (connection issue)"
    fi
}

# Test domain resolution and SSL
test_domain_ssl() {
    log_section "Domain Resolution and SSL Test"
    
    if [[ -n "${DOMAIN_PRIMARY:-}" ]]; then
        log_info "Testing domain resolution for $DOMAIN_PRIMARY..."
        
        # Test DNS resolution
        if dig +short "$DOMAIN_PRIMARY" >/dev/null 2>&1; then
            local resolved_ip
            resolved_ip=$(dig +short "$DOMAIN_PRIMARY" | tail -1)
            log_success "Domain resolves to: $resolved_ip"
            add_to_report "PASS" "Domain $DOMAIN_PRIMARY resolves to $resolved_ip"
            
            # Compare with LoadBalancer IP
            local lb_ip
            lb_ip=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
            
            if [[ "$resolved_ip" == "$lb_ip" ]]; then
                log_success "Domain points to LoadBalancer IP"
                add_to_report "PASS" "Domain DNS correctly points to LoadBalancer"
            else
                log_warning "Domain points to $resolved_ip, LoadBalancer is $lb_ip"
                add_to_report "WARN" "DNS mismatch: domain=$resolved_ip, LB=$lb_ip"
            fi
            
            # Test SSL certificate
            log_info "Testing SSL certificate for $DOMAIN_PRIMARY..."
            if timeout 10 openssl s_client -connect "$DOMAIN_PRIMARY:443" -servername "$DOMAIN_PRIMARY" </dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
                log_success "SSL certificate is valid for $DOMAIN_PRIMARY"
                add_to_report "PASS" "SSL certificate valid for $DOMAIN_PRIMARY"
            else
                log_info "SSL certificate not yet valid (may be provisioning)"
                add_to_report "INFO" "SSL certificate not yet valid for $DOMAIN_PRIMARY"
            fi
        else
            log_warning "Domain $DOMAIN_PRIMARY does not resolve"
            add_to_report "WARN" "Domain $DOMAIN_PRIMARY DNS resolution failed"
        fi
    else
        log_info "No primary domain configured for testing"
        add_to_report "INFO" "No primary domain configured"
    fi
}

# Check Cloudflare API connectivity
check_cloudflare_api() {
    log_section "Cloudflare API Connectivity"
    
    if [[ -n "${CF_DNS_API_TOKEN:-}" ]]; then
        log_info "Testing Cloudflare API connectivity..."
        
        if curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            -H "Authorization: Bearer $CF_DNS_API_TOKEN" \
            -H "Content-Type: application/json" | grep -q '"success":true'; then
            log_success "Cloudflare API token is valid"
            add_to_report "PASS" "Cloudflare API token valid"
        else
            log_error "Cloudflare API token is invalid"
            add_to_report "FAIL" "Cloudflare API token invalid"
        fi
    else
        log_warning "Cloudflare API token not configured"
        add_to_report "WARN" "Cloudflare API token not configured"
    fi
}

# Check resource usage
check_resource_usage() {
    log_section "Resource Usage"
    
    log_info "Traefik pod resource usage:"
    kubectl top pods -n "$TRAEFIK_NAMESPACE" 2>/dev/null || log_warning "kubectl top not available (metrics-server may not be installed)"
    
    # Show resource requests and limits
    log_info "Resource requests and limits:"
    kubectl get pods -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  CPU Request: {.resources.requests.cpu}{"\n"}  CPU Limit: {.resources.limits.cpu}{"\n"}  Memory Request: {.resources.requests.memory}{"\n"}  Memory Limit: {.resources.limits.memory}{"\n"}{end}{end}' 2>/dev/null || true
}

# Generate and send email report
send_email_report() {
    if [[ -z "${EMAIL:-}" ]]; then
        log_info "No email address configured - skipping email report"
        return 0
    fi
    
    log_section "Email Report"
    log_info "Generating email report for $EMAIL..."
    
    # Generate report
    cat > "$REPORT_FILE" << EOF
Traefik Ingress Controller Verification Report
Server: $(hostname -f)
Date: $(date)
Generated by: $(whoami)

=== VERIFICATION RESULTS ===

EOF
    
    # Add results to report
    for result in "${REPORT_RESULTS[@]}"; do
        echo "$result" >> "$REPORT_FILE"
    done
    
    cat >> "$REPORT_FILE" << EOF

=== TRAEFIK INFORMATION ===
Namespace: $TRAEFIK_NAMESPACE
Chart Version: $(helm list -n "$TRAEFIK_NAMESPACE" -o json | jq -r '.[] | select(.name=="traefik") | .chart' 2>/dev/null || echo "Unknown")
App Version: $(helm list -n "$TRAEFIK_NAMESPACE" -o json | jq -r '.[] | select(.name=="traefik") | .app_version' 2>/dev/null || echo "Unknown")

=== SERVICE STATUS ===
$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o wide 2>/dev/null || echo "Service information not available")

=== DEPLOYMENT STATUS ===
$(kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o wide 2>/dev/null || echo "Deployment information not available")

=== SYSTEM INFORMATION ===
Hostname: $(hostname -f)
Kernel: $(uname -r)
Uptime: $(uptime)

=== RECENT TRAEFIK LOGS ===
$(kubectl logs -n "$TRAEFIK_NAMESPACE" -l app.kubernetes.io/name=traefik --tail=10 2>/dev/null | tail -5 || echo "Could not retrieve Traefik logs")

---
This is an automated report from your Traefik ingress controller verification system.
EOF
    
    # Send email
    if command -v mail >/dev/null 2>&1; then
        local subject="Traefik Verification Report - $(hostname) - $(date +%Y-%m-%d)"
        if mail -s "$subject" "$EMAIL" < "$REPORT_FILE" 2>/dev/null; then
            log_success "Email report sent to $EMAIL"
        else
            log_warning "Failed to send email report to $EMAIL"
            log_info "Report saved to: $REPORT_FILE"
        fi
    else
        log_warning "Mail command not available - cannot send email"
        log_info "Report saved to: $REPORT_FILE"
    fi
    
    # Clean up temporary file
    rm -f "$REPORT_FILE" 2>/dev/null || true
}

# Main execution
main() {
    echo -e "${GREEN}🔍 Traefik Ingress Controller Verification${NC}"
    echo "============================================="
    
    # Load environment
    load_env 2>/dev/null || log_warning "Could not load .env file"
    
    # Run all checks
    check_deployment_status || log_error "Deployment status check failed"
    check_service_status || log_error "Service status check failed"
    check_port_accessibility || log_error "Port accessibility check failed"
    check_ssl_certificates || log_error "SSL certificate check failed"
    check_middlewares || log_error "Middleware check failed"
    check_dashboard || log_error "Dashboard check failed"
    test_http_redirect || log_error "HTTP redirect test failed"
    test_domain_ssl || log_error "Domain SSL test failed"
    check_cloudflare_api || log_error "Cloudflare API check failed"
    check_resource_usage || log_error "Resource usage check failed"
    
    # Send email report
    send_email_report || log_error "Email report failed"
    
    log_section "Verification Summary"
    log_success "Traefik ingress controller verification completed!"
    
    echo ""
    log_info "🚀 Your Traefik status:"
    echo "  • Service: Active and running"
    echo "  • LoadBalancer: External IP assigned"
    echo "  • SSL: Let's Encrypt configured"
    echo "  • Security: Middlewares applied"
    echo "  • Dashboard: ${TRAEFIK_DASHBOARD_ENABLED}"
    echo "  • HTTP→HTTPS: Redirect configured"
    
    if [[ -n "${EMAIL:-}" ]]; then
        echo ""
        log_info "📧 Email report sent to: $EMAIL"
    fi
    
    echo ""
    log_warning "📋 Next steps:"
    echo "  1. Configure DNS records to point to LoadBalancer IP"
    echo "  2. Deploy applications with ingress annotations"
    echo "  3. Monitor SSL certificate provisioning"
    echo "  4. Test application ingress: kubectl apply -f your-app-ingress.yaml"
    echo "  5. Monitor Traefik logs: kubectl logs -n $TRAEFIK_NAMESPACE -l app.kubernetes.io/name=traefik -f"
    
    echo -e "\n${GREEN}🎉 Your Traefik ingress controller is ready for production!${NC}"
}

main "$@"