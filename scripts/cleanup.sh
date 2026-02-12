#!/bin/bash
# ===========================================================
# Cleanup script - destroy all OCP lab resources
# ===========================================================
# Removes VMs, libvirt network, storage, and ISO files.
# USE WITH CAUTION - this is destructive and irreversible.
#
# Usage: bash scripts/cleanup.sh
# ===========================================================

set -uo pipefail

# ---- Configuration (edit to match your environment) ----
CLUSTER_NAME="${CLUSTER_NAME:-<CLUSTER>}"
LIBVIRT_NET="${LIBVIRT_NET:-ocp-net}"
LIBVIRT_POOL="${LIBVIRT_POOL:-ocp-pool}"
ISO_DIR="${ISO_DIR:-/var/lib/libvirt/images}"
OUTPUT_DIR="${OUTPUT_DIR:-$(dirname "$0")/../output}"
BASTION_NAME="${BASTION_NAME:-bastion}"
MASTER_NAMES="${MASTER_NAMES:-master-0 master-1 master-2}"

echo "============================================="
echo "  OCP Lab Cleanup"
echo "============================================="
echo ""
echo "This will DESTROY the following resources:"
echo "  VMs:      ${BASTION_NAME} ${MASTER_NAMES}"
echo "  Network:  ${LIBVIRT_NET}"
echo "  Pool:     ${LIBVIRT_POOL}"
echo "  ISOs in:  ${ISO_DIR}"
echo ""
read -p "Are you sure? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ---- Destroy VMs ----
echo "--- Destroying VMs ---"
for VM in ${BASTION_NAME} ${MASTER_NAMES}; do
    if virsh dominfo "$VM" > /dev/null 2>&1; then
        echo "Destroying VM: $VM"
        virsh destroy "$VM" 2>/dev/null || true
        virsh undefine "$VM" --remove-all-storage 2>/dev/null || \
        virsh undefine "$VM" 2>/dev/null || true
        echo "  Removed: $VM"
    else
        echo "  Not found: $VM (skipping)"
    fi
done

# ---- Remove disk images ----
echo ""
echo "--- Removing disk images ---"
for VM in ${BASTION_NAME} ${MASTER_NAMES}; do
    DISK="${ISO_DIR}/${VM}.qcow2"
    if [ -f "$DISK" ]; then
        rm -f "$DISK"
        echo "  Removed: $DISK"
    fi
done

# ---- Remove ISOs ----
echo ""
echo "--- Removing ISO files ---"
for ISO in "${ISO_DIR}/discovery-image.iso" "${ISO_DIR}/${BASTION_NAME}-cidata.iso"; do
    if [ -f "$ISO" ]; then
        rm -f "$ISO"
        echo "  Removed: $ISO"
    fi
done

# ---- Destroy libvirt network ----
echo ""
echo "--- Removing libvirt network ---"
if virsh net-info "$LIBVIRT_NET" > /dev/null 2>&1; then
    virsh net-destroy "$LIBVIRT_NET" 2>/dev/null || true
    virsh net-undefine "$LIBVIRT_NET" 2>/dev/null || true
    echo "  Removed: $LIBVIRT_NET"
else
    echo "  Not found: $LIBVIRT_NET (skipping)"
fi

# ---- Remove output directory ----
echo ""
echo "--- Removing output files ---"
if [ -d "$OUTPUT_DIR" ]; then
    rm -rf "$OUTPUT_DIR"
    echo "  Removed: $OUTPUT_DIR"
fi

echo ""
echo "============================================="
echo "  Cleanup complete"
echo "============================================="
