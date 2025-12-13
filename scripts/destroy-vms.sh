#!/bin/bash
# destroy-vms.sh - Remove all snail-core test VMs
# ================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(dirname "$SCRIPT_DIR")"

VM_PREFIX="${VM_PREFIX:-snail-test}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
CLOUDINIT_DIR="${CLOUDINIT_DIR:-/tmp/snail-test-cloudinit}"

# Expand relative paths relative to testing directory
if [[ "$IMAGE_DIR" != /* ]]; then
    IMAGE_DIR="${TESTING_DIR}/${IMAGE_DIR}"
fi
if [[ "$CLOUDINIT_DIR" != /* ]]; then
    CLOUDINIT_DIR="${TESTING_DIR}/${CLOUDINIT_DIR}"
fi
IMAGE_DIR=$(eval echo "$IMAGE_DIR")
CLOUDINIT_DIR=$(eval echo "$CLOUDINIT_DIR")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get list of test VMs
get_test_vms() {
    # Match pattern: snail-test-<version>-<number>
    sudo virsh list --all --name | grep "^${VM_PREFIX}-" | grep -E "^${VM_PREFIX}-[0-9]+-[0-9]+$" || true
}

# Destroy a single VM
destroy_vm() {
    local vm_name="$1"
    
    log_info "Destroying VM: ${vm_name}"
    
    # Check if VM is running
    local state
    state=$(sudo virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
    
    if [[ "$state" == "running" ]]; then
        log_info "  Stopping VM..."
        sudo virsh destroy "$vm_name" 2>/dev/null || true
    fi
    
    # Undefine VM and remove storage
    log_info "  Removing VM definition and storage..."
    sudo virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
    
    # Clean up any remaining disk images (use sudo only if directory is not user-writable)
    local resolved_image_dir
    resolved_image_dir=$(eval echo "$IMAGE_DIR")
    resolved_image_dir=$(cd "$(dirname "$resolved_image_dir")" 2>/dev/null && pwd)/$(basename "$resolved_image_dir") 2>/dev/null || echo "$resolved_image_dir"
    local disk_path="${resolved_image_dir}/${vm_name}.qcow2"
    if [[ -f "$disk_path" ]]; then
        if is_user_writable "$resolved_image_dir"; then
            rm -f "$disk_path"
        else
            sudo rm -f "$disk_path"
        fi
    fi
    
    log_success "  VM ${vm_name} destroyed"
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "    Destroy Snail Core Test VMs"
    echo "=========================================="
    echo ""
    
    # Parse arguments
    local force=false
    local specific_vm=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force|-f)
                force=true
                shift
                ;;
            --prefix|-p)
                VM_PREFIX="$2"
                shift 2
                ;;
            --vm)
                specific_vm="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --force, -f         Don't ask for confirmation"
                echo "  --prefix, -p NAME   VM name prefix (default: snail-test)"
                echo "  --vm NAME           Destroy specific VM only"
                echo ""
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Handle specific VM
    if [[ -n "$specific_vm" ]]; then
        if ! sudo virsh list --all --name | grep -q "^${specific_vm}$"; then
            log_error "VM not found: ${specific_vm}"
            exit 1
        fi
        
        if [[ "$force" != true ]]; then
            read -p "Are you sure you want to destroy ${specific_vm}? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Aborted"
                exit 0
            fi
        fi
        
        destroy_vm "$specific_vm"
        exit 0
    fi
    
    # Get all test VMs
    local vms
    vms=$(get_test_vms)
    
    if [[ -z "$vms" ]]; then
        log_info "No VMs found with prefix: ${VM_PREFIX}"
        exit 0
    fi
    
    # Count VMs
    local vm_count
    vm_count=$(echo "$vms" | wc -l)
    
    echo "Found ${vm_count} VM(s) to destroy:"
    echo "$vms" | sed 's/^/  - /'
    echo ""
    
    if [[ "$force" != true ]]; then
        read -p "Are you sure you want to destroy ALL these VMs? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted"
            exit 0
        fi
    fi
    
    # Destroy each VM
    while IFS= read -r vm_name; do
        if [[ -n "$vm_name" ]]; then
            destroy_vm "$vm_name"
        fi
    done <<< "$vms"
    
    # Clean up cloud-init directory
    if [[ -d "$CLOUDINIT_DIR" ]]; then
        log_info "Cleaning up cloud-init directory..."
        rm -rf "$CLOUDINIT_DIR"
    fi
    
    # Remove VM list file
    local vm_list_file="${TESTING_DIR}/vm-list.txt"
    if [[ -f "$vm_list_file" ]]; then
        rm -f "$vm_list_file"
    fi
    
    echo ""
    log_success "All test VMs have been destroyed!"
}

main "$@"

