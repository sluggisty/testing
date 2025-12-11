#!/bin/bash
# get-vm-ips.sh - Get IP addresses and status of all test VMs
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(dirname "$SCRIPT_DIR")"

VM_PREFIX="${VM_PREFIX:-snail-test}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get list of test VMs
get_test_vms() {
    sudo virsh list --all --name | grep "^${VM_PREFIX}-" | sort -V || true
}

# Get VM IP address
get_vm_ip() {
    local vm_name="$1"
    sudo virsh domifaddr "$vm_name" 2>/dev/null | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1 || echo ""
}

# Get VM state
get_vm_state() {
    local vm_name="$1"
    sudo virsh domstate "$vm_name" 2>/dev/null || echo "unknown"
}

# Check if snail-core is installed (via SSH)
check_snail_installed() {
    local ip="$1"
    local ssh_key="${SSH_KEY_PATH:-${HOME}/.ssh/snail-test-key}"
    local user="${VM_USER:-snail}"
    
    if [[ -z "$ip" ]]; then
        echo "no-ip"
        return
    fi
    
    if ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
        "${user}@${ip}" "test -f /var/lib/snail-core/.setup-complete" 2>/dev/null; then
        echo "ready"
    elif ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
        "${user}@${ip}" "true" 2>/dev/null; then
        echo "setup"
    else
        echo "unreachable"
    fi
}

# Output as table
output_table() {
    echo ""
    echo "=========================================="
    echo "      Snail Core Test VMs Status"
    echo "=========================================="
    echo ""
    
    printf "%-20s %-18s %-12s %-12s\n" "VM Name" "IP Address" "State" "Snail Status"
    printf "%-20s %-18s %-12s %-12s\n" "-------" "----------" "-----" "------------"
    
    local vms
    vms=$(get_test_vms)
    
    if [[ -z "$vms" ]]; then
        echo "No VMs found with prefix: ${VM_PREFIX}"
        return
    fi
    
    while IFS= read -r vm_name; do
        if [[ -n "$vm_name" ]]; then
            local ip state snail_status
            ip=$(get_vm_ip "$vm_name")
            state=$(get_vm_state "$vm_name")
            
            # Color coding for state
            local state_color=""
            case "$state" in
                running) state_color="${GREEN}running${NC}" ;;
                "shut off") state_color="${YELLOW}stopped${NC}" ;;
                *) state_color="${RED}${state}${NC}" ;;
            esac
            
            # Check snail status if running
            if [[ "$state" == "running" && -n "$ip" ]]; then
                snail_status=$(check_snail_installed "$ip")
            else
                snail_status="-"
            fi
            
            # Color coding for snail status
            local snail_color=""
            case "$snail_status" in
                ready) snail_color="${GREEN}ready${NC}" ;;
                setup) snail_color="${YELLOW}setup${NC}" ;;
                no-ip) snail_color="${YELLOW}no-ip${NC}" ;;
                unreachable) snail_color="${RED}unreachable${NC}" ;;
                *) snail_color="$snail_status" ;;
            esac
            
            # Use ip or placeholder
            [[ -z "$ip" ]] && ip="pending..."
            
            printf "%-20s %-18s %-12b %-12b\n" "$vm_name" "$ip" "$state_color" "$snail_color"
        fi
    done <<< "$vms"
    
    echo ""
}

# Output as JSON
output_json() {
    local vms
    vms=$(get_test_vms)
    
    echo "{"
    echo '  "vms": ['
    
    local first=true
    while IFS= read -r vm_name; do
        if [[ -n "$vm_name" ]]; then
            local ip state snail_status
            ip=$(get_vm_ip "$vm_name")
            state=$(get_vm_state "$vm_name")
            
            if [[ "$state" == "running" && -n "$ip" ]]; then
                snail_status=$(check_snail_installed "$ip")
            else
                snail_status="unknown"
            fi
            
            [[ "$first" != true ]] && echo ","
            first=false
            
            echo "    {"
            echo "      \"name\": \"${vm_name}\","
            echo "      \"ip\": \"${ip:-null}\","
            echo "      \"state\": \"${state}\","
            echo "      \"snail_status\": \"${snail_status}\""
            echo -n "    }"
        fi
    done <<< "$vms"
    
    echo ""
    echo "  ]"
    echo "}"
}

# Output as simple list (for scripting)
output_list() {
    local vms
    vms=$(get_test_vms)
    
    while IFS= read -r vm_name; do
        if [[ -n "$vm_name" ]]; then
            local ip
            ip=$(get_vm_ip "$vm_name")
            if [[ -n "$ip" ]]; then
                echo "${vm_name}:${ip}"
            fi
        fi
    done <<< "$vms"
}

# Output IPs only (for ansible inventory)
output_ips() {
    local vms
    vms=$(get_test_vms)
    
    while IFS= read -r vm_name; do
        if [[ -n "$vm_name" ]]; then
            local ip
            ip=$(get_vm_ip "$vm_name")
            if [[ -n "$ip" ]]; then
                echo "$ip"
            fi
        fi
    done <<< "$vms"
}

# Main
main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --format|-f)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --prefix|-p)
                VM_PREFIX="$2"
                shift 2
                ;;
            --json)
                OUTPUT_FORMAT="json"
                shift
                ;;
            --list)
                OUTPUT_FORMAT="list"
                shift
                ;;
            --ips)
                OUTPUT_FORMAT="ips"
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --format, -f FMT   Output format: table, json, list, ips"
                echo "  --prefix, -p NAME  VM name prefix (default: snail-test)"
                echo "  --json             Output as JSON"
                echo "  --list             Output as name:ip list"
                echo "  --ips              Output IPs only (one per line)"
                echo ""
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    case "$OUTPUT_FORMAT" in
        table) output_table ;;
        json) output_json ;;
        list) output_list ;;
        ips) output_ips ;;
        *)
            echo "Unknown format: $OUTPUT_FORMAT"
            exit 1
            ;;
    esac
}

main "$@"

