#!/usr/bin/env python3
"""
Snail Core Test Harness - VM Orchestration Tool

This tool manages Fedora VMs for testing snail-core. It provides commands
to create, manage, and interact with test VMs.
"""

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import click
import yaml
from rich.console import Console
from rich.panel import Panel
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.table import Table

console = Console()

# Default paths
SCRIPT_DIR = Path(__file__).parent.resolve()
CONFIG_FILE = SCRIPT_DIR / "config.yaml"
SCRIPTS_DIR = SCRIPT_DIR / "scripts"
ANSIBLE_DIR = SCRIPT_DIR / "ansible"
PLAYBOOKS_DIR = ANSIBLE_DIR / "playbooks"


@dataclass
class VMInfo:
    """Information about a VM."""
    name: str
    ip: str | None
    state: str
    snail_status: str = "unknown"


def load_config() -> dict[str, Any]:
    """Load configuration from config.yaml."""
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            return yaml.safe_load(f)
    return {}


def run_command(
    cmd: list[str],
    capture: bool = True,
    check: bool = True,
    sudo: bool = False,
    **kwargs
) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    if sudo and os.geteuid() != 0:
        cmd = ["sudo"] + cmd
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=capture,
            text=True,
            check=check,
            **kwargs
        )
        return result
    except subprocess.CalledProcessError as e:
        if capture:
            console.print(f"[red]Command failed:[/] {' '.join(cmd)}")
            if e.stdout:
                console.print(f"[dim]stdout:[/] {e.stdout}")
            if e.stderr:
                console.print(f"[dim]stderr:[/] {e.stderr}")
        raise


def run_script(script_name: str, args: list[str] = None, **kwargs) -> subprocess.CompletedProcess:
    """Run a script from the scripts directory."""
    script_path = SCRIPTS_DIR / script_name
    if not script_path.exists():
        raise FileNotFoundError(f"Script not found: {script_path}")
    
    cmd = ["bash", str(script_path)]
    if args:
        cmd.extend(args)
    
    return run_command(cmd, **kwargs)


def run_ansible_playbook(
    playbook: str,
    extra_vars: dict = None,
    limit: str = None,
    verbose: bool = False
) -> bool:
    """Run an Ansible playbook."""
    playbook_path = PLAYBOOKS_DIR / playbook
    if not playbook_path.exists():
        raise FileNotFoundError(f"Playbook not found: {playbook_path}")
    
    cmd = [
        "ansible-playbook",
        str(playbook_path),
    ]
    
    if extra_vars:
        cmd.extend(["-e", json.dumps(extra_vars)])
    
    if limit:
        cmd.extend(["--limit", limit])
    
    if verbose:
        cmd.append("-v")
    
    # Run from ansible directory to pick up ansible.cfg
    result = run_command(
        cmd,
        capture=False,
        check=False,
        cwd=str(ANSIBLE_DIR)
    )
    
    return result.returncode == 0


def get_vm_list() -> list[str]:
    """Get list of all snail-test VMs."""
    config = load_config()
    prefix = config.get("vms", {}).get("name_prefix", "snail-test")
    
    result = run_command(
        ["virsh", "list", "--all", "--name"],
        sudo=True,
        check=False
    )
    
    if result.returncode != 0:
        return []
    
    vms = []
    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        # Match pattern: snail-test-<distro>-<version>-<number> or snail-test-<version>-<number> (legacy)
        if line.startswith(prefix) and "-" in line[len(prefix):]:
            vms.append(line)
    
    # Sort by distro, version, then number
    def sort_key(vm_name: str) -> tuple:
        parts = vm_name.split("-")
        if len(parts) >= 4:
            # New format: prefix-distro-version-number
            try:
                distro = parts[-3]
                version = parts[-2]
                number = int(parts[-1])
                # Convert version to int if possible for sorting
                try:
                    version_num = int(version)
                except ValueError:
                    version_num = 0
                return (distro, version_num, number)
            except (ValueError, IndexError):
                pass
        elif len(parts) >= 3:
            # Legacy format: prefix-version-number
            try:
                version = int(parts[-2])
                number = int(parts[-1])
                return ("fedora", version, number)  # Assume fedora for legacy
            except ValueError:
                pass
        return ("", 0, 0)
    
    return sorted(vms, key=sort_key, reverse=True)


