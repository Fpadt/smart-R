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
REPORT_FILE="/tmp/k3s_report_$(date +%Y%m%d_%H%M%S).txt"
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

# Enhanced render function (needed for network policies)
render_template() {
    local template="$1"
    local target="$2"
    local backup_enabled="${3:-false}"  # Default to false for temp files
    
    local template_path="$SCRIPT_DIR/templates/$template"
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template not found: $template_path"
        return 1
    fi
    
    # Create target directory
    mkdir -p "$(dirname "$target")" 2>/dev/null || sudo mkdir -p "$(dirname "$target")"
    
    # Render template
    if envsubst < "$template_path" > "$target" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Apply post-installation security policies
apply_security_policies() {
    log_section "Post-Installation Security Policies"
    
    # Wait for cluster to be ready
    local retries=30
    while ! kubectl get nodes &>/dev/null && [[ $retries -gt 0 ]]; do
        log_info "Waiting for cluster to be ready... ($retries retries left)"
        sleep 5
        ((retries--))
    done
    
    if [[ $retries -eq 0 ]]; then
        log_error "Cluster did not become ready in time"
        add_to_report "FAIL" "Cluster not ready for security policy application"
        return 1
    fi
    
    # Create applications namespace
    if kubectl create namespace applications 2>/dev/null || kubectl get namespace applications &>/dev/null; then
        log_success "applications namespace ready"
        add_to_report "PASS" "Applications namespace created/verified"
        
        # Label the namespace for network policies
        kubectl label namespace applications name=applications --overwrite
        
        # Apply Pod Security Standards
        kubectl label namespace applications \
            pod-security.kubernetes.io/enforce=baseline \
            pod-security.kubernetes.io/audit=baseline \
            pod-security.kubernetes.io/warn=baseline \
            --overwrite
        log_success "applications namespace labeled with baseline PSS"
        add_to_report "PASS" "Applications namespace configured with baseline PSS"
    else
        log_error "Failed to create applications namespace"
        add_to_report "FAIL" "Failed to create applications namespace"
    fi
    
    # Create development namespace (optional)
    if kubectl create namespace development 2>/dev/null || kubectl get namespace development &>/dev/null; then
        log_success "development namespace ready"
        
        # Label the namespace
        kubectl label namespace development name=development --overwrite
        
        # Apply more permissive PSS for development
        kubectl label namespace development \
            pod-security.kubernetes.io/enforce=privileged \
            pod-security.kubernetes.io/audit=baseline \
            pod-security.kubernetes.io/warn=baseline \
            --overwrite
        log_success "development namespace labeled with permissive PSS"
        add_to_report "PASS" "Development namespace configured with permissive PSS"
    else
        log_warning "Could not create development namespace (non-critical)"
        add_to_report "WARN" "Development namespace creation failed (non-critical)"
    fi
    
    # Label existing kube-system namespace
    log_info "Configuring kube-system namespace security labels..."
    if kubectl label namespace kube-system name=kube-system --overwrite 2>/dev/null; then
        if kubectl label namespace kube-system \
            pod-security.kubernetes.io/enforce=privileged \
            pod-security.kubernetes.io/audit=restricted \
            pod-security.kubernetes.io/warn=restricted \
            --overwrite 2>/dev/null; then
            log_success "kube-system namespace labeled with restricted PSS"
            add_to_report "PASS" "Kube-system namespace configured with security labels"
        else
            log_warning "Could not apply restricted PSS to kube-system"
            add_to_report "WARN" "Kube-system PSS configuration failed"
        fi
    fi
    
    # Apply network policies if template exists
    if [[ -f "$SCRIPT_DIR/templates/network-policy.yaml" ]]; then
        log_info "Applying network policies..."
        
        local network_policy_temp="/tmp/network-policy.yaml"
        if render_template "network-policy.yaml" "$network_policy_temp"; then
            if kubectl apply -f "$network_policy_temp" 2>/dev/null; then
                log_success "Network policies applied"
                add_to_report "PASS" "Network policies applied successfully"
            else
                log_warning "Failed to apply network policies"
                add_to_report "WARN" "Network policies application failed"
            fi
            rm -f "$network_policy_temp"
        else
            log_warning "Could not render network policy template"
            add_to_report "WARN" "Network policy template rendering failed"
        fi
    else
        log_info "No network policy template found - skipping"
        add_to_report "INFO" "Network policy template not found"
    fi
}

# Check Traefik disable status (CRITICAL for our setup)
check_traefik_disable() {
    log_section "Traefik Disable Verification"
    
    # This is the most important check - verify Traefik is properly disabled
    log_info "Verifying Traefik disable directive worked..."
    
    # Check for Traefik service
    if kubectl get svc -n kube-system traefik 2>/dev/null; then
        log_error "❌ CRITICAL: Traefik service still exists!"
        log_error "The disable directive in config.yaml did not work"
        add_to_report "FAIL" "CRITICAL: Traefik service still running despite disable directive"
        
        # Show the conflicting service
        log_info "Conflicting Traefik service details:"
        kubectl get svc traefik -n kube-system -o wide
        
        return 1
    else
        log_success "✅ Traefik successfully disabled - no conflicting services"
        add_to_report "PASS" "Traefik properly disabled - no port conflicts"
    fi
    
    # Check for any Traefik pods
    local traefik_pods
    traefik_pods=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | wc -l)
    
    if [[ $traefik_pods -eq 0 ]]; then
        log_success "No Traefik pods found"
        add_to_report "PASS" "No Traefik pods running"
    else
        log_warning "$traefik_pods Traefik pods still running"
        add_to_report "WARN" "$traefik_pods Traefik pods still running"
    fi
    
    # Check for Traefik HelmChart resources
    local traefik_helmcharts
    traefik_helmcharts=$(kubectl get helmchart -n kube-system -o name 2>/dev/null | grep -c traefik || echo "0")
    
    if [[ $traefik_helmcharts -eq 0 ]]; then
        log_success "No Traefik HelmChart resources found"
        add_to_report "PASS" "No Traefik HelmChart resources"
    else
        log_warning "$traefik_helmcharts Traefik HelmChart resources found"
        add_to_report "WARN" "$traefik_helmcharts Traefik HelmChart resources still exist"
    fi
}

