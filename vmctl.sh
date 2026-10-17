#!/usr/bin/env bash
# vmctl.sh - CLI tool to manage VM lifecycle (placeholder)
#
# This script provides commands to manage the lifecycle of provisioned VMs:
#   logs, rebuild, health, ssh, status.
#
# For now, it only prints usage and placeholder actions.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  logs        Show VM logs
  rebuild     Rebuild project inside VM
  health      Run health check on VM
  ssh         Open SSH session to VM
  status      Get VM status

Options:
  --host <VM_IP_OR_HOSTNAME>  Target VM (required for most commands)
  --lines <N>                 Number of log lines to show (default: 100)
  --follow                    Follow logs (like tail -f)
  --service <NAME>            Show logs for specific service (e.g., orchestrator)
  --help                      Show this help

Examples:
  $0 logs --host 192.168.1.26 --follow
  $0 rebuild --host 192.168.1.26
  $0 health --host 192.168.1.26
  $0 ssh --host 192.168.1.26
  $0 status --host 192.168.1.26
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

# Parse common options
VM_HOST=""
LINES=100
FOLLOW=false
SERVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            VM_HOST="$2"
            shift 2
            ;;
        --lines)
            LINES="$2"
            shift 2
            ;;
        --follow)
            FOLLOW=true
            shift
            ;;
        --service)
            SERVICE="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$VM_HOST" && "$COMMAND" != "--help" ]]; then
    echo "Error: --host is required for command '$COMMAND'"
    usage
    exit 1
fi

echo "=== VM Control Tool (Placeholder) ==="
echo "Command: $COMMAND"
echo "Target VM: $VM_HOST"
echo ""
echo "This script would:"
case "$COMMAND" in
    logs)
        echo "  Show logs from VM $VM_HOST"
        if [[ "$SERVICE" != "" ]]; then
            echo "  For service: $SERVICE"
        fi
        if [[ "$FOLLOW" == true ]]; then
            echo "  Follow mode: true"
        else
            echo "  Lines: $LINES"
        fi
        ;;
    rebuild)
        echo "  Rebuild project inside VM $VM_HOST"
        ;;
    health)
        echo "  Run health check on VM $VM_HOST"
        ;;
    ssh)
        echo "  Open SSH session to VM $VM_HOST"
        ;;
    status)
        echo "  Get status of VM $VM_HOST"
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
echo ""
echo "To be implemented: actual SSH and command execution."