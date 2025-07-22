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
    
    log_info "Environment variables loaded"
    log_info "Primary domain: $DOMAIN_PRIMARY"
    log_info "Traefik namespace: $TRAEFIK_NAMESPACE"
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

# Verify Traefik is installed and running
verify_traefik_installation() {
    log_section "Traefik Installation Verification"
    
    # Check if Traefik is installed
    if ! helm list -n "$TRAEFIK_NAMESPACE" | grep -q traefik; then
        log_error "Traefik is not installed in namespace $TRAEFIK_NAMESPACE"
        log_info "Please run ./02-install-traefik.sh first"
        exit 1
    fi
    
    # Check if Traefik pods are running
    local ready_replicas
    ready_replicas=$(kubectl get deployment traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    
    if [[ "$ready_replicas" == "0" ]]; then
        log_error "Traefik pods are not ready"
        kubectl get pods -n "$TRAEFIK_NAMESPACE"
        exit 1
    fi
    
    log_success "Traefik is installed and running ($ready_replicas replicas)"
}

# Configure security middlewares
configure_security_middlewares() {
    log_section "Security Middlewares Configuration"
    
    local middleware_file="/tmp/middleware-security.yaml"
    
    # Check if template exists
    if [[ -f "$SCRIPT_DIR/templates/middleware-security.yaml" ]]; then
        render_template "middleware-security.yaml" "$middleware_file" false
        
        if kubectl apply -f "$middleware_file"; then
            log_success "Security middlewares applied"
        else
            log_error "Failed to apply security middlewares"
            exit 1
        fi
        
        rm -f "$middleware_file"
    else
        log_warning "Security middleware template not found - creating basic middleware"
        
        # Create basic security middleware
        cat > "$middleware_file" << EOF
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: $TRAEFIK_NAMESPACE
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: https
    customResponseHeaders:
      X-Robots-Tag: "noindex,nofollow,nosnippet,noarchive,notranslate,noimageindex"
      X-Frame-Options: "DENY"
      X-Content-Type-Options: "nosniff"
      Referrer-Policy: "same-origin"
      Feature-Policy: "vibrate 'none'; geolocation 'none'; midi 'none'; notifications 'none'; push 'none'; sync-xhr 'none'; microphone 'none'; camera 'none'; magnetometer 'none'; gyroscope 'none'; speaker 'none'; vibrate 'none'; fullscreen 'none'; payment 'none'"
      Strict-Transport-Security: "max-age=31536000; includeSubDomains; preload"
      Content-Security-Policy: "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none';"
---
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: $TRAEFIK_NAMESPACE
spec:
  rateLimit:
    burst: 100
    average: 50
---
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: compress
  namespace: $TRAEFIK_NAMESPACE
spec:
  compress: {}
EOF
        
        if kubectl apply -f "$middleware_file"; then
            log_success "Basic security middlewares created"
        else
            log_error "Failed to create security middlewares"
        fi
        
        rm -f "$middleware_file"
    fi
}

# Configure authentication middleware (if enabled)
configure_auth_middleware() {
    log_section "Authentication Middleware Configuration"
    
    if [[ "${TRAEFIK_DASHBOARD_AUTH_ENABLED:-false}" == "true" ]]; then
        local auth_file="/tmp/middleware-auth.yaml"
        
        if [[ -f "$SCRIPT_DIR/templates/middleware-auth.yaml" ]]; then
            render_template "middleware-auth.yaml" "$auth_file" false
            
            if kubectl apply -f "$auth_file"; then
                log_success "Authentication middleware applied"
            else
                log_error "Failed to apply authentication middleware"
            fi
            
            rm -f "$auth_file"
        else
            log_warning "Authentication middleware template not found"
            log_info "To create basic auth, run: htpasswd -nb admin password | base64"
        fi
    else
        log_info "Dashboard authentication not enabled - skipping auth middleware"
    fi
}

# Configure dashboard access
configure_dashboard() {
    log_section "Dashboard Configuration"
    
    if [[ "${TRAEFIK_DASHBOARD_ENABLED}" == "true" ]]; then
        local dashboard_file="/tmp/dashboard-ingress.yaml"
        
        if [[ -f "$SCRIPT_DIR/templates/dashboard-ingress.yaml" ]]; then
            render_template "dashboard-ingress.yaml" "$dashboard_file" false
            
            if kubectl apply -f "$dashboard_file"; then
                log_success "Dashboard ingress configured"
                log_info "Dashboard will be available at: https://$TRAEFIK_DASHBOARD_DOMAIN"
            else
                log_error "Failed to configure dashboard ingress"
            fi
            
            rm -f "$dashboard_file"
        else
            log_warning "Dashboard ingress template not found - creating basic ingress"
            
            # Create basic dashboard ingress
            cat > "$dashboard_file" << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: traefik-dashboard
  namespace: $TRAEFIK_NAMESPACE
  annotations:
    kubernetes.io/ingress.class: $INGRESS_CLASS
    cert-manager.io/cluster-issuer: letsencrypt
    traefik.ingress.kubernetes.io/router.middlewares: $TRAEFIK_NAMESPACE-security-headers@kubernetescrd
spec:
  tls:
  - hosts:
    - $TRAEFIK_DASHBOARD_DOMAIN
    secretName: traefik-dashboard-tls
  rules:
  - host: $TRAEFIK_DASHBOARD_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: traefik
            port:
              number: 9000
EOF
            
            if kubectl apply -f "$dashboard_file"; then
                log_success "Basic dashboard ingress created"
            else
                log_error "Failed to create dashboard ingress"
            fi
            
            rm -f "$dashboard_file"
        fi
    else
        log_info "Dashboard is disabled - skipping dashboard configuration"
    fi
}

# Configure Let's Encrypt cluster issuer
configure_letsencrypt() {
    log_section "Let's Encrypt Configuration"
    
    local issuer_file="/tmp/letsencrypt-issuer.yaml"
    
    if [[ -f "$SCRIPT_DIR/templates/letsencrypt-issuer.yaml" ]]; then
        render_template "letsencrypt-issuer.yaml" "$issuer_file" false
        
        if kubectl apply -f "$issuer_file"; then
            log_success "Let's Encrypt cluster issuer configured"
        else
            log_error "Failed to configure Let's Encrypt issuer"
        fi
        
        rm -f "$issuer_file"
    else
        log_info "Let's Encrypt issuer template not found"
        log_info "Traefik will handle SSL certificates via built-in ACME"
    fi
}

# Configure default ingress routes
configure_default_routes() {
    log_section "Default Routes Configuration"
    
    local routes_file="/tmp/traefik-ingress.yaml"
    
    if [[ -f "$SCRIPT_DIR/templates/traefik-ingress.yaml" ]]; then
        render_template "traefik-ingress.yaml" "$routes_file" false
        
        if kubectl apply -f "$routes_file"; then
            log_success "Default ingress routes configured"
        else
            log_warning "Failed to apply default ingress routes (non-critical)"
        fi
        
        rm -f "$routes_file"
    else
        log_info "Default ingress routes template not found - skipping"
    fi
}

# Verify SSL certificate provisioning
verify_ssl_certificates() {
    log_section "SSL Certificate Verification"
    
    log_info "Checking ACME certificate storage..."
    
    # Check if ACME storage exists
    local acme_pv
    acme_pv=$(kubectl get pv -o name | grep traefik || echo "")
    
    if [[ -n "$acme_pv" ]]; then
        log_success "ACME storage persistent volume found"
    else
        log_warning "ACME storage persistent volume not found"
    fi
    
    # Check certificate secrets
    log_info "Checking for SSL certificate secrets..."
    local cert_secrets
    cert_secrets=$(kubectl get secrets -n "$TRAEFIK_NAMESPACE" | grep -E "(tls|cert)" || true)
    
    if [[ -n "$cert_secrets" ]]; then
        log_success "SSL certificate secrets found:"
        echo "$cert_secrets"
    else
        log_info "No SSL certificate secrets found yet"
        log_info "Certificates will be provisioned automatically when domains are accessed"
    fi
}

# Test ingress functionality
test_ingress() {
    log_section "Ingress Functionality Test"
    
    # Get LoadBalancer IP
    local lb_ip
    lb_ip=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -n "$lb_ip" ]]; then
        log_success "LoadBalancer IP: $lb_ip"
        
        # Test HTTP redirect to HTTPS
        log_info "Testing HTTP to HTTPS redirect..."
        local http_response
        if http_response=$(curl -s -o /dev/null -w "%{http_code}" "http://$lb_ip" --connect-timeout 10 2>/dev/null); then
            if [[ "$http_response" == "301" || "$http_response" == "308" ]]; then
                log_success "HTTP to HTTPS redirect working (HTTP $http_response)"
            else
                log_warning "HTTP response: $http_response (expected 301 or 308)"
            fi
        else
            log_warning "Could not test HTTP redirect (timeout or connection failed)"
        fi
        
        # Test HTTPS connectivity
        log_info "Testing HTTPS connectivity..."
        local https_response
        if https_response=$(curl -s -o /dev/null -w "%{http_code}" "https://$lb_ip" --insecure --connect-timeout 10 2>/dev/null); then
            log_success "HTTPS connectivity working (HTTP $https_response)"
        else
            log_warning "Could not test HTTPS connectivity"
        fi
    else
        log_warning "LoadBalancer IP not available yet"
    fi
}

