#!/bin/bash
# ===========================================================
# Standalone Discovery ISO downloader
# ===========================================================
# Downloads the Discovery ISO from the Assisted Installer API
# without running the full Ansible playbook.
#
# Usage:
#   export OFFLINE_TOKEN_FILE="/safe/path/offline-token.txt"
#   export INFRA_ENV_ID="<infra-env-uuid>"
#   bash scripts/download_discovery_iso.sh
#
# Or pass as arguments:
#   bash scripts/download_discovery_iso.sh <offline_token_file> <infra_env_id> [output_dir]
# ===========================================================

set -euo pipefail

# ---- Configuration ----
OFFLINE_TOKEN_FILE="${1:-${OFFLINE_TOKEN_FILE:-/safe/path/offline-token.txt}}"
INFRA_ENV_ID="${2:-${INFRA_ENV_ID:-<INFRA_ENV_ID>}}"
OUTPUT_DIR="${3:-/var/lib/libvirt/images}"
API_BASE="https://api.openshift.com/api/assisted-install/v2"
SSO_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"

echo "============================================="
echo "  Discovery ISO Downloader"
echo "============================================="

# ---- Validate inputs ----
if [ ! -f "$OFFLINE_TOKEN_FILE" ]; then
    echo "ERROR: Offline token file not found: $OFFLINE_TOKEN_FILE"
    exit 1
fi

if [ "$INFRA_ENV_ID" = "<INFRA_ENV_ID>" ]; then
    echo "ERROR: INFRA_ENV_ID not set. Get it from console.redhat.com or the API."
    exit 1
fi

# ---- Authenticate ----
echo "Authenticating with Red Hat SSO..."
OFFLINE_TOKEN=$(cat "$OFFLINE_TOKEN_FILE" | tr -d '[:space:]')

ACCESS_TOKEN=$(curl -sf "$SSO_URL" \
    -d "grant_type=refresh_token" \
    -d "client_id=cloud-services" \
    -d "refresh_token=${OFFLINE_TOKEN}" \
    | jq -r '.access_token')

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "ERROR: Failed to obtain access token. Check your offline token."
    exit 1
fi
echo "Authentication successful."

# ---- Get ISO download URL ----
echo "Fetching ISO download URL..."
ISO_URL=$(curl -sf "${API_BASE}/infra-envs/${INFRA_ENV_ID}/downloads/image-url" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    | jq -r '.url')

if [ -z "$ISO_URL" ] || [ "$ISO_URL" = "null" ]; then
    echo "ERROR: Failed to get ISO URL. Check INFRA_ENV_ID."
    exit 1
fi

# ---- Download ISO ----
OUTPUT_PATH="${OUTPUT_DIR}/discovery-image.iso"
echo "Downloading Discovery ISO to: ${OUTPUT_PATH}"
curl -L -o "${OUTPUT_PATH}" "${ISO_URL}"

# ---- Verify ----
if [ -f "$OUTPUT_PATH" ]; then
    SIZE=$(du -sh "$OUTPUT_PATH" | cut -f1)
    echo "Download complete: ${OUTPUT_PATH} (${SIZE})"
else
    echo "ERROR: Download failed."
    exit 1
fi

echo "============================================="
echo "  ISO ready. Boot your VMs from this image."
echo "============================================="
