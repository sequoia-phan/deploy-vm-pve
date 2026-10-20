# Troubleshooting DHCP Issues on Proxmox VE VMs

## Overview
Two VMs (ID 131 and 133) on a Proxmox VE host were unable to obtain an IPv4 address via DHCP, even though the host’s bridge (`vmbr0`) received a lease successfully. The VMs were sending DHCP Discover packets, but no replies were arriving.

This document outlines the systematic troubleshooting steps performed, the root cause identified, the fix applied, and how to prevent similar issues in the future.

---

## Environment
- **Host:** Proxmox VE (PVE) server, hostname `nhatpx`
- **Bridge:** `vmbr0` (connected to physical NIC `enp0s31f6`)
- **DHCP Server:** External router on the same broadcast domain (192.168.1.0/24)
- **VMs:**
  - VM 131 – MAC `bc:24:11:e7:8c:bb`
  - VM 133 – MAC `bc:24:11:89:40:d6`
- **Guest Agent:** QEMU GA enabled (`agent: enabled=1`) in both VM configs.

---

## Symptoms
- `qm guest exec <vmid> ip a show eth0` showed only link-local IPv6 (`fe80::/64`) and no IPv4 address.
- `tcpdump` on the VM’s tap device (`tap131i0`, `tap133i0`) displayed repeated DHCP Discover messages but **no** DHCP Offer/ACK.
- `tcpdump` on the physical NIC (`enp0s31f6`) also showed **no** DHCP server replies.
- The host’s own `vmbr0` interface obtained a DHCP lease normally, confirming the DHCP server was reachable and functional.

---

## Diagnostic Steps

### 1. Verify VM Configuration
```bash
sudo qm config 131
sudo qm config 133
```
Both configs contained:
```
net0: virtio=BC:24:11:E7:8C:BB,bridge=vmbr0   # for VM 131
net0: virtio=BC:24:11:89:40:D6,bridge=vmbr0   # for VM 133
ipconfig0: ip=dhcp
```
No obvious misconfiguration.

### 2. Check That DHCP Requests Leave the VM
```bash
sudo timeout 10 tcpdump -i tap131i0 -e -vvv -s 1500 port 67 or port 68
```
Output (excerpt):
```
08:48:32.846663 bc:24:11:e7:8c:bb > Broadcast ... BOOTP/DHCP, Request from bc:24:11:e7:8c:bb
```
Similar output observed for VM 133 after it started sending requests.
*Conclusion:* VMs are generating DHCP Discover packets correctly.

### 3. See If Requests Reach the Physical NIC
```bash
sudo timeout 10 tcpdump -i enp0s31f6 -e -vvv -s 1500 port 67 or port 68
```
Result: **Zero packets captured.**
*Conclusion:* Something between the tap device and the physical NIC is dropping the packets.

### 4. Inspect Bridge State
```bash
bridge link show
```
Output:
```
2: enp0s31f6: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master vmbr0 state forwarding priority 32 cost 5
43: tap133i0: <BROADCAST,MULTICAST,PROMISC,UP,LOWER_UP> mtu 1500 master vmbr0 state forwarding priority 32 cost 2
44: tap131i0: <BROADCAST,MULTICAST,PROMISC,UP,LOWER_UP> mtu 1500 master vmbr0 state forwarding priority 32 cost 2
```
All ports are in `forwarding` state – the bridge should forward frames.

### 5. Examine iptables and ebtables Rules
```bash
sudo iptables -L -v -n
sudo ebtables -L
```
- **iptables:** FORWARD chain policy `DROP`; only Docker‑related chains present. No explicit DHCP rules.
- **ebtables:** Empty, policies `ACCEPT`.
*Conclusion:* No obvious drop rules, but the FORWARD chain’s default `DROP` is suspicious.

### 6. Determine if Bridge Frames Are Being Passed to iptables
```bash
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
```
Output:
```
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 0
```
*Interpretation:* With `bridge-nf-call-iptables = 1`, every bridged frame (including DHCP replies) is sent through the `iptables FORWARD` chain before being delivered to the destination tap. Since the FORWARD chain’s default policy is `DROP`, the DHCP reply packets were being dropped despite no explicit match.

### 7. Verify That the Host’s Own DHCP Works
The host’s `vmbr0` interface got a lease because its traffic originates **locally** (not forwarded), thus it bypasses the FORWARD chain. This explained why only the host worked while the VMs did not.

---

## Root Cause
The Linux bridge configuration was forwarding bridged frames to iptables (`net.bridge.bridge-nf-call-iptables = 1`). The Docker‑installed iptables rules set the FORWARD chain policy to `DROP`. DHCP reply packets from the router, arriving on the physical NIC and forwarded to the VM’s tap device, traversed the bridge, hit the FORWARD chain, and were dropped because no rule matched them.

