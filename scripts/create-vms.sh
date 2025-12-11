#!/bin/bash
# create-vms.sh - Create multiple Fedora VMs for snail-core testing
# ==================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(dirname "$SCRIPT_DIR")"

# Default configuration
VM_COUNT="${VM_COUNT:-10}"
VM_PREFIX="${VM_PREFIX:-snail-test}"
MEMORY_MB="${MEMORY_MB:-2048}"
VCPUS="${VCPUS:-2}"
DISK_SIZE_GB="${DISK_SIZE_GB:-15}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
CLOUDINIT_DIR="${CLOUDINIT_DIR:-/tmp/snail-test-cloudinit}"
BASE_IMAGE="${BASE_IMAGE:-${IMAGE_DIR}/fedora-cloud-base.qcow2}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/snail-test-key}"

# Snail core configuration
SNAIL_REPO="${SNAIL_REPO:-https://github.com/sluggisty/snail-core}"
SNAIL_API_ENDPOINT="${SNAIL_API_ENDPOINT:-http://192.168.122.1:8080/api/v1/ingest}"
SNAIL_API_KEY="${SNAIL_API_KEY:-test-api-key-12345}"

# VM user credentials
VM_USER="${VM_USER:-snail}"
VM_PASSWORD="${VM_PASSWORD:-snailtest123}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Check requirements
check_requirements() {
    local missing=()
    
    for cmd in virsh virt-install qemu-img genisoimage; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: sudo dnf install libvirt virt-install qemu-img genisoimage"
        exit 1
    fi
    
    # Check if libvirtd is running
    if ! systemctl is-active --quiet libvirtd; then
        log_error "libvirtd is not running"
        log_info "Start with: sudo systemctl start libvirtd"
        exit 1
    fi
    
    # Check if base image exists
    if [[ ! -f "$BASE_IMAGE" ]]; then
        log_error "Base image not found: ${BASE_IMAGE}"
        log_info "Run ./scripts/setup-base-image.sh first"
        exit 1
    fi
}

# Generate SSH key if needed
setup_ssh_key() {
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_info "Generating SSH key pair..."
        ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "snail-test-vms"
        log_success "SSH key generated: ${SSH_KEY_PATH}"
    else
        log_info "Using existing SSH key: ${SSH_KEY_PATH}"
    fi
}

