# OCP 4.20 Compact Cluster - Assisted Installer on KVM/libvirt

Automated deployment of an OpenShift 4.20 **Compact** cluster (3 control-plane nodes, schedulable masters, no dedicated workers) using the **Assisted Installer** service via `console.redhat.com`, running on KVM/libvirt (Fedora or RHEL hypervisor).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Hypervisor Host (Fedora / RHEL)                    │
│  KVM / libvirt                                      │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│  │ master-0 │  │ master-1 │  │ master-2 │          │
│  │ .101     │  │ .102     │  │ .103     │          │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│       │              │              │                │
│  ─────┴──────────────┴──────────────┴────────────── │
│       ocp-net (192.168.122.0/24, NAT)               │
│       │                                              │
│  ┌────┴─────┐                                        │
│  │ bastion  │  DNS (dnsmasq) + DHCP + HAProxy       │
│  │ .5       │  api VIP: .10  ingress VIP: .11       │
│  └──────────┘                                        │
└─────────────────────────────────────────────────────┘
          │
          ▼  console.redhat.com (Assisted Installer API)
```

## Prerequisites

| Requirement | Details |
|---|---|
| Hypervisor OS | Fedora 39+ or RHEL 9+ |
| CPU | 16+ vCPUs (4 per master + 2 bastion + host) |
| RAM | 52+ GB (16 GB per master + 4 GB bastion) |
| Disk | 420+ GB free in `/var/lib/libvirt/images` |
| Red Hat account | [console.redhat.com](https://console.redhat.com) with pull secret |
| Offline token | [Generate at cloud.redhat.com](https://console.redhat.com/openshift/token) |
| Ansible | `ansible-core >= 2.15` |
| Internet | Hypervisor must reach `api.openshift.com` and `sso.redhat.com` |

## Quick Start

```bash
# 1. Clone and enter the project
git clone <repo-url> && cd ocp4-compact-assisted

# 2. Place your secrets (NEVER commit these)
cp /path/to/pull-secret.json /safe/path/pull-secret.json
echo "your-offline-token" > /safe/path/offline-token.txt
chmod 600 /safe/path/pull-secret.json /safe/path/offline-token.txt

# 3. Download a Fedora Cloud base image for the bastion VM
curl -L -o /var/lib/libvirt/images/fedora-cloud-base.qcow2 \
  "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"

# 4. Edit variables
vi ansible/group_vars/all.yml   # Set cluster_name, base_domain, ssh_pubkey, paths

# 5. Run pre-flight checks
bash scripts/check_env.sh

# 6. Deploy (full run)
cd ansible
ansible-playbook site.yml -i inventory/hosts.ini

# 7. Deploy a single phase
ansible-playbook site.yml -i inventory/hosts.ini --tags assisted

# 8. Dry-run (no changes)
ansible-playbook site.yml -i inventory/hosts.ini --check --diff
```

## Variables Reference

All variables are defined in `ansible/group_vars/all.yml`. Key variables requiring manual edit:

| Variable | Description | Example |
|---|---|---|
| `cluster_name` | OCP cluster name | `lab` |
| `base_domain` | DNS base domain | `openshift.local` |
| `ssh_pubkey` | SSH public key for core user | `ssh-ed25519 AAAA...` |
| `pull_secret_file` | Path to pull-secret.json | `/safe/path/pull-secret.json` |
| `offline_token_file` | Path to offline API token | `/safe/path/offline-token.txt` |
| `bastion_vm.base_image` | Path to Fedora/RHEL cloud qcow2 | `/var/lib/libvirt/images/fedora-cloud-base.qcow2` |
| `masters[].mac` | MAC addresses for master VMs | `52:54:00:aa:bb:01` |

## Playbook Phases

| # | Playbook | Tag | Description |
|---|---|---|---|
| 01 | `01_prepare_host.yml` | `prepare` | Install KVM/libvirt packages, enable services |
| 02 | `02_network.yml` | `network` | Create libvirt network and storage pool |
| 03 | `03_bastion.yml` | `bastion` | Provision bastion VM, configure DNS + DHCP |
| 04 | `04_services.yml` | `services` | Configure HAProxy load balancer |
| 05 | `05_assisted.yml` | `assisted` | Assisted Installer API workflow + master VMs |
| 06 | `06_post.yml` | `post` | Post-install verification |

## Roles

| Role | Purpose |
|---|---|
| `libvirt` | Libvirt packages, network, storage pool |
| `kvm_vms` | Create VMs (bastion via cloud-init) |
| `bastion` | Base config: packages, sysctl, firewall |
| `dns` | Dnsmasq DNS configuration |
| `dhcp` | Dnsmasq DHCP reservations |
| `haproxy` | HAProxy load balancer |
| `assisted` | Assisted Installer API interactions |
| `postinstall` | Post-installation health checks |

## Helper Scripts

| Script | Usage |
|---|---|
| `scripts/check_env.sh` | Pre-flight environment validation |
| `scripts/download_discovery_iso.sh` | Standalone ISO download |
| `scripts/cleanup.sh` | Destroy all VMs, network, and storage |

## Cleanup

```bash
# Remove everything (VMs, network, ISOs)
bash scripts/cleanup.sh

# Or selectively via Ansible tags
ansible-playbook site.yml -i inventory/hosts.ini --tags cleanup
```

## Troubleshooting

- **Hosts not registering**: Check bastion DNS resolution (`dig @192.168.122.5 api.<cluster>.<domain>`) and that the discovery ISO booted correctly (`virsh console master-0`).
- **HAProxy errors**: Verify ports with `ss -tlnp | grep -E '6443|22623|80|443'` on the bastion.
- **API token expired**: Offline tokens expire after 30 days of inactivity. Regenerate at [console.redhat.com/openshift/token](https://console.redhat.com/openshift/token).
- **Installation stuck**: Check `GET /v2/clusters/<id>` status via the Assisted Service API or the console.redhat.com UI.
