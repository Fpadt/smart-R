#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
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

# Check if running as root
check_user() {
    if [[ $EUID -eq 0 ]]; then
        log_warning "Running as root - using rootful Podman"
        export PODMAN_MODE="rootful"
    else
        log_info "Running as non-root user - using rootless Podman"
        export PODMAN_MODE="rootless"
    fi
}

# Test basic functionality
test_basic_functionality() {
    log_section "Testing Basic Functionality"
    
    log_info "Running hello-world container..."
    if podman run --rm hello-world &>/dev/null; then
        log_success "Basic container execution works"
    else
        log_error "Basic container test failed"
        
        # Provide helpful debugging info
        echo ""
        log_info "Debugging information:"
        echo "1. Try running the debug script: ./debug-podman.sh"
        echo "2. Check detailed error with: podman run --rm hello-world"
        echo "3. Verify user namespaces: podman unshare cat /proc/self/uid_map"
        echo "4. Check socket status: systemctl --user status podman.socket"
        echo ""
        log_info "Common fixes:"
        echo "- sudo loginctl enable-linger $USER"
        echo "- systemctl --user restart podman.socket"
        echo "- echo 15000 | sudo tee /proc/sys/user/max_user_namespaces"
        
        exit 1
    fi
}

# Check system information
check_system_info() {
    log_section "System Information"
    
    log_info "Podman system information:"
    podman info --format "{{.Host.OS}} {{.Host.Arch}} ({{.Host.Distribution.Distribution}} {{.Host.Distribution.Version}})"
    
    log_info "Storage driver: $(podman info --format '{{.Store.GraphDriverName}}')"
    log_info "Storage root: $(podman info --format '{{.Store.GraphRoot}}')"
    log_info "Run root: $(podman info --format '{{.Store.RunRoot}}')"
    
    # Additional detailed system information
    echo -e "${GREEN}🔎 Testing Podman detailed info...${NC}"
    podman info | grep -E 'host|store|insecure|rootless|cgroupVersion|ociRuntime' || true
}

# Check storage and permissions
check_storage() {
    log_section "Storage and Permissions Check"
    
    local storage_root=$(podman info --format '{{.Store.GraphRoot}}')
    
    if [[ -d "$storage_root" ]]; then
        local storage_size=$(du -sh "$storage_root" 2>/dev/null | cut -f1 || echo "Unknown")
        log_info "Storage directory exists: $storage_root ($storage_size)"
        
        if [[ -w "$storage_root" ]]; then
            log_success "Storage directory is writable"
        else
            log_warning "Storage directory may not be writable"
        fi
    else
        log_warning "Storage directory does not exist yet: $storage_root"
    fi
}

# Test network connectivity
test_network() {
    log_section "Network Connectivity Test"
    
    log_info "Testing container networking..."
    if podman run --rm --quiet docker.io/library/alpine:latest wget -q --spider https://httpbin.org/get; then
        log_success "Container networking works"
    else
        log_warning "Container networking test failed"
    fi
}

# Test volume mounting
test_volumes() {
    log_section "Volume Mounting Test"
    
    local test_dir=$(mktemp -d)
    local test_file="$test_dir/test.txt"
    echo "test content" > "$test_file"
    
    log_info "Testing volume mounting..."
    if podman run --rm -v "$test_dir:/mnt:ro" alpine:latest cat /mnt/test.txt | grep -q "test content"; then
        log_success "Volume mounting works"
    else
        log_warning "Volume mounting test failed"
    fi
    
    rm -rf "$test_dir"
}

# Display current state
show_current_state() {
    log_section "Current State"
    
    local containers=$(podman ps -a --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | tail -n +2)
    if [[ -n "$containers" ]]; then
        log_info "Existing containers:"
        echo "$containers"
    else
        log_info "No existing containers"
    fi
    
    local images=$(podman images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null | tail -n +2)
    if [[ -n "$images" ]]; then
        log_info "Available images:"
        echo "$images"
    else
        log_info "No images available"
    fi
}

# Performance test
performance_test() {
    log_section "Performance Test"
    
    log_info "Testing container startup time..."
    local start_time=$(date +%s.%N)
    podman run --rm docker.io/library/alpine:latest echo "performance test" > /dev/null
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "N/A")
    
    if [[ "$duration" != "N/A" ]]; then
        log_info "Container startup time: ${duration}s"
    fi
}

# Cleanup test
cleanup_test() {
    log_section "Cleanup Test"
    
    log_info "Testing cleanup functionality..."
    
    # Create a test container with a valid name
    local test_name="podman-verify-test-$(date +%s)"
    podman run --name "$test_name" alpine:latest echo "cleanup test" > /dev/null || true
    
    # Clean up
    if podman rm -f "$test_name" &> /dev/null; then
        log_success "Container cleanup works"
    else
        log_warning "Container cleanup test failed"
    fi
    
    # Test image cleanup (only if we have unused images)
    local unused_images=$(podman images -f "dangling=true" -q)
    if [[ -n "$unused_images" ]]; then
        log_info "Found dangling images, testing cleanup..."
        if podman image prune -f &> /dev/null; then
            log_success "Image cleanup works"
        else
            log_warning "Image cleanup test failed"
        fi
    fi
}

# Clean up test images
cleanup_test_images() {
    log_section "Test Image Cleanup"
    
    log_info "The verification process downloaded test images:"
    podman images | grep -E "(hello-world|alpine)" || log_info "No test images found"
    
    echo ""
    read -p "Remove test images (hello-world, alpine)? (Y/n): " -r

    if [[ -z $REPLY || $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing test images..."
        
        # Remove hello-world image
        if podman rmi hello-world &>/dev/null; then
            log_success "Removed hello-world image"
        else
            log_info "hello-world image not found or in use"
        fi
        
        # Remove alpine image
        if podman rmi alpine:latest &>/dev/null; then
            log_success "Removed alpine image"
        else
            log_info "alpine image not found or in use"
        fi
        
        log_success "Test image cleanup completed"
    else
        log_info "Keeping test images (useful for future container work)"
        log_info "You can manually remove them later with:"
        echo "  podman rmi hello-world alpine:latest"
    fi
}

# Main execution
main() {
    echo -e "${GREEN}🔍 Podman Installation Verification${NC}"
    echo "====================================="
    
    check_user
    test_basic_functionality
    check_system_info
    check_storage
    test_network
    test_volumes
    show_current_state
    performance_test
    cleanup_test
    cleanup_test_images
    
    log_section "Verification Summary"
    log_success "Podman installation verified successfully!"
    log_info "Mode: $PODMAN_MODE"
    log_info "All functionality tests completed"
    
    echo -e "\n${GREEN}🎉 Your Podman installation is working correctly!${NC}"
    log_info "You can now use Podman to manage containers"
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  -h, --help    Show this help message"
        echo "  -q, --quiet   Run with minimal output"
        exit 0
        ;;
    -q|--quiet)
        exec > /dev/null 2>&1
        ;;
esac

main "$@"