# Claude.ai Collaboration Guide

## 🎯 Quick Context for Claude

### Project Overview
- **Purpose**: Production-ready VPS configuration system
- **Stack**: Ubuntu 24.04 LTS, K3s, Traefik, Podman
- **Architecture**: Modular scripts with template-driven configuration
- **Repository**: [https://github.com/Fpadt/smart-R]
- **Target Environment**: Single-node VPS with external LoadBalancer IP

### Current Module Status
- ✅ **01-system-hardening**: Complete (Ubuntu security, SSH, firewall)
- ✅ **02-container-runtime**: Complete (Podman installation & config)  
- ✅ **03-kubernetes**: Complete (K3s cluster with kubectl)
- ✅ **04-ingress-controller**: Complete (Traefik with Let's Encrypt SSL)
- 🚧 **05-monitoring**: In development (Prometheus/Grafana)
- 📋 **06-backup**: Planned (automated backup solutions)
- 📋 **07-applications**: Planned (sample app deployments)

### Module Dependencies
```
01-system-hardening (base)
    ↓
02-container-runtime (podman)
    ↓  
03-kubernetes (k3s)
    ↓
04-ingress-controller (traefik) ← requires external IP
    ↓
05-monitoring (observability)
    ↓
06-backup (data protection)
    ↓
07-applications (workloads)
```

## 🔧 Key Patterns in This Project

### Script Structure
```bash
#!/bin/bash
set -euo pipefail

# 1. Source common functions library
source "$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")/lib/common.sh"

# 2. Load and validate environment variables  
load_env_with_validation "$SCRIPT_DIR/.env" "REQUIRED_VAR1" "REQUIRED_VAR2"

# 3. Main functions with descriptive names
verify_prerequisites() {
    log_section "Prerequisites Verification"
    # Check dependencies, ports, services
}

install_component() {
    log_section "Component Installation"
    # Template rendering, service installation
}

configure_component() {
    log_section "Component Configuration"
    # Apply configurations, restart services
}

verify_installation() {
    log_section "Installation Verification"
    # Test functionality, check ports, validate configs
}

# 4. Template rendering with envsubst
render_template "config.yaml" "/etc/app/config.yaml" true # with backup

# 5. Comprehensive logging with sections
log_info "Task starting..."
log_success "Task completed"
log_error "Task failed"
log_warning "Non-critical issue"
```

### Directory Structure
```
vps/
├── lib/
│   └── common.sh              # Shared functions (logging, templating, env)
├── config/                    # Global configuration files
├── tools/                     # Utility scripts
├── logs/                      # Script execution logs
├── backups/                   # Configuration backups
└── modules/
    └── XX-module-name/
        ├── scripts/           # Numbered execution scripts (01, 02, 03...)
        │   ├── 01-prepare-*.sh    # Prerequisites and validation
        │   ├── 02-install-*.sh    # Main installation
        │   ├── 03-configure-*.sh  # Configuration and setup
        │   ├── 04-verify-*.sh     # Testing and verification
        │   ├── 05-manage-*.sh     # Ongoing management
        │   └── setup.sh           # Run all scripts in sequence
        ├── templates/         # Config templates with ${VARS}
        ├── docs/             # Module documentation
        ├── .env.example      # Environment template
        └── .env             # Module environment (gitignored)
```

### Template Pattern
- All configurations are templates with `${VARIABLE}` placeholders
- Use `envsubst` for variable substitution
- Templates stored in `modules/XX/templates/`
- Backup original configs before replacement
- Validate YAML/JSON syntax after rendering

### Testing and Verification Patterns
```bash
# Always include verification after installation
verify_service() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_success "$SERVICE_NAME is running"
    else
        log_error "$SERVICE_NAME failed to start"
        return 1
    fi
}

# Test connectivity and functionality
test_connectivity() {
    if curl -sf "http://localhost:$PORT/health" >/dev/null; then
        log_success "Service responding on port $PORT"
    else
        log_error "Service not responding"
        return 1
    fi
}
```

## 🎯 Common Tasks for Claude

### 🔧 **Script Development**
```
"Create a new script for module XX that follows the project pattern:
- Purpose: [describe what the script should accomplish]
- Dependencies: [list prerequisite modules/services]
- Configuration: [describe config templates needed]
- Verification: [describe how to test success]

Reference patterns from: modules/04-ingress-controller/scripts/02-install-traefik.sh
Use common.sh functions for logging and template rendering."
```

### 🐛 **Debugging**
```
"Debug this error in module XX:
- Error message: [paste complete error with context]
- Script path: modules/XX/scripts/problematic-script.sh
- Environment: [paste relevant .env variables]
- Expected behavior: [describe what should happen]
- System info: [Ubuntu version, services running]

Common debugging steps:
1. Check service status: systemctl status service-name
2. Review logs: journalctl -u service-name -f
3. Verify network: ss -tlnp | grep port
4. Check file permissions and ownership"
```

### 📝 **Documentation**
```
"Generate documentation for module XX following our README pattern:
- Overview and purpose
- Prerequisites (from other modules)
- Installation steps (numbered scripts)
- Configuration options (.env variables)
- Troubleshooting guide (common issues)
- Management commands (ongoing operations)

Reference example: modules/04-ingress-controller/README.md
Include command examples and expected outputs."
```

### 🔄 **Refactoring**
```
"Refactor this script to use our established patterns:
- Current script: [path or paste script content]
- Issues: [describe what needs improvement]
- Target: [describe desired improvements]

Apply these patterns:
- Use common.sh logging functions
- Extract configs to templates/
- Add proper error handling with set -euo pipefail
- Include verification steps
- Add backup functionality for config changes"
```

### 🔍 **Code Review**
```
"Review this script for our quality standards:
- Security: no hardcoded secrets, proper permissions
- Reliability: idempotent operations, error handling
- Maintainability: clear functions, good logging
- Testing: verification steps, health checks

Check against: docs/QUALITY_STANDARDS.md"
```

## 📋 Environment Variables by Module

### Global Variables (all modules)
```bash
# System identification
HOME_IP="192.168.1.100"        # Home/office IP for SSH access
EMAIL="admin@example.com"       # For notifications and certificates
SSH_USER="ubuntu"               # SSH username
SSH_PORT="22"                   # SSH port (changed during hardening)

# Server identification  
SERVER_NAME="vps-prod-01"       # Hostname
PUBLIC_IP="203.0.113.10"        # External LoadBalancer IP
```

### Module-Specific Variables
```bash
# 01-system-hardening
UFW_ALLOWED_PORTS="22,80,443"
FAIL2BAN_ENABLED="true"

# 03-kubernetes
K3S_VERSION="v1.28.5+k3s1"
K3S_NODE_NAME="k3s-node-01"
KUBECONFIG="/home/ubuntu/.kube/config"

# 04-ingress-controller
DOMAIN_PRIMARY="example.com"
DOMAIN_SECONDARY="example.net"
CF_DNS_API_TOKEN="your-cloudflare-token"
TRAEFIK_NAMESPACE="traefik"
INGRESS_CLASS="traefik"

# 05-monitoring (planned)
GRAFANA_ADMIN_PASSWORD="secure-password"
PROMETHEUS_RETENTION="30d"
```

## 🔒 Security Considerations

### Secrets Management
- **Never commit secrets**: Use `.env.example` templates
- **Environment validation**: Scripts validate required variables exist
- **Backup security**: Encrypt backups containing sensitive data
- **Access control**: Scripts check user permissions before proceeding

### Configuration Security
```bash
# Always validate inputs
validate_domain() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid domain format: $1"
        return 1
    fi
}

# Secure file permissions
secure_config() {
    sudo chown root:root "$CONFIG_FILE"
    sudo chmod 600 "$CONFIG_FILE"
}
```

## ⚡ Quality Standards

### Script Requirements
- **Idempotent**: Can run multiple times safely
- **Atomic**: Either complete successfully or fail cleanly
- **Logged**: All actions logged with appropriate levels
- **Tested**: Include verification and health checks
- **Documented**: Clear comments and documentation

### Error Handling
```bash
# Always use strict error handling
set -euo pipefail

# Trap errors for cleanup
cleanup() {
    log_error "Script failed at line $1"
    # Cleanup temporary files, reset services, etc.
}
trap 'cleanup $LINENO' ERR

# Validate before proceeding
validate_prerequisites() {
    command -v kubectl >/dev/null || {
        log_error "kubectl not found"
        exit 1
    }
}
```

### Performance Considerations
- **Resource limits**: All deployments include resource requests/limits
- **Monitoring**: Include resource usage in verification steps
- **Optimization**: Use efficient base images and minimal installations
- **Scaling**: Consider single-node limitations in configurations

## 🛠️ Common Issues and Solutions

### Module 03 (K3s)
```bash
# Issue: kubectl connection refused
# Solution: Check k3s service and copy kubeconfig
sudo systemctl status k3s
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

### Module 04 (Traefik)
```bash
# Issue: SSL certificates not issued
# Solution: Check DNS propagation and Cloudflare API
dig +short yourdomain.com
curl -H "Authorization: Bearer $CF_DNS_API_TOKEN" \
     "https://api.cloudflare.com/client/v4/user/tokens/verify"
```

### General Debugging
```bash
# Check service logs
journalctl -u service-name -f --no-pager

# Verify network connectivity
ss -tlnp | grep :80
curl -I http://localhost:port/health

# Check resource usage
kubectl top nodes
kubectl top pods -A
```

## 🔄 Development Workflow

### Adding New Modules
1. **Plan**: Define purpose, dependencies, and integration points
2. **Structure**: Create directory with scripts/, templates/, docs/
3. **Develop**: Follow script patterns and quality standards
4. **Test**: Verify on clean Ubuntu 24.04 LTS system
5. **Document**: Update this guide and module README
6. **Integrate**: Update setup.sh and dependency documentation

### Git Workflow
```bash
# Feature development
git checkout -b feature/module-XX-component
# ... develop and test
git add modules/XX-component/
git commit -m "feat: add XX component with SSL configuration"

# Keep .env files local
echo "modules/*/\.env" >> .gitignore
```

### Version Management
- Tag stable releases: `git tag v1.0.0`
- Document breaking changes in CHANGELOG.md
- Maintain backward compatibility in common.sh
- Test upgrades on non-production systems first

---

*This guide is maintained alongside the VPS configuration project. Update it when adding new patterns or modules.*