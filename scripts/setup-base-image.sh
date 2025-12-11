#!/bin/bash
# setup-base-image.sh - Download and prepare Fedora cloud base image
# ==================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(dirname "$SCRIPT_DIR")"

# Load configuration
CONFIG_FILE="${TESTING_DIR}/config.yaml"

# Default values (can be overridden by config)
FEDORA_VERSION="${FEDORA_VERSION:-41}"
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
    
    for cmd in wget qemu-img virsh; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: sudo dnf install wget qemu-img libvirt"
        exit 1
    fi
}

# Download Fedora cloud image
download_image() {
    local version="$1"
    local dest_dir="$2"
    local dest_file="${dest_dir}/${BASE_IMAGE_NAME}"
    
    # Fedora cloud image URL
    local base_url="https://download.fedoraproject.org/pub/fedora/linux/releases"
    local image_name="Fedora-Cloud-Base-Generic.x86_64-${version}-1.4.qcow2"
    local download_url="${base_url}/${version}/Cloud/x86_64/images/${image_name}"
    
    if [[ -f "$dest_file" ]]; then
        log_warning "Base image already exists at ${dest_file}"
        read -p "Do you want to re-download? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Using existing image"
            return 0
        fi
    fi
    
    log_info "Downloading Fedora ${version} cloud image..."
    log_info "URL: ${download_url}"
    
    # Create directory if needed
    sudo mkdir -p "$dest_dir"
    
    # Download to temp location first
    local temp_file="/tmp/fedora-cloud-download.qcow2"
    
    if wget --progress=bar:force -O "$temp_file" "$download_url"; then
        sudo mv "$temp_file" "$dest_file"
        sudo chown root:root "$dest_file"
        sudo chmod 644 "$dest_file"
        log_success "Image downloaded to ${dest_file}"
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
                echo "  --version, -v    Fedora version (default: 41)"
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

