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
        # Match pattern: snail-test-<version>-<number>
        if line.startswith(prefix) and "-" in line[len(prefix):]:
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
@click.option("--versions", "-v", help="Comma-separated Fedora versions (e.g., 42,41,40). Default: 42")
@click.option("--count", "-n", default=5, help="Number of VMs per version (default: 5)")
@click.option("--memory", "-m", default=2048, help="Memory per VM in MB")
@click.option("--cpus", "-c", default=2, help="vCPUs per VM")
def create(versions: str, count: int, memory: int, cpus: int):
    """Create test VMs for specified Fedora versions."""
    console.print(Panel.fit(
        "[bold blue]Creating Snail Core Test VMs[/]",
        border_style="blue"
    ))
    
    config = load_config()
    
    # Determine which versions to use
    if not versions:
        versions = ",".join(map(str, config.get("vms", {}).get("default_versions", [42])))
    
    version_list = [v.strip() for v in versions.split(",")]
    console.print(f"\n[dim]Fedora versions: {', '.join(version_list)}[/]")
    console.print(f"[dim]VMs per version: {count}[/]\n")
    
    # Check for base images
    console.print("[dim]Checking base images...[/]")
    image_dir = config.get("host", {}).get("image_dir", "/var/lib/libvirt/images")
    missing_images = []
    
    for version in version_list:
        base_image = Path(image_dir) / f"fedora-cloud-base-{version}.qcow2"
        if not base_image.exists():
            missing_images.append(version)
            console.print(f"[yellow]Base image missing for Fedora {version}[/]")
    
    if missing_images:
        console.print(f"\n[yellow]Downloading missing base images...[/]\n")
        for version in missing_images:
            try:
                run_script("setup-base-image.sh", ["--version", version], capture=False)
            except subprocess.CalledProcessError:
                console.print(f"[red]Failed to download base image for Fedora {version}[/]")
                sys.exit(1)
    
    # Create VMs
    total_vms = len(version_list) * count
    console.print(f"\n[dim]Creating {total_vms} VMs ({count} per version)...[/]\n")
    
    env = os.environ.copy()
    env["FEDORA_VERSIONS"] = versions
    env["VM_COUNT_PER_VERSION"] = str(count)
    env["MEMORY_MB"] = str(memory)
    env["VCPUS"] = str(cpus)
    
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
def ips():
    """List VM IP addresses (for scripting)."""
    vms = get_all_vm_info()
    for vm in vms:
        if vm.ip:
            print(f"{vm.name}:{vm.ip}")


@cli.command("list-versions")
def list_versions():
    """List available Fedora versions and their status."""
    config = load_config()
    available = config.get("vms", {}).get("available_versions", {})
    image_dir = config.get("host", {}).get("image_dir", "/var/lib/libvirt/images")
    
    console.print()
    table = Table(title="Available Fedora Versions")
    table.add_column("Version", style="cyan")
    table.add_column("Name", style="green")
    table.add_column("Base Image", justify="center")
    
    for version, name in sorted(available.items(), reverse=True):
        base_image = Path(image_dir) / f"fedora-cloud-base-{version}.qcow2"
        status = "[green]✓[/]" if base_image.exists() else "[red]✗[/]"
        table.add_row(str(version), name, status)
    
    console.print(table)
    console.print()
    console.print("[dim]Use --versions option when creating VMs to select specific versions[/]")
    console.print("[dim]Example: ./harness.py create --versions 42,41,40,39[/]")


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

