# Claude.ai Collaboration Guide

## 🎯 Quick Context for Claude

### Project Overview
- **Purpose**: Production-ready VPS configuration system
- **Stack**: Ubuntu 24.04 LTS, K3s, Traefik, Podman
- **Architecture**: Modular scripts with template-driven configuration
- **Repository**: [Your GitHub URL]

### Current Module Status
- ✅ **01-system-hardening**: Complete (Ubuntu security)
- ✅ **02-container-runtime**: Complete (Podman)  
- ✅ **03-kubernetes**: Complete (K3s cluster)
- ✅ **04-ingress-controller**: Complete (Traefik SSL)
- 🚧 **05-monitoring**: In development
- 📋 **06-backup**: Planned

### Key Patterns in This Project

#### Script Structure
```bash
#!/bin/bash
set -euo pipefail

# 1. Source common functions
source "$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")/lib/common.sh"

# 2. Load environment variables  
load_env() {
    local env_file="$SCRIPT_DIR/.env"
    # ... load and validate
}

# 3. Template rendering with envsubst
render_template() {
    # Pattern: templates/file.yaml -> target/file.yaml with ${VAR} substitution
}

# 4. Comprehensive logging
log_info "Task starting..."
log_success "Task completed"
log_error "Task failed"
```

#### Directory Structure
```
vps/
├── lib/common.sh              # Shared functions
├── modules/
│   └── XX-module-name/
│       ├── scripts/           # Numbered execution scripts
│       ├── templates/         # Config templates with ${VARS}
│       ├── docs/             # Module documentation
│       └── .env              # Module environment
```

#### Template Pattern
- All configs are templates with `${VARIABLE}` placeholders
- Use `envsubst` for variable substitution
- Templates enable reusability across environments

### Common Tasks for Claude

#### 🔧 **Script Development**
```
"Create a new script for module XX that follows the project pattern:
- Uses common.sh functions
- Includes template rendering
- Has comprehensive error handling
- Template: https://github.com/user/repo/blob/main/modules/01-system-hardening/scripts/01-check-system.sh"
```

#### 🐛 **Debugging**
```
"Debug this error in module XX:
- Error message: [paste error]
- Relevant script: https://github.com/user/repo/blob/main/modules/XX/scripts/problematic-script.sh
- Expected behavior: [describe]"
```

#### 📝 **Documentation**
```
"Generate documentation for module XX following our README pattern:
- Installation steps
- Configuration options  
- Troubleshooting guide
- Example: https://github.com/user/repo/blob/main/modules/04-ingress-controller/README.md"
```

#### 🔄 **Refactoring**
```
"Refactor this script to use our template pattern:
- Current script: https://github.com/user/repo/blob/main/path/to/script.sh
- Should use templates from: modules/XX/templates/
- Follow common.sh pattern"
```

### Environment Variables by Module
- **System**: `HOME_IP`, `EMAIL`, `SSH_USER`, `SSH_PORT`
- **K3s**: `K3S_VERSION`, `K3S_NODE_NAME`, `PUBLIC_IP`
- **Traefik**: `DOMAIN_PRIMARY`, `CF_DNS_API_TOKEN`, `TRAEFIK_NAMESPACE`

### Security Considerations
- No secrets in GitHub (use .env.example templates)
- All scripts handle missing variables gracefully
- Backup configs before changes
- Comprehensive logging for audit trails

### Quality Standards
- All scripts must be idempotent
- Include verification steps
- Comprehensive error handling with `set -euo pipefail`
- Template-driven configuration
- Modular, reusable components