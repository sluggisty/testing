#!/bin/bash
# setup-base-image.sh - Download and prepare cloud base images (Fedora/Debian)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(dirname "$SCRIPT_DIR")"

# Load configuration
CONFIG_FILE="${TESTING_DIR}/config.yaml"

# Default values (can be overridden by config)
DISTRO="${DISTRO:-fedora}"
VERSION="${VERSION:-42}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"

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

# Find the correct Debian image name
find_debian_image_name() {
    local version="$1"
    
    # Debian version to codename mapping
    local codename=""
    case "$version" in
        "12") codename="bookworm" ;;
        "11") codename="bullseye" ;;
        "10") codename="buster" ;;
        "9") codename="stretch" ;;
        *)
            log_error "Unsupported Debian version: $version"
            return 1
            ;;
    esac
    
    # Debian cloud images are at:
    # https://cloud.debian.org/images/cloud/<codename>/latest/
    local base_url="https://cloud.debian.org/images/cloud/${codename}/latest/"
    
    # Try to find the generic cloud image
    local image_name
    image_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE 'debian-[0-9]+-generic[^"]*\.qcow2' | head -1 || true)
    
    if [[ -n "$image_name" ]]; then
        echo "$image_name"
        echo "$base_url" > /tmp/debian_base_url_${version}
        return 0
    fi
    
    # Fallback: try common naming patterns
    for pattern in \
        "debian-${version}-generic-amd64-*.qcow2" \
        "debian-${version}-genericcloud-amd64-*.qcow2" \
        "debian-${codename}-generic-amd64-*.qcow2" \
        "debian-${codename}-genericcloud-amd64-*.qcow2"; do
        
        # Try to find actual file matching pattern
        local found_name
        found_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE "$(echo "$pattern" | sed 's/\*/[^"]*/g')" | head -1 || true)
        if [[ -n "$found_name" ]]; then
            echo "$found_name"
            echo "$base_url" > /tmp/debian_base_url_${version}
            return 0
        fi
    done
    
    return 1
}

# Find the correct Ubuntu image name
find_ubuntu_image_name() {
    local version="$1"
    
    # Ubuntu version to codename mapping
    local codename
    case "$version" in
        "24.04")
            codename="noble"
            ;;
        "23.10")
            codename="mantic"
            ;;
        "23.04")
            codename="lunar"
            ;;
        "22.04")
            codename="jammy"
            ;;
        "20.04")
            codename="focal"
            ;;
        "18.04")
            codename="bionic"
            ;;
        *)
            log_error "Unsupported Ubuntu version: $version"
            return 1
            ;;
    esac
    
    # Ubuntu cloud images are at:
    # https://cloud-images.ubuntu.com/{codename}/current/
    local base_url="https://cloud-images.ubuntu.com/${codename}/current/"
    
    # Try to find the KVM-optimized image first (recommended for libvirt)
    local image_name
    image_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE "${codename}-server-cloudimg-amd64-disk-kvm\.img" | head -1 || true)
    
    if [[ -n "$image_name" ]]; then
        echo "$image_name"
        echo "$base_url" > /tmp/ubuntu_base_url_${version//./_}
        return 0
    fi
    
    # Fallback: try standard image (not KVM-optimized)
    image_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE "${codename}-server-cloudimg-amd64\.img" | head -1 || true)
    
    if [[ -n "$image_name" ]]; then
        echo "$image_name"
        echo "$base_url" > /tmp/ubuntu_base_url_${version//./_}
        return 0
    fi
    
    return 1
}

