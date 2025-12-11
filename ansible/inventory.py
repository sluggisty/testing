#!/usr/bin/env python3
"""
Dynamic Ansible inventory for snail-core test VMs.

This script queries libvirt to get the list of running snail-test VMs
and their IP addresses.
"""

import json
import subprocess
import sys
import re
import argparse


VM_PREFIX = "snail-test"
SSH_USER = "snail"
SSH_KEY = "~/.ssh/snail-test-key"


def run_command(cmd: list[str]) -> tuple[str, int]:
    """Run a command and return stdout and return code."""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.stdout.strip(), result.returncode
    except subprocess.TimeoutExpired:
        return "", 1
    except Exception as e:
        return str(e), 1


def get_vm_list() -> list[str]:
    """Get list of all snail-test VMs."""
    stdout, rc = run_command(["sudo", "virsh", "list", "--all", "--name"])
    if rc != 0:
        return []
    
    vms = []
    for line in stdout.split("\n"):
        line = line.strip()
        # Match pattern: snail-test-<version>-<number>
        if line.startswith(VM_PREFIX) and "-" in line[len(VM_PREFIX):]:
            vms.append(line)
    
    # Sort by version then number
    def sort_key(vm_name: str) -> tuple:
        parts = vm_name.split("-")
        if len(parts) >= 3:
            try:
                version = int(parts[-2])
                number = int(parts[-1])
                return (version, number)
            except ValueError:
                return (0, 0)
        return (0, 0)
    
    return sorted(vms, key=sort_key, reverse=True)


def get_vm_ip(vm_name: str) -> str | None:
    """Get IP address for a VM."""
    stdout, rc = run_command(["sudo", "virsh", "domifaddr", vm_name])
    if rc != 0:
        return None
    
    # Parse IP from output like: vnet0  52:54:00:xx:xx:xx  ipv4  192.168.124.xxx/24
    # Match any private IP (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
    match = re.search(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', stdout)
    if match:
        return match.group(0)
    return None


def get_vm_state(vm_name: str) -> str:
    """Get VM state."""
    stdout, rc = run_command(["sudo", "virsh", "domstate", vm_name])
    if rc != 0:
        return "unknown"
    return stdout.strip()


def build_inventory() -> dict:
    """Build Ansible inventory from running VMs."""
    inventory = {
        "_meta": {
            "hostvars": {}
        },
        "all": {
            "children": ["snail_vms"]
        },
        "snail_vms": {
            "hosts": [],
            "vars": {
                "ansible_user": SSH_USER,
                "ansible_ssh_private_key_file": SSH_KEY,
                "ansible_python_interpreter": "/usr/bin/python3",
                "snail_install_path": "/opt/snail-core",
                "snail_venv_path": "/opt/snail-core/venv",
                "snail_config_path": "/etc/snail-core/config.yaml"
            }
        }
    }
    
    vms = get_vm_list()
    
    for vm_name in vms:
        state = get_vm_state(vm_name)
        if state != "running":
            continue
        
        ip = get_vm_ip(vm_name)
        if not ip:
            continue
        
        inventory["snail_vms"]["hosts"].append(vm_name)
        inventory["_meta"]["hostvars"][vm_name] = {
            "ansible_host": ip,
            "vm_name": vm_name
        }
    
    return inventory


def get_host_vars(hostname: str) -> dict:
    """Get variables for a specific host."""
    ip = get_vm_ip(hostname)
    if ip:
        return {
            "ansible_host": ip,
            "vm_name": hostname
        }
    return {}


def main():
    parser = argparse.ArgumentParser(description="Dynamic inventory for snail-test VMs")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--list", action="store_true", help="List all hosts")
    group.add_argument("--host", type=str, help="Get host vars for specific host")
    
    args = parser.parse_args()
    
    if args.list:
        inventory = build_inventory()
        print(json.dumps(inventory, indent=2))
    elif args.host:
        hostvars = get_host_vars(args.host)
        print(json.dumps(hostvars, indent=2))


if __name__ == "__main__":
    main()

