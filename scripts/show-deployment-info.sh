#!/bin/bash
# list-ips.sh — Display deployment info for all deployed VMs
#
# Usage:
#   bash scripts/list-ips.sh
#
# Displays:
#   - External IPs and connection endpoints
#   - SSH login commands
#   - Kill commands for each service
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
echo "Distributed Password Manager - Deployment Info"
echo "=========================================="
echo ""

# Fetch master IP
echo "Fetching deployment information..."
MASTER_IP=$(gcloud compute instances describe "${VM_PREFIX}-master" \
  --zone="$MASTER_ZONE" --project="$GCP_PROJECT" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "N/A")

echo ""
echo "==================== MASTER ===================="
echo ""
echo "  Endpoints:"
echo "    gob/TLS Protocol : $MASTER_IP:9000"
echo "    HTTPS REST API   : https://$MASTER_IP:8443"
echo ""
echo "  SSH Login:"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT"
echo ""
echo "  Kill master service:"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl stop pwm-master'"
echo ""
echo "  Start master service:"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl start pwm-master'"
echo ""
echo "  Restart master service:"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl restart pwm-master'"
echo ""
echo "  View logs:"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo journalctl -u pwm-master --no-pager'"
echo ""
echo "  Stream logs (real-time):"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo journalctl -u pwm-master -f'"
echo ""

# Fetch chunk IPs
for i in 1 2 3; do
  CHUNK_ZONE="${CHUNK_ZONES[$((i-1))]}"
  CHUNK_IP=$(gcloud compute instances describe "${VM_PREFIX}-chunk${i}" \
    --zone="$CHUNK_ZONE" --project="$GCP_PROJECT" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "N/A")
  
  IS_PRIMARY=""
  if [[ $i -eq 1 ]]; then
    IS_PRIMARY=" (PRIMARY)"
  fi
  
  echo "==================== CHUNK $i$IS_PRIMARY ===================="
  echo ""
  echo "  Endpoints:"
  echo "    gRPC/TLS Protocol : $CHUNK_IP:900$i"
  echo ""
  echo "  SSH Login:"
  echo "    gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT"
  echo ""
  echo "  Kill chunk$i service:"
  echo "    gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl stop pwm-chunk'"
  echo ""
  echo "  Start chunk$i service:"
  echo "    gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl start pwm-chunk'"
  echo ""
  echo "  Restart chunk$i service:"
  echo "    gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl restart pwm-chunk'"
  echo ""
  echo "  View logs:"
  echo "    gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo journalctl -u pwm-chunk --no-pager'"
  echo ""
  echo "  Stream logs (real-time):"
  echo "    gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo journalctl -u pwm-chunk -f'"
  echo ""
done

echo "==================== QUICK COMMANDS ===================="
echo ""
echo "Kill all services at once:"
echo "  gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl stop pwm-master' && \\"
for i in 1 2 3; do
  CHUNK_ZONE="${CHUNK_ZONES[$((i-1))]}"
  if [[ $i -lt 3 ]]; then
    echo "  gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl stop pwm-chunk' && \\"
  else
    echo "  gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl stop pwm-chunk'"
  fi
done
echo ""

echo "Start all services at once:"
echo "  gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl start pwm-master' && \\"
for i in 1 2 3; do
  CHUNK_ZONE="${CHUNK_ZONES[$((i-1))]}"
  if [[ $i -lt 3 ]]; then
    echo "  gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl start pwm-chunk' && \\"
  else
    echo "  gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl start pwm-chunk'"
  fi
done
echo ""

echo "Restart all services at once:"
echo "  gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl restart pwm-master' && \\"
for i in 1 2 3; do
  CHUNK_ZONE="${CHUNK_ZONES[$((i-1))]}"
  if [[ $i -lt 3 ]]; then
    echo "  gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl restart pwm-chunk' && \\"
  else
    echo "  gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo systemctl restart pwm-chunk'"
  fi
done
echo ""

echo "View logs from all services:"
echo "  Master:  gcloud compute ssh ${VM_PREFIX}-master --zone=$MASTER_ZONE --project=$GCP_PROJECT --quiet --command='sudo journalctl -u pwm-master --no-pager'"
for i in 1 2 3; do
  CHUNK_ZONE="${CHUNK_ZONES[$((i-1))]}"
  echo "  Chunk$i:  gcloud compute ssh ${VM_PREFIX}-chunk${i} --zone=$CHUNK_ZONE --project=$GCP_PROJECT --quiet --command='sudo journalctl -u pwm-chunk --no-pager'"
done
echo ""

echo "Stream logs (real-time) - use logs, logs1, logs2, logs3:"
echo "  bash scripts/connect.sh logs    # Master"
echo "  bash scripts/connect.sh logs1   # Chunk1"
echo "  bash scripts/connect.sh logs2   # Chunk2"
echo "  bash scripts/connect.sh logs3   # Chunk3"
echo ""

echo "========================================"