# Find the correct CentOS image name
find_centos_image_name() {
    local version="$1"
    
    # CentOS cloud images are at:
    # https://cloud.centos.org/centos/{version}-stream/x86_64/images/ (for Stream 9, 8)
    # https://cloud.centos.org/centos/{version}/x86_64/images/ (for CentOS 7)
    local base_url
    if [[ "$version" == "9" || "$version" == "8" ]]; then
        base_url="https://cloud.centos.org/centos/${version}-stream/x86_64/images/"
    else
        # CentOS 7 and older
        base_url="https://cloud.centos.org/centos/${version}/x86_64/images/"
    fi
    
    # CentOS Stream images are named like: CentOS-Stream-GenericCloud-9-20250101.0.x86_64.qcow2
    # CentOS 7 images are named like: CentOS-7-x86_64-GenericCloud-*.qcow2
    local image_name
    
    if [[ "$version" == "9" || "$version" == "8" ]]; then
        # For Stream versions, look for CentOS-Stream-GenericCloud-{version}-*.qcow2
        image_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE 'CentOS-Stream-GenericCloud-'${version}'-[0-9]+[^"]*\.x86_64\.qcow2' | head -1 || true)
    else
        # For CentOS 7, look for CentOS-7-x86_64-GenericCloud-*.qcow2
        image_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE 'CentOS-'${version}'-x86_64-GenericCloud[^"]*\.qcow2' | head -1 || true)
    fi
    
    if [[ -n "$image_name" ]]; then
        echo "$image_name"
        echo "$base_url" > /tmp/centos_base_url_${version}
        return 0
    fi
    
    # Fallback: try more generic patterns
    if [[ "$version" == "9" || "$version" == "8" ]]; then
        image_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE 'CentOS-Stream[^"]*GenericCloud[^"]*\.qcow2' | grep -v "\.MD5SUM\|\.SHA" | head -1 || true)
    else
        image_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE 'CentOS-'${version}'[^"]*GenericCloud[^"]*\.qcow2' | grep -v "\.MD5SUM\|\.SHA" | head -1 || true)
    fi
    
    if [[ -n "$image_name" ]]; then
        echo "$image_name"
        echo "$base_url" > /tmp/centos_base_url_${version}
        return 0
    fi
    
    return 1
}

# Find the correct image name from Fedora's directory listing
find_fedora_image_name() {
    local version="$1"
    
    # Determine which location to try first
    # Versions 40 and below are in archive, 41+ are in main releases
    local try_archive_first=false
    if [[ "$version" -le 40 ]]; then
        try_archive_first=true
    fi
    
    # Function to try finding image at a given base URL
    try_find_at_url() {
        local base_url="$1"
        local url_label="$2"
        
        # Try to get directory listing and find the qcow2 image
        local image_name
        image_name=$(curl -sL "$base_url" 2>/dev/null | grep -oE 'Fedora-Cloud-Base[^"]+\.qcow2' | head -1 || true)
        
        if [[ -n "$image_name" ]]; then
            echo "$image_name"
            echo "$base_url" > /tmp/fedora_base_url_${version}
            return 0
        fi
        
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
            # Check if URL exists and returns actual content (not error page)
            local http_code
            http_code=$(curl -sL -o /dev/null -w "%{http_code}" "$test_url" 2>/dev/null || echo "000")
            
            if [[ "$http_code" == "200" ]]; then
                # Download a small chunk to verify it's not HTML
                local test_content
                test_content=$(curl -sL -r 0-100 "$test_url" 2>/dev/null || true)
                
                # Check if it looks like QCOW2 (starts with QFI\xfb) or is HTML
                local looks_like_qcow2=false
                if echo "$test_content" | head -c 4 | hexdump -e '4/1 "%02x"' 2>/dev/null | grep -q "^514649fb"; then
                    looks_like_qcow2=true
                elif ! echo "$test_content" | grep -qE "<html|<!DOCTYPE"; then
                    # If it doesn't look like HTML, assume it might be binary (qcow2)
                    looks_like_qcow2=true
                fi
                
                if [[ "$looks_like_qcow2" == "true" ]]; then
                    echo "$pattern"
                    echo "$base_url" > /tmp/fedora_base_url_${version}
                    return 0
                fi
            fi
        done
        
        return 1
    }
    
    # Try archive location first for versions 40 and below
    if [[ "$try_archive_first" == "true" ]]; then
        local archive_url="https://archive.fedoraproject.org/pub/archive/fedora/linux/releases/${version}/Cloud/x86_64/images/"
        if try_find_at_url "$archive_url" "archive"; then
            return 0
        fi
    fi
    
    # Try main releases location
    local main_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/x86_64/images/"
    if try_find_at_url "$main_url" "main"; then
        return 0
    fi
    
    # If archive wasn't tried first, try it now as fallback
    if [[ "$try_archive_first" != "true" ]] && [[ "$version" -le 40 ]]; then
        local archive_url="https://archive.fedoraproject.org/pub/archive/fedora/linux/releases/${version}/Cloud/x86_64/images/"
        if try_find_at_url "$archive_url" "archive"; then
            return 0
        fi
    fi
    
    return 1
}