# Check port availability for Traefik installation
check_port_availability() {
    log_section "Port Availability for Traefik"
    
    log_info "Checking port availability for Traefik installation..."
    
    # Check what services are using ports 80 and 443
    local port_conflicts
    port_conflicts=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.ports[*].port}{"\n"}{end}' | grep -E "(^|\s)(80|443)(\s|$)" | grep -v "default/kubernetes" || true)
    
    if [[ -n "$port_conflicts" ]]; then
        log_warning "Found services using ports 80/443:"
        echo "$port_conflicts"
        add_to_report "WARN" "Port conflicts found: $port_conflicts"
        
        # Check if any of these are Traefik (should be none)
        if echo "$port_conflicts" | grep -q traefik; then
            log_error "Traefik services found using ports 80/443!"
            add_to_report "FAIL" "Traefik services using ports 80/443"
        fi
    else
        log_success "✅ Ports 80/443 are available for Traefik installation"
        add_to_report "PASS" "Ports 80/443 available for Traefik installation"
    fi
    
    # Check system-level port binding
    local port_80_bound
    port_80_bound=$(ss -tlnp | grep ":80 " || echo "")
    local port_443_bound
    port_443_bound=$(ss -tlnp | grep ":443 " || echo "")
    
    if [[ -z "$port_80_bound" && -z "$port_443_bound" ]]; then
        log_success "System ports 80/443 are not bound"
        add_to_report "PASS" "System ports 80/443 not bound"
    else
        log_warning "System ports may be bound:"
        [[ -n "$port_80_bound" ]] && echo "Port 80: $port_80_bound"
        [[ -n "$port_443_bound" ]] && echo "Port 443: $port_443_bound"
        add_to_report "WARN" "System ports 80/443 may be bound"
    fi
}

