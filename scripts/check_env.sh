#!/bin/bash
# ===========================================================
# Pre-flight environment checks
# ===========================================================
# Run BEFORE ansible-playbook to verify the hypervisor host
# and bastion are ready. Exits non-zero on any failure.
#
# Usage: bash scripts/check_env.sh
# ===========================================================

set -euo pipefail

# ---- Configuration (edit to match your environment) ----
BASTION_IP="${BASTION_IP:-192.168.122.5}"
API_VIP="${API_VIP:-192.168.122.10}"
INGRESS_VIP="${INGRESS_VIP:-192.168.122.11}"
CLUSTER_NAME="${CLUSTER_NAME:-<CLUSTER>}"
BASE_DOMAIN="${BASE_DOMAIN:-<example.com>}"
LIBVIRT_NET="${LIBVIRT_NET:-ocp-net}"

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "[PASS] $desc"
        ((PASS++))
    else
        echo "[FAIL] $desc"
        ((FAIL++))
    fi
}

echo "============================================="
echo "  OCP Pre-flight Environment Checks"
echo "============================================="
echo ""

# ---- Hypervisor checks ----
echo "--- Hypervisor ---"
check "KVM module loaded"          test -e /dev/kvm
check "libvirtd running"           systemctl is-active libvirtd
check "virsh accessible"           virsh version
check "Libvirt network '$LIBVIRT_NET' active" virsh net-info "$LIBVIRT_NET"
check "firewalld running"          systemctl is-active firewalld
check "virt-install available"     command -v virt-install
check "genisoimage available"      command -v genisoimage
check "curl available"             command -v curl
check "jq available"               command -v jq
echo ""

# ---- Bastion connectivity ----
echo "--- Bastion connectivity ---"
check "Bastion reachable (ping)"   ping -c 1 -W 2 "$BASTION_IP"
check "Bastion SSH (port 22)"      nc -z -w 3 "$BASTION_IP" 22
echo ""

# ---- DNS checks (bastion as DNS server) ----
echo "--- DNS resolution (@$BASTION_IP) ---"
check "DNS: api.${CLUSTER_NAME}.${BASE_DOMAIN}" \
    dig @"$BASTION_IP" "api.${CLUSTER_NAME}.${BASE_DOMAIN}" +short +time=3
check "DNS: *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}" \
    dig @"$BASTION_IP" "test.apps.${CLUSTER_NAME}.${BASE_DOMAIN}" +short +time=3
check "DNS: PTR for master-0 IP" \
    dig @"$BASTION_IP" -x 192.168.122.101 +short +time=3
echo ""

# ---- HAProxy port checks ----
echo "--- HAProxy ports (@$BASTION_IP) ---"
for port in 6443 22623 80 443; do
    check "HAProxy port $port" nc -z -w 3 "$BASTION_IP" "$port"
done
check "HAProxy stats (9000)" nc -z -w 3 "$BASTION_IP" 9000
echo ""

# ---- NTP check ----
echo "--- NTP ---"
check "Chrony/NTP synchronized" chronyc tracking
echo ""

# ---- Internet connectivity ----
echo "--- Internet ---"
check "Reach api.openshift.com"    curl -sf --max-time 5 https://api.openshift.com/api/assisted-install/v2/component-versions
check "Reach sso.redhat.com"       curl -sf --max-time 5 -o /dev/null https://sso.redhat.com
echo ""

# ---- Summary ----
echo "============================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================="

if [ "$FAIL" -gt 0 ]; then
    echo "WARNING: $FAIL check(s) failed. Fix issues before running Ansible."
    exit 1
else
    echo "All checks passed. Ready to deploy."
    exit 0
fi
