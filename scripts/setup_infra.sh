#!/bin/bash
# ===========================================================
# Initial infrastructure setup - run with sudo
# ===========================================================
# This script must be run as root/sudo on the hypervisor.
# It:
#   1. Installs missing packages (libguestfs-tools)
#   2. Starts libvirtd
#   3. Creates ocp-net libvirt network
#   4. Creates storage pool
#   5. Copies RHEL 9.7 qcow2 and injects static IP + SSH key
#   6. Defines and boots the bastion VM
#
# Usage: sudo bash scripts/setup_infra.sh
# ===========================================================

set -euo pipefail

# ---- Configuration ----
RHEL_SOURCE="${RHEL_SOURCE:-/home/user/VirtualMachines/rhel9.7.qcow2}"
BASTION_DISK="/var/lib/libvirt/images/bastion.qcow2"
NET_NAME="ocp-net"
BRIDGE_NAME="virbr-ocp"
BASTION_IP="192.168.122.5"
GATEWAY_IP="192.168.122.1"
SSH_PUBKEY="${SSH_PUBKEY:-$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo '<YOUR_SSH_PUBKEY>')}"

echo "============================================="
echo "  OCP Lab - Initial Infrastructure Setup"
echo "============================================="

# ---- Step 1: Install missing packages ----
echo ""
echo "[1/6] Installing missing packages..."
dnf install -y libguestfs-tools libguestfs 2>/dev/null || true

# ---- Step 2: Start libvirtd ----
echo ""
echo "[2/6] Starting libvirtd..."
systemctl enable --now libvirtd
systemctl is-active libvirtd && echo "  libvirtd is active" || { echo "FAIL: libvirtd not running"; exit 1; }

# ---- Step 3: Create ocp-net ----
echo ""
echo "[3/6] Creating libvirt network '${NET_NAME}'..."
if virsh net-info "${NET_NAME}" &>/dev/null; then
    echo "  Network '${NET_NAME}' already exists, skipping"
else
    cat > /tmp/ocp-net.xml <<NETEOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <ip address='${GATEWAY_IP}' netmask='255.255.255.0'>
    <!-- Temporary DHCP just for bastion initial boot -->
    <dhcp>
      <range start='192.168.122.5' end='192.168.122.5'/>
    </dhcp>
  </ip>
</network>
NETEOF
    virsh net-define /tmp/ocp-net.xml
    virsh net-start "${NET_NAME}"
    virsh net-autostart "${NET_NAME}"
    rm -f /tmp/ocp-net.xml
    echo "  Network '${NET_NAME}' created and active"
fi

# ---- Step 4: Create storage pool ----
echo ""
echo "[4/6] Creating storage pool..."
if virsh pool-info ocp-pool &>/dev/null; then
    echo "  Pool 'ocp-pool' already exists, skipping"
else
    virsh pool-define-as ocp-pool dir - - - - /var/lib/libvirt/images
    virsh pool-build ocp-pool 2>/dev/null || true
    virsh pool-start ocp-pool
    virsh pool-autostart ocp-pool
    echo "  Pool 'ocp-pool' created"
fi

# ---- Step 5: Prepare bastion disk ----
echo ""
echo "[5/6] Preparing bastion disk..."
if [ -f "${BASTION_DISK}" ]; then
    echo "  Bastion disk already exists at ${BASTION_DISK}, skipping copy"
else
    if [ ! -f "${RHEL_SOURCE}" ]; then
        echo "FAIL: Source image not found: ${RHEL_SOURCE}"
        exit 1
    fi
    echo "  Copying RHEL 9.7 image (this may take a while)..."
    cp "${RHEL_SOURCE}" "${BASTION_DISK}"
    echo "  Copy complete"
fi

# Inject SSH key and network config using virt-customize
echo "  Injecting SSH key and network configuration..."
if command -v virt-customize &>/dev/null; then
    virt-customize -a "${BASTION_DISK}" \
        --ssh-inject root:string:"${SSH_PUBKEY}" \
        --write /etc/NetworkManager/system-connections/ocp-static.nmconnection:"[connection]
id=ocp-static
type=ethernet
autoconnect=true
autoconnect-priority=100

[ipv4]
method=manual
address1=${BASTION_IP}/24,${GATEWAY_IP}
dns=8.8.8.8;8.8.4.4;

[ipv6]
method=disabled
" \
        --run-command 'chmod 600 /etc/NetworkManager/system-connections/ocp-static.nmconnection' \
        --run-command 'hostnamectl set-hostname bastion.ocp.local.lab' \
        --selinux-relabel
    echo "  SSH key and network config injected"
else
    echo "  WARNING: virt-customize not available. You will need to configure"
    echo "  the bastion network manually after first boot via virsh console."
fi

# ---- Step 6: Define and boot bastion VM ----
echo ""
echo "[6/6] Defining and starting bastion VM..."
if virsh dominfo bastion &>/dev/null; then
    echo "  VM 'bastion' already defined"
    # Make sure it's running
    virsh start bastion 2>/dev/null || echo "  VM already running or cannot start"
else
    virt-install \
        --name bastion \
        --cpu host-passthrough \
        --vcpus 2 \
        --memory 4096 \
        --disk "path=${BASTION_DISK},format=qcow2,bus=virtio" \
        --network "network=${NET_NAME},model=virtio" \
        --os-variant rhel9-unknown \
        --graphics none \
        --noautoconsole \
        --import
    echo "  VM 'bastion' created and starting"
fi

# ---- Wait for bastion to boot ----
echo ""
echo "Waiting for bastion VM to boot (up to 120s)..."
for i in $(seq 1 24); do
    if ping -c 1 -W 2 "${BASTION_IP}" &>/dev/null; then
        echo "  Bastion is reachable at ${BASTION_IP}"
        break
    fi
    if [ "$i" -eq 24 ]; then
        echo "  WARNING: Bastion not reachable after 120s."
        echo "  Try 'virsh console bastion' to check its status."
        echo "  You may need to configure the network manually."
    fi
    sleep 5
done

# ---- Verify SSH ----
echo ""
echo "Testing SSH connectivity..."
if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${BASTION_IP} 'hostname' 2>/dev/null; then
    echo "  SSH to bastion: OK"
else
    echo "  WARNING: SSH not yet available. Give it a moment or check virsh console."
fi

echo ""
echo "============================================="
echo "  Infrastructure setup complete"
echo "============================================="
echo "  Network:  ${NET_NAME} (active)"
echo "  Bastion:  ${BASTION_IP}"
echo "  Next:     cd $(dirname "$0")/../ansible"
echo "            ansible-playbook 03_bastion.yml -i inventory/hosts.ini --tags bastion_config"
echo "============================================="
