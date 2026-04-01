#!/bin/bash
# list-ips.sh — Display external IPs of all deployed VMs
#
# Usage:
#   bash scripts/list-ips.sh
#
# Requires:
#   GCP_PROJECT environment variable set (export GCP_PROJECT=your-project-id)
#   gcloud authenticated and configured

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-}"
VM_PREFIX="${VM_PREFIX:-pwm}"
MASTER_ZONE="us-central1-a"
CHUNK_ZONES=("us-east1-c" "us-west4-a" "us-central1-b")

[[ -z "$GCP_PROJECT" ]] && { echo "Error: Set GCP_PROJECT first"; echo "  export GCP_PROJECT=your-project-id"; exit 1; }

echo "=========================================="
echo "Distributed Password Manager - VM IPs"
echo "=========================================="
echo ""

# Fetch master IP
echo "Fetching IPs..."
MASTER_IP=$(gcloud compute instances describe "${VM_PREFIX}-master" \
  --zone="$MASTER_ZONE" --project="$GCP_PROJECT" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "N/A")

echo ""
echo "  Master:"
echo "    External IP : $MASTER_IP"
echo "    gob/TLS     : $MASTER_IP:9000"
echo "    HTTPS API   : $MASTER_IP:8443"
echo ""

# Fetch chunk IPs
for i in 1 2 3; do
  CHUNK_ZONE="${CHUNK_ZONES[$((i-1))]}"
  CHUNK_IP=$(gcloud compute instances describe "${VM_PREFIX}-chunk${i}" \
    --zone="$CHUNK_ZONE" --project="$GCP_PROJECT" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "N/A")
  
  echo "  Chunk $i:"
  echo "    External IP : $CHUNK_IP"
  echo "    Port        : 900$i"
  echo ""
done

echo "=========================================="
