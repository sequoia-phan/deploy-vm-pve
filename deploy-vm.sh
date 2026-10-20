#!/usr/bin/env bash
# deploy-vm.sh - VM provisioning for Proxmox VE
#
# Main goal: Provision a VM in PVE with configurable CPU/RAM/SSD/IP settings.
#
# Usage:
#   ./deploy-vm.sh [--dry-run|--execute] <config-file>
#
#   --dry-run: Only print the qm commands without executing them.
#   <config-file>: File containing VAR=VALUE lines (see examples/dhcp.env or examples/static.env)
#
# The script will:
#   1. Read configuration from .env file (or environment variables).
#   2. Check if the VM ID is already in use.
#   3. Create a VM in PVE using qm command.
#   4. Import the cloud-init image as a disk.
#   5. Attach the imported disk as a SCSI disk (using the unused disk after import).
#   6. Set boot order to boot from the SCSI disk.
#   7. Add a cloud-init drive.
#   8. Configure cloud-init with user and SSH key.
#   9. Set network configuration (DHCP or static).
#   10. Start the VM and wait for SSH.
#   11. Enable QEMU guest agent for better host-guest communication.
#   12. Optionally run health-check.sh after provisioning.
#
# For safety, the script defaults to dry-run mode. To execute for real, omit --dry-run.

# Set default to dry-run for safety
DRY_RUN=true

# Parse command line arguments
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    CONFIG_FILE="$2"
elif [[ "$1" == "--execute" ]]; then
    DRY_RUN=false
    CONFIG_FILE="$2"
else
    # If neither --dry-run nor --execute is given, treat first argument as config file and default to dry-run
    CONFIG_FILE="$1"
fi

if [[ -z "$CONFIG_FILE" ]]; then
    echo "Usage: $0 [--dry-run|--execute] <config-file>"
    echo "Example: $0 --dry-run examples/dhcp.env"
    echo "Example: $0 --execute examples/dhcp.env"
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file '$CONFIG_FILE' not found."
    exit 1
fi

# Source the configuration (key=value lines)
# shellcheck disable=SC1091
source "$CONFIG_FILE"

# Storage to use for disks and cloud-init
STORAGE="${STORAGE:-local}"

# Helper function to run a command (or echo it in dry-run)
run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] $*"
    else
        echo "Running: $*"
        "$@"
    fi
}

echo "=== VM Provisioning ==="
echo "Mode: $(if [[ "$DRY_RUN" == true ]]; then echo "DRY-RUN (no changes will be made)"; else echo "EXECUTE"; fi)"
echo "Configuration loaded from: $CONFIG_FILE"
echo "PVE_HOST: ${PVE_HOST:-not set}"
echo "VM_NAME: ${VM_NAME:-not set}"
echo "VM_ID: ${VM_ID:-not set}"
echo "CPU_CORES: ${CPU_CORES:-not set}"
echo "RAM_MB: ${RAM_MB:-not set}"
echo "DISK_GB: ${DISK_GB:-not set}"
echo "IP_ADDRESS: ${IP_ADDRESS:-not set}"
echo "GIT_REPO_URL: ${GIT_REPO_URL:-not set}"
echo ""

# Check required variables
if [[ -z "$PVE_HOST" || -z "$VM_NAME" || -z "$VM_ID" || -z "$CPU_CORES" || -z "$RAM_MB" || -z "$DISK_GB" ]]; then
    echo "Error: Required variables (PVE_HOST, VM_NAME, VM_ID, CPU_CORES, RAM_MB, DISK_GB) must be set in the config file."
    exit 1
fi

# Check if VM ID is already in use
echo "Checking if VM ID $VM_ID is already in use..."
if qm list | grep -q "^$VM_ID "; then
    echo "Error: VM ID $VM_ID is already in use."
    exit 1
else
    echo "VM ID $VM_ID is free."
fi

# Step 1: Create the VM
echo "Step 1: Creating VM $VM_ID ($VM_NAME) with $CPU_CORES cores, $RAM_MB MB RAM..."
# Note: We assume the bridge is vmbr0 (common in PVE). Adjust if needed.
run_cmd qm create "$VM_ID" --memory "$RAM_MB" --cores "$CPU_CORES" --name "$VM_NAME" --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single

# Step 2: Import the cloud-init image
echo "Step 2: Importing cloud-init image..."
# Assumes the image is located at ./img/ubuntu-20.04-server-cloudimg-amd64.img relative to this script
IMAGE_PATH="$(dirname "$0")/img/ubuntu-20.04-server-cloudimg-amd64.img"
if [[ ! -f "$IMAGE_PATH" ]]; then
    echo "Error: Cloud image not found at $IMAGE_PATH"
    exit 1
fi
run_cmd qm importdisk "$VM_ID" "$IMAGE_PATH" "$STORAGE"