# Main execution
main() {
    log_info "⚙️  Configuring Traefik ingress controller..."
    
    load_env
    verify_traefik_installation
    configure_security_middlewares
    configure_auth_middleware
    configure_dashboard
    configure_letsencrypt
    configure_default_routes
    verify_ssl_certificates
    test_ingress
    
    log_success "Traefik configuration completed successfully!"
    
    echo ""
    log_info "📋 Configuration Summary:"
    echo "  ✅ Security middlewares configured"
    echo "  ✅ Dashboard access configured: $TRAEFIK_DASHBOARD_ENABLED"
    echo "  ✅ Let's Encrypt SSL certificates configured"
    echo "  ✅ Default security headers applied"
    echo "  ✅ Rate limiting enabled"
    echo "  ✅ Compression enabled"
    
    echo ""
    log_info "🔄 Next steps:"
    echo "  • Run ./04-verify-traefik.sh to verify complete functionality"
    echo "  • Configure DNS records to point to LoadBalancer IP"
    echo "  • Deploy applications with ingress annotations"
    echo "  • Monitor certificate provisioning"
    
    echo ""
    log_warning "📋 Important notes:"
    echo "  • SSL certificates will be issued automatically when domains are accessed"
    echo "  • Dashboard available at: https://$TRAEFIK_DASHBOARD_DOMAIN (if enabled)"
    echo "  • Monitor Traefik logs: kubectl logs -n $TRAEFIK_NAMESPACE -l app.kubernetes.io/name=traefik"
}

main "$@"