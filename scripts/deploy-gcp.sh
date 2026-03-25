#!/bin/bash
# Deploy the Distributed Password Manager to Google Cloud.
# Usage:
#   GCP_PROJECT=<project-id> ./scripts/deploy-gcp.sh

set -euo pipefail

PROJECT="${GCP_PROJECT:-}"
if [[ -z "$PROJECT" ]]; then
  echo "error: set GCP_PROJECT before running this script"
  echo "example: GCP_PROJECT=my-project ./scripts/deploy-gcp.sh"
  exit 1
fi

MACHINE="e2-micro"
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"

MASTER1_NAME="pwm-master1"
MASTER2_NAME="pwm-master2"
CHUNK_NAMES=("pwm-chunk1" "pwm-chunk2" "pwm-chunk3")

MASTER1_ZONE="us-central1-a"
MASTER2_ZONE="us-east1-b"
CHUNK_ZONES=("us-west1-a" "europe-west1-b" "us-central1-f")

echo "=== Building Linux binaries ==="
mkdir -p bin
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bin/master ./cmd/master
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bin/chunk ./cmd/chunkserver
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bin/client ./cmd/client

echo "=== Creating VMs ==="
gcloud compute instances create "$MASTER1_NAME" \
  --zone="$MASTER1_ZONE" --machine-type="$MACHINE" \
  --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
  --tags=pwm-master --project="$PROJECT" || true

gcloud compute instances create "$MASTER2_NAME" \
  --zone="$MASTER2_ZONE" --machine-type="$MACHINE" \
  --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
  --tags=pwm-master --project="$PROJECT" || true

for i in 0 1 2; do
  gcloud compute instances create "${CHUNK_NAMES[$i]}" \
    --zone="${CHUNK_ZONES[$i]}" --machine-type="$MACHINE" \
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
    --tags=pwm-chunk --project="$PROJECT" || true
done

echo "=== Creating firewall rules ==="
# Internal east-west traffic between cluster nodes.
gcloud compute firewall-rules create allow-pwm-internal-master \
  --allow=tcp:9000,tcp:9100,tcp:8443,tcp:9443 --target-tags=pwm-master \
  --source-ranges=10.0.0.0/8 --project="$PROJECT" 2>/dev/null || true

gcloud compute firewall-rules create allow-pwm-internal-chunks \
  --allow=tcp:9001-9003 --target-tags=pwm-chunk \
  --source-ranges=10.0.0.0/8 --project="$PROJECT" 2>/dev/null || true

# Optional external access for client/UI demos.
gcloud compute firewall-rules create allow-pwm-external-master \
  --allow=tcp:9000,tcp:9100,tcp:8443,tcp:9443 --target-tags=pwm-master \
  --source-ranges=0.0.0.0/0 --project="$PROJECT" 2>/dev/null || true

echo "=== Resolving internal and external IPs ==="
MASTER1_INT_IP=$(gcloud compute instances describe "$MASTER1_NAME" \
  --zone="$MASTER1_ZONE" --project="$PROJECT" \
  --format='value(networkInterfaces[0].networkIP)')
MASTER2_INT_IP=$(gcloud compute instances describe "$MASTER2_NAME" \
  --zone="$MASTER2_ZONE" --project="$PROJECT" \
  --format='value(networkInterfaces[0].networkIP)')

MASTER1_EXT_IP=$(gcloud compute instances describe "$MASTER1_NAME" \
  --zone="$MASTER1_ZONE" --project="$PROJECT" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
MASTER2_EXT_IP=$(gcloud compute instances describe "$MASTER2_NAME" \
  --zone="$MASTER2_ZONE" --project="$PROJECT" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

echo "=== Uploading binaries and certs ==="
gcloud compute scp bin/master certs/server-cert.pem certs/server-key.pem certs/ca-cert.pem \
  "$MASTER1_NAME":~ --zone="$MASTER1_ZONE" --project="$PROJECT"
gcloud compute scp bin/master certs/server-cert.pem certs/server-key.pem certs/ca-cert.pem \
  "$MASTER2_NAME":~ --zone="$MASTER2_ZONE" --project="$PROJECT"

for i in 0 1 2; do
  gcloud compute scp bin/chunk certs/server-cert.pem certs/server-key.pem certs/ca-cert.pem \
    "${CHUNK_NAMES[$i]}":~ --zone="${CHUNK_ZONES[$i]}" --project="$PROJECT"
done

echo "=== Starting masters ==="
gcloud compute ssh "$MASTER1_NAME" --zone="$MASTER1_ZONE" --project="$PROJECT" --command \
  "chmod +x master && mkdir -p data/master && nohup ./master -addr :9000 -primary chunk1 -epoch 100 -wal ./data/master/wal.json -users ./data/users.json -http :8443 -cert server-cert.pem -key server-key.pem -ca ca-cert.pem > master.log 2>&1 &"

gcloud compute ssh "$MASTER2_NAME" --zone="$MASTER2_ZONE" --project="$PROJECT" --command \
  "chmod +x master && mkdir -p data/master && nohup ./master -addr :9100 -primary chunk1 -epoch 200 -wal ./data/master/wal.json -users ./data/users.json -http :9443 -cert server-cert.pem -key server-key.pem -ca ca-cert.pem > master.log 2>&1 &"

echo "=== Starting chunk servers (failover aware) ==="
for i in 0 1 2; do
  chunk_id=$((i + 1))
  port=$((9001 + i))
  gcloud compute ssh "${CHUNK_NAMES[$i]}" --zone="${CHUNK_ZONES[$i]}" --project="$PROJECT" --command \
    "chmod +x chunk && mkdir -p data/chunk${chunk_id} && nohup ./chunk -id chunk${chunk_id} -addr :${port} -master ${MASTER1_INT_IP}:9000 -masters ${MASTER1_INT_IP}:9000,${MASTER2_INT_IP}:9100 -data ./data/chunk${chunk_id} -cert server-cert.pem -key server-key.pem -ca ca-cert.pem > chunk.log 2>&1 &"
done

echo ""
echo "=== Deployment complete ==="
echo "Master1 internal/external: ${MASTER1_INT_IP} / ${MASTER1_EXT_IP}"
echo "Master2 internal/external: ${MASTER2_INT_IP} / ${MASTER2_EXT_IP}"
echo ""
echo "Client command (local machine):"
echo "  go run ./cmd/client -master ${MASTER1_EXT_IP}:9000 -masters ${MASTER1_EXT_IP}:9000,${MASTER2_EXT_IP}:9100 -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"
echo ""
echo "Health probes (if firewall allows external):"
echo "  curl -k https://${MASTER1_EXT_IP}:8443/health"
echo "  curl -k https://${MASTER2_EXT_IP}:9443/health"
echo ""
echo "Teardown:"
echo "  gcloud compute instances delete ${MASTER1_NAME} ${MASTER2_NAME} ${CHUNK_NAMES[*]} --quiet --project=${PROJECT}"
echo "  gcloud compute firewall-rules delete allow-pwm-internal-master allow-pwm-internal-chunks allow-pwm-external-master --quiet --project=${PROJECT}"
echo ""
echo "Note: this script deploys endpoint failover topology, but does not provide shared storage between masters."
