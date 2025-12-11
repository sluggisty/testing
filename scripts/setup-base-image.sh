#!/bin/bash
# setup-base-image.sh - Download and prepare Fedora cloud base image
# ==================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(dirname "$SCRIPT_DIR")"

# Load configuration
CONFIG_FILE="${TESTING_DIR}/config.yaml"

# Default values (can be overridden by config)
FEDORA_VERSION="${FEDORA_VERSION:-42}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
BASE_IMAGE_NAME="fedora-cloud-base.qcow2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check for required tools
check_requirements() {
    local missing=()
    
    for cmd in curl qemu-img virsh; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: sudo dnf install curl qemu-img libvirt"
        exit 1
    fi
}

# Find the correct image name from Fedora's directory listing
find_image_name() {
    local version="$1"
    local base_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/x86_64/images/"
    
    # Try to get directory listing and find the qcow2 image
    local image_name
    image_name=$(curl -sL "$base_url" | grep -oE 'Fedora-Cloud-Base[^"]+\.qcow2' | head -1 || true)
    
    if [[ -z "$image_name" ]]; then
        # Fallback: try common naming patterns
        for pattern in \
            "Fedora-Cloud-Base-Generic-${version}-1.6.x86_64.qcow2" \
            "Fedora-Cloud-Base-Generic.x86_64-${version}-1.6.qcow2" \
            "Fedora-Cloud-Base-Generic-${version}-1.5.x86_64.qcow2" \
            "Fedora-Cloud-Base-Generic.x86_64-${version}-1.5.qcow2" \
            "Fedora-Cloud-Base-Generic-${version}-1.4.x86_64.qcow2" \
            "Fedora-Cloud-Base-Generic.x86_64-${version}-1.4.qcow2" \
            "Fedora-Cloud-Base-${version}-1.6.x86_64.qcow2" \
            "Fedora-Cloud-Base-${version}-1.5.x86_64.qcow2" \
            "Fedora-Cloud-Base-${version}-1.4.x86_64.qcow2"; do
            
            local test_url="${base_url}${pattern}"
            if curl -sIf "$test_url" >/dev/null 2>&1; then
                echo "$pattern"
                return 0
            fi
        done
    else
        echo "$image_name"
        return 0
    fi
    
    return 1
}

# Download Fedora cloud image
download_image() {
    local version="$1"
    local dest_dir="$2"
    local dest_file="${dest_dir}/${BASE_IMAGE_NAME}"
    
    if [[ -f "$dest_file" ]]; then
        log_warning "Base image already exists at ${dest_file}"
        read -p "Do you want to re-download? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Using existing image"
            return 0
        fi
    fi
    
    log_info "Finding Fedora ${version} cloud image..."
    
    # Find the correct image name
    local image_name
    if ! image_name=$(find_image_name "$version"); then
        log_error "Could not find Fedora ${version} cloud image"
        log_info "Try a different version with: $0 --version 42"
        log_info "Or download manually from: https://fedoraproject.org/cloud/download"
        exit 1
    fi
    
    local base_url="https://download.fedoraproject.org/pub/fedora/linux/releases"
    local download_url="${base_url}/${version}/Cloud/x86_64/images/${image_name}"
    
    log_info "Found image: ${image_name}"
    log_info "Downloading from: ${download_url}"
    
    # Create directory if needed
    sudo mkdir -p "$dest_dir"
    
    # Download to temp location first
    local temp_file="/tmp/fedora-cloud-download.qcow2"
    
    # Use curl with better progress and redirect following
    if curl -L --progress-bar -o "$temp_file" "$download_url"; then
        # Verify it's a valid qcow2 image (not an error page)
        if file "$temp_file" | grep -q "QEMU QCOW"; then
            sudo mv "$temp_file" "$dest_file"
            sudo chown root:root "$dest_file"
            sudo chmod 644 "$dest_file"
            log_success "Image downloaded to ${dest_file}"
        else
            log_error "Downloaded file is not a valid QCOW2 image"
            log_info "The file might be an error page. Try downloading manually."
            rm -f "$temp_file"
            exit 1
        fi
    else
        log_error "Failed to download image"
        rm -f "$temp_file"
        exit 1
    fi
}

# Verify image
verify_image() {
    local image_path="$1"
    
    log_info "Verifying image..."
    
    if qemu-img info "$image_path" &> /dev/null; then
        local format
        format=$(qemu-img info "$image_path" | grep "file format" | awk '{print $3}')
        local size
        size=$(qemu-img info "$image_path" | grep "virtual size" | awk '{print $3}')
        
        log_success "Image verified: format=${format}, size=${size}"
    else
        log_error "Image verification failed"
        exit 1
    fi
}

# Main
main() {
    log_info "=== Fedora Cloud Image Setup ==="
    
    check_requirements
    
    # Parse command line args
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version|-v)
                FEDORA_VERSION="$2"
                shift 2
                ;;
            --dir|-d)
                IMAGE_DIR="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--version VERSION] [--dir DIRECTORY]"
                echo ""
                echo "Options:"
                echo "  --version, -v    Fedora version (default: 42)"
                echo "  --dir, -d        Image directory (default: /var/lib/libvirt/images)"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    download_image "$FEDORA_VERSION" "$IMAGE_DIR"
    verify_image "${IMAGE_DIR}/${BASE_IMAGE_NAME}"
    
    log_success "Base image setup complete!"
    echo ""
    echo "Base image location: ${IMAGE_DIR}/${BASE_IMAGE_NAME}"
    echo "You can now run: ./scripts/create-vms.sh"
}

main "$@"

