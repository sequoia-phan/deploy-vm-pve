### This codebase of VM provisioning

Current folder structure:
```
.
├── READ_BEFORE_REASONING.md
└── img/
    └── ubuntu-20.04-server-cloudimg-amd64.img
```

/home/nhatpx/
```
├── IO-project/
│   └── high-throughput-io/       ← Your main Go/Rust application project
└── vm-provisioner/               ← Provisioning & ops toolkit
    ├── deploy-vm.sh              ← VM creation/provisioning 
    ├── build.sh                  ← ← NEW: Inside-VM rebuild script
    ├── vmctl.sh                  ← ← NEW: CLI tool for VM lifecycle
    ├── logrotate.conf            ← ← NEW: Log rotation config
    └── health-check.sh           ← ← NEW: Run from laptop to verify health
    ├── examples/
    │   ├── dhcp.env
    │   └── static.env
    └── README.md
```

##### Current Implementation Status ✅

We have built a foundational VM provisioning and operations toolkit that:
- Provisions VMs in PVE with configurable CPU/RAM/SSD/IP settings
- Includes lifecycle management (logs, rebuild, health checks, SSH)
- Supports log rotation and health monitoring
- Provides both DHCP and static IP deployment options

##### Objective Goal (**ignore this part**)

- Building a high throughput IO and monitoring system using Prometheus+Grafana and scaling project in K8S cluster, deploy K8S cluster in server we called on-premise. There is no cloud platform here. In case we still need multiple VMs in PVE cluster, there is also another PC PVE bare-metal/Hyper-V... with more resources
- **Immediate next step**: Extend VM provisioning to optionally deploy K8s (k3s/microk8s) and observability stack (Prometheus+Grafana)
- **Long-term vision**: Orchestrate multiple VMs into a K8s cluster for horizontal scaling of the logging system

##### Context:

```
- A PVE laptop bare-metal server 4C 8T CPU + 16GB RAM + 256GB NVMe Gen 3 SSD
- Running in a Internal network the server starting with 192.168.1.27
- PVE server can create/deploy another server and presently we're starting another VM from .25 .26 .27 IP
```

##### Requirement:

- We want to build a tool/automation script that can be able to deploy/provision VM in PVE server. This tool can decide CPU/RAM/SSD and internet masking before provide final VM production ready.
- This will be a Shell script tool or even you can choose Makefile wrapper for better experience of user.

##### Architecture Overview

```text
Provisioning Workflow:
1. deploy-vm.sh → Creates VM in PVE
2. VM boots cloud-init → Installs dependencies
4. build.sh → Compiles Application components and dependencies inside VM (We can build by using Ansible and building CI/CD for application)
5. vmctl.sh → Manages VM lifecycle (logs, health, rebuild)
6. health-check.sh → Verifies VM health from laptop

Future Extensions:
- K8s bootstrap step after VM creation
- Prometheus Operator + Grafana deployment via Helm
- ServiceMesh for traffic management
- Auto-scaling based on metrics
```

##### Next Steps 🚀

1. **Enhance deploy-vm.sh**:
   - Add flags for K8s installation (k3s recommended for low-resource VMs)
   - Add Prometheus+Grafana deployment options
   - Support for custom values.yaml for Helm charts
   - Multi-VM coordination for K8s cluster formation

2. **Create cluster orchestration**:
   - New script: `provision-cluster.sh` for multi-VM K8s setup
   - Inventory management of provisioned VMs
   - K8s node joining automation

3. **Observability integration**:
   - Deploy Prometheus Operator to scrape metrics from high-throughput-io
   - Configure Grafana dashboards for logging throughput, latency, error rates
   - Set up alerting for system health

4. **GitOps integration**:
   - ArgoCD or Flux for continuous deployment
   - Repository structure for environment-specific configs

##### Usage Examples

```bash
# Provision a VM with DHCP
./deploy-vm.sh --config examples/dhcp.env

# Provision a VM with static IP
./deploy-vm.sh --config examples/static.env

# Rebuild project inside VM
./vmctl.sh rebuild --host 192.168.1.26

# Check VM health from laptop
./health-check.sh --host 192.168.1.26

# Follow logs in real-time
./vmctl.sh logs --host 192.168.1.26 --follow

# Get VM status
./vmctl.sh status --host 192.168.1.26

# SSH into VM
./vmctl.sh ssh --host 192.168.1.26
```

##### Extension Points

1. **Resource Optimization**:
   - Add dynamic resource allocation based on workload profiles
   - Support for GPU passthrough for accelerated processing
   - NUMA-aware VM placement

2. **Networking Enhancements**:
   - VLAN tagging support
   - Multiple network interfaces
   - Load balancer integration (HAProxy/nginx)

3. **Security Improvements**:
   - Automated certificate rotation (cert-manager)
   - Vault integration for secret management
   - CIS benchmark hardening scripts

4. **Monitoring Depth**:
   - Custom Prometheus metrics for application-level insights
   - Distributed tracing (Jaeger/Tempo)
   - Log aggregation (Loki/EFK stack)



sequenceDiagram
    participant S as Provisioning Script
    participant P as Proxmox
    participant C as Cloud-Init
    participant G as Guest Agent

    S->>P: Create VM and attach cloud image
    S->>P: Configure Cloud-Init and Agent device
    S->>P: Start VM
    P->>C: Provide Cloud-Init configuration
    C->>C: Configure Ubuntu on first boot
    C->>C: Install and start Guest Agent
    G->>P: Establish agent communication
    loop Until IP available or timeout
        S->>P: Query guest-agent network interfaces
        P-->>S: Agent status and network information
    end
    S->>S: Record VM IP and continue provisioning
