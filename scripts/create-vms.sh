#!/bin/bash
# create-vms.sh - Create multiple VMs (Fedora/Debian) for snail-core testing
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(dirname "$SCRIPT_DIR")"

# Default configuration
VM_COUNT_PER_VERSION="${VM_COUNT_PER_VERSION:-5}"
VM_PREFIX="${VM_PREFIX:-snail-test}"
MEMORY_MB="${MEMORY_MB:-2048}"
VCPUS="${VCPUS:-2}"
DISK_SIZE_GB="${DISK_SIZE_GB:-15}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/libvirt/images}"
CLOUDINIT_DIR="${CLOUDINIT_DIR:-/tmp/snail-test-cloudinit}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/snail-test-key}"


# Snail core configuration
SNAIL_REPO="${SNAIL_REPO:-https://github.com/sluggisty/snail-core}"
SNAIL_API_ENDPOINT="${SNAIL_API_ENDPOINT:-http://192.168.124.1:8080/api/v1/ingest}"
SNAIL_API_KEY="${SNAIL_API_KEY:-test-api-key-12345}"

# VM user credentials
VM_USER="${VM_USER:-snail}"
VM_PASSWORD="${VM_PASSWORD:-snailtest123}"

# Distribution and versions to create
# Format: "distro:version" or just "version" (defaults to fedora)
# Examples: "fedora:42,41" or "debian:12,11" or "42,41" (assumes fedora)
VM_SPECS="${VM_SPECS:-fedora:42}"

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
}

# Get base image path for a distribution and version
get_base_image_path() {
    local distro="$1"
    local version="$2"
    if [[ "$distro" == "fedora" ]]; then
        echo "${IMAGE_DIR}/fedora-cloud-base-${version}.qcow2"
    elif [[ "$distro" == "debian" ]]; then
        echo "${IMAGE_DIR}/debian-cloud-base-${version}.qcow2"
    elif [[ "$distro" == "ubuntu" ]]; then
        local version_key="${version//./_}"
        echo "${IMAGE_DIR}/ubuntu-cloud-base-${version_key}.qcow2"
    elif [[ "$distro" == "centos" ]]; then
        echo "${IMAGE_DIR}/centos-cloud-base-${version}.qcow2"
    elif [[ "$distro" == "rhel" ]]; then
        # Convert version dots to underscores for filename (9.4 -> 9_4)
        local version_key="${version//./_}"
        echo "${IMAGE_DIR}/rhel-cloud-base-${version_key}.qcow2"
    else
        log_error "Unknown distribution: $distro"
        return 1
    fi
}

# Check if base image exists for a distribution and version
check_base_image() {
    local distro="$1"
    local version="$2"
    local base_image
    base_image=$(get_base_image_path "$distro" "$version")
    
    if [[ ! -f "$base_image" ]]; then
        log_error "Base image not found for ${distro} ${version}: ${base_image}"
        log_info "Run: ./scripts/setup-base-image.sh --distro ${distro} --version ${version}"
        return 1
    fi
    return 0
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
    local distro="$3"
    local version="$4"
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
    
    # Generate distribution-specific cloud-init
    if [[ "$distro" == "fedora" ]]; then
        create_fedora_cloud_init "$vm_name" "$version" "$output_dir" "$ssh_pubkey"
    elif [[ "$distro" == "debian" ]]; then
        create_debian_cloud_init "$vm_name" "$version" "$output_dir" "$ssh_pubkey"
    elif [[ "$distro" == "ubuntu" ]]; then
        create_ubuntu_cloud_init "$vm_name" "$version" "$output_dir" "$ssh_pubkey"
    elif [[ "$distro" == "centos" ]]; then
        create_centos_cloud_init "$vm_name" "$version" "$output_dir" "$ssh_pubkey"
    elif [[ "$distro" == "rhel" ]]; then
        create_rhel_cloud_init "$vm_name" "$version" "$output_dir" "$ssh_pubkey"
    else
        log_error "Unsupported distribution: $distro"
        return 1
    fi
}