---

## Fix Applied
Disable the bridge’s netfilter call to iptables for bridged IPv4 traffic:

```bash
# Immediately disable (affects existing bridges)
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0

# Make the setting persistent across reboots
sudo bash -c 'echo "net.bridge.bridge-nf-call-iptables = 0" > /etc/sysctl.d/99-bridge-no-iptables.conf'
```

### Verification After Fix
```bash
# Check that the setting is now 0
sysctl net.bridge.bridge-nf-call-iptables
# Expected: net.bridge.bridge-nf-call-iptables = 0

# Test DHCP on VM 131
sudo qm guest exec 131 ip a show eth0
```
Output (excerpt):
```
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether bc:24:11:e7:8c:bb brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.40/24 metric 100 brd 192.168.1.255 scope global dynamic eth0
       valid_lft 10784sec preferred_lft 10784sec
    inet6 2402:800:637d:e40:be24:11ff:fee7:8cbb/64 scope global dynamic mngtmpaddr noprefixroute
       valid_lft 86110sec preferred_lft 86110sec
    inet6 fe80::be24:11ff:fee7:8cbb/64 scope link
       valid_lft forever preferred_lft forever
```
VM 131 now has an IPv4 address (`192.168.1.40/24`).

For VM 133, after ensuring the QEMU guest agent was running inside the guest (see below), the same command yielded an IPv4 lease as well.

---

## Additional Notes for VM 133
VM 133 initially showed no DHCP requests because its QEMU guest agent was not running (`QEMU guest agent is not running`). This prevented `qm guest exec` from working and may have delayed cloud‑init network configuration.

**Steps to ensure guest agent availability:**
1. Inside the VM (via console or SSH if you can get in):
   ```bash
   sudo apt update && sudo apt install -y qemu-guest-agent
   sudo systemctl enable --now qemu-guest-agent
   ```
2. Verify:
   ```bash
   systemctl status qemu-guest-agent
   ```
3. After the agent is active, `qm guest exec 133 ...` will succeed, allowing you to run the same DHCP verification steps.

---

## Preventive Measures & Recommendations
| Action | Reason |
|--------|--------|
| **Keep `net.bridge.bridge-nf-call-iptables=0`** unless you explicitly need iptables filtering on bridged traffic. Most Proxmox hosts do not require this; disabling avoids accidental drops. |
| **Document iptables changes** – when Docker or other software modifies the FORWARD chain policy, review the impact on bridged VM traffic. |
| **Use bridge‑specific firewall rules** (via `ebtables` or `iptables` with `-m physdev --physdev-is-bridged`) if you need filtering, rather than relying on the default FORWARD policy. |
| **Monitor DHCP traffic** with `tcpdump -i <tap>` and `tcpdump -i <physical>` during VM boot or network changes to catch regressions early. |
| **Ensure QEMU guest agent runs** inside each VM for reliable guest‑agent commands (`qm guest exec`, `qm guest ping`, etc.). |
| **Log sysctl changes** in `/etc/sysctl.d/` and verify persistence after reboot. |

---

## Quick Reference Commands
```bash
# 1. Check bridge netfilter setting
sysctl net.bridge.bridge-nf-call-iptables

# 2. Disable it (temporary)
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0

# 3. Make it persistent
sudo bash -c 'echo "net.bridge.bridge-nf-call-iptables = 0" > /etc/sysctl.d/99-bridge-no-iptables.conf'

# 4. Verify DHCP on a VM
sudo qm guest exec <vmid> ip a show eth0

# 5. Tap‑level tcpdump (see if requests leave VM)
sudo timeout 10 tcpdump -i tap<vmid>i0 -e -vvv -s 1500 port 67 or port 68

# 6. Physical NIC tcpdump (see if replies arrive)
sudo timeout 10 tcpdump -i enp0s31f6 -e -vvv -s 1500 port 67 or port 68
# For more, capture packet from vmbr0 specifically udp port 67 and 68 or arp for troubleshooting dhcp
sudo tcpdump -ni vmbr0 -e -vvv   '(udp port 67 or udp port 68) or arp'

# 7. Bridge state
bridge link show

# 8. iptables/ebtables
sudo iptables -L -v -n
sudo ebtables -L
```

---

## Conclusion
The DHCP failure was caused by the bridge forwarding traffic to iptables, where a default `DROP` policy (installed by Docker) silently discarded the reply packets. Disabling `net.bridge.bridge-nf-call-iptables` bypassed iptables for bridged frames, allowing DHCP replies to reach the VMs. After the change, both VMs obtained IPv4 leases successfully. Ensuring the QEMU guest agent runs inside each VM further enables reliable guest‑agent troubleshooting.

*Documented by: Hermes Agent*  
*Date: 2026-10-17*