#!/bin/bash
# teardown-gcp.sh — Completely removes all PWM GCP resources
# After this runs, zero ongoing cost. Nothing left.
#
# Usage:
#   export GCP_PROJECT=your-project-id
#   bash scripts/teardown-gcp.sh
# =============================================================================

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-}"
VM_PREFIX="${VM_PREFIX:-pwm}"
MASTER_ZONE="us-central1-a"
CHUNK_ZONES=("us-east1-c" "us-west4-a" "us-central1-b")

[[ -z "$GCP_PROJECT" ]] && { echo "Set GCP_PROJECT first: export GCP_PROJECT=your-project-id"; exit 1; }

echo ""
echo "WARNING: This will permanently delete all PWM VMs, disks, and firewall rules."
echo "Project: $GCP_PROJECT"
echo ""
read -r -p "Type YES to confirm: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 0; }

echo ""
echo "Deleting VMs and their boot disks..."

delete_vm() {
  local name=$1 zone=$2
  if gcloud compute instances describe "$name" --zone="$zone" --project="$GCP_PROJECT" &>/dev/null; then
    gcloud compute instances delete "$name" \
      --zone="$zone" --project="$GCP_PROJECT" \
      --delete-disks=all --quiet
    echo "  Deleted $name"
  else
    echo "  $name not found — skipping"
  fi
}

delete_vm "${VM_PREFIX}-master" "$MASTER_ZONE"
delete_vm "${VM_PREFIX}-chunk1" "${CHUNK_ZONES[0]}"
delete_vm "${VM_PREFIX}-chunk2" "${CHUNK_ZONES[1]}"
delete_vm "${VM_PREFIX}-chunk3" "${CHUNK_ZONES[2]}"

echo ""
echo "Deleting firewall rules..."

delete_fw() {
  local rule=$1
  if gcloud compute firewall-rules describe "$rule" --project="$GCP_PROJECT" &>/dev/null; then
    gcloud compute firewall-rules delete "$rule" --project="$GCP_PROJECT" --quiet
    echo "  Deleted $rule"
  else
    echo "  $rule not found — skipping"
  fi
}

delete_fw "allow-pwm-master-internal"
delete_fw "allow-pwm-master-https"
delete_fw "allow-pwm-chunks-internal"
delete_fw "allow-pwm-ssh"

echo ""
echo "Done. All PWM resources deleted. Zero ongoing cost."
echo ""
echo "To redeploy later:"
echo "  export GCP_PROJECT=$GCP_PROJECT"
echo "  bash scripts/deploy-gcp.sh"