# Create Fedora-specific cloud-init
create_fedora_cloud_init() {
    local vm_name="$1"
    local version="$2"
    local output_dir="$3"
    local ssh_pubkey="$4"
    
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
# Note: Some packages may not be available in older Fedora versions
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
  - dnf update -y || true
  
  # Install optional security packages (may not be available in older versions)
  - dnf install -y openscap-scanner scap-security-guide || echo "Some optional packages not available, continuing..."
  
  # Install trivy using official install script (works across all Fedora versions)
  - curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin || echo "Trivy installation failed, continuing..."
  
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
    cat > /etc/snail-core/config.yaml << EOF2
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
    EOF2
  
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

final_message: "Snail Core VM ${vm_name} (Fedora ${version}) is ready! Setup took \$UPTIME seconds."
EOF
}

# Create Debian-specific cloud-init
create_debian_cloud_init() {
    local vm_name="$1"
    local version="$2"
    local output_dir="$3"
    local ssh_pubkey="$4"
    
    cat > "${output_dir}/user-data" << EOF
#cloud-config
hostname: ${vm_name}
fqdn: ${vm_name}.local

# User configuration
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, adm, systemd-journal
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
  - python3-venv
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
  - apt-get update -y || true
  - apt-get upgrade -y || true
  
  # Install optional security packages
  - apt-get install -y openscap-scanner scap-security-guide || echo "Some optional packages not available, continuing..."
  
  # Install trivy using official install script
  - curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin || echo "Trivy installation failed, continuing..."
  
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
    cat > /etc/snail-core/config.yaml << EOF2
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
    EOF2
  
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

final_message: "Snail Core VM ${vm_name} (Debian ${version}) is ready! Setup took \$UPTIME seconds."
EOF
}

# Create Ubuntu-specific cloud-init
create_ubuntu_cloud_init() {
    local vm_name="$1"
    local version="$2"
    local output_dir="$3"
    local ssh_pubkey="$4"
    
    cat > "${output_dir}/user-data" << EOF
#cloud-config
hostname: ${vm_name}
fqdn: ${vm_name}.local

# User configuration
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, adm, systemd-journal
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
  - python3-venv
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
  - apt-get update -y || true
  - apt-get upgrade -y || true
  
  # Install optional security packages
  - apt-get install -y openscap-scanner scap-security-guide || echo "Some optional packages not available, continuing..."
  
  # Install trivy using official install script
  - curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin || echo "Trivy installation failed, continuing..."
  
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
    cat > /etc/snail-core/config.yaml << 'EOF2'
api:
  endpoint: ${SNAIL_API_ENDPOINT}
  api_key: ${SNAIL_API_KEY}
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
    EOF2
  
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

final_message: "Snail Core VM ${vm_name} (Ubuntu ${version}) is ready! Setup took \$UPTIME seconds."
EOF
}

# Create CentOS-specific cloud-init
create_centos_cloud_init() {
    local vm_name="$1"
    local version="$2"
    local output_dir="$3"
    local ssh_pubkey="$4"
    
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
  - dnf update -y || yum update -y || true
  
  # Install python3-venv (package name varies by CentOS version)
  - dnf install -y python3-virtualenv || yum install -y python3-virtualenv || python3 -m pip install virtualenv || true
  
  # Install optional security packages
  - dnf install -y openscap-scanner scap-security-guide || yum install -y openscap-scanner scap-security-guide || echo "Some optional packages not available, continuing..."
  
  # Install trivy using official install script
  - curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin || echo "Trivy installation failed, continuing..."
  
  # Clone snail-core
  - git clone ${SNAIL_REPO} /opt/snail-core
  
  # Create virtual environment and install
  - python3 -m venv /opt/snail-core/venv || python3 -m virtualenv /opt/snail-core/venv
  - /opt/snail-core/venv/bin/pip install --upgrade pip
  - /opt/snail-core/venv/bin/pip install -e /opt/snail-core
  
  # Create snail-core config directory
  - mkdir -p /etc/snail-core
  
  # Create configuration file
  - |
    cat > /etc/snail-core/config.yaml << 'EOF2'
api:
  endpoint: ${SNAIL_API_ENDPOINT}
  api_key: ${SNAIL_API_KEY}
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
    EOF2
  
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

final_message: "Snail Core VM ${vm_name} (CentOS ${version}) is ready! Setup took \$UPTIME seconds."
EOF
}

