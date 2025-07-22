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
REPORT_FILE="/tmp/hardening_report_$(date +%Y%m%d_%H%M%S).txt"
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

# Check firewall status
check_firewall() {
    log_section "Firewall Status"
    
    if systemctl is-active --quiet nftables 2>/dev/null; then
        log_success "nftables is active"
        add_to_report "PASS" "nftables firewall is active"
        
        log_info "Active firewall rules:"
        # Get rules (ignoring warnings which are normal with iptables-nft)
        local rules_output
        if rules_output=$(sudo nft list ruleset 2>/dev/null); then
            if [[ -n "$rules_output" ]]; then
                local total_lines=$(echo "$rules_output" | wc -l)
                echo "$rules_output" | head -25
                if [[ $total_lines -gt 25 ]]; then
                    echo "  ... ($total_lines total lines, showing first 25)"
                fi
                log_success "Firewall rules displayed ($total_lines lines total)"
                
                # Note about warnings if they exist
                if sudo nft list ruleset 2>&1 | grep -q "Warning:"; then
                    log_info "Note: iptables-nft compatibility warnings are normal"
                fi
            else
                log_warning "nftables is running but no rules are loaded"
                add_to_report "WARN" "nftables running but no rules loaded"
                log_info "Check: sudo cat /etc/nftables.conf"
            fi
        else
            log_warning "Could not retrieve firewall rules"
            add_to_report "WARN" "Could not retrieve firewall rules"
            log_info "Attempting to show any error messages:"
            sudo nft list ruleset 2>&1 | head -5 || true
        fi
        
        # Also check if tables exist
        local tables_output
        if tables_output=$(sudo nft list tables 2>/dev/null); then
            if [[ -n "$tables_output" ]]; then
                log_info "Active tables: $tables_output"
            else
                log_warning "No nftables tables found"
            fi
        fi
    else
        log_error "nftables is not active"
        add_to_report "FAIL" "nftables firewall is NOT active"
    fi
    
    log_info "nftables service status:"
    systemctl status nftables --no-pager -l --lines=5 2>/dev/null || log_warning "Could not get nftables status"
}

# Check fail2ban status
check_fail2ban() {
    log_section "Fail2ban Status"
    
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_success "fail2ban is active"
        add_to_report "PASS" "fail2ban intrusion prevention is active"
        
        log_info "fail2ban jail status:"
        if sudo fail2ban-client status 2>/dev/null; then
            log_success "fail2ban status retrieved"
        else
            log_warning "Could not get fail2ban status"
        fi
    else
        log_error "fail2ban is not active"
        add_to_report "FAIL" "fail2ban intrusion prevention is NOT active"
        log_info "fail2ban service status:"
        systemctl status fail2ban --no-pager -l --lines=5 2>/dev/null || log_warning "Could not get fail2ban service status"
    fi
}

# Check SSH configuration
check_ssh() {
    log_section "SSH Configuration"
    
    if sudo sshd -t 2>/dev/null; then
        log_success "SSH configuration is valid"
        add_to_report "PASS" "SSH configuration is valid"
    else
        log_error "SSH configuration has errors"
        add_to_report "FAIL" "SSH configuration has errors"
        log_info "Testing SSH config in detail:"
        sudo sshd -t 2>&1 || true
    fi
    
    if systemctl is-active --quiet ssh 2>/dev/null; then
        log_success "SSH service is active"
        add_to_report "PASS" "SSH service is active on port ${SSH_PORT:-'unknown'}"
    else
        log_error "SSH service is not active"
        add_to_report "FAIL" "SSH service is NOT active"
    fi
    
    log_info "SSH is configured to listen on port: ${SSH_PORT:-'unknown'}"
    
    if command -v netstat >/dev/null 2>&1; then
        if netstat -tlnp 2>/dev/null | grep ":${SSH_PORT:-22} " > /dev/null; then
            log_success "SSH is listening on port ${SSH_PORT:-22}"
        else
            log_warning "SSH may not be listening on expected port ${SSH_PORT:-22}"
            add_to_report "WARN" "SSH may not be listening on expected port ${SSH_PORT:-22}"
            log_info "Current listening ports:"
            netstat -tlnp 2>/dev/null | grep LISTEN | head -5 || true
        fi
    else
        if ss -tlnp 2>/dev/null | grep ":${SSH_PORT:-22} " > /dev/null; then
            log_success "SSH is listening on port ${SSH_PORT:-22}"
        else
            log_warning "SSH may not be listening on expected port ${SSH_PORT:-22}"
            add_to_report "WARN" "SSH may not be listening on expected port ${SSH_PORT:-22}"
            log_info "Current listening ports:"
            ss -tlnp 2>/dev/null | grep LISTEN | head -5 || true
        fi
    fi
}

# Check automatic updates
check_updates() {
    log_section "Automatic Updates"
    
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        log_success "unattended-upgrades is active"
        add_to_report "PASS" "Automatic security updates are active"
    else
        log_warning "unattended-upgrades is not active"
        add_to_report "WARN" "Automatic security updates are NOT active"
        systemctl status unattended-upgrades --no-pager -l --lines=3 2>/dev/null || true
    fi
    
    if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
        log_success "Unattended upgrades configuration exists"
    else
        log_warning "Unattended upgrades configuration missing"
        add_to_report "WARN" "Unattended upgrades configuration missing"
    fi
    
    if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
        log_success "Auto-upgrades configuration exists"
    else
        log_warning "Auto-upgrades configuration missing"
        add_to_report "WARN" "Auto-upgrades configuration missing"
    fi
}