# Download Debian cloud image
download_debian_image() {
    local version="$1"
    local dest_dir="$2"
    local dest_file="${dest_dir}/debian-cloud-base-${version}.qcow2"
    
    if [[ -f "$dest_file" ]]; then
        log_warning "Base image already exists at ${dest_file}"
        read -p "Do you want to re-download? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Using existing image"
            return 0
        fi
    fi
    
    log_info "Finding Debian ${version} cloud image..."
    
    # Find the correct image name
    local image_name
    if ! image_name=$(find_debian_image_name "$version"); then
        log_error "Could not find Debian ${version} cloud image"
        log_info "This version may be too old or no longer available."
        log_info "Try a different version with: $0 --distro debian --version 12"
        log_info "Or check: https://cloud.debian.org/images/cloud/"
        exit 1
    fi
    
    # Get base URL from temp file (set by find_debian_image_name)
    local base_url
    if [[ -f "/tmp/debian_base_url_${version}" ]]; then
        base_url=$(cat "/tmp/debian_base_url_${version}")
        rm -f "/tmp/debian_base_url_${version}"
    else
        # Fallback: construct URL from version
        local codename=""
        case "$version" in
            "12") codename="bookworm" ;;
            "11") codename="bullseye" ;;
            "10") codename="buster" ;;
            "9") codename="stretch" ;;
        esac
        base_url="https://cloud.debian.org/images/cloud/${codename}/latest/"
    fi
    
    local download_url="${base_url}${image_name}"
    
    log_info "Found image: ${image_name}"
    log_info "Downloading from: ${download_url}"
    
    # Create directory if needed
    sudo mkdir -p "$dest_dir"
    
    # Download to temp location first
    local temp_file="/tmp/debian-cloud-download-${version}.qcow2"
    
    # Use curl with better progress and redirect following
    if curl -L --progress-bar -f -o "$temp_file" "$download_url" 2>&1; then
        # Verify it's a valid qcow2 image
        local file_size
        file_size=$(stat -f%z "$temp_file" 2>/dev/null || stat -c%s "$temp_file" 2>/dev/null || echo "0")
        
        # Check if it's HTML (error page)
        if head -c 100 "$temp_file" | grep -q "<html\|<!DOCTYPE\|404\|Not Found\|Error"; then
            log_error "Downloaded file appears to be an HTML error page"
            log_info "The image may not be available for Debian ${version}"
            rm -f "$temp_file"
            exit 1
        fi
        
        # Check if it's a QCOW2 file
        local is_qcow2=false
        if command -v hexdump &> /dev/null; then
            local magic
            magic=$(hexdump -n 4 -e '4/1 "%02x"' "$temp_file" 2>/dev/null || echo "")
            if [[ "$magic" == "514649fb" ]]; then
                is_qcow2=true
            fi
        elif command -v od &> /dev/null; then
            local magic
            magic=$(od -An -tx1 -N 4 "$temp_file" 2>/dev/null | tr -d ' \n' || echo "")
            if [[ "$magic" == "514649fb" ]]; then
                is_qcow2=true
            fi
        fi
        
        if file "$temp_file" 2>/dev/null | grep -qE "QEMU QCOW|QCOW"; then
            is_qcow2=true
        fi
        
        if [[ "$is_qcow2" == "true" ]]; then
            if [[ $file_size -lt 104857600 ]]; then
                log_warning "File size is small (${file_size} bytes). This might not be a complete image."
            fi
            
            sudo mv "$temp_file" "$dest_file"
            sudo chown root:root "$dest_file"
            sudo chmod 644 "$dest_file"
            log_success "Image downloaded to ${dest_file}"
        else
            log_error "Downloaded file is not a valid QCOW2 image"
            rm -f "$temp_file"
            exit 1
        fi
    else
        log_error "Failed to download image"
        rm -f "$temp_file"
        exit 1
    fi
}