# Create RHEL-specific cloud-init
create_rhel_cloud_init() {
    local vm_name="$1"
    local version="$2"
    local output_dir="$3"
    local ssh_pubkey="$4"
    
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
  - dnf update -y || yum update -y || true
  
  # Install python3-venv (package name varies by RHEL version)
  - dnf install -y python3-virtualenv || yum install -y python3-virtualenv || python3 -m pip install virtualenv || true
  
  # Install optional security packages
  - dnf install -y openscap-scanner scap-security-guide || yum install -y openscap-scanner scap-security-guide || echo "Some optional packages not available, continuing..."
  
  # Install trivy using official install script
  - curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin || echo "Trivy installation failed, continuing..."
  
  # Clone snail-core
  - git clone ${SNAIL_REPO} /opt/snail-core
  
  # Create virtual environment and install
  - python3 -m venv /opt/snail-core/venv || python3 -m virtualenv /opt/snail-core/venv
  - /opt/snail-core/venv/bin/pip install --upgrade pip
  - /opt/snail-core/venv/bin/pip install -e /opt/snail-core
  
  # Create snail-core config directory
  - mkdir -p /etc/snail-core
  
  # Create configuration file
  - |
    cat > /etc/snail-core/config.yaml << 'EOF2'
api:
  endpoint: ${SNAIL_API_ENDPOINT}
  api_key: ${SNAIL_API_KEY}
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
    EOF2
  
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

final_message: "Snail Core VM ${vm_name} (RHEL ${version}) is ready! Setup took \$UPTIME seconds."
EOF
}

# Create cloud-init ISO
create_cloud_init_iso() {
    local output_dir="$1"
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
    local distro="$3"
    local version="$4"
    
    log_step "Creating VM: ${vm_name} (${distro^} ${version})"
    
    # Check if VM already exists
    if sudo virsh list --all --name | grep -q "^${vm_name}$"; then
        log_warning "VM ${vm_name} already exists, skipping..."
        return 0
    fi
    
    # Check base image exists
    if ! check_base_image "$distro" "$version"; then
        return 1
    fi
    
    local base_image
    base_image=$(get_base_image_path "$distro" "$version")
    
    # Create disk from base image
    local disk_path="${IMAGE_DIR}/${vm_name}.qcow2"
    log_info "Creating disk: ${disk_path}"
    sudo cp "$base_image" "$disk_path"
    sudo qemu-img resize "$disk_path" "${DISK_SIZE_GB}G" 2>/dev/null
    
    # Create cloud-init ISO
    log_info "Creating cloud-init configuration..."
    local cloudinit_iso
    create_cloud_init "$vm_name" "$vm_number" "$distro" "$version"
    cloudinit_iso=$(create_cloud_init_iso "${CLOUDINIT_DIR}/${vm_name}")
    
    # Determine OS variant
    local os_variant="generic"
    if [[ "$distro" == "fedora" ]]; then
        os_variant="fedora-unknown"
        if [[ "$version" -ge 40 ]]; then
            os_variant="fedora40"
        elif [[ "$version" -ge 38 ]]; then
            os_variant="fedora38"
        elif [[ "$version" -ge 36 ]]; then
            os_variant="fedora36"
        fi
    elif [[ "$distro" == "debian" ]]; then
        case "$version" in
            "12") os_variant="debian12" ;;
            "11") os_variant="debian11" ;;
            "10") os_variant="debian10" ;;
            "9") os_variant="debian9" ;;
            *) os_variant="debian10" ;;
        esac
    elif [[ "$distro" == "ubuntu" ]]; then
        case "$version" in
            "24.04") os_variant="ubuntu24.04" ;;
            "22.04") os_variant="ubuntu22.04" ;;
            "20.04") os_variant="ubuntu20.04" ;;
            "18.04") os_variant="ubuntu18.04" ;;
            *) os_variant="ubuntu22.04" ;;
        esac
    elif [[ "$distro" == "centos" ]]; then
        case "$version" in
            "9") os_variant="centos-stream9" ;;
            "8") os_variant="centos-stream8" ;;
            "7") os_variant="centos7" ;;
            *) os_variant="centos-stream9" ;;
        esac
    elif [[ "$distro" == "rhel" ]]; then
        case "$version" in
            "9") os_variant="rhel9" ;;
            "8") os_variant="rhel8" ;;
            "7") os_variant="rhel7" ;;
            *) os_variant="rhel9" ;;
        esac
    fi
    
    # Create the VM
    log_info "Creating VM with virt-install..."
    sudo virt-install \
        --name "$vm_name" \
        --memory "$MEMORY_MB" \
        --vcpus "$VCPUS" \
        --disk "$disk_path" \
        --disk "${cloudinit_iso},device=cdrom" \
        --os-variant "$os_variant" \
        --network network=default \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole \
        --wait 0
    
    log_success "VM ${vm_name} created!"
}

