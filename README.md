# Snail Core VM Testing Environment

Automated testing infrastructure for snail-core using Fedora, Debian, Ubuntu, CentOS, and RHEL VMs. This environment creates and manages multiple VMs that clone, install, and run snail-core, reporting to a local snail-shell server.

## Overview

This testing harness:
- Creates multiple VMs (default: 5 per version) using libvirt/KVM
- Supports testing across multiple distributions:
  - **Fedora**: versions 42, 41, 40, 39, 38, 37, 36, 35, 34, 33
  - **Debian**: versions 12 (Bookworm), 11 (Bullseye), 10 (Buster), 9 (Stretch)
  - **Ubuntu**: versions 24.04 LTS (Noble), 22.04 LTS (Jammy), 20.04 LTS (Focal), 18.04 LTS (Bionic)
  - **CentOS**: versions 9 (Stream), 8 (Stream), 7 (EOL)
  - **RHEL**: versions 9.4, 9.3, 9.2, 9.1, 9, 8.10, 8.9, 8.8, 8, 7.9, 7 (requires Red Hat subscription)
- Automatically clones and installs snail-core from GitHub
- Configures VMs to report to `localhost:8080` on the host
- Provides tools to manage, update, and execute commands on all VMs
- VM names include distribution and version: `snail-test-fedora-42-1`, `snail-test-debian-12-1`, `snail-test-ubuntu-24.04-1`, `snail-test-centos-9-1`, `snail-test-rhel-9.4-1`, etc.

## Prerequisites

### Host System Requirements

- **Fedora Linux** (tested on Fedora 41)
- **KVM/libvirt** virtualization stack
- **Python 3.9+** with pip
- At least **20GB** free disk space
- At least **20GB** RAM (for 10 VMs @ 2GB each)

### Install Required Packages

```bash
# Virtualization tools
sudo dnf install -y \
    libvirt \
    libvirt-daemon-kvm \
    virt-install \
    qemu-img \
    genisoimage

# Enable and start libvirtd
sudo systemctl enable --now libvirtd

# Add your user to libvirt group (logout/login required)
sudo usermod -aG libvirt $USER

# Python tools
sudo dnf install -y python3 python3-pip

# Ansible
sudo dnf install -y ansible-core
```

### Install Python Dependencies

```bash
cd testing
pip install -r requirements.txt
```

## Quick Start

### 1. Start snail-shell Server

Make sure the snail-shell server is running on the host:

```bash
cd ../snail-shell
make run
# Or: docker-compose up -d
```

The server should be accessible at `http://localhost:8080`.

### 2. List Available Distributions and Versions

```bash
# See which distributions and versions are available and which base images are downloaded
./harness.py list-versions
```

### 3. Download Base Images

```bash
# Download Fedora base images
./scripts/setup-base-image.sh --distro fedora --version 42
./scripts/setup-base-image.sh --distro fedora --version 41
./scripts/setup-base-image.sh --distro fedora --version 40

# Download Debian base images
./scripts/setup-base-image.sh --distro debian --version 12
./scripts/setup-base-image.sh --distro debian --version 11
./scripts/setup-base-image.sh --distro debian --version 10

# Download Ubuntu base images
./scripts/setup-base-image.sh --distro ubuntu --version 24.04
./scripts/setup-base-image.sh --distro ubuntu --version 22.04
./scripts/setup-base-image.sh --distro ubuntu --version 20.04

# Download CentOS base images
./scripts/setup-base-image.sh --distro centos --version 9
./scripts/setup-base-image.sh --distro centos --version 8

# Download RHEL base images (requires Red Hat subscription)
./scripts/setup-base-image.sh --distro rhel --version 9.4
./scripts/setup-base-image.sh --distro rhel --version 8.10
./scripts/setup-base-image.sh --distro rhel --version 9
```

**Note on RHEL Images:**
RHEL cloud images require a Red Hat subscription and cannot be downloaded automatically. If the download fails, you'll need to:

1. Log in to [Red Hat Customer Portal](https://access.redhat.com/downloads/content/rhel)
2. Navigate to: Red Hat Enterprise Linux > [version] > Cloud Images
3. Download the QCOW2 image (KVM/GenericCloud variant)
4. Place it at: `/var/lib/libvirt/images/rhel-cloud-base-[version].qcow2`
   - For version 9.4: `rhel-cloud-base-9_4.qcow2`
   - For version 8.10: `rhel-cloud-base-8_10.qcow2`
   - For version 9: `rhel-cloud-base-9.qcow2`

**Alternative:** Use CentOS Stream (similar to RHEL, free and publicly available):
```bash
./scripts/setup-base-image.sh --distro centos --version 9
```

### 4. Create Test VMs

```bash
# Create 5 VMs for Fedora 42 (default)
./harness.py create

# Create VMs for multiple Fedora versions
./harness.py create --specs fedora:42,41,40,39,38

# Create Debian VMs
./harness.py create --specs debian:12,11

# Create Ubuntu VMs
./harness.py create --specs ubuntu:24.04
./harness.py create --specs ubuntu:24.04,22.04

# Create CentOS VMs
./harness.py create --specs centos:9
./harness.py create --specs centos:9,8

# Create RHEL VMs (requires base images to be manually downloaded)
./harness.py create --specs rhel:9.4
./harness.py create --specs rhel:9.4,9.3,8.10

# Create mixed distribution VMs
./harness.py create --specs fedora:42,debian:12,ubuntu:24.04,centos:9,rhel:9.4

# Create 3 VMs per version
./harness.py create --specs fedora:42,41 --count 3

# Custom resources
./harness.py create --specs fedora:42,41 --memory 1024 --cpus 1

# Legacy format (still supported for Fedora)
./harness.py create --versions 42,41,40
```

This will:
1. Check for required base images (download if missing)
2. Create VM disk images (5 per version by default)
3. Generate cloud-init configurations with snail-core setup
4. Start all VMs
5. Wait for VMs to get IP addresses

**Note:** 
- VM names include distribution and version: `snail-test-fedora-42-1`, `snail-test-debian-12-1`, `snail-test-ubuntu-24.04-1`, `snail-test-centos-9-1`, `snail-test-rhel-9.4-1`, etc.
- Initial setup takes 5-10 minutes per VM as they run system updates and install snail-core.
- Package managers: Fedora/CentOS/RHEL use `dnf`/`yum`, Debian/Ubuntu use `apt`.
- RHEL images require Red Hat subscription - see "Download Base Images" section for manual download instructions.

### 5. Check VM Status

```bash
# Show all VMs and their status
./harness.py status

# Check snail-core installation status
./harness.py check
```

### 6. Run Snail on All VMs

```bash
# Run 'snail run' on all VMs (collect and upload)
./harness.py run

# Run specific collectors only
./harness.py run -C system -C network -C packages
```

### 7. Update Snail Core

```bash
# Pull latest from GitHub and reinstall
./harness.py update

# Force reinstall even if no changes
./harness.py update --force
```

### 8. Shutdown VMs (Without Deleting)

```bash
# Gracefully shutdown all VMs (VMs remain but are stopped)
./harness.py shutdown

# Shutdown and wait for completion
./harness.py shutdown --wait

# Shutdown specific VM
./harness.py shutdown --vm snail-test-42-1

# Start VMs again later
./harness.py start
```

### 9. Clean Up

```bash
# Destroy all VMs (permanently deletes VM disks)
./harness.py destroy

# Destroy with force (no confirmation)
./harness.py destroy --force
```

## Command Reference

### VM Management

| Command | Description |
|---------|-------------|
| `./harness.py create` | Create test VMs (default: 5 VMs for Fedora 42) |
| `./harness.py create --specs fedora:42,41` | Create VMs for specific Fedora versions |
| `./harness.py create --specs debian:12,11` | Create VMs for specific Debian versions |
| `./harness.py create --specs ubuntu:24.04,22.04` | Create VMs for specific Ubuntu versions |
| `./harness.py create --specs centos:9,8` | Create VMs for specific CentOS versions |
| `./harness.py create --specs rhel:9.4,8.10` | Create VMs for specific RHEL versions (minor releases supported) |
| `./harness.py create --specs fedora:42,debian:12,ubuntu:24.04,centos:9,rhel:9.4` | Create mixed distribution VMs |
| `./harness.py list-versions` | List available distributions and versions |
| `./harness.py start` | Start all VMs |
| `./harness.py shutdown` | Gracefully shutdown all VMs (without deleting them) |
| `./harness.py shutdown --wait` | Shutdown and wait for completion |
| `./harness.py shutdown --vm VM_NAME` | Shutdown specific VM only |
| `./harness.py stop` | Gracefully stop all VMs |
| `./harness.py stop --force` | Force stop all VMs (destroy) |
| `./harness.py destroy` | Remove all test VMs (deletes VM disks) |
| `./harness.py status` | Show VM status |
| `./harness.py ips` | List VM IPs (for scripting) |

### Snail Core Management

| Command | Description |
|---------|-------------|
| `./harness.py run` | Execute `snail run` on all VMs |
| `./harness.py update` | Update to latest snail-core |
| `./harness.py configure` | Update snail-core configuration |
| `./harness.py check` | Check snail-core status on all VMs |

### Remote Execution

| Command | Description |
|---------|-------------|
| `./harness.py exec "command"` | Run command on all VMs |
| `./harness.py ssh VM_NAME` | SSH into specific VM |
| `./harness.py console-connect VM_NAME` | Connect to VM console |

### Ansible Integration

| Command | Description |
|---------|-------------|
| `./harness.py ansible inventory` | Show dynamic inventory |
| `./harness.py ansible playbook NAME` | Run specific playbook |

## Examples

### Execute Custom Commands

```bash
# Check snail version on all VMs
./harness.py exec "snail --version"

# View snail config on all VMs
./harness.py exec "cat /etc/snail-core/config.yaml"

# Check systemd timer status
./harness.py exec "systemctl status snail-core.timer"

# View recent snail runs
./harness.py exec "journalctl -u snail-core.service -n 20"

# Update system packages on all VMs
./harness.py exec "dnf update -y"
```

### Limit to Specific VMs

```bash
# Run only on a specific VM
./harness.py run --limit snail-test-42-1

# Run on all Fedora 42 VMs
./harness.py run --limit "snail-test-42-*"

# Run on all VMs for versions 42 and 41
./harness.py run --limit "snail-test-42-*,snail-test-41-*"
```

### Update Configuration

```bash
# Change API endpoint
./harness.py configure --api-endpoint "http://192.168.122.1:9000/api/v1/ingest"

# Change log level
./harness.py configure --log-level DEBUG

# Update API key
./harness.py configure --api-key "new-secret-key"
```

### SSH Access

```bash
# SSH into VM
./harness.py ssh snail-test-1

# Or manually
ssh -i ~/.ssh/snail-test-key snail@<VM_IP>
```

### Shutdown vs Destroy

**Shutdown** (`./harness.py shutdown`):
- Gracefully stops VMs using ACPI shutdown
- VMs remain on disk and can be started again with `./harness.py start`
- Use this when you want to temporarily stop VMs to save resources
- VM disks and configurations are preserved

**Destroy** (`./harness.py destroy`):
- Permanently deletes VMs and their disk images
- Cannot be recovered - you'll need to recreate VMs
- Use this when you're done testing and want to free up disk space

## Shell Scripts

For direct shell access, use the scripts in the `scripts/` directory:

```bash
# Setup base image
./scripts/setup-base-image.sh

# Create VMs
./scripts/create-vms.sh --count 10 --memory 2048

# Get VM IPs
./scripts/get-vm-ips.sh

# Get IPs as JSON
./scripts/get-vm-ips.sh --json

# Destroy VMs
./scripts/destroy-vms.sh --force
```

## Ansible Playbooks

Direct Ansible playbook execution:

```bash
cd ansible

# Update snail-core
ansible-playbook playbooks/update-snail.yaml

# Run snail
ansible-playbook playbooks/run-snail.yaml

# Check status
ansible-playbook playbooks/status.yaml

# Run custom command
ansible-playbook playbooks/run-command.yaml -e 'cmd="uptime"'

# Configure snail
ansible-playbook playbooks/configure.yaml \
    -e 'snail_api_endpoint="http://192.168.122.1:8080/api/v1/ingest"' \
    -e 'snail_log_level="DEBUG"'
```

## Configuration

Edit `config.yaml` to customize:

```yaml
vms:
  count: 10
  name_prefix: "snail-test"
  memory_mb: 2048
  vcpus: 2
  username: "snail"
  password: "snailtest123"

snail_core:
  repo_url: "https://github.com/sluggisty/snail-core"
  api_endpoint: "http://192.168.122.1:8080/api/v1/ingest"
  api_key: "test-api-key-12345"
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Host Machine                             │
│  ┌─────────────────┐                                            │
│  │  snail-shell    │ ◄─── Receives reports from VMs             │
│  │  :8080          │                                            │
│  └────────▲────────┘                                            │
│           │                                                      │
│           │ HTTP POST /api/v1/ingest                            │
│           │                                                      │
│  ┌────────┼────────────────────────────────────────────────┐    │
│  │        │            libvirt/KVM                          │    │
│  │  ┌─────┴─────┐  ┌───────────┐       ┌───────────┐      │    │
│  │  │snail-test-1│  │snail-test-2│  ...  │snail-test-10│     │    │
│  │  │           │  │           │       │           │      │    │
│  │  │snail-core │  │snail-core │       │snail-core │      │    │
│  │  └───────────┘  └───────────┘       └───────────┘      │    │
│  │         192.168.122.0/24 (NAT)                          │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  testing/harness.py  ─────►  Orchestration & Management         │
└─────────────────────────────────────────────────────────────────┘
```

## VM Details

Each VM is configured with:

- **OS:** Distribution and version specified at creation (Fedora, Debian, Ubuntu, CentOS, or RHEL)
- **Resources:** 2GB RAM, 2 vCPUs, 15GB disk (configurable)
- **User:** `snail` with sudo access
- **Password:** `snailtest123` (for console access)
- **SSH Key:** `~/.ssh/snail-test-key`
- **Naming:** `snail-test-<distro>-<version>-<number>` (e.g., `snail-test-fedora-42-1`, `snail-test-rhel-9.4-1`, `snail-test-ubuntu-24.04-1`)

### Snail Core Setup in VMs

- **Install Path:** `/opt/snail-core`
- **Virtual Env:** `/opt/snail-core/venv`
- **Config:** `/etc/snail-core/config.yaml`
- **Binary:** `/usr/local/bin/snail` (symlink)
- **Service:** `snail-core.timer` (runs every 5 minutes)
- **Additional Packages:** `openscap-scanner`, `scap-security-guide`, and `trivy` are installed by default

## Distribution-Specific Notes

### RHEL Minor Releases

RHEL supports both major and minor releases:
- **Major releases:** `9`, `8`, `7` (downloads latest minor)
- **Minor releases:** `9.4`, `9.3`, `8.10`, `8.9`, etc. (specific versions)

When using minor releases, image filenames use underscores:
- Version `9.4` → `rhel-cloud-base-9_4.qcow2`
- Version `8.10` → `rhel-cloud-base-8_10.qcow2`

### RHEL Subscription Requirements

RHEL cloud images require a Red Hat subscription. The script will:
1. Check if the image already exists locally (if manually downloaded)
2. Attempt automatic download (will fail without subscription)
3. Provide clear instructions for manual download

**Manual Download Steps:**
1. Visit: https://access.redhat.com/downloads/content/rhel
2. Navigate to: Red Hat Enterprise Linux > [version] > Cloud Images
3. Download: QCOW2 (KVM/GenericCloud) variant
4. Place at: `/var/lib/libvirt/images/rhel-cloud-base-[version].qcow2`

**Alternative:** Use CentOS Stream (free, similar to RHEL):
```bash
./scripts/setup-base-image.sh --distro centos --version 9
./harness.py create --specs centos:9
```

## Troubleshooting

### VMs Not Getting IP Addresses

```bash
# Check libvirt network
sudo virsh net-list
sudo virsh net-start default

# Check DHCP leases
sudo virsh net-dhcp-leases default
```

### Cannot Connect to VMs

```bash
# Check VM is running
sudo virsh list

# Check IP address
sudo virsh domifaddr snail-test-1

# Test SSH
ssh -i ~/.ssh/snail-test-key -v snail@<IP>
```

### Cloud-init Not Completing

```bash
# Connect to console
sudo virsh console snail-test-1

# Inside VM, check cloud-init status
sudo cloud-init status --long
sudo cat /var/log/cloud-init-output.log
```

### Snail Core Not Uploading

```bash
# Check if host is reachable from VM
./harness.py exec "curl -v http://192.168.122.1:8080/health"

# Check snail config
./harness.py exec "cat /etc/snail-core/config.yaml"

# Run snail manually with debug
./harness.py exec "SNAIL_API_KEY=test-api-key-12345 /opt/snail-core/venv/bin/snail -v run"
```

### Insufficient Resources

If VMs are slow or won't start:

```bash
# Check host resources
free -h
df -h

# Create fewer VMs with less resources
./harness.py destroy --force
./harness.py create --count 3 --memory 1024 --cpus 1
```

## Directory Structure

```
testing/
├── README.md                 # This file
├── config.yaml               # Main configuration
├── requirements.txt          # Python dependencies
├── harness.py                # Main CLI tool
├── vm-list.txt               # List of created VMs (generated)
├── scripts/
│   ├── setup-base-image.sh   # Download cloud images (Fedora, Debian, Ubuntu, CentOS, RHEL)
│   ├── create-vms.sh         # Create VMs with cloud-init
│   ├── destroy-vms.sh        # Remove VMs
│   └── get-vm-ips.sh         # Get VM IP addresses
└── ansible/
    ├── ansible.cfg           # Ansible configuration
    ├── inventory.py          # Dynamic inventory script
    └── playbooks/
        ├── update-snail.yaml # Update snail-core
        ├── run-snail.yaml    # Run snail collection
        ├── run-command.yaml  # Execute arbitrary commands
        ├── status.yaml       # Check snail status
        └── configure.yaml    # Update configuration
```

## License

Same as snail-core - Apache License 2.0