# Download Ubuntu cloud image
download_ubuntu_image() {
    local version="$1"
    local dest_dir="$2"
    # Ubuntu images use .img extension but are QCOW2 format
    # We'll rename to .qcow2 for consistency
    local dest_file="${dest_dir}/ubuntu-cloud-base-${version//./_}.qcow2"
    
    if [[ -f "$dest_file" ]]; then
        log_warning "Base image already exists at ${dest_file}"
        read -p "Do you want to re-download? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Using existing image"
            return 0
        fi
    fi
    
    log_info "Finding Ubuntu ${version} cloud image..."
    
    # Find the correct image name
    local image_name
    if ! image_name=$(find_ubuntu_image_name "$version"); then
        log_error "Could not find Ubuntu ${version} cloud image"
        log_info "This version may be too old or no longer available."
        log_info "Try a different version with: $0 --distro ubuntu --version 24.04"
        log_info "Or check: https://cloud-images.ubuntu.com/"
        exit 1
    fi
    
    # Get base URL from temp file (set by find_ubuntu_image_name)
    local base_url
    local version_key="${version//./_}"
    if [[ -f "/tmp/ubuntu_base_url_${version_key}" ]]; then
        base_url=$(cat "/tmp/ubuntu_base_url_${version_key}")
        rm -f "/tmp/ubuntu_base_url_${version_key}"
    else
        # Fallback: construct URL from version
        local codename=""
        case "$version" in
            "24.04") codename="noble" ;;
            "22.04") codename="jammy" ;;
            "20.04") codename="focal" ;;
            "18.04") codename="bionic" ;;
        esac
        base_url="https://cloud-images.ubuntu.com/${codename}/current/"
    fi
    
    local download_url="${base_url}${image_name}"
    
    log_info "Found image: ${image_name}"
    log_info "Downloading from: ${download_url}"
    
    # Create directory if needed
    sudo mkdir -p "$dest_dir"
    
    # Download to temp location first
    local temp_file="/tmp/ubuntu-cloud-download-${version//./_}.img"
    
    # Use curl with better progress and redirect following
    if curl -L --progress-bar -f -o "$temp_file" "$download_url" 2>&1; then
        # Verify it's a valid qcow2 image (Ubuntu uses .img but it's QCOW2 format)
        local file_size
        file_size=$(stat -f%z "$temp_file" 2>/dev/null || stat -c%s "$temp_file" 2>/dev/null || echo "0")
        
        # Check if it's HTML (error page)
        if head -c 100 "$temp_file" | grep -q "<html\|<!DOCTYPE\|404\|Not Found\|Error"; then
            log_error "Downloaded file appears to be an HTML error page"
            log_info "The image may not be available for Ubuntu ${version}"
            rm -f "$temp_file"
            exit 1
        fi
        
        # Check QCOW2 magic bytes (Ubuntu .img files are actually QCOW2)
        local magic_bytes
        magic_bytes=$(head -c 4 "$temp_file" | od -An -tx1 | tr -d ' \n' || echo "")
        local is_qcow2=false
        if [[ "$magic_bytes" == "514649fb" ]]; then
            is_qcow2=true
        fi
        
        if [[ "$is_qcow2" == "true" ]]; then
            if [[ $file_size -lt 104857600 ]]; then
                log_warning "File size is small (${file_size} bytes). This might not be a complete image."
            fi
            
            sudo mv "$temp_file" "$dest_file"
            sudo chown root:root "$dest_file"
            sudo chmod 644 "$dest_file"
            log_success "Image downloaded to ${dest_file}"
        else
            log_error "Downloaded file is not a valid QCOW2 image"
            log_info "Magic bytes: ${magic_bytes} (expected: 514649fb)"
            log_info "File type: $(file "$temp_file" || echo 'unknown')"
            log_info "The file might be an error page or corrupted download."
            rm -f "$temp_file"
            exit 1
        fi
    else
        log_error "Failed to download image"
        log_info "URL might be incorrect or the file is no longer available"
        rm -f "$temp_file"
        exit 1
    fi
}

