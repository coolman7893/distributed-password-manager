#!/bin/bash
# =============================================================================
# deploy-gcp.sh — Full GCP deployment for Distributed Password Manager
# CMPT 756
#
# Usage (Git Bash on Windows):
#   export GCP_PROJECT=rfa-cmpt756
#   bash scripts/deploy-gcp.sh
# =============================================================================

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
GCP_PROJECT="${GCP_PROJECT:-}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
VM_PREFIX="${VM_PREFIX:-pwm}"
MASTER_PORT="${MASTER_PORT:-9000}"
HTTP_PORT="${HTTP_PORT:-8443}"

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
ok()    { green "    v $*"; }
err()   { red "    x $*"; exit 1; }

# ── pre-flight ────────────────────────────────────────────────────────────────
info "Pre-flight checks"

[[ -z "$GCP_PROJECT" ]] && err "GCP_PROJECT is not set. Run: export GCP_PROJECT=rfa-cmpt756"

command -v gcloud  >/dev/null 2>&1 || err "gcloud not found. Install Google Cloud SDK."
command -v go      >/dev/null 2>&1 || err "go not found. Install from https://go.dev"
command -v openssl >/dev/null 2>&1 || err "openssl not found."
command -v node    >/dev/null 2>&1 || { red "    ! node not found — frontend build will be skipped"; NODE_SKIP=1; }
command -v npm     >/dev/null 2>&1 || { red "    ! npm not found — frontend build will be skipped"; NODE_SKIP=1; }

gcloud config set project "$GCP_PROJECT" 2>/dev/null
ok "GCP project: $GCP_PROJECT"

# ── step 1 — build Linux binaries ─────────────────────────────────────────────
info "Building Go binaries (linux/amd64)"
cd "$REPO_ROOT"
mkdir -p "$BIN_DIR"

GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$BIN_DIR/master"  ./cmd/master
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$BIN_DIR/chunk"   ./cmd/chunkserver
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$BIN_DIR/client"  ./cmd/client
ok "master, chunk, client built"

# ── step 2 — build React frontend ─────────────────────────────────────────────
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

# ── step 3 — TLS certificates ─────────────────────────────────────────────────
# Server cert is generated without IPs here, then RE-ISSUED in step 7
# once we have the real VM IPs. CA and client cert only need to be made once.
info "TLS certificates (initial pass)"
mkdir -p "$CERT_DIR"

if [[ ! -f "$CERT_DIR/ca-cert.pem" ]]; then
  info "Generating CA"
  openssl genrsa -out "$CERT_DIR/ca-key.pem" 4096 2>/dev/null
  # NOTE: //CN= double-slash is intentional for Windows Git Bash.
  # MINGW path mangling eats the leading / in -subj on Windows.
  openssl req -new -x509 -days 365 -key "$CERT_DIR/ca-key.pem" \
    -out "$CERT_DIR/ca-cert.pem" -subj "//CN=DistPWM-CA" 2>/dev/null
  ok "CA generated"
fi

if [[ ! -f "$CERT_DIR/server-key.pem" ]]; then
  openssl genrsa -out "$CERT_DIR/server-key.pem" 2048 2>/dev/null
  ok "Server key generated (cert will be issued after VMs are up)"
fi