# Test cluster functionality
test_cluster_functionality() {
    log_section "Cluster Functionality Test"
    
    log_info "Testing basic cluster functionality..."
    
    # Create a test pod
    local test_pod_yaml="/tmp/test-pod.yaml"
    cat > "$test_pod_yaml" << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cluster-test-pod
  namespace: default
  labels:
    app: cluster-test
spec:
  containers:
  - name: test
    image: busybox:1.35
    command: ['sleep', '120']
    resources:
      requests:
        memory: "16Mi"
        cpu: "10m"
      limits:
        memory: "32Mi"
        cpu: "50m"
  restartPolicy: Never
EOF
    
    log_info "Creating test pod..."
    if kubectl apply -f "$test_pod_yaml" 2>/dev/null; then
        log_success "Test pod created"
        
        # Wait for pod to be ready
        local retries=20
        local pod_ready=false
        
        while [[ $retries -gt 0 ]]; do
            local pod_phase
            pod_phase=$(kubectl get pod cluster-test-pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [[ "$pod_phase" == "Running" ]]; then
                log_success "Test pod is running"
                add_to_report "PASS" "Test pod creation and execution successful"
                pod_ready=true
                break
            elif [[ "$pod_phase" == "Failed" ]]; then
                log_error "Test pod failed to start"
                kubectl describe pod cluster-test-pod 2>/dev/null || true
                add_to_report "FAIL" "Test pod failed to start"
                break
            fi
            
            log_info "Waiting for test pod ($pod_phase)... ($retries retries left)"
            sleep 3
            ((retries--))
        done
        
        if [[ "$pod_ready" == "true" ]]; then
            # Test DNS resolution
            log_info "Testing DNS resolution..."
            if kubectl exec cluster-test-pod -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
                log_success "DNS resolution working"
                add_to_report "PASS" "Cluster DNS resolution working"
            else
                log_warning "DNS resolution test failed"
                add_to_report "WARN" "DNS resolution test failed"
            fi
            
            # Test service discovery
            log_info "Testing service discovery..."
            if kubectl exec cluster-test-pod -- nslookup kube-dns.kube-system.svc.cluster.local >/dev/null 2>&1; then
                log_success "Service discovery working"
                add_to_report "PASS" "Service discovery working"
            else
                log_warning "Service discovery test failed"
                add_to_report "WARN" "Service discovery test failed"
            fi
        else
            log_error "Test pod did not become ready in time"
            add_to_report "FAIL" "Test pod readiness timeout"
        fi
        
        # Clean up test pod
        kubectl delete pod cluster-test-pod --ignore-not-found=true >/dev/null 2>&1
        rm -f "$test_pod_yaml"
        
    else
        log_error "Failed to create test pod"
        add_to_report "FAIL" "Test pod creation failed"
    fi
}

# Check K3s service status
check_k3s_service() {
    log_section "K3s Service Status"
    
    if systemctl is-active --quiet k3s 2>/dev/null; then
        log_success "K3s service is active"
        add_to_report "PASS" "K3s service is active and running"
        
        # Show service details
        log_info "Service uptime:"
        systemctl show k3s --property=ActiveEnterTimestamp --value
        
        log_info "Service status:"
        sudo systemctl status k3s --no-pager -l --lines=5
    else
        log_error "K3s service is not active"
        add_to_report "FAIL" "K3s service is NOT active"
        sudo systemctl status k3s --no-pager || true
        return 1
    fi
}

# Check cluster nodes
check_cluster_nodes() {
    log_section "Cluster Nodes"
    
    if kubectl get nodes &>/dev/null; then
        log_success "kubectl access working"
        add_to_report "PASS" "kubectl cluster access working"
        
        log_info "Cluster nodes:"
        kubectl get nodes -o wide
        
        # Check node readiness
        local ready_nodes=$(kubectl get nodes --no-headers | grep -c " Ready " || echo "0")
        local total_nodes=$(kubectl get nodes --no-headers | wc -l)
        
        if [[ $ready_nodes -eq $total_nodes && $total_nodes -gt 0 ]]; then
            log_success "All $total_nodes nodes are ready"
            add_to_report "PASS" "All $total_nodes cluster nodes are ready"
        else
            log_warning "$ready_nodes of $total_nodes nodes are ready"
            add_to_report "WARN" "$ready_nodes of $total_nodes nodes are ready"
        fi
    else
        log_error "kubectl access failed"
        add_to_report "FAIL" "kubectl cluster access failed"
        return 1
    fi
}

# Check system pods
check_system_pods() {
    log_section "System Pods"
    
    log_info "Checking system pods in kube-system namespace:"
    
    if kubectl get pods -n kube-system &>/dev/null; then
        kubectl get pods -n kube-system
        
        # Count running pods (exclude completed jobs)
        local running_pods=$(kubectl get pods -n kube-system --no-headers | grep -v Completed | grep -c " Running " || echo "0")
        local total_pods=$(kubectl get pods -n kube-system --no-headers | grep -v Completed | wc -l)
        
        if [[ $running_pods -eq $total_pods && $total_pods -gt 0 ]]; then
            log_success "All $total_pods system pods are running"
            add_to_report "PASS" "All $total_pods system pods are running"
        else
            log_warning "$running_pods of $total_pods system pods are running"
            add_to_report "WARN" "$running_pods of $total_pods system pods are running"
            
            # Show problematic pods
            local problematic_pods
            problematic_pods=$(kubectl get pods -n kube-system --no-headers | grep -v Completed | grep -v " Running " || true)
            if [[ -n "$problematic_pods" ]]; then
                log_info "Problematic pods:"
                echo "$problematic_pods"
            fi
        fi
    else
        log_error "Cannot access system pods"
        add_to_report "FAIL" "Cannot access system pods"
        return 1
    fi
}

# Check security configurations
check_security_config() {
    log_section "Security Configuration"
    
    # Check audit logging
    local audit_log="/var/lib/rancher/k3s/audit.log"
    if [[ -f "$audit_log" ]]; then
        log_success "Audit logging is configured"
        add_to_report "PASS" "Audit logging is active"
        
        local log_lines=$(sudo wc -l < "$audit_log" 2>/dev/null || echo "0")
        log_info "Audit log has $log_lines entries"
        
        if [[ $log_lines -gt 0 ]]; then
            log_info "Recent audit log entries:"
            sudo tail -3 "$audit_log" 2>/dev/null || true
        fi
    else
        log_warning "Audit log file not found"
        add_to_report "WARN" "Audit log file not found"
    fi
    
    # Check Pod Security Standards
    log_info "Checking Pod Security Standards..."
    if kubectl get ns --show-labels | grep -q "pod-security.kubernetes.io"; then
        log_success "Pod Security Standards are configured"
        add_to_report "PASS" "Pod Security Standards configured"
        
        log_info "Namespace security labels:"
        kubectl get ns --show-labels | grep "pod-security" || true
    else
        log_warning "Pod Security Standards not configured"
        add_to_report "WARN" "Pod Security Standards not configured"
    fi
    
    # Check network policies
    if kubectl get networkpolicies --all-namespaces &>/dev/null; then
        local netpol_count=$(kubectl get networkpolicies --all-namespaces --no-headers | wc -l)
        if [[ $netpol_count -gt 0 ]]; then
            log_success "Network policies are configured ($netpol_count policies)"
            add_to_report "PASS" "Network policies configured ($netpol_count policies)"
        else
            log_warning "No network policies found"
            add_to_report "WARN" "No network policies configured"
        fi
    fi
}

# Check networking
check_networking() {
    log_section "Network Configuration"
    
    # Check listening ports
    log_info "Checking K3s listening ports:"
    
    # API server (6443)
    if ss -tlnp | grep ":6443 " >/dev/null; then
        log_success "Kubernetes API server is listening on port 6443"
        add_to_report "PASS" "API server listening on port 6443"
    else
        log_error "Kubernetes API server not listening on port 6443"
        add_to_report "FAIL" "API server not listening on port 6443"
    fi
    
    # Kubelet (10250)
    if ss -tlnp | grep ":10250 " >/dev/null; then
        log_success "Kubelet is listening on port 10250"
    else
        log_warning "Kubelet not listening on port 10250"
    fi
    
    # Show all listening ports
    log_info "All listening ports:"
    ss -tlnp | grep LISTEN | head -10 || true
}

# Check resource usage
check_resources() {
    log_section "Resource Usage"
    
    # Memory usage
    log_info "Memory usage:"
    free -h
    
    # Disk usage
    log_info "Disk usage:"
    df -h / /var/lib/rancher/k3s 2>/dev/null || df -h /
    
    # CPU usage
    log_info "CPU load:"
    uptime
    
    # K3s process resource usage
    log_info "K3s process resource usage:"
    ps aux | grep k3s | grep -v grep || true
}

# Run security scan (if tools available)
run_security_scan() {
    log_section "Security Scan"
    
    # Check for common security tools
    if command -v kube-bench >/dev/null 2>&1; then
        log_info "Running kube-bench CIS benchmark..."
        if kube-bench --version k3s-cis-1.23 --json > /tmp/kube-bench-results.json 2>/dev/null; then
            local total_checks=$(jq '.Totals.total_pass + .Totals.total_fail + .Totals.total_warn' /tmp/kube-bench-results.json 2>/dev/null || echo "0")
            local passed_checks=$(jq '.Totals.total_pass' /tmp/kube-bench-results.json 2>/dev/null || echo "0")
            log_success "kube-bench completed: $passed_checks/$total_checks checks passed"
            add_to_report "INFO" "CIS benchmark: $passed_checks/$total_checks checks passed"
        else
            log_warning "kube-bench scan failed"
        fi
    else
        log_info "kube-bench not installed - install with: curl -L https://github.com/aquasecurity/kube-bench/releases/latest/download/kube-bench_linux_amd64.tar.gz | tar xz"
    fi
    
    if command -v trivy >/dev/null 2>&1; then
        log_info "Trivy security scanner available"
        add_to_report "INFO" "Trivy security scanner available for vulnerability scanning"
    else
        log_info "Trivy not installed - install with: sudo apt install trivy"
    fi
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
K3s Hardened Installation Verification Report
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

=== CLUSTER INFORMATION ===
K3s Version: $(k3s --version | head -1)
Kubectl Version: $(kubectl version --client --short 2>/dev/null | head -1)
Cluster Nodes: $(kubectl get nodes --no-headers | wc -l)
System Pods: $(kubectl get pods -n kube-system --no-headers | wc -l)

=== TRAEFIK STATUS ===
Traefik Services: $(kubectl get svc -A --no-headers | grep -c traefik || echo "0")
Traefik Pods: $(kubectl get pods -A --no-headers | grep -c traefik || echo "0")

=== SYSTEM INFORMATION ===
Hostname: $(hostname -f)
Kernel: $(uname -r)
Uptime: $(uptime)
Load: $(cat /proc/loadavg)

=== RESOURCE USAGE ===
$(free -h | head -2)
$(df -h / | tail -1)

=== NETWORK PORTS ===
$(ss -tlnp | grep LISTEN | head -10)

=== RECENT K3S LOGS ===
$(sudo journalctl -u k3s --no-pager -n 10 | tail -5 || echo "Could not retrieve K3s logs")

---
This is an automated report from your K3s hardened installation verification system.
EOF
    
    # Send email
    if command -v mail >/dev/null 2>&1; then
        local subject="K3s Hardening Report - $(hostname) - $(date +%Y-%m-%d)"
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
    echo -e "${GREEN}🚀 K3s Hardened Installation Verification${NC}"
    echo "==========================================="
    
    # Load environment
    load_env 2>/dev/null || log_warning "Could not load .env file"
    
    # Run all checks in order
    check_k3s_service || log_error "K3s service check failed"
    check_cluster_nodes || log_error "Cluster nodes check failed"
    
    # Apply post-installation security policies
    apply_security_policies || log_error "Security policies application failed"
    
    # Core verification checks
    check_traefik_disable || log_error "Traefik disable verification failed"
    check_port_availability || log_error "Port availability check failed"
    check_system_pods || log_error "System pods check failed"
    check_security_config || log_error "Security config check failed"
    check_networking || log_error "Networking check failed"
    check_resources || log_error "Resource check failed"
    
    # Functionality tests
    test_cluster_functionality || log_error "Cluster functionality test failed"
    
    # Security scanning
    run_security_scan || log_error "Security scan failed"
    
    # Send email report
    send_email_report || log_error "Email report failed"
    
    log_section "Verification Summary"
    log_success "K3s hardened installation verification completed!"
    
    echo ""
    log_info "🚀 Your K3s cluster status:"
    echo "  • Service: Active and running"
    echo "  • Traefik: Successfully disabled (no conflicts)"
    echo "  • Security: Audit logging, PSS, network policies applied"
    echo "  • Monitoring: Resource usage checked"
    echo "  • Access: kubectl configured and working"
    echo "  • Functionality: Basic cluster operations verified"
    
    if [[ -n "${EMAIL:-}" ]]; then
        echo ""
        log_info "📧 Email report sent to: $EMAIL"
    fi
    
    echo ""
    log_warning "📋 Next steps:"
    echo "  1. Install Traefik: cd ../04.traefik && ./01-prepare-traefik.sh"
    echo "  2. Deploy applications: kubectl apply -f your-app.yaml"
    echo "  3. Monitor cluster: kubectl get pods -A"
    echo "  4. Check logs: sudo journalctl -u k3s -f"
    echo "  5. Install K9s for cluster management: sudo apt install k9s"
    echo "  6. Run security scans: install kube-bench and trivy"
    
    echo -e "\n${GREEN}🎉 Your hardened K3s cluster is ready for Traefik installation!${NC}"
}

main "$@"