# Download CentOS cloud image
download_centos_image() {
    local version="$1"
    local dest_dir="$2"
    local dest_file="${dest_dir}/centos-cloud-base-${version}.qcow2"
    
    if [[ -f "$dest_file" ]]; then
        log_warning "Base image already exists at ${dest_file}"
        read -p "Do you want to re-download? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Using existing image"
            return 0
        fi
    fi
    
    log_info "Finding CentOS ${version} cloud image..."
    
    # Find the correct image name
    local image_name
    if ! image_name=$(find_centos_image_name "$version"); then
        log_error "Could not find CentOS ${version} cloud image"
        log_info "This version may be too old or no longer available."
        log_info "Try a different version with: $0 --distro centos --version 9"
        log_info "Or check: https://cloud.centos.org/"
        exit 1
    fi
    
    # Get base URL from temp file (set by find_centos_image_name)
    local base_url
    if [[ -f "/tmp/centos_base_url_${version}" ]]; then
        base_url=$(cat "/tmp/centos_base_url_${version}")
        rm -f "/tmp/centos_base_url_${version}"
    else
        # Fallback: construct URL from version
        if [[ "$version" == "9" || "$version" == "8" ]]; then
            base_url="https://cloud.centos.org/centos/${version}-stream/x86_64/images/"
        else
            base_url="https://cloud.centos.org/centos/${version}/x86_64/images/"
        fi
    fi
    
    local download_url="${base_url}${image_name}"
    
    log_info "Found image: ${image_name}"
    log_info "Downloading from: ${download_url}"
    
    # Create directory if needed
    sudo mkdir -p "$dest_dir"
    
    # Download to temp location first
    local temp_file="/tmp/centos-cloud-download-${version}.qcow2"
    
    # Use curl with better progress and redirect following
    if curl -L --progress-bar -f -o "$temp_file" "$download_url" 2>&1; then
        # Verify it's a valid qcow2 image
        local file_size
        file_size=$(stat -f%z "$temp_file" 2>/dev/null || stat -c%s "$temp_file" 2>/dev/null || echo "0")
        
        # Check if it's HTML (error page)
        if head -c 100 "$temp_file" | grep -q "<html\|<!DOCTYPE\|404\|Not Found\|Error"; then
            log_error "Downloaded file appears to be an HTML error page"
            log_info "The image may not be available for CentOS ${version}"
            rm -f "$temp_file"
            exit 1
        fi
        
        # Check QCOW2 magic bytes
        local magic_bytes
        magic_bytes=$(head -c 4 "$temp_file" | od -An -tx1 | tr -d ' \n' || echo "")
        local is_qcow2=false
        if [[ "$magic_bytes" == "514649fb" ]]; then
            is_qcow2=true
        fi
        
        if [[ "$is_qcow2" == "true" ]]; then
            if [[ $file_size -lt 104857600 ]]; then
                log_warning "File size is small (${file_size} bytes). This might not be a complete image."
            fi
            
            sudo mv "$temp_file" "$dest_file"
            sudo chown root:root "$dest_file"
            sudo chmod 644 "$dest_file"
            log_success "Image downloaded to ${dest_file}"
        else
            log_error "Downloaded file is not a valid QCOW2 image"
            log_info "Magic bytes: ${magic_bytes} (expected: 514649fb)"
            log_info "File type: $(file "$temp_file" || echo 'unknown')"
            log_info "The file might be an error page or corrupted download."
            rm -f "$temp_file"
            exit 1
        fi
    else
        log_error "Failed to download image"
        log_info "URL might be incorrect or the file is no longer available"
        rm -f "$temp_file"
        exit 1
    fi
}

