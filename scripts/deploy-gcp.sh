#!/bin/bash
# =============================================================================
# deploy-gcp.sh — Full GCP deployment for Distributed Password Manager
# CMPT 756
#
# What this script does:
#   1. Builds all Go binaries (master, chunk, client) for Linux/amd64
#   2. Builds the React frontend (web/dist)
#   3. Generates TLS certificates (or reuses existing ones)
#   4. Creates 4 GCE VMs:  1 master + 3 chunk servers in different zones
#   5. Creates firewall rules for internal + external access
#   6. Uploads binaries, certs, and web dist to each VM
#   7. Starts all services with systemd units (so they survive reboots)
#   8. Prints connection info at the end
#
# Usage:
#   export GCP_PROJECT=your-project-id
#   bash deploy-gcp.sh
#
# Optional overrides (set before running):
#   GCP_PROJECT   — GCP project ID (required)
#   REGION        — default us-central1
#   MACHINE_TYPE  — default e2-small  (e2-micro is fine for demo)
#   VM_PREFIX     — default pwm  (VMs: pwm-master, pwm-chunk1 ...)
#   MASTER_PORT   — default 9000
#   HTTP_PORT     — default 8443  (HTTPS web UI)
# =============================================================================

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
GCP_PROJECT="${GCP_PROJECT:-}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
VM_PREFIX="${VM_PREFIX:-pwm}"
MASTER_PORT="${MASTER_PORT:-9000}"
HTTP_PORT="${HTTP_PORT:-8443}"

# Zones — each chunk in a different zone to demonstrate geo-redundancy
MASTER_ZONE="us-central1-a"
CHUNK_ZONES=("us-east1-c" "us-west4-a" "us-central1-b")

CERT_DIR="./certs"
BIN_DIR="./bin/linux"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────
red()   { echo -e "\033[0;31m$*\033[0m"; }
green() { echo -e "\033[0;32m$*\033[0m"; }
blue()  { echo -e "\033[0;34m$*\033[0m"; }
info()  { blue "==> $*"; }
ok()    { green "    ✓ $*"; }
err()   { red "    ✗ $*"; exit 1; }

# ── pre-flight checks ─────────────────────────────────────────────────────────
info "Pre-flight checks"

[[ -z "$GCP_PROJECT" ]] && err "GCP_PROJECT is not set. Run: export GCP_PROJECT=your-project-id"

command -v gcloud >/dev/null 2>&1 || err "gcloud CLI not found. Install from https://cloud.google.com/sdk"
command -v go     >/dev/null 2>&1 || err "go not found. Install from https://go.dev"
command -v openssl >/dev/null 2>&1 || err "openssl not found."
command -v node   >/dev/null 2>&1 || { red "    ! node not found — frontend build will be skipped"; NODE_SKIP=1; }
command -v npm    >/dev/null 2>&1 || { red "    ! npm not found — frontend build will be skipped"; NODE_SKIP=1; }

gcloud config set project "$GCP_PROJECT" 2>/dev/null
ok "GCP project: $GCP_PROJECT"

# ── step 1 — build Linux binaries ────────────────────────────────────────────
info "Building Go binaries (linux/amd64)"
cd "$REPO_ROOT"

mkdir -p "$BIN_DIR"

GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$BIN_DIR/master"  ./cmd/master
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$BIN_DIR/chunk"   ./cmd/chunkserver
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$BIN_DIR/client"  ./cmd/client
ok "master, chunk, client built"

# ── step 2 — build React frontend ────────────────────────────────────────────
if [[ "${NODE_SKIP:-0}" != "1" ]]; then
  info "Building React frontend"
  cd "$REPO_ROOT/web"
  npm install --silent
  npm run build
  ok "web/dist ready"
  cd "$REPO_ROOT"
else
  info "Skipping frontend build (node/npm not available)"
fi

# ── step 3 — TLS certificates ────────────────────────────────────────────────
info "TLS certificates"
mkdir -p "$CERT_DIR"

