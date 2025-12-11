# Snail Core VM Testing Environment

Automated testing infrastructure for snail-core using Fedora VMs. This environment creates and manages multiple Fedora VMs that clone, install, and run snail-core, reporting to a local snail-shell server.

## Overview

This testing harness:
- Creates 10 Fedora minimal VMs using libvirt/KVM
- Automatically clones and installs snail-core from GitHub
- Configures VMs to report to `localhost:8080` on the host
- Provides tools to manage, update, and execute commands on all VMs

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

### 2. Create Test VMs

```bash
# Download base image and create 10 VMs
./harness.py create

# Or with custom settings
./harness.py create --count 5 --memory 1024 --cpus 1
```

This will:
1. Download the Fedora Cloud Base image (if not present)
2. Create 10 VM disk images
3. Generate cloud-init configurations with snail-core setup
4. Start all VMs
5. Wait for VMs to get IP addresses

**Note:** Initial setup takes 5-10 minutes as VMs run dnf updates and install snail-core.

### 3. Check VM Status

```bash
# Show all VMs and their status
./harness.py status

# Check snail-core installation status
./harness.py check
```

### 4. Run Snail on All VMs

```bash
# Run 'snail run' on all VMs (collect and upload)
./harness.py run

# Run specific collectors only
./harness.py run -C system -C network -C packages
```

### 5. Update Snail Core

```bash
# Pull latest from GitHub and reinstall
./harness.py update

# Force reinstall even if no changes
./harness.py update --force
```

### 6. Clean Up

```bash
# Destroy all VMs
./harness.py destroy

# Destroy with force (no confirmation)
./harness.py destroy --force
```

## Command Reference

### VM Management

| Command | Description |
|---------|-------------|
| `./harness.py create` | Create test VMs |
| `./harness.py destroy` | Remove all test VMs |
| `./harness.py start` | Start all VMs |
| `./harness.py stop` | Gracefully stop all VMs |
| `./harness.py stop --force` | Force stop all VMs |
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
# Run only on snail-test-1
./harness.py run --limit snail-test-1

# Update on first 3 VMs
./harness.py update --limit "snail-test-[1:3]"
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

- **OS:** Fedora 42 Cloud (minimal)
- **Resources:** 2GB RAM, 2 vCPUs, 15GB disk
- **User:** `snail` with sudo access
- **Password:** `snailtest123` (for console access)
- **SSH Key:** `~/.ssh/snail-test-key`

### Snail Core Setup in VMs

- **Install Path:** `/opt/snail-core`
- **Virtual Env:** `/opt/snail-core/venv`
- **Config:** `/etc/snail-core/config.yaml`
- **Binary:** `/usr/local/bin/snail` (symlink)
- **Service:** `snail-core.timer` (runs every 5 minutes)

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
│   ├── setup-base-image.sh   # Download Fedora cloud image
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