# Create cloud-init configuration for a VM
create_cloud_init() {
    local vm_name="$1"
    local vm_number="$2"
    local output_dir="${CLOUDINIT_DIR}/${vm_name}"
    
    mkdir -p "$output_dir"
    
    # Read SSH public key
    local ssh_pubkey=""
    if [[ -f "${SSH_KEY_PATH}.pub" ]]; then
        ssh_pubkey=$(cat "${SSH_KEY_PATH}.pub")
    fi
    
    # Create meta-data
    cat > "${output_dir}/meta-data" << EOF
instance-id: ${vm_name}
local-hostname: ${vm_name}
EOF
    
    # Create user-data with snail-core bootstrap
    cat > "${output_dir}/user-data" << EOF
#cloud-config
hostname: ${vm_name}
fqdn: ${vm_name}.local

# User configuration
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel, systemd-journal
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${ssh_pubkey}

# Set password (for console access)
chpasswd:
  list: |
    ${VM_USER}:${VM_PASSWORD}
  expire: false

# Enable SSH password auth (backup)
ssh_pwauth: true

# Install required packages
packages:
  - python3
  - python3-pip
  - python3-virtualenv
  - git
  - curl
  - vim
  - lsof
  - lshw
  - pciutils
  - usbutils

# Run commands after boot
runcmd:
  # Update system
  - dnf update -y
  
  # Clone snail-core
  - git clone ${SNAIL_REPO} /opt/snail-core
  
  # Create virtual environment and install
  - python3 -m venv /opt/snail-core/venv
  - /opt/snail-core/venv/bin/pip install --upgrade pip
  - /opt/snail-core/venv/bin/pip install -e /opt/snail-core
  
  # Create snail-core config directory
  - mkdir -p /etc/snail-core
  
  # Create configuration file
  - |
    cat > /etc/snail-core/config.yaml << 'SNAILCONFIG'
    upload:
      url: ${SNAIL_API_ENDPOINT}
      enabled: true
      timeout: 30
      retries: 3
    auth:
      api_key: ${SNAIL_API_KEY}
    collection:
      enabled_collectors: []
      disabled_collectors: []
      timeout: 300
    output:
      dir: /var/lib/snail-core
      keep_local: true
      compress: true
    logging:
      level: INFO
    SNAILCONFIG
  
  # Create systemd service for snail
  - |
    cat > /etc/systemd/system/snail-core.service << 'SNAILSERVICE'
    [Unit]
    Description=Snail Core System Collection
    After=network-online.target
    Wants=network-online.target
    
    [Service]
    Type=oneshot
    ExecStart=/opt/snail-core/venv/bin/snail run
    Environment=SNAIL_API_KEY=${SNAIL_API_KEY}
    
    [Install]
    WantedBy=multi-user.target
    SNAILSERVICE
  
  # Create timer to run periodically (every 5 minutes for testing)
  - |
    cat > /etc/systemd/system/snail-core.timer << 'SNAILTIMER'
    [Unit]
    Description=Run Snail Core periodically
    
    [Timer]
    OnBootSec=2min
    OnUnitActiveSec=5min
    
    [Install]
    WantedBy=timers.target
    SNAILTIMER
  
  # Create output directory
  - mkdir -p /var/lib/snail-core
  
  # Create symlink for easy access
  - ln -sf /opt/snail-core/venv/bin/snail /usr/local/bin/snail
  
  # Enable and start the timer
  - systemctl daemon-reload
  - systemctl enable snail-core.timer
  - systemctl start snail-core.timer
  
  # Run snail once immediately
  - SNAIL_API_KEY=${SNAIL_API_KEY} /opt/snail-core/venv/bin/snail run || true
  
  # Mark setup complete
  - touch /var/lib/snail-core/.setup-complete

# Write files
write_files:
  - path: /etc/profile.d/snail.sh
    content: |
      export SNAIL_API_KEY="${SNAIL_API_KEY}"
      alias snail="/opt/snail-core/venv/bin/snail"
    permissions: '0644'

final_message: "Snail Core VM ${vm_name} is ready! Setup took \$UPTIME seconds."
EOF

    # Create cloud-init ISO
    genisoimage -output "${output_dir}/cloud-init.iso" \
        -volid cidata \
        -joliet \
        -rock \
        "${output_dir}/user-data" \
        "${output_dir}/meta-data" \
        2>/dev/null
    
    echo "${output_dir}/cloud-init.iso"
}

# Create a single VM
create_vm() {
    local vm_name="$1"
    local vm_number="$2"
    
    log_step "Creating VM: ${vm_name}"
    
    # Check if VM already exists
    if sudo virsh list --all --name | grep -q "^${vm_name}$"; then
        log_warning "VM ${vm_name} already exists, skipping..."
        return 0
    fi
    
    # Create disk from base image
    local disk_path="${IMAGE_DIR}/${vm_name}.qcow2"
    log_info "Creating disk: ${disk_path}"
    sudo cp "$BASE_IMAGE" "$disk_path"
    sudo qemu-img resize "$disk_path" "${DISK_SIZE_GB}G" 2>/dev/null
    
    # Create cloud-init ISO
    log_info "Creating cloud-init configuration..."
    local cloudinit_iso
    cloudinit_iso=$(create_cloud_init "$vm_name" "$vm_number")
    
    # Create the VM
    log_info "Creating VM with virt-install..."
    sudo virt-install \
        --name "$vm_name" \
        --memory "$MEMORY_MB" \
        --vcpus "$VCPUS" \
        --disk "$disk_path" \
        --disk "${cloudinit_iso},device=cdrom" \
        --os-variant fedora-unknown \
        --network network=default \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole \
        --wait 0
    
    log_success "VM ${vm_name} created!"
}

