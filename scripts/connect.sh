#!/bin/bash
# connect.sh — Dynamically fetches the master external IP and connects
# Run this after starting VMs (after a stop/start cycle)
#
# Usage:
#   bash scripts/connect.sh             — just prints the current IP and URLs
#   bash scripts/connect.sh cli         — launches the CLI client
#   bash scripts/connect.sh status      — shows service status on all VMs
#   bash scripts/connect.sh logs        — tails master logs live
#   bash scripts/connect.sh logs1       — tails chunk1 logs live
#   bash scripts/connect.sh logs2       — tails chunk2 logs live
#   bash scripts/connect.sh logs3       — tails chunk3 logs live
# =============================================================================

set -euo pipefail

# Detect OS to use correct client binary
detect_os() {
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin" ]]; then
    echo "windows"
  else
    echo "linux"
  fi
}

OS=$(detect_os)

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
echo "  CLI client (copy-paste ready):"

CLIENT_BIN="./bin/linux/client"
if [[ "$OS" == "windows" ]]; then
  CLIENT_BIN="./bin/windows/client.exe"
fi
echo "    $CLIENT_BIN -master ${MASTER_EXTERNAL}:${MASTER_PORT} -cert ./certs/client-cert.pem -key ./certs/client-key.pem -ca ./certs/ca-cert.pem"
echo ""

MODE="${1:-info}"

case "$MODE" in
  cli)
    echo "Launching CLI client..."
    CLIENT_BIN="./bin/linux/client"
    if [[ "$OS" == "windows" ]]; then
      CLIENT_BIN="./bin/windows/client.exe"
    fi
    "$CLIENT_BIN" \
      -master "${MASTER_EXTERNAL}:${MASTER_PORT}" \
      -cert "./certs/client-cert.pem" \
      -key  "./certs/client-key.pem" \
      -ca   "./certs/ca-cert.pem"
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

  logs1)
    echo "Tailing chunk1 logs (Ctrl+C to stop)..."
    gcloud compute ssh "${VM_PREFIX}-chunk1" --zone="${CHUNK_ZONES[0]}" \
      --project="$GCP_PROJECT" --quiet \
      --command="sudo journalctl -u pwm-chunk -f"
    ;;

  logs2)
    echo "Tailing chunk2 logs (Ctrl+C to stop)..."
    gcloud compute ssh "${VM_PREFIX}-chunk2" --zone="${CHUNK_ZONES[1]}" \
      --project="$GCP_PROJECT" --quiet \
      --command="sudo journalctl -u pwm-chunk -f"
    ;;

  logs3)
    echo "Tailing chunk3 logs (Ctrl+C to stop)..."
    gcloud compute ssh "${VM_PREFIX}-chunk3" --zone="${CHUNK_ZONES[2]}" \
      --project="$GCP_PROJECT" --quiet \
      --command="sudo journalctl -u pwm-chunk -f"
    ;;

  info)
    echo "Run with: cli | status | logs | logs1 | logs2 | logs3"
    ;;
esac
