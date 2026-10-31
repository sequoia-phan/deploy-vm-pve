# VM Provisioner for Proxmox VE

This repository contains scripts to automate the provisioning of virtual machines in Proxmox VE (PVE) using cloud-init images. The main entry point is `deploy-vm.sh`, which creates a VM, imports a cloud-init image, configures networking, cloud-init user/SSH key, enables the QEMU Guest Agent, starts the VM, waits for SSH, and optionally runs a health check.

## Table of Contents
- [Overview](#overview)
- [Usage](#usage)
- [Required Variables](#required-variables)
- [Optional Variables](#optional-variables)
- [Dry‑Run vs Execute](#dry-run-vs-execute)
- [Example Config Files](#example-config-files)
- [QEMU Guest Agent Snippet](#qemu-guest-agent-snippet)
- [Notes](#notes)

## Overview

The provisioning process follows these steps:

1. **Check VM ID** – ensure the requested ID is free.
2. **Create VM** – set memory, cores, name, network (virtio bridge vmbr0), SCSI controller.
3. **Import Cloud‑Init Image** – import the specified image (`IMAGE_PATH`) into the configured storage.
4. **Attach Disk** – attach the imported disk as SCSI‑0 and resize it to `DISK_GB`.
5. **Set Boot Order** – boot from the SCSI disk.
6. **Add Cloud‑Init Drive** – attach an IDE cloud‑init drive.
7. **Configure Cloud‑Init** – set the default user (`CI_USER`, defaults to `ubuntu`) and inject the SSH public key.
8. **Network Configuration** – DHCP or static IP (with optional gateway/DNS).
9. **Enable QEMU Guest Agent** – via `qm set --agent enabled=1`.
10. **Vendor Data** – apply a cloud-init snippet to install and start the QEMU Guest Agent inside the VM.
11. **Start VM** – boot the machine.
12. **Wait for Network & SSH** – poll the QEMU Guest Agent for IP/MAC, then wait for SSH port 22.
13. **Optional Health Check** – run `health-check.sh --host <VM_IP>` if `HEALTH_CHECK_ENABLED=true`.

All steps respect a `--dry-run` mode that only prints the `qm` commands without executing them.

## Usage

```bash
# Dry‑run (default, safe)
./deploy-vm.sh [--dry-run] <config-file>

# Actual execution
./deploy-vm.sh --execute <config-file>
```

`<config-file>` is a plain text file with `KEY=VALUE` lines (see examples/dhcp.env or examples/static.env). Lines beginning with `#` are ignored.

## Required Variables

These **must** be defined in the config file or exported in the environment before running the script:

| Variable | Description |
|----------|-------------|
| `PVE_HOST` | (Informational only) The Proxmox host hostname or IP. The script prints this value but does **not** use it for SSH unless you modify the script to wrap `qm` commands. |
| `VM_NAME` | Desired name for the VM. |
| `VM_ID` | Unique numeric ID for the VM in the PVE cluster. |
| `CPU_CORES` | Number of CPU cores to allocate. |
| `RAM_MB` | Amount of RAM in megabytes. |
| `DISK_GB` | Size of the VM's primary disk in gigabytes. |
| `IMAGE_PATH` | **Full path** to a cloud‑init image (e.g., `/home/nhatpx/vm-provisioner/img/ubuntu-22.04-server-cloudimg-amd64.img`). **No default is provided**; you must set this explicitly. |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STORAGE` | `local` | Storage name where the imported disk and cloud‑init drive will be placed. |
| `CI_USER` | `ubuntu` | The cloud‑init user that will be created inside the VM. Can be overridden (e.g., `CI_USER=admin`). |
| `VM_SSH_PUB_KEY_PATH` | *(empty)* | Path to an SSH public key file that will be injected for the cloud‑init user. If set and the file exists, the key is applied; otherwise a warning is printed. |
| `CI_SNIPPET_STORAGE` | `local` | Storage where the cloud‑init snippet directory resides (used with `CI_VENDOR_FILE`). |
| `CI_VENDOR_FILE` | `qemu-guest-agent.yaml` | Name of the cloud‑init snippet file that installs the QEMU Guest Agent. |
| `IP_ADDRESS` | *(empty)* | If set, configures a static IP (netmask defaults to /24 unless you provide CIDR in the value). If empty, DHCP is used. |
| `GATEWAY` | *(empty)* | Gateway for static IP configuration. |
| `DNS_SERVERS` | *(empty)* | Comma‑separated list of DNS servers for static IP configuration. |
| `HEALTH_CHECK_ENABLED` | `false` | If `true`, runs `./health-check.sh --host <VM_IP>` after the VM is reachable via SSH. |

## Dry‑Run vs Execute

- **Dry‑run** (`--dry-run` or no flag) only echoes the `qm` commands that would be run. No changes are made to the PVE cluster.
- **Execute** (`--execute`) runs the actual `qm` commands, creating and starting the VM.

The script defaults to dry‑run for safety. Always verify the output of a dry‑run before switching to execute.

## Example Config Files

See the `examples/` directory:

- `dhcp.env` – obtains IP via DHCP.
- `static.env` – demonstrates static IP with gateway and DNS.

Copy one of these, adjust the values to your environment, and reference it when invoking the script.

### Minimal Example (`myvm.env`)

```bash
VM_ID=101
VM_NAME="my-test-vm"
CPU_CORES=2
RAM_MB=4096
DISK_GB=30
IMAGE_PATH=/home/nhatpx/vm-provisioner/img/ubuntu-22.04-server-cloudimg-amd64.img
# Optional:
CI_USER=ubuntu
VM_SSH_PUB_KEY_PATH=/home/nhatpx/.ssh/id_rsa.pub
IP_ADDRESS=192.168.1.150/24
GATEWAY=192.168.1.1
DNS_SERVERS=1.1.1.1,8.8.8.8
HEALTH_CHECK_ENABLED=true
```

Run:

```bash
./deploy-vm.sh --execute myvm.env
```

## QEMU Guest Agent Snippet

The script installs and starts the QEMU Guest Agent inside the VM via a cloud‑init snippet. This snippet is **not** part of this repository; it is expected to exist on the Proxmox host at:

```
/var/lib/vz/snippets/qemu-guest-agent.yaml
```

Contents of that file:

```yaml
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
```

The provisioner references it using the variables `CI_SNIPPET_STORAGE` (defaults to `local`) and `CI_VENDOR_FILE` (defaults to `qemu-guest-agent.yaml`), forming the selector `local:snippets/qemu-guest-agent.yaml` when calling `qm set --cicustom`.

If you wish to customize the snippet (e.g., add additional packages or configuration), you can either:

1. Override the default by placing a file with the same name in a custom storage snippets directory and setting `CI_SNIPPET_STORAGE` accordingly, **or**
2. Edit `/var/lib/vz/snippets/qemu-guest-agent.yaml` directly (be aware that Proxmox updates may overwrite it).

## Notes

- The script assumes the Linux bridge `vmbr0` exists and is used for the VM’s network adapter (`net0`). Adjust the `qm set … --net0` line in the script if your environment uses a different bridge.
- All `qm` commands are executed **locally** on the host where you run the script. To target a remote PVE host you would need to modify the script to prefix each `qm` call with `ssh "$PVE_HOST"` (or use `pvecexec`). The variable `PVE_HOST` is currently only printed for informational purposes.
- Ensure the user running the script has sufficient privileges to execute `qm` commands (typically root or a user with `sudo` access to `/usr/bin/qm`).
- The health‑check script (`health-check.sh`) is expected in the same directory as `deploy-vm.sh`. It performs SSH, binary, service, log, and resource checks after provisioning.
- Temporary files or logs are not created by the provisioner itself; any output from `qm` is streamed to the terminal (or suppressed in dry‑run).

--- 
*Happy provisioning!*