# Parse VM spec (format: "distro:version" or just "version" which defaults to fedora)
parse_vm_spec() {
    local spec="$1"
    if [[ "$spec" == *":"* ]]; then
        echo "$spec"
    else
        echo "fedora:${spec}"
    fi
}

# Wait for all VMs to get IP addresses
wait_for_vms() {
    log_info "Waiting for VMs to boot and get IP addresses..."
    
    local max_wait=180
    local waited=0
    local interval=10
    
    # Count total VMs
    local total_vms=0
    IFS=',' read -ra SPECS <<< "$VM_SPECS"
    for spec in "${SPECS[@]}"; do
        local parsed_spec
        parsed_spec=$(parse_vm_spec "$spec")
        IFS=':' read -r distro version <<< "$parsed_spec"
        total_vms=$((total_vms + VM_COUNT_PER_VERSION))
    done
    
    while [[ $waited -lt $max_wait ]]; do
        local ready=0
        
        IFS=',' read -ra SPECS <<< "$VM_SPECS"
        for spec in "${SPECS[@]}"; do
            local parsed_spec
            parsed_spec=$(parse_vm_spec "$spec")
            IFS=':' read -r distro version <<< "$parsed_spec"
            for i in $(seq 1 "$VM_COUNT_PER_VERSION"); do
                local vm_name="${VM_PREFIX}-${distro}-${version}-${i}"
                local ip
                ip=$(sudo virsh domifaddr "$vm_name" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
                
                if [[ -n "$ip" ]]; then
                    ready=$((ready + 1))
                fi
            done
        done
        
        if [[ $ready -eq $total_vms ]]; then
            echo ""
            log_success "All ${total_vms} VMs have IP addresses!"
            return 0
        fi
        
        printf "\r${BLUE}[INFO]${NC} %d/%d VMs ready... (%ds elapsed)    " "$ready" "$total_vms" "$waited"
        sleep "$interval"
        waited=$((waited + interval))
    done
    
    echo ""
    log_warning "Timeout waiting for all VMs. Some VMs may not have IP addresses yet."
    log_info "VMs are still booting. Check status with: ./harness.py status"
    return 0
}

# Display VM information
show_vm_info() {
    echo ""
    echo "=========================================="
    echo "        VM Information Summary"
    echo "=========================================="
    
    printf "%-30s %-18s %-10s\n" "VM Name" "IP Address" "Status"
    printf "%-30s %-18s %-10s\n" "------------------------------" "------------------" "----------"
    
    IFS=',' read -ra SPECS <<< "$VM_SPECS"
    for spec in "${SPECS[@]}"; do
        local parsed_spec
        parsed_spec=$(parse_vm_spec "$spec")
        IFS=':' read -r distro version <<< "$parsed_spec"
        for i in $(seq 1 "$VM_COUNT_PER_VERSION"); do
            local vm_name="${VM_PREFIX}-${distro}-${version}-${i}"
            local status
            status=$(sudo virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
            local ip
            ip=$(sudo virsh domifaddr "$vm_name" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "pending...")
            
            printf "%-30s %-18s %-10s\n" "$vm_name" "$ip" "$status"
        done
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
            --specs|-s)
                VM_SPECS="$2"
                shift 2
                ;;
            --count|-n)
                VM_COUNT_PER_VERSION="$2"
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
                echo "  --specs, -s LIST      Comma-separated VM specs (default: fedora:42)"
                echo "                       Format: distro:version or just version (defaults to fedora)"
                echo "                       Examples: fedora:42,41 or debian:12,11 or 42,41"
                echo "  --count, -n NUM      Number of VMs per version (default: 5)"
                echo "  --prefix, -p NAME    VM name prefix (default: snail-test)"
                echo "  --memory, -m MB      Memory per VM in MB (default: 2048)"
                echo "  --cpus, -c NUM       vCPUs per VM (default: 2)"
                echo ""
                echo "Examples:"
                echo "  $0 --specs fedora:42,41,40"
                echo "  $0 --specs debian:12,11"
                echo "  $0 --specs fedora:42,debian:12"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    log_info "Configuration:"
    log_info "  VM Specs: ${VM_SPECS}"
    log_info "  VMs per Version: ${VM_COUNT_PER_VERSION}"
    log_info "  VM Prefix: ${VM_PREFIX}"
    log_info "  Memory: ${MEMORY_MB} MB"
    log_info "  vCPUs: ${VCPUS}"
    echo ""
    
    check_requirements
    setup_ssh_key
    
    # Verify base images exist for all specs
    log_info "Checking base images..."
    IFS=',' read -ra SPECS <<< "$VM_SPECS"
    local missing_specs=()
    for spec in "${SPECS[@]}"; do
        local parsed_spec
        parsed_spec=$(parse_vm_spec "$spec")
        IFS=':' read -r distro version <<< "$parsed_spec"
        if ! check_base_image "$distro" "$version"; then
            missing_specs+=("${distro}:${version}")
        fi
    done
    
    if [[ ${#missing_specs[@]} -gt 0 ]]; then
        log_error "Missing base images for: ${missing_specs[*]}"
        log_info "Download them with:"
        for spec in "${missing_specs[@]}"; do
            IFS=':' read -r distro version <<< "$spec"
            log_info "  ./scripts/setup-base-image.sh --distro ${distro} --version ${version}"
        done
        exit 1
    fi
    
    # Create cloud-init directory
    mkdir -p "$CLOUDINIT_DIR"
    
    # Create VMs for each spec
    local vm_counter=1
    IFS=',' read -ra SPECS <<< "$VM_SPECS"
    for spec in "${SPECS[@]}"; do
        local parsed_spec
        parsed_spec=$(parse_vm_spec "$spec")
        IFS=':' read -r distro version <<< "$parsed_spec"
        log_info ""
        log_info "Creating VMs for ${distro^} ${version}..."
        for i in $(seq 1 "$VM_COUNT_PER_VERSION"); do
            create_vm "${VM_PREFIX}-${distro}-${version}-${i}" "$vm_counter" "$distro" "$version"
            vm_counter=$((vm_counter + 1))
        done
    done
    
    echo ""
    wait_for_vms
    show_vm_info
    
    # Save VM list for later use
    local vm_list_file="${TESTING_DIR}/vm-list.txt"
    > "$vm_list_file"
    IFS=',' read -ra SPECS <<< "$VM_SPECS"
    for spec in "${SPECS[@]}"; do
        local parsed_spec
        parsed_spec=$(parse_vm_spec "$spec")
        IFS=':' read -r distro version <<< "$parsed_spec"
        for i in $(seq 1 "$VM_COUNT_PER_VERSION"); do
            echo "${VM_PREFIX}-${distro}-${version}-${i}"
        done
    done >> "$vm_list_file"
    
    log_success "VM creation complete!"
    log_info "VM list saved to: ${vm_list_file}"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Wait a few minutes for VMs to complete cloud-init setup"
    log_info "  2. Check VM status: ./harness.py status"
    log_info "  3. Run snail on all VMs: ./harness.py run"
}

main "$@"