# Check mail system
check_mail() {
    log_section "Mail System"
    
    if systemctl is-active --quiet postfix 2>/dev/null; then
        log_success "postfix is active"
        add_to_report "PASS" "Mail system (postfix) is active"
    else
        log_warning "postfix is not active"
        add_to_report "WARN" "Mail system (postfix) is NOT active"
        systemctl status postfix --no-pager -l --lines=3 2>/dev/null || true
    fi
    
    log_info "Testing mail delivery..."
    if command -v mail >/dev/null 2>&1; then
        if echo "Test mail from hardened system verification" | mail -s "System Hardening Test" root 2>/dev/null; then
            log_success "Test mail sent to root user"
        else
            log_warning "Failed to send test mail"
        fi
    else
        log_warning "mail command not available"
        add_to_report "WARN" "Mail command not available"
    fi
}

# Check system security
check_security() {
    log_section "Security Status"
    
    # Check for security updates
    log_info "Checking for security updates..."
    if apt list --upgradable 2>/dev/null | grep -i security >/dev/null; then
        local security_updates=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
        log_warning "$security_updates security updates available"
        add_to_report "WARN" "$security_updates security updates available"
        log_info "Run 'apt list --upgradable | grep security' to see them"
    else
        log_success "No pending security updates"
        add_to_report "PASS" "No pending security updates"
    fi
    
    # Check running services
    log_info "Critical services status:"
    local services=("nftables" "fail2ban" "ssh" "postfix" "unattended-upgrades")
    local inactive_services=()
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "  ✅ $service: active"
        else
            echo "  ❌ $service: inactive"
            inactive_services+=("$service")
        fi
    done
    
    if [[ ${#inactive_services[@]} -gt 0 ]]; then
        add_to_report "WARN" "Inactive services: ${inactive_services[*]}"
    fi
    
    # Check open ports
    log_info "Open network ports:"
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep LISTEN | head -10 || log_warning "Could not list listening ports"
    else
        ss -tlnp 2>/dev/null | grep LISTEN | head -10 || log_warning "Could not list listening ports"
    fi
}

# Run security audit
run_audit() {
    log_section "Security Audit"
    
    if command -v lynis >/dev/null 2>&1; then
        log_info "Running Lynis security audit (this may take a moment)..."
        if sudo lynis audit system --quick --quiet 2>/dev/null; then
            log_success "Lynis audit completed"
            add_to_report "PASS" "Lynis security audit completed successfully"
            log_info "Check /var/log/lynis.log for detailed results"
        else
            log_warning "Lynis audit completed with warnings"
            add_to_report "WARN" "Lynis security audit completed with warnings"
            log_info "Check /var/log/lynis.log for details"
        fi
    else
        log_warning "Lynis not available for security audit"
        add_to_report "INFO" "Lynis not available for security audit"
        log_info "Install with: sudo apt install lynis"
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
Ubuntu 24.04 LTS Hardening Verification Report
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

=== SYSTEM INFORMATION ===
Hostname: $(hostname -f)
Kernel: $(uname -r)
Uptime: $(uptime)
Load: $(cat /proc/loadavg)

=== DISK USAGE ===
$(df -h / | tail -1)

=== MEMORY USAGE ===
$(free -h | head -2)

=== ACTIVE CONNECTIONS ===
EOF
    
    if command -v netstat >/dev/null 2>&1; then
        echo "$(netstat -tuln | grep LISTEN | head -10)" >> "$REPORT_FILE"
    else
        echo "$(ss -tuln | grep LISTEN | head -10)" >> "$REPORT_FILE"
    fi
    
    cat >> "$REPORT_FILE" << EOF

=== RECENT FAILED LOGIN ATTEMPTS ===
$(sudo journalctl -u ssh -n 20 --no-pager | grep -i "failed\|invalid" | tail -5 || echo "No recent failed attempts found")

---
This is an automated report from your Ubuntu hardening verification system.
EOF
    
    # Send email
    if command -v mail >/dev/null 2>&1; then
        local subject="Ubuntu Hardening Report - $(hostname) - $(date +%Y-%m-%d)"
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
    echo -e "${GREEN}🛡️ Verifying Ubuntu System Hardening ${NC}"
    echo "=========================================="
    
    # Load environment but don't fail if missing
    load_env 2>/dev/null || log_warning "Could not load .env file"
    
    # Run all checks, continuing even if some fail
    check_firewall || log_error "Firewall check failed"
    check_fail2ban || log_error "Fail2ban check failed"
    check_ssh || log_error "SSH check failed"
    check_updates || log_error "Updates check failed"
    check_mail || log_error "Mail check failed"
    check_security || log_error "Security check failed"
    run_audit || log_error "Security audit failed"
    
    # Send email report
    send_email_report || log_error "Email report failed"
    
    log_section "Verification Summary"
    log_success "System hardening verification completed!"
    
    echo ""
    log_info "🔒 Your Ubuntu 24.04 LTS system hardening status checked"
    echo "  • Firewall protection (nftables)"
    echo "  • Intrusion prevention (fail2ban)"
    echo "  • Secure SSH configuration"
    echo "  • Automatic security updates"
    echo "  • System monitoring and alerting"
    
    if [[ -n "${EMAIL:-}" ]]; then
        echo ""
        log_info "📧 Email report sent to: $EMAIL"
    fi
    
    echo ""
    log_warning "📋 Next steps:"
    echo "  1. Review any warnings or errors above"
    echo "  2. Check service logs if any services are inactive"
    echo "  3. Monitor fail2ban logs: sudo journalctl -u fail2ban -f"
    echo "  4. Check system mail: sudo mail"
    
    echo -e "\n${GREEN}🎉 System verification completed!${NC}"
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  -h, --help    Show this help message"
        echo "  -v, --verbose Run with verbose output"
        echo ""
        echo "Email reports will be sent to EMAIL address from .env file"
        exit 0
        ;;
    -v|--verbose)
        set -x
        ;;
esac

main "$@"