# Step 3: Attach the imported disk as SCSI disk and resize the imported OS disk
echo "Step 3: Attaching disk as SCSI disk... and resizing OS disk to ${DISK_GB} GB..."
if [[ "$DRY_RUN" == false ]]; then
    # Get the unused volume that corresponds to the imported disk
    UNUSED_VOL=$(qm config "$VM_ID" | grep -oP 'unused0:\s*\K\S+')
    if [[ -z "$UNUSED_VOL" ]]; then
        echo "Error: Could not find unused disk after import."
        exit 1
    fi
    run_cmd qm set "$VM_ID" --scsi0 "$UNUSED_VOL"
    run_cmd qm resize "$VM_ID" scsi0 "${DISK_GB}G"
else
    echo "[DRY-RUN] Would attach unused disk as scsi0 (unused0 -> ${STORAGE}:vm-${VM_ID}-disk-0.raw) and resize scsi0 to ${DISK_GB}G"
fi
run_cmd qm set "$VM_ID" --boot order=scsi0
# Also add a cloud-init drive
run_cmd qm set "$VM_ID" --ide2 "$STORAGE:cloudinit"

# Step 4: Configure cloud-init
echo "Step 4: Configuring cloud-init..."
# Set the CI user (default is ubuntu) and SSH key
if [[ -n "$VM_SSH_PUB_KEY_PATH" && -f "$VM_SSH_PUB_KEY_PATH" ]]; then
    run_cmd qm set "$VM_ID" --ciuser ubuntu --sshkey "$VM_SSH_PUB_KEY_PATH"
else
    echo "Warning: SSH key file not found at $VM_SSH_PUB_KEY_PATH. Skipping SSH key setup."
fi

# Step 5: Configure network: DHCP or static
echo "Step 5: Configuring network..."
if [[ -z "$IP_ADDRESS" ]]; then
    echo "Configuring network for DHCP..."
    run_cmd qm set "$VM_ID" --ipconfig0 ip=dhcp
else
    echo "Configuring network for static IP: $IP_ADDRESS"
    # If gateway and DNS are provided, use them
    if [[ -n "$GATEWAY" && -n "$DNS_SERVERS" ]]; then
        run_cmd qm set "$VM_ID" --ipconfig0 ip=$IP_ADDRESS,gw=$GATEWAY,dns=$DNS_SERVERS
    else
        run_cmd qm set "$VM_ID" --ipconfig0 ip=$IP_ADDRESS
        echo "Warning: GATEWAY or DNS_SERVERS not set. You may need to configure them manually."
    fi
fi

# Step 6: Enable QEMU guest agent for better host-guest communication
echo "Step 6: Enabling QEMU guest agent..."
run_cmd qm set "$VM_ID" --agent enabled=1

# Step 7: Configure Cloud-Init vendor data
echo "Step 7: Configuring Cloud-Init to install QEMU Guest Agent..."

CI_SNIPPET_STORAGE="${CI_SNIPPET_STORAGE:-local}"
CI_VENDOR_FILE="qemu-guest-agent.yaml"

run_cmd qm set "$VM_ID" \
    --cicustom "vendor=${CI_SNIPPET_STORAGE}:snippets/${CI_VENDOR_FILE}"

# Step 8: Start the VM
echo "Step 8: Starting the VM..."
run_cmd qm start "$VM_ID"

# Step 9: Wait for SSH and get IP (if DHCP)

# echo "Step 9: Waiting for VM to get an IP and SSH to be ready..."
# if [[ "$DRY_RUN" == false ]]; then
#     # In real mode, we would wait for the VM to get an IP and then wait for SSH port 22
#     echo "Waiting for agent to report IP (this may take a moment)..."
#     # If static IP is set, we can use it directly
#     if [[ -n "$IP_ADDRESS" ]]; then
#         # Extract IP without netmask
#         VM_IP=$(echo "$IP_ADDRESS" | cut -d'/' -f1)
#         echo "Using static IP: $VM_IP"
#     else
#         # Wait for DHCP: get MAC from net0 config, then poll ARP table
#         echo "Waiting for VM to get an IP via DHCP..."
#         # Get MAC address from VM config
#         VM_MAC=$(qm config "$VM_ID" | grep "net0:" | sed -E 's/.*virtio=([^,]+).*/\1/')
#         if [[ -z "$VM_MAC" ]]; then
#             echo "Error: Could not determine MAC address for net0."
#             exit 1
#         fi
#         echo "VM MAC address: $VM_MAC"
#         # Poll ARP/neighbor table for up to 30 seconds
#         for i in {1..30}; do
#             # Try ip neigh show first (works on newer systems)
#             VM_IP=$(ip neigh show | grep -i "$VM_MAC" | awk '{print $1}' | head -1)
#             if [[ -n "$VM_IP" ]]; then
#                 echo "VM IP address: $VM_IP (from ip neigh)"
#                 break
#             fi
#             # Fallback to arp -n if ip neigh not available
#             VM_IP=$(arp -n | grep -i "$VM_MAC" | awk '{print $1}' | head -1)
#             if [[ -n "$VM_IP" ]]; then
#                 echo "VM IP address: $VM_IP (from arp)"
#                 break
#             fi
#             sleep 1
#         done
#         if [[ -z "$VM_IP" ]]; then
#             echo "Warning: Could not determine VM IP via ARP/neigh after waiting."
#             echo "You may need to check the VM console or manually assign IP."
#         fi
#     fi
# else
#     echo "[DRY-RUN] Would wait for VM to get IP and SSH to be ready."
# fi

