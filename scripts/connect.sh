#!/bin/bash
# connect.sh — Dynamically fetches the master external IP and connects
# Run this after starting VMs (after a stop/start cycle)
#
# Usage:
#   bash scripts/connect.sh          — just prints the current IP and URLs
#   bash scripts/connect.sh cli      — launches the CLI client
#   bash scripts/connect.sh status   — shows service status on all VMs
#   bash scripts/connect.sh logs     — tails master logs live
# =============================================================================

set -euo pipefail

GCP_PROJECT="${GCP_PROJECT:-}"
VM_PREFIX="${VM_PREFIX:-pwm}"
MASTER_ZONE="us-central1-a"
CHUNK_ZONES=("us-east1-c" "us-west4-a" "us-central1-b")
MASTER_PORT="${MASTER_PORT:-9000}"
HTTP_PORT="${HTTP_PORT:-8443}"

[[ -z "$GCP_PROJECT" ]] && { echo "Set GCP_PROJECT first: export GCP_PROJECT=your-project-id"; exit 1; }

echo "Fetching current master IP..."
MASTER_EXTERNAL=$(gcloud compute instances describe "${VM_PREFIX}-master" \
  --zone="$MASTER_ZONE" --project="$GCP_PROJECT" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

echo ""
echo "  Master external IP : $MASTER_EXTERNAL"
echo "  Web UI             : https://${MASTER_EXTERNAL}:${HTTP_PORT}"
echo "  CLI master addr    : ${MASTER_EXTERNAL}:${MASTER_PORT}"
echo ""

MODE="${1:-info}"

case "$MODE" in
  cli)
    echo "Launching CLI client..."
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    "$REPO_ROOT/bin/linux/client" \
      -master "${MASTER_EXTERNAL}:${MASTER_PORT}" \
      -cert "$REPO_ROOT/certs/client-cert.pem" \
      -key  "$REPO_ROOT/certs/client-key.pem" \
      -ca   "$REPO_ROOT/certs/ca-cert.pem"
    ;;

  status)
    echo "--- Master ---"
    gcloud compute ssh "${VM_PREFIX}-master" --zone="$MASTER_ZONE" \
      --project="$GCP_PROJECT" --quiet \
      --command="sudo systemctl is-active pwm-master && sudo journalctl -u pwm-master -n 5 --no-pager"

    for i in 1 2 3; do
      echo "--- Chunk $i ---"
      gcloud compute ssh "${VM_PREFIX}-chunk${i}" --zone="${CHUNK_ZONES[$((i-1))]}" \
        --project="$GCP_PROJECT" --quiet \
        --command="sudo systemctl is-active pwm-chunk && sudo journalctl -u pwm-chunk -n 5 --no-pager"
    done
    ;;

  logs)
    echo "Tailing master logs (Ctrl+C to stop)..."
    gcloud compute ssh "${VM_PREFIX}-master" --zone="$MASTER_ZONE" \
      --project="$GCP_PROJECT" --quiet \
      --command="sudo journalctl -u pwm-master -f"
    ;;

  info)
    echo "Run with: cli | status | logs"
    ;;
esac