if [[ -f "$CERT_DIR/ca-cert.pem" && -f "$CERT_DIR/server-cert.pem" && -f "$CERT_DIR/client-cert.pem" ]]; then
  ok "Certs already exist in $CERT_DIR — reusing"
else
  info "Generating new self-signed certificates"

  # CA
  openssl genrsa -out "$CERT_DIR/ca-key.pem" 4096 2>/dev/null
  openssl req -new -x509 -days 365 -key "$CERT_DIR/ca-key.pem" \
    -out "$CERT_DIR/ca-cert.pem" -subj "//CN=DistPWM-CA" 2>/dev/null

  # We need the master external IP in the SAN — we'll patch the cert after VM creation.
  # For now generate without it; see step 7 for the re-issue.
  cat > /tmp/san.cnf <<'SAN'
[req]
distinguished_name = req_dn
[req_dn]
[v3_ext]
subjectAltName=DNS:localhost,DNS:master,DNS:chunk1,DNS:chunk2,DNS:chunk3,IP:127.0.0.1
SAN

  # Server cert (master + chunks)
  openssl genrsa -out "$CERT_DIR/server-key.pem" 2048 2>/dev/null
  openssl req -new -key "$CERT_DIR/server-key.pem" \
    -out "$CERT_DIR/server.csr" -subj "//CN=localhost" 2>/dev/null
  openssl x509 -req -days 365 -in "$CERT_DIR/server.csr" \
    -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" \
    -CAcreateserial -out "$CERT_DIR/server-cert.pem" \
    -extfile /tmp/san.cnf -extensions v3_ext 2>/dev/null

  # Client cert
  openssl genrsa -out "$CERT_DIR/client-key.pem" 2048 2>/dev/null
  openssl req -new -key "$CERT_DIR/client-key.pem" \
    -out "$CERT_DIR/client.csr" -subj "//CN=client" 2>/dev/null
  openssl x509 -req -days 365 -in "$CERT_DIR/client.csr" \
    -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" \
    -CAcreateserial -out "$CERT_DIR/client-cert.pem" 2>/dev/null

  rm -f "$CERT_DIR"/*.csr "$CERT_DIR"/*.srl /tmp/san.cnf
  ok "Certificates generated in $CERT_DIR"
fi

# ── step 4 — create VMs ───────────────────────────────────────────────────────
info "Creating GCE virtual machines"

create_vm_if_missing() {
  local name=$1 zone=$2 tags=$3
  if gcloud compute instances describe "$name" --zone="$zone" --project="$GCP_PROJECT" &>/dev/null; then
    ok "$name already exists — skipping creation"
  else
    gcloud compute instances create "$name" \
      --zone="$zone" \
      --machine-type="$MACHINE_TYPE" \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --boot-disk-size=10GB \
      --tags="$tags" \
      --project="$GCP_PROJECT" \
      --quiet
    ok "Created $name in $zone"
  fi
}

create_vm_if_missing "${VM_PREFIX}-master" "$MASTER_ZONE"        "pwm-master,pwm-node"
create_vm_if_missing "${VM_PREFIX}-chunk1" "${CHUNK_ZONES[0]}"   "pwm-chunk,pwm-node"
create_vm_if_missing "${VM_PREFIX}-chunk2" "${CHUNK_ZONES[1]}"   "pwm-chunk,pwm-node"
create_vm_if_missing "${VM_PREFIX}-chunk3" "${CHUNK_ZONES[2]}"   "pwm-chunk,pwm-node"

# ── step 5 — firewall rules ───────────────────────────────────────────────────
info "Firewall rules"

create_fw_if_missing() {
  local rule=$1; shift
  if gcloud compute firewall-rules describe "$rule" --project="$GCP_PROJECT" &>/dev/null; then
    ok "$rule already exists"
  else
    gcloud compute firewall-rules create "$rule" "$@" --project="$GCP_PROJECT" --quiet
    ok "Created $rule"
  fi
}

# Master: gob/TLS port (internal only) + HTTPS web UI (public)
create_fw_if_missing "allow-pwm-master-internal" \
  --allow=tcp:${MASTER_PORT} \
  --target-tags=pwm-master \
  --source-tags=pwm-node \
  --description="Master gob port — internal VM-to-VM only"

create_fw_if_missing "allow-pwm-master-https" \
  --allow=tcp:${HTTP_PORT} \
  --target-tags=pwm-master \
  --source-ranges=0.0.0.0/0 \
  --description="Master HTTPS web UI — public"

# Chunk servers: internal only
create_fw_if_missing "allow-pwm-chunks-internal" \
  --allow=tcp:9001-9003 \
  --target-tags=pwm-chunk \
  --source-tags=pwm-node \
  --description="Chunk server ports — internal VM-to-VM only"

# SSH (should already exist as default-allow-ssh, just in case)
create_fw_if_missing "allow-pwm-ssh" \
  --allow=tcp:22 \
  --target-tags=pwm-node \
  --source-ranges=0.0.0.0/0 \
  --description="SSH access to all PWM nodes"

# ── step 6 — get IPs ─────────────────────────────────────────────────────────
info "Fetching VM IP addresses"

get_internal_ip() {
  gcloud compute instances describe "$1" --zone="$2" --project="$GCP_PROJECT" \
    --format='value(networkInterfaces[0].networkIP)'
}
get_external_ip() {
  gcloud compute instances describe "$1" --zone="$2" --project="$GCP_PROJECT" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)'
}

MASTER_INTERNAL=$(get_internal_ip "${VM_PREFIX}-master" "$MASTER_ZONE")
MASTER_EXTERNAL=$(get_external_ip "${VM_PREFIX}-master" "$MASTER_ZONE")
CHUNK1_INTERNAL=$(get_internal_ip "${VM_PREFIX}-chunk1" "${CHUNK_ZONES[0]}")
CHUNK2_INTERNAL=$(get_internal_ip "${VM_PREFIX}-chunk2" "${CHUNK_ZONES[1]}")
CHUNK3_INTERNAL=$(get_internal_ip "${VM_PREFIX}-chunk3" "${CHUNK_ZONES[2]}")

ok "Master:  internal=$MASTER_INTERNAL  external=$MASTER_EXTERNAL"
ok "Chunk1:  internal=$CHUNK1_INTERNAL"
ok "Chunk2:  internal=$CHUNK2_INTERNAL"
ok "Chunk3:  internal=$CHUNK3_INTERNAL"

# ── step 7 — re-issue server cert with master external IP in SAN ──────────────
info "Re-issuing server cert with master external IP ($MASTER_EXTERNAL) in SAN"

cat > /tmp/san2.cnf <<SAN
[req]
distinguished_name = req_dn
[req_dn]
[v3_ext]
subjectAltName=DNS:localhost,DNS:master,DNS:chunk1,DNS:chunk2,DNS:chunk3,IP:127.0.0.1,IP:${MASTER_INTERNAL},IP:${MASTER_EXTERNAL},IP:${CHUNK1_INTERNAL},IP:${CHUNK2_INTERNAL},IP:${CHUNK3_INTERNAL}
SAN

openssl req -new -key "$CERT_DIR/server-key.pem" \
  -out "$CERT_DIR/server.csr" -subj "//CN=localhost"
openssl x509 -req -days 365 -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" \
  -CAcreateserial -out "$CERT_DIR/server-cert.pem" \
  -extfile /tmp/san2.cnf -extensions v3_ext
rm -f "$CERT_DIR/server.csr" "$CERT_DIR"/*.srl /tmp/san2.cnf
ok "Server cert re-issued with all IPs in SAN"

# ── step 8 — helper: run SSH command on a VM ─────────────────────────────────
# ssh_cmd() {
#   local vm=$1 zone=$2; shift 2
#   gcloud compute ssh "$vm" --zone="$zone" --project="$GCP_PROJECT" \
#     --command="$*" --quiet 2>/dev/null
# }

ssh_cmd() {
  local vm=$1 zone=$2; shift 2
  gcloud compute ssh "$vm" --zone="$zone" --project="$GCP_PROJECT" \
    --command="$*"
}

# ── step 9 — upload files ─────────────────────────────────────────────────────
# info "Uploading binaries and certificates to all VMs"

# upload_files() {
#   local vm=$1 zone=$2; shift 2
#   # $@ = list of local files
#   gcloud compute scp "$@" "${vm}:~/" \
#     --zone="$zone" --project="$GCP_PROJECT" --quiet 2>/dev/null
# }

info "Uploading binaries and certificates to all VMs"

upload_files() {
  local vm=$1 zone=$2; shift 2
  # $@ = list of local files
  gcloud compute scp "$@" "${vm}:" \
    --zone="$zone" --project="$GCP_PROJECT"
}

# Prepare list of cert files
CERT_FILES=(
  "$CERT_DIR/ca-cert.pem"
  "$CERT_DIR/server-cert.pem"
  "$CERT_DIR/server-key.pem"
  "$CERT_DIR/client-cert.pem"
  "$CERT_DIR/client-key.pem"
)

# Master: binary + certs + web dist
info "  Uploading to master..."
upload_files "${VM_PREFIX}-master" "$MASTER_ZONE" \
  "$BIN_DIR/master" "$BIN_DIR/client" "${CERT_FILES[@]}"

# Upload web/dist as a tar to avoid the scp directory limitation
if [[ -d "$REPO_ROOT/web/dist" ]]; then
  tar -czf /tmp/web-dist.tar.gz -C "$REPO_ROOT/web" dist
  gcloud compute scp /tmp/web-dist.tar.gz "${VM_PREFIX}-master:" \
    --zone="$MASTER_ZONE" --project="$GCP_PROJECT" --quiet 2>/dev/null
  ssh_cmd "${VM_PREFIX}-master" "$MASTER_ZONE" \
    "tar -xzf ~/web-dist.tar.gz -C ~/ && rm web-dist.tar.gz"
  ok "web/dist uploaded"
fi

# Chunks: binary + certs
for i in 1 2 3; do
  vm="${VM_PREFIX}-chunk${i}"
  zone="${CHUNK_ZONES[$((i-1))]}"
  info "  Uploading to chunk${i}..."
  upload_files "$vm" "$zone" "$BIN_DIR/chunk" "${CERT_FILES[@]}"
done
ok "All files uploaded"

# ── step 10 — install and start services ─────────────────────────────────────
info "Installing systemd services on all VMs"

# ---- master ----
ssh_cmd "${VM_PREFIX}-master" "$MASTER_ZONE" "
  set -e
  chmod +x ~/master ~/client
  mkdir -p ~/data/master

  cat > /tmp/pwm-master.service <<'UNIT'
[Unit]
Description=PWM Master Node
After=network.target

[Service]
User=$(whoami)
WorkingDirectory=/home/$(whoami)
ExecStart=/home/$(whoami)/master \
  -addr :${MASTER_PORT} \
  -http :${HTTP_PORT} \
  -primary chunk1 \
  -wal /home/$(whoami)/data/master/wal.json \
  -cert /home/$(whoami)/server-cert.pem \
  -key  /home/$(whoami)/server-key.pem \
  -ca   /home/$(whoami)/ca-cert.pem \
  -users /home/$(whoami)/data/users.json \
  -static /home/$(whoami)/dist
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  sudo cp /tmp/pwm-master.service /etc/systemd/system/pwm-master.service
  sudo systemctl daemon-reload
  sudo systemctl enable pwm-master
  sudo systemctl restart pwm-master
  echo 'master service started'
"

# ---- chunk servers ----
for i in 1 2 3; do
  vm="${VM_PREFIX}-chunk${i}"
  zone="${CHUNK_ZONES[$((i-1))]}"
  port=$((9000 + i))

# Grab the correct internal IP address for the specific chunk
  if [ "$i" -eq 1 ]; then chunk_ip="${CHUNK1_INTERNAL}"; fi
  if [ "$i" -eq 2 ]; then chunk_ip="${CHUNK2_INTERNAL}"; fi
  if [ "$i" -eq 3 ]; then chunk_ip="${CHUNK3_INTERNAL}"; fi

  ssh_cmd "$vm" "$zone" "
    set -e
    chmod +x ~/chunk
    mkdir -p ~/data/chunk${i}

    cat > /tmp/pwm-chunk.service <<'UNIT'
[Unit]
Description=PWM Chunk Server ${i}
After=network.target

[Service]
User=$(whoami)
WorkingDirectory=/home/$(whoami)
ExecStart=/home/$(whoami)/chunk \
  -id chunk${i} \
  -addr ${chunk_ip}:${port} \
  -master ${MASTER_INTERNAL}:${MASTER_PORT} \
  -data /home/$(whoami)/data/chunk${i} \
  -cert /home/$(whoami)/server-cert.pem \
  -key  /home/$(whoami)/server-key.pem \
  -ca   /home/$(whoami)/ca-cert.pem
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    sudo cp /tmp/pwm-chunk.service /etc/systemd/system/pwm-chunk.service
    sudo systemctl daemon-reload
    sudo systemctl enable pwm-chunk
    sudo systemctl restart pwm-chunk
    echo 'chunk${i} service started'
  "
done

ok "All services installed and started"

# ── step 11 — wait for services and verify ────────────────────────────────────
info "Waiting 15s for services to come up..."
sleep 15

info "Health check"
ssh_cmd "${VM_PREFIX}-master" "$MASTER_ZONE" \
  "sudo systemctl is-active pwm-master && echo 'master: OK' || echo 'master: FAILED'"

for i in 1 2 3; do
  ssh_cmd "${VM_PREFIX}-chunk${i}" "${CHUNK_ZONES[$((i-1))]}" \
    "sudo systemctl is-active pwm-chunk && echo 'chunk${i}: OK' || echo 'chunk${i}: FAILED'"
done

# ── step 12 — print summary ───────────────────────────────────────────────────
echo ""
green "════════════════════════════════════════════════════════════"
green "  Deployment complete!"
green "════════════════════════════════════════════════════════════"
echo ""
echo "  Web UI (HTTPS):"
echo "    https://${MASTER_EXTERNAL}:${HTTP_PORT}"
echo "    (browser will warn about self-signed cert — click Advanced > Proceed)"
echo ""
echo "  CLI client (from your local machine):"
echo "    ./bin/client \\"
echo "      -master ${MASTER_EXTERNAL}:${MASTER_PORT} \\"
echo "      -cert certs/client-cert.pem \\"
echo "      -key  certs/client-key.pem \\"
echo "      -ca   certs/ca-cert.pem"
echo ""
echo "  VM SSH access:"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=${MASTER_ZONE} --project=${GCP_PROJECT}"
echo "    gcloud compute ssh ${VM_PREFIX}-chunk1 --zone=${CHUNK_ZONES[0]} --project=${GCP_PROJECT}"
echo "    gcloud compute ssh ${VM_PREFIX}-chunk2 --zone=${CHUNK_ZONES[1]} --project=${GCP_PROJECT}"
echo "    gcloud compute ssh ${VM_PREFIX}-chunk3 --zone=${CHUNK_ZONES[2]} --project=${GCP_PROJECT}"
echo ""
echo "  Service logs:"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=${MASTER_ZONE} \\"
echo "      --command='sudo journalctl -u pwm-master -f'"
echo "    gcloud compute ssh ${VM_PREFIX}-chunk1 --zone=${CHUNK_ZONES[0]} \\"
echo "      --command='sudo journalctl -u pwm-chunk -f'"
echo ""
echo "  Tear down everything:"
echo "    bash scripts/teardown-gcp.sh"
echo ""
green "════════════════════════════════════════════════════════════"