if [[ ! -f "$CERT_DIR/client-cert.pem" ]]; then
  info "Generating client cert"
  openssl genrsa -out "$CERT_DIR/client-key.pem" 2048 2>/dev/null
  openssl req -new -key "$CERT_DIR/client-key.pem" \
    -out "$CERT_DIR/client.csr" -subj "//CN=client" 2>/dev/null
  openssl x509 -req -days 365 -in "$CERT_DIR/client.csr" \
    -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" \
    -CAcreateserial -out "$CERT_DIR/client-cert.pem" 2>/dev/null
  rm -f "$CERT_DIR/client.csr" "$CERT_DIR"/*.srl
  ok "Client cert generated"
fi

# ── step 4 — create VMs ───────────────────────────────────────────────────────
info "Creating GCE virtual machines"

create_vm_if_missing() {
  local name=$1 zone=$2 tags=$3
  if gcloud compute instances describe "$name" --zone="$zone" \
       --project="$GCP_PROJECT" &>/dev/null; then
    ok "$name already exists — skipping"
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

create_vm_if_missing "${VM_PREFIX}-master" "$MASTER_ZONE"      "pwm-master,pwm-node"
create_vm_if_missing "${VM_PREFIX}-chunk1" "${CHUNK_ZONES[0]}" "pwm-chunk,pwm-node"
create_vm_if_missing "${VM_PREFIX}-chunk2" "${CHUNK_ZONES[1]}" "pwm-chunk,pwm-node"
create_vm_if_missing "${VM_PREFIX}-chunk3" "${CHUNK_ZONES[2]}" "pwm-chunk,pwm-node"

# ── step 5 — firewall rules ───────────────────────────────────────────────────
info "Firewall rules"

create_fw_if_missing() {
  local rule=$1; shift
  if gcloud compute firewall-rules describe "$rule" \
       --project="$GCP_PROJECT" &>/dev/null; then
    ok "$rule already exists"
  else
    gcloud compute firewall-rules create "$rule" "$@" \
      --project="$GCP_PROJECT" --quiet
    ok "Created $rule"
  fi
}

create_fw_if_missing "allow-pwm-master-internal" \
  --allow=tcp:${MASTER_PORT} \
  --target-tags=pwm-master \
  --source-tags=pwm-node \
  --description="Master gob port — internal only"

create_fw_if_missing "allow-pwm-master-https" \
  --allow=tcp:${HTTP_PORT} \
  --target-tags=pwm-master \
  --source-ranges=0.0.0.0/0 \
  --description="Master HTTPS web UI — public"

create_fw_if_missing "allow-pwm-chunks-internal" \
  --allow=tcp:9001-9003 \
  --target-tags=pwm-chunk \
  --source-tags=pwm-node \
  --description="Chunk ports — internal only"

create_fw_if_missing "allow-pwm-ssh" \
  --allow=tcp:22 \
  --target-tags=pwm-node \
  --source-ranges=0.0.0.0/0 \
  --description="SSH to all PWM nodes"

# ── step 6 — get IPs (with retry loop for external IP) ───────────────────────
info "Fetching VM IP addresses"

get_internal_ip() {
  gcloud compute instances describe "$1" --zone="$2" --project="$GCP_PROJECT" \
    --format='value(networkInterfaces[0].networkIP)'
}

# External IPs can take several seconds to be assigned after VM creation.
# This retries up to 20 times (100 seconds total) before giving up.
get_external_ip_with_retry() {
  local vm=$1 zone=$2
  local ip="" attempts=0
  while [[ -z "$ip" && $attempts -lt 20 ]]; do
    ip=$(gcloud compute instances describe "$vm" --zone="$zone" \
           --project="$GCP_PROJECT" \
           --format='value(networkInterfaces[0].accessConfigs[0].natIP)' \
           2>/dev/null || true)
    if [[ -z "$ip" ]]; then
      attempts=$((attempts + 1))
      echo "    waiting for external IP on $vm (attempt $attempts/20)..."
      sleep 5
    fi
  done
  [[ -z "$ip" ]] && err "Could not get external IP for $vm after 100s. Check GCP console."
  echo "$ip"
}

MASTER_INTERNAL=$(get_internal_ip "${VM_PREFIX}-master" "$MASTER_ZONE")
MASTER_EXTERNAL=$(get_external_ip_with_retry "${VM_PREFIX}-master" "$MASTER_ZONE")
CHUNK1_INTERNAL=$(get_internal_ip "${VM_PREFIX}-chunk1" "${CHUNK_ZONES[0]}")
CHUNK2_INTERNAL=$(get_internal_ip "${VM_PREFIX}-chunk2" "${CHUNK_ZONES[1]}")
CHUNK3_INTERNAL=$(get_internal_ip "${VM_PREFIX}-chunk3" "${CHUNK_ZONES[2]}")

ok "Master:  internal=$MASTER_INTERNAL  external=$MASTER_EXTERNAL"
ok "Chunk1:  internal=$CHUNK1_INTERNAL"
ok "Chunk2:  internal=$CHUNK2_INTERNAL"
ok "Chunk3:  internal=$CHUNK3_INTERNAL"

# Hard stop if any IP is still empty — the cert would be malformed
for check in \
    "MASTER_INTERNAL=$MASTER_INTERNAL" \
    "MASTER_EXTERNAL=$MASTER_EXTERNAL" \
    "CHUNK1_INTERNAL=$CHUNK1_INTERNAL" \
    "CHUNK2_INTERNAL=$CHUNK2_INTERNAL" \
    "CHUNK3_INTERNAL=$CHUNK3_INTERNAL"; do
  label="${check%%=*}"
  val="${check#*=}"
  [[ -z "$val" ]] && err "$label is empty — cannot build SAN for TLS cert. Check GCP console."
done

ok "All IPs confirmed non-empty"

# ── step 7 — re-issue server cert with all real IPs in SAN ───────────────────
info "Re-issuing server cert with all IPs in SAN"

# Use mktemp so there are no path collision issues across parallel runs
SAN_FILE="$(mktemp /tmp/san_XXXXXX.cnf)"

cat > "$SAN_FILE" <<SAN
[req]
distinguished_name = req_dn
[req_dn]
[v3_ext]
subjectAltName=DNS:localhost,DNS:master,DNS:chunk1,DNS:chunk2,DNS:chunk3,IP:127.0.0.1,IP:${MASTER_INTERNAL},IP:${MASTER_EXTERNAL},IP:${CHUNK1_INTERNAL},IP:${CHUNK2_INTERNAL},IP:${CHUNK3_INTERNAL}
SAN

openssl req -new -key "$CERT_DIR/server-key.pem" \
  -out "$CERT_DIR/server.csr" -subj "//CN=localhost" 2>/dev/null

openssl x509 -req -days 365 -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" \
  -CAcreateserial -out "$CERT_DIR/server-cert.pem" \
  -extfile "$SAN_FILE" -extensions v3_ext 2>/dev/null

rm -f "$CERT_DIR/server.csr" "$CERT_DIR"/*.srl "$SAN_FILE"
ok "Server cert issued with SANs: localhost, 127.0.0.1, all VM IPs"

# ── step 8 — SSH helper ───────────────────────────────────────────────────────
ssh_cmd() {
  local vm=$1 zone=$2; shift 2
  gcloud compute ssh "$vm" --zone="$zone" --project="$GCP_PROJECT" \
    --command="$*"
}

# ── step 9 — upload files ─────────────────────────────────────────────────────
info "Uploading files to all VMs"

# Destination is "vm:" not "vm:~/" — the ~/  gets mangled by MINGW on Windows
upload_files() {
  local vm=$1 zone=$2; shift 2
  gcloud compute scp "$@" "${vm}:" \
    --zone="$zone" --project="$GCP_PROJECT"
}

CERT_FILES=(
  "$CERT_DIR/ca-cert.pem"
  "$CERT_DIR/server-cert.pem"
  "$CERT_DIR/server-key.pem"
  "$CERT_DIR/client-cert.pem"
  "$CERT_DIR/client-key.pem"
)

info "  Uploading to master..."
upload_files "${VM_PREFIX}-master" "$MASTER_ZONE" \
  "$BIN_DIR/master" "$BIN_DIR/client" "${CERT_FILES[@]}"

if [[ -d "$REPO_ROOT/web/dist" ]]; then
  info "  Uploading web/dist to master..."
  tar -czf /tmp/web-dist.tar.gz -C "$REPO_ROOT/web" dist
  gcloud compute scp /tmp/web-dist.tar.gz "${VM_PREFIX}-master:" \
    --zone="$MASTER_ZONE" --project="$GCP_PROJECT"
  ssh_cmd "${VM_PREFIX}-master" "$MASTER_ZONE" \
    "tar -xzf ~/web-dist.tar.gz -C ~/ && rm ~/web-dist.tar.gz"
  ok "web/dist uploaded and extracted"
fi

for i in 1 2 3; do
  vm="${VM_PREFIX}-chunk${i}"
  zone="${CHUNK_ZONES[$((i-1))]}"
  info "  Uploading to chunk${i}..."
  upload_files "$vm" "$zone" "$BIN_DIR/chunk" "${CERT_FILES[@]}"
done

ok "All files uploaded"

# ── step 10 — install systemd services ───────────────────────────────────────
# Service unit files are built locally and uploaded via scp, then installed.
# This avoids heredoc variable-expansion problems when the remote shell
# tries to interpret local variables like $MASTER_PORT inside a remote command.
info "Installing systemd services"

# ---- master ----
info "  Installing master service..."
MASTER_USER=$(ssh_cmd "${VM_PREFIX}-master" "$MASTER_ZONE" "echo \$USER")

MASTER_SVC="$(mktemp /tmp/pwm-master_XXXXXX.service)"
cat > "$MASTER_SVC" <<UNIT
[Unit]
Description=PWM Master Node
After=network.target

[Service]
User=${MASTER_USER}
WorkingDirectory=/home/${MASTER_USER}
ExecStart=/home/${MASTER_USER}/master \\
  -addr :${MASTER_PORT} \\
  -http :${HTTP_PORT} \\
  -primary chunk1 \\
  -wal /home/${MASTER_USER}/data/master/wal.json \\
  -cert /home/${MASTER_USER}/server-cert.pem \\
  -key  /home/${MASTER_USER}/server-key.pem \\
  -ca   /home/${MASTER_USER}/ca-cert.pem \\
  -users /home/${MASTER_USER}/data/users.json \\
  -static /home/${MASTER_USER}/dist
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

gcloud compute scp "$MASTER_SVC" "${VM_PREFIX}-master:/tmp/pwm-master.service" \
  --zone="$MASTER_ZONE" --project="$GCP_PROJECT"

ssh_cmd "${VM_PREFIX}-master" "$MASTER_ZONE" "
  set -e
  chmod +x ~/master ~/client
  mkdir -p ~/data/master
  sudo cp /tmp/pwm-master.service /etc/systemd/system/pwm-master.service
  sudo systemctl daemon-reload
  sudo systemctl enable pwm-master
  sudo systemctl restart pwm-master
"
rm -f "$MASTER_SVC"
ok "Master service installed and started"

# ---- chunk servers ----
for i in 1 2 3; do
  vm="${VM_PREFIX}-chunk${i}"
  zone="${CHUNK_ZONES[$((i-1))]}"
  port=$((9000 + i))

  case $i in
    1) this_chunk_internal="$CHUNK1_INTERNAL" ;;
    2) this_chunk_internal="$CHUNK2_INTERNAL" ;;
    3) this_chunk_internal="$CHUNK3_INTERNAL" ;;
  esac

  info "  Installing chunk${i} service..."
  CHUNK_USER=$(ssh_cmd "$vm" "$zone" "echo \$USER")

  CHUNK_SVC="$(mktemp /tmp/pwm-chunk${i}_XXXXXX.service)"
  cat > "$CHUNK_SVC" <<UNIT
[Unit]
Description=PWM Chunk Server ${i}
After=network.target

[Service]
User=${CHUNK_USER}
WorkingDirectory=/home/${CHUNK_USER}
ExecStart=/home/${CHUNK_USER}/chunk \\
  -id chunk${i} \\
  -addr :${port} \\
  -regaddr ${this_chunk_internal}:${port} \\
  -master ${MASTER_INTERNAL}:${MASTER_PORT} \\
  -data /home/${CHUNK_USER}/data/chunk${i} \\
  -cert /home/${CHUNK_USER}/server-cert.pem \\
  -key  /home/${CHUNK_USER}/server-key.pem \\
  -ca   /home/${CHUNK_USER}/ca-cert.pem
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  gcloud compute scp "$CHUNK_SVC" "${vm}:/tmp/pwm-chunk.service" \
    --zone="$zone" --project="$GCP_PROJECT"

  ssh_cmd "$vm" "$zone" "
    set -e
    chmod +x ~/chunk
    mkdir -p ~/data/chunk${i}
    sudo cp /tmp/pwm-chunk.service /etc/systemd/system/pwm-chunk.service
    sudo systemctl daemon-reload
    sudo systemctl enable pwm-chunk
    sudo systemctl restart pwm-chunk
  "
  rm -f "$CHUNK_SVC"
  ok "Chunk${i} service installed and started"
done

# ── step 11 — health check ────────────────────────────────────────────────────
info "Waiting 20s for all services to settle..."
sleep 20

info "Health check"
ssh_cmd "${VM_PREFIX}-master" "$MASTER_ZONE" \
  "sudo systemctl is-active pwm-master && echo 'master: OK' || echo 'master: FAILED'"

for i in 1 2 3; do
  ssh_cmd "${VM_PREFIX}-chunk${i}" "${CHUNK_ZONES[$((i-1))]}" \
    "sudo systemctl is-active pwm-chunk && echo 'chunk${i}: OK' || echo 'chunk${i}: FAILED'"
done

# ── step 12 — summary ─────────────────────────────────────────────────────────
# Detect OS to display platform-appropriate commands
detect_os() {
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin" ]]; then
    echo "windows"
  else
    echo "linux"
  fi
}

OS=$(detect_os)
CLIENT_BIN="./bin/linux/client"
if [[ "$OS" == "windows" ]]; then
  CLIENT_BIN="./bin/windows/client.exe"
fi

echo ""
green "=================================================="
green "  Deployment complete! (OS: $OS)"
green "=================================================="
echo ""
echo "  Web UI (accept the self-signed cert warning in browser):"
echo "    https://${MASTER_EXTERNAL}:${HTTP_PORT}"
echo ""
echo "  CLI client (copy-paste ready):"
echo "    $CLIENT_BIN -master ${MASTER_EXTERNAL}:${MASTER_PORT} -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"
echo ""
echo "  SSH into VMs:"
echo "    gcloud compute ssh ${VM_PREFIX}-master --zone=${MASTER_ZONE} --project=${GCP_PROJECT}"
echo "    gcloud compute ssh ${VM_PREFIX}-chunk1 --zone=${CHUNK_ZONES[0]} --project=${GCP_PROJECT}"
echo "    gcloud compute ssh ${VM_PREFIX}-chunk2 --zone=${CHUNK_ZONES[1]} --project=${GCP_PROJECT}"
echo "    gcloud compute ssh ${VM_PREFIX}-chunk3 --zone=${CHUNK_ZONES[2]} --project=${GCP_PROJECT}"
echo ""
echo "  Live logs:"
echo "    Master:"
echo "      gcloud compute ssh ${VM_PREFIX}-master --zone=${MASTER_ZONE} --project=${GCP_PROJECT} --command=\"sudo journalctl -u pwm-master -f\""
echo "    Chunk1:"
echo "      gcloud compute ssh ${VM_PREFIX}-chunk1 --zone=${CHUNK_ZONES[0]} --project=${GCP_PROJECT} --command=\"sudo journalctl -u pwm-chunk -f\""
echo "    Chunk2:"
echo "      gcloud compute ssh ${VM_PREFIX}-chunk2 --zone=${CHUNK_ZONES[1]} --project=${GCP_PROJECT} --command=\"sudo journalctl -u pwm-chunk -f\""
echo "    Chunk3:"
echo "      gcloud compute ssh ${VM_PREFIX}-chunk3 --zone=${CHUNK_ZONES[2]} --project=${GCP_PROJECT} --command=\"sudo journalctl -u pwm-chunk -f\""
echo ""
echo "  Or use the connect script:"
echo "    bash scripts/connect.sh logs   (master)"
echo "    bash scripts/connect.sh logs1  (chunk1)"
echo "    bash scripts/connect.sh logs2  (chunk2)"
echo "    bash scripts/connect.sh logs3  (chunk3)"
echo ""
echo "  Get updated IP after stop/start:"
echo "    bash scripts/connect.sh"
echo ""
echo "  Tear down everything (zero cost):"
echo "    bash scripts/teardown-gcp.sh"
echo ""
green "=================================================="