echo "Step 9: Waiting for VM network information and SSH to be ready..."

if [[ "$DRY_RUN" == false ]]; then
    VM_IP=""
    VM_MAC=""

    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to parse QEMU Guest Agent output."
        exit 1
    fi

    # Retrieve network information through QEMU Guest Agent.
    echo "Waiting for QEMU Guest Agent to report network information..."

    for i in {1..60}; do
        if GUEST_INFO=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null); then

            # Extract the first non-loopback interface with an IPv4 address.
            NETWORK_INFO=$(echo "$GUEST_INFO" | jq -r '
                [
                    .[]
                    | select(."name" != "lo")
                    | select(."hardware-address"? != null)
                    | select(
                        any(."ip-addresses"[]?;
                            ."ip-address-type" == "ipv4"
                            and (."ip-address" | startswith("127.") | not)
                            and (."ip-address" | startswith("169.254.") | not)
                        )
                    )
                ]
                | .[0] // empty
                | [
                    ."hardware-address",
                    (."ip-addresses"[]
                        | select(."ip-address-type" == "ipv4")
                        | ."ip-address"
                        | select(startswith("127.") | not)
                        | select(startswith("169.254.") | not)
                    )
                ]
                | .[0:2][]
            ' 2>/dev/null)

            if [[ -n "$NETWORK_INFO" ]]; then
                VM_MAC=$(echo "$NETWORK_INFO" | sed -n '1p')
                VM_IP=$(echo "$NETWORK_INFO" | sed -n '2p')

                if [[ -n "$VM_IP" && -n "$VM_MAC" ]]; then
                    echo "VM IPv4 address: $VM_IP"
                    echo "VM MAC address:  $VM_MAC"
                    break
                fi
            fi
        fi

        sleep 1
    done

    if [[ -z "$VM_IP" || -z "$VM_MAC" ]]; then
        echo "Error: Could not retrieve VM IPv4 address and MAC address."
        echo "Check QEMU Guest Agent, Cloud-Init, and DHCP configuration."
        exit 1
    fi

    # Wait for SSH to become reachable.
    echo "Waiting for SSH on $VM_IP:22..."

    SSH_READY=false

    for i in {1..60}; do
        if timeout 2 bash -c 'echo > /dev/tcp/$1/22' _ "$VM_IP" 2>/dev/null; then
            SSH_READY=true
            echo "SSH is reachable at $VM_IP:22"
            break
        fi

        sleep 1
    done

    if [[ "$SSH_READY" != true ]]; then
        echo "Error: SSH did not become reachable at $VM_IP:22 after 60 seconds."
        exit 1
    fi

else
    echo "[DRY-RUN] Would retrieve the VM IPv4 and MAC addresses and wait for SSH."
fi

# If we have an IP, wait for SSH to become available
if [[ -n "$VM_IP" && "$DRY_RUN" == false ]]; then
    echo "Waiting for SSH to become available on $VM_IP..."
    for i in {1..30}; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$VM_IP" true 2>/dev/null; then
            echo "SSH is ready!"
            break
        fi
        sleep 2
    done
elif [[ "$DRY_RUN" == false ]]; then
    echo "Warning: No IP address determined; skipping SSH wait."
fi

# Step 9: Optional health check
if [[ "$HEALTH_CHECK_ENABLED" == "true" ]]; then
    echo "Step 9: Running health check..."
    if [[ "$DRY_RUN" == false && -n "$VM_IP" ]]; then
        ./health-check.sh --host "$VM_IP"
    else
        echo "[DRY-RUN] Would run health-check.sh --host <VM_IP>"
    fi
else
    echo "Step 9: Skipping health check (HEALTH_CHECK_ENABLED is not true)."
fi

echo ""
echo "=== Provisioning complete ==="
if [[ "$DRY_RUN" == true ]]; then
    echo "This was a dry-run. To actually create the VM, run:"
    echo "  $0 --execute $CONFIG_FILE"
else
    echo "VM $VM_ID ($VM_NAME) has been created and started."
    echo "You can check its status with: qm status $VM_ID"
    echo "To stop the VM: qm stop $VM_ID"
fi