# Download Fedora cloud image
download_fedora_image() {
    local version="$1"
    local dest_dir="$2"
    local dest_file="${dest_dir}/fedora-cloud-base-${version}.qcow2"
    
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
    if ! image_name=$(find_fedora_image_name "$version"); then
        log_error "Could not find Fedora ${version} cloud image"
        log_info "This version may be too old or no longer available."
        log_info "Try a different version with: $0 --version 42"
        log_info "Or check: https://fedoraproject.org/cloud/download"
        exit 1
    fi
    
    # Get base URL from temp file (set by find_image_name)
    local base_url
    if [[ -f "/tmp/fedora_base_url_${version}" ]]; then
        base_url=$(cat "/tmp/fedora_base_url_${version}")
        rm -f "/tmp/fedora_base_url_${version}"
    else
        base_url="https://download.fedoraproject.org/pub/fedora/linux/releases/${version}/Cloud/x86_64/images/"
    fi
    
    local download_url="${base_url}${image_name}"
    
    log_info "Found image: ${image_name}"
    log_info "Downloading from: ${download_url}"
    
    # Create directory if needed
    sudo mkdir -p "$dest_dir"
    
    # Download to temp location first
    local temp_file="/tmp/fedora-cloud-download-${version}.qcow2"
    
    # Use curl with better progress and redirect following
    if curl -L --progress-bar -f -o "$temp_file" "$download_url" 2>&1; then
        # Verify it's a valid qcow2 image (not an error page)
        # Check file size (should be > 100MB for a cloud image)
        local file_size
        file_size=$(stat -f%z "$temp_file" 2>/dev/null || stat -c%s "$temp_file" 2>/dev/null || echo "0")
        
        # Check if it's HTML (error page)
        if head -c 100 "$temp_file" | grep -q "<html\|<!DOCTYPE\|404\|Not Found\|Error"; then
            log_error "Downloaded file appears to be an HTML error page"
            log_info "The image may not be available for Fedora ${version}"
            log_info "First 100 bytes:"
            head -c 100 "$temp_file" | cat -A
            echo ""
            rm -f "$temp_file"
            exit 1
        fi
        
        # Check if it's a QCOW2 file (magic bytes: QFI\xfb = 0x514649fb)
        # Use hexdump or od to check magic bytes
        local is_qcow2=false
        if command -v hexdump &> /dev/null; then
            local magic
            magic=$(hexdump -n 4 -e '4/1 "%02x"' "$temp_file" 2>/dev/null || echo "")
            if [[ "$magic" == "514649fb" ]]; then
                is_qcow2=true
            fi
        elif command -v od &> /dev/null; then
            local magic
            magic=$(od -An -tx1 -N 4 "$temp_file" 2>/dev/null | tr -d ' \n' || echo "")
            if [[ "$magic" == "514649fb" ]]; then
                is_qcow2=true
            fi
        fi
        
        # Also check with file command
        if file "$temp_file" 2>/dev/null | grep -qE "QEMU QCOW|QCOW"; then
            is_qcow2=true
        fi
        
        if [[ "$is_qcow2" == "true" ]]; then
            if [[ $file_size -lt 104857600 ]]; then
                log_warning "File size is small (${file_size} bytes). This might not be a complete image."
            fi
            
            sudo mv "$temp_file" "$dest_file"
            sudo chown root:root "$dest_file"
            sudo chmod 644 "$dest_file"
            log_success "Image downloaded to ${dest_file}"
        else
            log_error "Downloaded file is not a valid QCOW2 image"
            log_info "Magic bytes: ${magic_bytes} (expected: 514649fb)"
            log_info "File type: $(file "$temp_file" || echo 'unknown')"
            log_info "The file might be an error page or corrupted download."
            rm -f "$temp_file"
            exit 1
        fi
    else
        log_error "Failed to download image"
        log_info "URL might be incorrect or the file is no longer available"
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
    log_info "=== Cloud Image Setup ==="
    
    check_requirements
    
    # Parse command line args
    while [[ $# -gt 0 ]]; do
        case $1 in
            --distro|-d)
                DISTRO="$2"
                shift 2
                ;;
            --version|-v)
                VERSION="$2"
                shift 2
                ;;
            --dir)
                IMAGE_DIR="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--distro DISTRO] [--version VERSION] [--dir DIRECTORY]"
                echo ""
                echo "Options:"
                echo "  --distro, -d     Distribution: fedora, debian, ubuntu, or centos (default: fedora)"
                echo "  --version, -v    Version number (default: 42 for fedora, 12 for debian)"
                echo "  --dir            Image directory (default: /var/lib/libvirt/images)"
                echo ""
                echo "Examples:"
                echo "  $0 --distro fedora --version 42"
                echo "  $0 --distro debian --version 12"
                echo "  $0 --distro ubuntu --version 24.04"
                echo "  $0 --distro centos --version 9"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Normalize distro name
    DISTRO=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$DISTRO" != "fedora" && "$DISTRO" != "debian" && "$DISTRO" != "ubuntu" && "$DISTRO" != "centos" ]]; then
        log_error "Unsupported distribution: $DISTRO"
        log_info "Supported distributions: fedora, debian, ubuntu, centos"
        exit 1
    fi
    
    log_info "Distribution: ${DISTRO}"
    log_info "Version: ${VERSION}"
    
    # Download image based on distribution
    if [[ "$DISTRO" == "fedora" ]]; then
        download_fedora_image "$VERSION" "$IMAGE_DIR"
        verify_image "${IMAGE_DIR}/fedora-cloud-base-${VERSION}.qcow2"
        log_success "Base image setup complete!"
        echo ""
        echo "Base image location: ${IMAGE_DIR}/fedora-cloud-base-${VERSION}.qcow2"
    elif [[ "$DISTRO" == "debian" ]]; then
        download_debian_image "$VERSION" "$IMAGE_DIR"
        verify_image "${IMAGE_DIR}/debian-cloud-base-${VERSION}.qcow2"
        log_success "Debian base image setup complete!"
        echo "Base image location: ${IMAGE_DIR}/debian-cloud-base-${VERSION}.qcow2"
    elif [[ "$DISTRO" == "ubuntu" ]]; then
        download_ubuntu_image "$VERSION" "$IMAGE_DIR"
        local version_key="${VERSION//./_}"
        verify_image "${IMAGE_DIR}/ubuntu-cloud-base-${version_key}.qcow2"
        log_success "Ubuntu base image setup complete!"
        echo "Base image location: ${IMAGE_DIR}/ubuntu-cloud-base-${version_key}.qcow2"
    elif [[ "$DISTRO" == "centos" ]]; then
        download_centos_image "$VERSION" "$IMAGE_DIR"
        verify_image "${IMAGE_DIR}/centos-cloud-base-${VERSION}.qcow2"
        log_success "CentOS base image setup complete!"
        echo "Base image location: ${IMAGE_DIR}/centos-cloud-base-${VERSION}.qcow2"
    else
        log_error "Unsupported distribution: $DISTRO"
        exit 1
    fi
}

main "$@"

