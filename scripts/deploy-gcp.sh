#!/bin/bash
# Deploy the Distributed Password Manager to Google Cloud
# Usage: ./scripts/deploy-gcp.sh
set -e

PROJECT="${GCP_PROJECT:-your-gcp-project}"
ZONES=("us-central1-a" "us-east1-b" "us-west1-a" "europe-west1-b")
MACHINE="e2-micro"

echo "=== Building Linux binaries ==="
mkdir -p bin
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bin/master  ./cmd/master
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bin/chunk   ./cmd/chunkserver
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o bin/client  ./cmd/client

echo "=== Creating VMs ==="
gcloud compute instances create pwm-master \
  --zone=${ZONES[0]} --machine-type=$MACHINE \
  --image-family=debian-12 --image-project=debian-cloud \
  --tags=pwm-master --project=$PROJECT

for i in 1 2 3; do
  gcloud compute instances create pwm-chunk$i \
    --zone=${ZONES[$i]} --machine-type=$MACHINE \
    --image-family=debian-12 --image-project=debian-cloud \
    --tags=pwm-chunk --project=$PROJECT
done

echo "=== Creating firewall rules ==="
gcloud compute firewall-rules create allow-pwm-master \
  --allow=tcp:9000 --target-tags=pwm-master \
  --source-ranges=10.0.0.0/8 --project=$PROJECT 2>/dev/null || true

gcloud compute firewall-rules create allow-pwm-chunks \
  --allow=tcp:9001-9003 --target-tags=pwm-chunk \
  --source-ranges=10.0.0.0/8 --project=$PROJECT 2>/dev/null || true

echo "=== Uploading binaries and certs ==="
gcloud compute scp bin/master certs/server-cert.pem certs/server-key.pem certs/ca-cert.pem \
  pwm-master:~ --zone=${ZONES[0]} --project=$PROJECT

for i in 1 2 3; do
  gcloud compute scp bin/chunk certs/server-cert.pem certs/server-key.pem certs/ca-cert.pem \
    pwm-chunk$i:~ --zone=${ZONES[$i]} --project=$PROJECT
done

echo "=== Starting master ==="
MASTER_IP=$(gcloud compute instances describe pwm-master \
  --zone=${ZONES[0]} --project=$PROJECT \
  --format='value(networkInterfaces[0].networkIP)')

gcloud compute ssh pwm-master --zone=${ZONES[0]} --project=$PROJECT --command \
  "chmod +x master && mkdir -p data && nohup ./master -addr :9000 -primary chunk1 -wal ./data/wal.json -cert server-cert.pem -key server-key.pem -ca ca-cert.pem > master.log 2>&1 &"

echo "=== Starting chunk servers ==="
for i in 1 2 3; do
  PORT=$((9000 + i))
  gcloud compute ssh pwm-chunk$i --zone=${ZONES[$i]} --project=$PROJECT --command \
    "chmod +x chunk && mkdir -p data && nohup ./chunk -id chunk$i -addr :$PORT -master $MASTER_IP:9000 -data ./data -cert server-cert.pem -key server-key.pem -ca ca-cert.pem > chunk.log 2>&1 &"
done

echo ""
echo "=== Deployment complete ==="
echo "Master internal IP: $MASTER_IP"
echo ""
echo "To connect the client locally:"
echo "  go run ./cmd/client -master <MASTER_EXTERNAL_IP>:9000 -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"
echo ""
echo "To tear down:"
echo "  gcloud compute instances delete pwm-master pwm-chunk1 pwm-chunk2 pwm-chunk3 --quiet"
echo "  gcloud compute firewall-rules delete allow-pwm-master allow-pwm-chunks --quiet"