def get_vm_info(vm_name: str) -> VMInfo:
    """Get information about a specific VM."""
    # Get state
    result = run_command(
        ["virsh", "domstate", vm_name],
        sudo=True,
        check=False
    )
    state = result.stdout.strip() if result.returncode == 0 else "unknown"
    
    # Get IP
    ip = None
    if state == "running":
        result = run_command(
            ["virsh", "domifaddr", vm_name],
            sudo=True,
            check=False
        )
        if result.returncode == 0:
            match = re.search(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', result.stdout)
            if match:
                ip = match.group(0)
    
    return VMInfo(name=vm_name, ip=ip, state=state)


def get_all_vm_info() -> list[VMInfo]:
    """Get information about all test VMs."""
    vms = get_vm_list()
    return [get_vm_info(vm) for vm in vms]


# CLI Commands
@click.group()
@click.version_option(version="0.1.0", prog_name="snail-harness")
def cli():
    """
    Snail Core Test Harness - VM management and testing tool.
    
    This tool helps you create, manage, and test snail-core across
    multiple Fedora VMs.
    """
    pass


@cli.command()
@click.option("--distro", "-d", help="Distribution: fedora or debian (default: fedora)")
@click.option("--versions", "-v", help="Comma-separated versions (e.g., 42,41,40 for fedora or 12,11 for debian)")
@click.option("--specs", "-s", help="VM specs in format 'distro:version' (e.g., 'fedora:42,debian:12')")
@click.option("--count", "-n", default=5, help="Number of VMs per version (default: 5)")
@click.option("--memory", "-m", default=2048, help="Memory per VM in MB")
@click.option("--cpus", "-c", default=2, help="vCPUs per VM")
def create(distro: str, versions: str, specs: str, count: int, memory: int, cpus: int):
    """Create test VMs for specified distributions and versions."""
    console.print(Panel.fit(
        "[bold blue]Creating Snail Core Test VMs[/]",
        border_style="blue"
    ))
    
    config = load_config()
    default_distro = config.get("vms", {}).get("default_distribution", "fedora")
    
    # Build VM specs
    vm_specs = []
    
    if specs:
        # Use explicit specs format: "fedora:42,debian:12"
        vm_specs = [s.strip() for s in specs.split(",")]
    elif versions:
        # Use versions with optional distro
        distro_to_use = distro or default_distro
        version_list = [v.strip() for v in versions.split(",")]
        vm_specs = [f"{distro_to_use}:{v}" for v in version_list]
    else:
        # Use defaults from config
        default_versions = config.get("vms", {}).get("default_versions", ["fedora:42"])
        vm_specs = [str(v) for v in default_versions]
    
    console.print(f"\n[dim]VM specs: {', '.join(vm_specs)}[/]")
    console.print(f"[dim]VMs per version: {count}[/]\n")
    
    # Check for base images
    console.print("[dim]Checking base images...[/]")
    image_dir = config.get("host", {}).get("image_dir", "/var/lib/libvirt/images")
    missing_images = []
    
    for spec in vm_specs:
        # Parse spec (format: "distro:version" or just "version")
        if ":" in spec:
            spec_distro, spec_version = spec.split(":", 1)
        else:
            spec_distro = default_distro
            spec_version = spec
        
        if spec_distro == "fedora":
            base_image = Path(image_dir) / f"fedora-cloud-base-{spec_version}.qcow2"
        elif spec_distro == "debian":
            base_image = Path(image_dir) / f"debian-cloud-base-{spec_version}.qcow2"
        elif spec_distro == "ubuntu":
            version_key = spec_version.replace(".", "_")
            base_image = Path(image_dir) / f"ubuntu-cloud-base-{version_key}.qcow2"
        else:
            console.print(f"[red]Unknown distribution: {spec_distro}[/]")
            sys.exit(1)
        
        if not base_image.exists():
            missing_images.append((spec_distro, spec_version))
            console.print(f"[yellow]Base image missing for {spec_distro} {spec_version}[/]")
    
    if missing_images:
        console.print(f"\n[yellow]Downloading missing base images...[/]\n")
        for spec_distro, spec_version in missing_images:
            try:
                run_script("setup-base-image.sh", ["--distro", spec_distro, "--version", spec_version], capture=False)
            except subprocess.CalledProcessError:
                console.print(f"[red]Failed to download base image for {spec_distro} {spec_version}[/]")
                sys.exit(1)
    
    # Create VMs
    total_vms = len(vm_specs) * count
    console.print(f"\n[dim]Creating {total_vms} VMs ({count} per version)...[/]\n")
    
    # Get image and cloudinit directories from config
    host_config = config.get("host", {})
    image_dir_config = host_config.get("image_dir", "/var/lib/libvirt/images")
    cloudinit_dir_config = host_config.get("cloudinit_dir", "/tmp/snail-test-cloudinit")
    
    env = os.environ.copy()
    env["VM_SPECS"] = ",".join(vm_specs)
    env["VM_COUNT_PER_VERSION"] = str(count)
    env["MEMORY_MB"] = str(memory)
    env["VCPUS"] = str(cpus)
    env["IMAGE_DIR"] = image_dir_config
    env["CLOUDINIT_DIR"] = cloudinit_dir_config
    
    result = run_command(
        ["bash", str(SCRIPTS_DIR / "create-vms.sh")],
        capture=False,
        check=False,  # Don't fail on non-zero exit
        env=env
    )
    
    # Check if VMs were actually created
    vms = get_vm_list()
    if len(vms) > 0:
        console.print(f"\n[green]✓ {len(vms)} VMs created![/]")
        console.print("[dim]Note: VMs may take a few minutes to boot and get IP addresses.[/]")
        console.print("[dim]Check status with: ./harness.py status[/]")
    else:
        console.print("[red]Failed to create VMs[/]")
        sys.exit(1)


@cli.command()
@click.option("--force", "-f", is_flag=True, help="Don't ask for confirmation")
@click.option("--vm", help="Destroy specific VM only")
def destroy(force: bool, vm: str):
    """Destroy test VMs."""
    args = []
    if force:
        args.append("--force")
    if vm:
        args.extend(["--vm", vm])
    
    try:
        run_script("destroy-vms.sh", args, capture=False)
    except subprocess.CalledProcessError:
        sys.exit(1)


@cli.command()
@click.option("--json", "as_json", is_flag=True, help="Output as JSON")
def status(as_json: bool):
    """Show status of all test VMs."""
    vms = get_all_vm_info()
    
    if not vms:
        console.print("[yellow]No test VMs found[/]")
        return
    
    if as_json:
        data = [{"name": v.name, "ip": v.ip, "state": v.state} for v in vms]
        console.print_json(json.dumps(data))
        return
    
    console.print()
    table = Table(title="Snail Core Test VMs")
    table.add_column("VM Name", style="cyan")
    table.add_column("IP Address")
    table.add_column("State")
    
    for vm in vms:
        state_style = "green" if vm.state == "running" else "yellow"
        ip_display = vm.ip or "[dim]pending...[/]"
        table.add_row(vm.name, ip_display, f"[{state_style}]{vm.state}[/]")
    
    console.print(table)
    
    running = sum(1 for v in vms if v.state == "running")
    console.print(f"\n[dim]Total: {len(vms)} VMs, {running} running[/]")


@cli.command("run")
@click.option("--collectors", "-C", multiple=True, help="Specific collectors to run")
@click.option("--limit", "-l", help="Limit to specific VM(s)")
@click.option("--verbose", "-v", is_flag=True, help="Verbose output")
def run_snail(collectors: tuple, limit: str, verbose: bool):
    """Run 'snail run' on all VMs."""
    console.print(Panel.fit(
        "[bold blue]Running snail-core on VMs[/]",
        border_style="blue"
    ))
    
    extra_vars = {}
    if collectors:
        extra_vars["snail_collectors"] = list(collectors)
    
    success = run_ansible_playbook(
        "run-snail.yaml",
        extra_vars=extra_vars,
        limit=limit,
        verbose=verbose
    )
    
    if success:
        console.print("\n[green]✓ Snail run completed on all VMs[/]")
    else:
        console.print("\n[red]✗ Some VMs failed[/]")
        sys.exit(1)


@cli.command()
@click.option("--force", "-f", is_flag=True, help="Force reinstall even if no changes")
@click.option("--limit", "-l", help="Limit to specific VM(s)")
@click.option("--verbose", "-v", is_flag=True, help="Verbose output")
def update(force: bool, limit: str, verbose: bool):
    """Update snail-core to latest version on all VMs."""
    console.print(Panel.fit(
        "[bold blue]Updating snail-core on VMs[/]",
        border_style="blue"
    ))
    
    extra_vars = {}
    if force:
        extra_vars["force_reinstall"] = True
    
    success = run_ansible_playbook(
        "update-snail.yaml",
        extra_vars=extra_vars,
        limit=limit,
        verbose=verbose
    )
    
    if success:
        console.print("\n[green]✓ Update completed on all VMs[/]")
    else:
        console.print("\n[red]✗ Update failed on some VMs[/]")
        sys.exit(1)


@cli.command()
@click.option("--api-endpoint", help="API endpoint URL")
@click.option("--api-key", help="API key for authentication")
@click.option("--log-level", type=click.Choice(["DEBUG", "INFO", "WARNING", "ERROR"]))
@click.option("--limit", "-l", help="Limit to specific VM(s)")
@click.option("--verbose", "-v", is_flag=True, help="Verbose output")
def configure(api_endpoint: str, api_key: str, log_level: str, limit: str, verbose: bool):
    """Update snail-core configuration on all VMs."""
    console.print(Panel.fit(
        "[bold blue]Configuring snail-core on VMs[/]",
        border_style="blue"
    ))
    
    extra_vars = {}
    if api_endpoint:
        extra_vars["snail_api_endpoint"] = api_endpoint
    if api_key:
        extra_vars["snail_api_key"] = api_key
    if log_level:
        extra_vars["snail_log_level"] = log_level
    
    success = run_ansible_playbook(
        "configure.yaml",
        extra_vars=extra_vars,
        limit=limit,
        verbose=verbose
    )
    
    if success:
        console.print("\n[green]✓ Configuration updated on all VMs[/]")
    else:
        console.print("\n[red]✗ Configuration failed on some VMs[/]")
        sys.exit(1)


@cli.command()
@click.argument("command")
@click.option("--limit", "-l", help="Limit to specific VM(s)")
@click.option("--no-sudo", is_flag=True, help="Don't run as root")
@click.option("--ignore-errors", is_flag=True, help="Continue on errors")
def exec(command: str, limit: str, no_sudo: bool, ignore_errors: bool):
    """Execute a command on all VMs."""
    console.print(Panel.fit(
        f"[bold blue]Executing command on VMs[/]\n[dim]{command}[/]",
        border_style="blue"
    ))
    
    extra_vars = {
        "cmd": command,
        "run_as_root": not no_sudo,
        "ignore_errors": ignore_errors
    }
    
    success = run_ansible_playbook(
        "run-command.yaml",
        extra_vars=extra_vars,
        limit=limit
    )
    
    if not success and not ignore_errors:
        sys.exit(1)


@cli.command()
@click.option("--limit", "-l", help="Limit to specific VM(s)")
@click.option("--verbose", "-v", is_flag=True, help="Verbose output")
def check(limit: str, verbose: bool):
    """Check snail-core status on all VMs."""
    console.print(Panel.fit(
        "[bold blue]Checking snail-core status[/]",
        border_style="blue"
    ))
    
    success = run_ansible_playbook(
        "status.yaml",
        limit=limit,
        verbose=verbose
    )
    
    if not success:
        console.print("\n[yellow]Some VMs may have issues[/]")


@cli.command("cloud-init-status")
@click.option("--limit", "-l", help="Limit to specific VM(s)")
def cloud_init_status(limit: str):
    """Check cloud-init status on all VMs."""
    console.print(Panel.fit(
        "[bold blue]Checking cloud-init status[/]",
        border_style="blue"
    ))
    
    extra_vars = {"cmd": "cloud-init status --long"}
    
    success = run_ansible_playbook(
        "run-command.yaml",
        extra_vars=extra_vars,
        limit=limit
    )
    
    if not success:
        console.print("\n[yellow]Some VMs may have issues[/]")


@cli.command()
@click.argument("vm_name")
def ssh(vm_name: str):
    """SSH into a specific VM."""
    vm = get_vm_info(vm_name)
    
    if vm.state != "running":
        console.print(f"[red]VM {vm_name} is not running (state: {vm.state})[/]")
        sys.exit(1)
    
    if not vm.ip:
        console.print(f"[red]VM {vm_name} has no IP address[/]")
        sys.exit(1)
    
    config = load_config()
    ssh_key = os.path.expanduser(
        config.get("vms", {}).get("ssh_key_path", "~/.ssh/snail-test-key")
    )
    username = config.get("vms", {}).get("username", "snail")
    
    console.print(f"[dim]Connecting to {vm_name} ({vm.ip})...[/]\n")
    
    os.execvp("ssh", [
        "ssh",
        "-i", ssh_key,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        f"{username}@{vm.ip}"
    ])


@cli.command()
@click.argument("vm_name")
def console_connect(vm_name: str):
    """Connect to VM console (virsh console)."""
    vm = get_vm_info(vm_name)
    
    if vm.state != "running":
        console.print(f"[red]VM {vm_name} is not running (state: {vm.state})[/]")
        sys.exit(1)
    
    console.print(f"[dim]Connecting to console (Ctrl+] to exit)...[/]\n")
    os.execvp("sudo", ["sudo", "virsh", "console", vm_name])


@cli.command()
@click.option("--vm", "-v", help="Start specific VM only")
def start(vm: str):
    """Start test VMs."""
    if vm:
        vms = [vm]
    else:
        vms = get_vm_list()
    
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        task = progress.add_task(f"Starting {len(vms)} VMs...", total=len(vms))
        
        for vm_name in vms:
            progress.update(task, description=f"Starting {vm_name}...")
            run_command(["virsh", "start", vm_name], sudo=True, check=False)
            progress.advance(task)
    
    console.print("[green]✓ VMs started[/]")


@cli.command()
@click.option("--vm", "-v", help="Stop specific VM only")
@click.option("--force", "-f", is_flag=True, help="Force stop (destroy)")
def stop(vm: str, force: bool):
    """Stop test VMs."""
    if vm:
        vms = [vm]
    else:
        vms = get_vm_list()
    
    cmd = "destroy" if force else "shutdown"
    
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        task = progress.add_task(f"Stopping {len(vms)} VMs...", total=len(vms))
        
        for vm_name in vms:
            progress.update(task, description=f"Stopping {vm_name}...")
            run_command(["virsh", cmd, vm_name], sudo=True, check=False)
            progress.advance(task)
    
    console.print("[green]✓ VMs stopped[/]")


@cli.command()
@click.option("--vm", "-v", help="Shutdown specific VM only")
@click.option("--wait", "-w", is_flag=True, help="Wait for VMs to fully shutdown")
def shutdown(vm: str, wait: bool):
    """Gracefully shutdown test VMs (without destroying them)."""
    console.print(Panel.fit(
        "[bold blue]Shutting Down Test VMs[/]\n[dim]VMs will be gracefully shut down but not deleted[/]",
        border_style="blue"
    ))
    
    if vm:
        vms = [vm]
    else:
        vms = get_vm_list()
    
    if not vms:
        console.print("[yellow]No test VMs found[/]")
        return
    
    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        task = progress.add_task(f"Shutting down {len(vms)} VMs...", total=len(vms))
        
        for vm_name in vms:
            progress.update(task, description=f"Shutting down {vm_name}...")
            # Use virsh shutdown for graceful shutdown
            result = run_command(["virsh", "shutdown", vm_name], sudo=True, check=False)
            if result.returncode != 0:
                # Check if VM is already shut down
                vm_info = get_vm_info(vm_name)
                if vm_info.state not in ["shut off", "shutdown"]:
                    console.print(f"[yellow]Warning: Failed to shutdown {vm_name}[/]")
            progress.advance(task)
    
    if wait:
        console.print("\n[dim]Waiting for VMs to fully shutdown...[/]")
        import time
        max_wait = 60  # Maximum 60 seconds
        elapsed = 0
        while elapsed < max_wait:
            all_shut = True
            for vm_name in vms:
                vm_info = get_vm_info(vm_name)
                if vm_info.state not in ["shut off", "shutdown"]:
                    all_shut = False
                    break
            if all_shut:
                break
            time.sleep(2)
            elapsed += 2
        
        if elapsed >= max_wait:
            console.print("[yellow]Some VMs may still be shutting down[/]")
    
    console.print("[green]✓ VMs shutdown complete[/]")
    console.print("[dim]VMs are stopped but not deleted. Use './harness.py start' to start them again.[/]")


@cli.command()
def ips():
    """List VM IP addresses (for scripting)."""
    vms = get_all_vm_info()
    for vm in vms:
        if vm.ip:
            print(f"{vm.name}:{vm.ip}")


@cli.command("list-versions")
def list_versions():
    """List available distributions and their versions."""
    config = load_config()
    distributions = config.get("vms", {}).get("distributions", {})
    image_dir = config.get("host", {}).get("image_dir", "/var/lib/libvirt/images")
    
    console.print()
    
    # Show Fedora versions
    if "fedora" in distributions:
        fedora_versions = distributions["fedora"].get("available_versions", {})
        table = Table(title="Available Fedora Versions")
        table.add_column("Version", style="cyan")
        table.add_column("Name", style="green")
        table.add_column("Base Image", justify="center")
        
        # Sort by version number (handle both int and string keys)
        def sort_key(item):
            version = item[0]
            if isinstance(version, int):
                return version
            elif isinstance(version, str) and version.isdigit():
                return int(version)
            else:
                return 0
        
        for version, name in sorted(fedora_versions.items(), key=sort_key, reverse=True):
            base_image = Path(image_dir) / f"fedora-cloud-base-{version}.qcow2"
            status = "[green]✓[/]" if base_image.exists() else "[red]✗[/]"
            table.add_row(str(version), name, status)
        
        console.print(table)
        console.print()
    
    # Show Debian versions
    if "debian" in distributions:
        debian_versions = distributions["debian"].get("available_versions", {})
        table = Table(title="Available Debian Versions")
        table.add_column("Version", style="cyan")
        table.add_column("Name", style="green")
        table.add_column("Base Image", justify="center")
        
        # Sort by version number (handle both int and string keys)
        def sort_key(item):
            version = item[0]
            if isinstance(version, int):
                return version
            elif isinstance(version, str) and version.isdigit():
                return int(version)
            else:
                return 0
        
        for version, name in sorted(debian_versions.items(), key=sort_key, reverse=True):
            base_image = Path(image_dir) / f"debian-cloud-base-{version}.qcow2"
            status = "[green]✓[/]" if base_image.exists() else "[red]✗[/]"
            table.add_row(str(version), name, status)
        
        console.print(table)
        console.print()
    
    # Show Ubuntu versions
    if "ubuntu" in distributions:
        ubuntu_versions = distributions["ubuntu"].get("available_versions", {})
        table = Table(title="Available Ubuntu Versions")
        table.add_column("Version", style="cyan")
        table.add_column("Name", style="green")
        table.add_column("Base Image", justify="center")
        
        # Sort Ubuntu versions (they're like "24.04", "22.04", etc.)
        def ubuntu_sort_key(item):
            version = item[0]
            if isinstance(version, str) and "." in version:
                parts = version.split(".")
                if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                    return int(parts[0]) * 100 + int(parts[1])
            return 0
        
        for version, name in sorted(ubuntu_versions.items(), key=ubuntu_sort_key, reverse=True):
            version_key = version.replace(".", "_")
            base_image = Path(image_dir) / f"ubuntu-cloud-base-{version_key}.qcow2"
            status = "[green]✓[/]" if base_image.exists() else "[red]✗[/]"
            table.add_row(str(version), name, status)
        
        console.print(table)
        console.print()
    
    console.print("[dim]Use --specs option when creating VMs to select specific versions[/]")
    console.print("[dim]Examples:[/]")
    console.print("[dim]  ./harness.py create --specs fedora:42,41[/]")
    console.print("[dim]  ./harness.py create --specs debian:12,11[/]")
    console.print("[dim]  ./harness.py create --specs ubuntu:24.04,22.04[/]")
    console.print("[dim]  ./harness.py create --specs fedora:42,debian:12,ubuntu:24.04[/]")


@cli.group()
def ansible():
    """Run Ansible commands directly."""
    pass


@ansible.command("inventory")
def ansible_inventory():
    """Show Ansible inventory."""
    run_command(
        ["python3", str(ANSIBLE_DIR / "inventory.py"), "--list"],
        capture=False,
        cwd=str(ANSIBLE_DIR)
    )


@ansible.command("playbook")
@click.argument("playbook_name")
@click.option("--extra-vars", "-e", help="Extra variables (JSON)")
@click.option("--limit", "-l", help="Limit hosts")
@click.option("--verbose", "-v", is_flag=True)
def ansible_playbook(playbook_name: str, extra_vars: str, limit: str, verbose: bool):
    """Run an Ansible playbook."""
    extra = json.loads(extra_vars) if extra_vars else None
    
    if not playbook_name.endswith(".yaml"):
        playbook_name += ".yaml"
    
    success = run_ansible_playbook(
        playbook_name,
        extra_vars=extra,
        limit=limit,
        verbose=verbose
    )
    
    if not success:
        sys.exit(1)


if __name__ == "__main__":
    cli()