# Wait for all VMs to get IP addresses
wait_for_vms() {
    log_info "Waiting for VMs to boot and get IP addresses..."
    
    local max_wait=300
    local waited=0
    local interval=10
    
    while [[ $waited -lt $max_wait ]]; do
        local ready=0
        
        for i in $(seq 1 "$VM_COUNT"); do
            local vm_name="${VM_PREFIX}-${i}"
            local ip
            ip=$(sudo virsh domifaddr "$vm_name" 2>/dev/null | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1 || true)
            
            if [[ -n "$ip" ]]; then
                ((ready++))
            fi
        done
        
        if [[ $ready -eq $VM_COUNT ]]; then
            log_success "All ${VM_COUNT} VMs have IP addresses!"
            return 0
        fi
        
        echo -ne "\r${BLUE}[INFO]${NC} ${ready}/${VM_COUNT} VMs ready... (${waited}s elapsed)"
        sleep "$interval"
        ((waited+=interval))
    done
    
    echo ""
    log_warning "Timeout waiting for all VMs. Some VMs may not have IP addresses yet."
}

# Display VM information
show_vm_info() {
    echo ""
    echo "=========================================="
    echo "        VM Information Summary"
    echo "=========================================="
    
    printf "%-20s %-18s %-10s\n" "VM Name" "IP Address" "Status"
    printf "%-20s %-18s %-10s\n" "-------" "----------" "------"
    
    for i in $(seq 1 "$VM_COUNT"); do
        local vm_name="${VM_PREFIX}-${i}"
        local status
        status=$(sudo virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
        local ip
        ip=$(sudo virsh domifaddr "$vm_name" 2>/dev/null | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1 || echo "pending...")
        
        printf "%-20s %-18s %-10s\n" "$vm_name" "$ip" "$status"
    done
    
    echo ""
    echo "SSH Access: ssh -i ${SSH_KEY_PATH} ${VM_USER}@<IP>"
    echo "Console:    sudo virsh console <vm-name>"
    echo ""
}

# Main
main() {
    echo ""
    echo "=========================================="
    echo "    Snail Core VM Test Environment"
    echo "=========================================="
    echo ""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --count|-n)
                VM_COUNT="$2"
                shift 2
                ;;
            --prefix|-p)
                VM_PREFIX="$2"
                shift 2
                ;;
            --memory|-m)
                MEMORY_MB="$2"
                shift 2
                ;;
            --cpus|-c)
                VCPUS="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --count, -n NUM     Number of VMs to create (default: 10)"
                echo "  --prefix, -p NAME   VM name prefix (default: snail-test)"
                echo "  --memory, -m MB     Memory per VM in MB (default: 2048)"
                echo "  --cpus, -c NUM      vCPUs per VM (default: 2)"
                echo ""
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    log_info "Configuration:"
    log_info "  VM Count: ${VM_COUNT}"
    log_info "  VM Prefix: ${VM_PREFIX}"
    log_info "  Memory: ${MEMORY_MB} MB"
    log_info "  vCPUs: ${VCPUS}"
    log_info "  Base Image: ${BASE_IMAGE}"
    echo ""
    
    check_requirements
    setup_ssh_key
    
    # Create cloud-init directory
    mkdir -p "$CLOUDINIT_DIR"
    
    # Create VMs
    for i in $(seq 1 "$VM_COUNT"); do
        create_vm "${VM_PREFIX}-${i}" "$i"
    done
    
    echo ""
    wait_for_vms
    show_vm_info
    
    # Save VM list for later use
    local vm_list_file="${TESTING_DIR}/vm-list.txt"
    for i in $(seq 1 "$VM_COUNT"); do
        echo "${VM_PREFIX}-${i}"
    done > "$vm_list_file"
    
    log_success "VM creation complete!"
    log_info "VM list saved to: ${vm_list_file}"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Wait a few minutes for VMs to complete cloud-init setup"
    log_info "  2. Check VM status: ./scripts/get-vm-ips.sh"
    log_info "  3. Run snail on all VMs: ./harness.py run-all"
}

main "$@"

