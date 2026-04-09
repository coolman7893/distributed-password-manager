#!/bin/bash
# =============================================================================
# benchmark_gcp.sh — GCP benchmark suite, Windows Git Bash compatible
#
# Run from your project root (same place you ran deploy-gcp.sh):
#   export GCP_PROJECT=rfa-cmpt756
#   bash scripts/benchmark_gcp.sh
#
# Requires: gcloud CLI, python3, certs/, and bin/windows/client.exe or bin/linux/client
# Output:   results/ directory with one CSV per benchmark + SUMMARY.txt
# =============================================================================

# Intentionally NOT set -euo pipefail — individual failures are caught per-command

GCP_PROJECT="${GCP_PROJECT:-}"
VM_PREFIX="${VM_PREFIX:-pwm}"
MASTER_ZONE="us-central1-a"
CHUNK_ZONES=("us-east1-c" "us-west4-a" "us-central1-b")
MASTER_PORT="9000"
HTTP_PORT="8443"
RESULTS_DIR="./results"
mkdir -p "$RESULTS_DIR"

[[ -z "$GCP_PROJECT" ]] && { echo "ERROR: export GCP_PROJECT=rfa-cmpt756 first"; exit 1; }

# ── OS detection ──────────────────────────────────────────────────────────────
IS_WINDOWS=0
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin" ]]; then
  IS_WINDOWS=1
  CLIENT_BIN="./bin/windows/client.exe"
else
  CLIENT_BIN="./bin/linux/client"
fi
CERTS="-cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"

# ── timestamp in ms (python3 because Git Bash lacks date +%s%N) ──────────────
now_ms() {
  python3 -c "import time; print(int(time.time()*1000))"
}

# ── ping helper: Windows uses -n, Linux uses -c ───────────────────────────────
ping_avg_ms() {
  local target="$1"
  if [[ $IS_WINDOWS -eq 1 ]]; then
    ping -n 10 "$target" 2>/dev/null \
      | grep -i "Average" \
      | grep -oE '[0-9]+ms' \
      | grep -oE '[0-9]+' \
      | tail -1 \
      || echo "N/A"
  else
    ping -c 10 "$target" 2>/dev/null \
      | tail -1 \
      | awk -F'/' '{print $5}' \
      || echo "N/A"
  fi
}

# ── SSH ping (VMs are always Linux) ──────────────────────────────────────────
ssh_ping_avg_ms() {
  local vm="$1" zone="$2" target_ip="$3"
  gcloud compute ssh "$vm" --zone="$zone" --project="$GCP_PROJECT" --quiet \
    --command="ping -c 10 $target_ip 2>/dev/null | tail -1 | awk -F'/' '{print \$5}'" \
    2>/dev/null || echo "N/A"
}

# ── pipe commands into the client binary ─────────────────────────────────────
run_client() {
  printf '%b' "$1" | "$CLIENT_BIN" -master "$MASTER_ADDR" -http "$MASTER_HTTP" $CERTS 2>/dev/null
}

# ── fetch master IP ───────────────────────────────────────────────────────────
echo "Fetching master external IP..."
MASTER_IP=$(gcloud compute instances describe "${VM_PREFIX}-master" \
  --zone="$MASTER_ZONE" --project="$GCP_PROJECT" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
[[ -z "$MASTER_IP" ]] && { echo "ERROR: could not get master IP. Are VMs running?"; exit 1; }

MASTER_ADDR="${MASTER_IP}:${MASTER_PORT}"
MASTER_HTTP="${MASTER_IP}:${HTTP_PORT}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         CMPT 756 GCP BENCHMARK SUITE                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  Master:  $MASTER_IP (us-central1-a)"
echo "  Client:  $(hostname) on $(uname -s)"
echo "  Started: $(date)"
echo ""

echo "Setting up benchmark user..."
run_client "register\nbenchuser\nBenchPass123!\nexit" > /dev/null 2>&1 || true
echo "Done (user exists or was created)."
echo ""

# =============================================================================
# B1: Cross-Zone Network RTT
# =============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BENCHMARK 1: Cross-Zone Network RTT (10-ping average per pair)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
B1="${RESULTS_DIR}/b1_zone_rtt.txt"
echo "# Zone RTT — $(date)" > "$B1"

echo "  Fetching internal IPs..."
C1_INT=$(gcloud compute instances describe "${VM_PREFIX}-chunk1" --zone="${CHUNK_ZONES[0]}" \
  --project="$GCP_PROJECT" --format='value(networkInterfaces[0].networkIP)' 2>/dev/null)
C2_INT=$(gcloud compute instances describe "${VM_PREFIX}-chunk2" --zone="${CHUNK_ZONES[1]}" \
  --project="$GCP_PROJECT" --format='value(networkInterfaces[0].networkIP)' 2>/dev/null)
C3_INT=$(gcloud compute instances describe "${VM_PREFIX}-chunk3" --zone="${CHUNK_ZONES[2]}" \
  --project="$GCP_PROJECT" --format='value(networkInterfaces[0].networkIP)' 2>/dev/null)

measure_and_save() {
  local label="$1" rtt="$2"
  printf "  %-52s %s ms\n" "$label" "$rtt"
  echo "$label: $rtt ms" >> "$B1"
}

echo -n "  master→chunk1 (us-central1-a→us-east1-c) ... "
R=$(ssh_ping_avg_ms "${VM_PREFIX}-master" "$MASTER_ZONE" "$C1_INT"); echo "$R ms"
echo "master→chunk1 (us-central1-a→us-east1-c): $R ms" >> "$B1"
RTT_M_C1="$R"

echo -n "  master→chunk2 (us-central1-a→us-west4-a) ... "
R=$(ssh_ping_avg_ms "${VM_PREFIX}-master" "$MASTER_ZONE" "$C2_INT"); echo "$R ms"
echo "master→chunk2 (us-central1-a→us-west4-a): $R ms" >> "$B1"
RTT_M_C2="$R"

echo -n "  master→chunk3 (us-central1-a→us-central1-b) ... "
R=$(ssh_ping_avg_ms "${VM_PREFIX}-master" "$MASTER_ZONE" "$C3_INT"); echo "$R ms"
echo "master→chunk3 (us-central1-a→us-central1-b): $R ms" >> "$B1"
RTT_M_C3="$R"

echo -n "  chunk1→chunk2 (us-east1-c→us-west4-a) ... "
R=$(ssh_ping_avg_ms "${VM_PREFIX}-chunk1" "${CHUNK_ZONES[0]}" "$C2_INT"); echo "$R ms"
echo "chunk1→chunk2 (us-east1-c→us-west4-a): $R ms" >> "$B1"
RTT_C1_C2="$R"

echo -n "  $(hostname)→master (Surrey→GCP) ... "
R=$(ping_avg_ms "$MASTER_IP"); echo "$R ms"
echo "local→master: $R ms" >> "$B1"
RTT_LOCAL="$R"

echo "  → Saved: $B1"

# =============================================================================
# B2: Write Latency
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BENCHMARK 2: Write Latency — 30 trials"
echo "  (login + save → 3x replicated across zones)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
B2="${RESULTS_DIR}/b2_write_latency.csv"
echo "trial,latency_ms" > "$B2"

for i in $(seq 1 30); do
  TS=$(python3 -c "import time; print(int(time.time()*1000))")
  T0=$(now_ms)
  run_client "login\nbenchuser\nBenchPass123!\nsave\nbw-${i}-${TS}\nbenchuser\nsupersecret\nexit" > /dev/null
  T1=$(now_ms)
  MS=$(( T1 - T0 ))
  echo "${i},${MS}" >> "$B2"
  printf "  trial %2d: %d ms\n" "$i" "$MS"
done

python3 - "$B2" << 'PY'
import sys, csv
rows = list(csv.DictReader(open(sys.argv[1])))
t = sorted(int(r['latency_ms']) for r in rows)
n = len(t)
print(f"\n  WRITE LATENCY SUMMARY (n={n})")
print(f"    mean = {sum(t)//n} ms")
print(f"    min  = {t[0]} ms")
print(f"    p50  = {t[n//2]} ms")
print(f"    p95  = {t[int(n*0.95)]} ms")
print(f"    max  = {t[-1]} ms")
PY
echo "  → Saved: $B2"

# =============================================================================
# B3: Read Latency
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BENCHMARK 3: Read Latency — 30 trials"
echo "  (login + get → single chunk, decrypt locally)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

run_client "login\nbenchuser\nBenchPass123!\nsave\nread-probe\nbenchuser\nreadpassword\nexit" > /dev/null

B3="${RESULTS_DIR}/b3_read_latency.csv"
echo "trial,latency_ms" > "$B3"

for i in $(seq 1 30); do
  T0=$(now_ms)
  run_client "login\nbenchuser\nBenchPass123!\nget\nread-probe\nexit" > /dev/null
  T1=$(now_ms)
  MS=$(( T1 - T0 ))
  echo "${i},${MS}" >> "$B3"
  printf "  trial %2d: %d ms\n" "$i" "$MS"
done

python3 - "$B3" << 'PY'
import sys, csv
rows = list(csv.DictReader(open(sys.argv[1])))
t = sorted(int(r['latency_ms']) for r in rows)
n = len(t)
print(f"\n  READ LATENCY SUMMARY (n={n})")
print(f"    mean = {sum(t)//n} ms")
print(f"    min  = {t[0]} ms")
print(f"    p50  = {t[n//2]} ms")
print(f"    p95  = {t[int(n*0.95)]} ms")
print(f"    max  = {t[-1]} ms")
PY
echo "  → Saved: $B3"

# =============================================================================
# B4: Scalability (latency vs vault size)
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BENCHMARK 4: Scalability — latency vs vault size"
echo "  (expect flat line — O(1) per-key file, no index)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
B4="${RESULTS_DIR}/b4_scalability.csv"
echo "vault_entries,write_ms,read_ms" > "$B4"

run_client "register\nscaleuser\nScalePass123!\nexit" > /dev/null 2>&1 || true

PREV=0
for TARGET in 1 10 25 50 100; do
  FILL=$(( TARGET - PREV ))
  echo "  Filling to $TARGET entries (adding $FILL)..."
  for j in $(seq 1 $FILL); do
    run_client "login\nscaleuser\nScalePass123!\nsave\nsc-${PREV}-${j}\nu\np\nexit" > /dev/null
  done
  PREV=$TARGET

  T0=$(now_ms)
  run_client "login\nscaleuser\nScalePass123!\nsave\nsc-probe-${TARGET}\nu\np\nexit" > /dev/null
  T1=$(now_ms)
  W=$(( T1 - T0 ))

  T0=$(now_ms)
  run_client "login\nscaleuser\nScalePass123!\nget\nsc-1-1\nexit" > /dev/null
  T1=$(now_ms)
  R=$(( T1 - T0 ))

  echo "${TARGET},${W},${R}" >> "$B4"
  printf "  vault_size=%3d  write=%dms  read=%dms\n" "$TARGET" "$W" "$R"
done
echo "  → Saved: $B4"

# =============================================================================
# B5: Recovery Time
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BENCHMARK 5: Recovery Time — WAL replay after chunk2 restart"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
B5="${RESULTS_DIR}/b5_recovery.csv"
echo "missed_writes,recovery_ms,data_intact" > "$B5"

for MISSED in 1 5 10 20; do
  echo ""
  echo "  [chunk2 kill → write $MISSED → restart → verify]"

  gcloud compute ssh "${VM_PREFIX}-chunk2" --zone="${CHUNK_ZONES[1]}" \
    --project="$GCP_PROJECT" --quiet \
    --command="sudo systemctl stop pwm-chunk" 2>/dev/null
  echo "  chunk2 stopped. Waiting 9s for master dead-detection..."
  sleep 9

  echo "  Writing $MISSED entries while chunk2 is down..."
  for j in $(seq 1 $MISSED); do
    run_client "login\nbenchuser\nBenchPass123!\nsave\nrec-${MISSED}-${j}\nu\np\nexit" > /dev/null
  done

  echo "  Restarting chunk2 and timing until /health shows chunks=3..."
  T0=$(now_ms)
  gcloud compute ssh "${VM_PREFIX}-chunk2" --zone="${CHUNK_ZONES[1]}" \
    --project="$GCP_PROJECT" --quiet \
    --command="sudo systemctl start pwm-chunk" 2>/dev/null

  CHUNKS=0; WAITED=0
  while [[ "$CHUNKS" != "3" && $WAITED -lt 35 ]]; do
    sleep 1; WAITED=$(( WAITED + 1 ))
    CHUNKS=$(curl -sk "https://${MASTER_HTTP}/health" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('chunks',0))" 2>/dev/null \
      || echo "0")
    printf "    waited %2ds — chunks alive: %s\n" "$WAITED" "$CHUNKS"
  done

  T1=$(now_ms)
  RMS=$(( T1 - T0 ))

  # Verify data written during outage is readable
  OUT=$(run_client "login\nbenchuser\nBenchPass123!\nget\nrec-${MISSED}-1\nexit" 2>/dev/null)
  INTACT="NO"
  echo "$OUT" | grep -q "rec-${MISSED}-1" && INTACT="YES"

  echo "${MISSED},${RMS},${INTACT}" >> "$B5"
  printf "  missed=%2d  recovery=%dms  data_intact=%s\n" "$MISSED" "$RMS" "$INTACT"

  echo "  Stabilizing 5s before next trial..."
  sleep 5
done
echo "  → Saved: $B5"

# =============================================================================
# B6: Availability Under Node Failure
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BENCHMARK 6: Availability — reads/writes during node failure"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
B6="${RESULTS_DIR}/b6_availability.csv"
echo "scenario,reads_ok,reads_total,writes_ok,writes_total" > "$B6"

run_client "login\nbenchuser\nBenchPass123!\nsave\navail-stable\nu\nstablepass\nexit" > /dev/null

for IDX in 0 1; do
  if [[ $IDX -eq 0 ]]; then
    LABEL="replica_down"; VM="${VM_PREFIX}-chunk2"; ZONE="${CHUNK_ZONES[1]}"
    DESC="1 replica down (chunk2 / us-west4-a)"
  else
    LABEL="primary_down"; VM="${VM_PREFIX}-chunk1"; ZONE="${CHUNK_ZONES[0]}"
    DESC="Primary down (chunk1 / us-east1-c)"
  fi

  echo ""
  echo "  Scenario: $DESC"
  gcloud compute ssh "$VM" --zone="$ZONE" --project="$GCP_PROJECT" --quiet \
    --command="sudo systemctl stop pwm-chunk" 2>/dev/null
  echo "  Waiting 9s for dead-detection..."
  sleep 9

  R_OK=0
  for r in $(seq 1 5); do
    OUT=$(run_client "login\nbenchuser\nBenchPass123!\nget\navail-stable\nexit" 2>/dev/null)
    echo "$OUT" | grep -q "stablepass" && R_OK=$(( R_OK + 1 ))
  done

  W_OK=0
  for w in $(seq 1 5); do
    OUT=$(run_client "login\nbenchuser\nBenchPass123!\nsave\navw-${LABEL}-${w}\nu\np\nexit" 2>/dev/null)
    echo "$OUT" | grep -qi "Saved" && W_OK=$(( W_OK + 1 ))
  done

  echo "  reads: ${R_OK}/5   writes: ${W_OK}/5"
  echo "${LABEL},${R_OK},5,${W_OK},5" >> "$B6"

  gcloud compute ssh "$VM" --zone="$ZONE" --project="$GCP_PROJECT" --quiet \
    --command="sudo systemctl start pwm-chunk" 2>/dev/null
  echo "  $VM restored — waiting 8s..."
  sleep 8
done
echo "  → Saved: $B6"

# =============================================================================
# B7: Concurrent Write Throughput
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BENCHMARK 7: Concurrent Write Throughput (5, 10, 20 clients)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
B7="${RESULTS_DIR}/b7_concurrent.csv"
echo "concurrent_clients,total_batch_ms,ops_per_sec" > "$B7"

for N in 5 10 20; do
  echo "  Launching $N concurrent writers..."
  PIDS=()
  T0=$(now_ms)
  for i in $(seq 1 $N); do
    TS=$(python3 -c "import time; print(int(time.time()*1000))")
    run_client "login\nbenchuser\nBenchPass123!\nsave\ncw-${N}-${i}-${TS}\nu\np\nexit" > /dev/null &
    PIDS+=($!)
  done
  for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
  T1=$(now_ms)
  BATCH=$(( T1 - T0 ))
  OPS=$(python3 -c "print(round($N*1000/max($BATCH,1),2))")
  echo "${N},${BATCH},${OPS}" >> "$B7"
  printf "  %2d clients: batch_ms=%d  ops/s=%s\n" "$N" "$BATCH" "$OPS"
done
echo "  → Saved: $B7"

# =============================================================================
# B8: Login Latency
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BENCHMARK 8: Login Latency (bcrypt + PBKDF2 100K rounds)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
B8="${RESULTS_DIR}/b8_login_latency.csv"
echo "trial,latency_ms" > "$B8"

for i in $(seq 1 10); do
  T0=$(now_ms)
  run_client "login\nbenchuser\nBenchPass123!\nexit" > /dev/null
  T1=$(now_ms)
  MS=$(( T1 - T0 ))
  echo "${i},${MS}" >> "$B8"
  printf "  trial %2d: %d ms\n" "$i" "$MS"
done

python3 - "$B8" << 'PY'
import sys, csv
t = sorted(int(r['latency_ms']) for r in csv.DictReader(open(sys.argv[1])))
n = len(t)
print(f"\n  LOGIN LATENCY: mean={sum(t)//n}ms  min={t[0]}ms  max={t[-1]}ms")
print(f"  Intentionally slow — PBKDF2 100K rounds = brute-force resistance")
PY
echo "  → Saved: $B8"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              ALL BENCHMARKS COMPLETE                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  Results in: $RESULTS_DIR/"
ls -1 "$RESULTS_DIR/"
echo ""
echo "  Next: copy results to slides. Key numbers to show:"
echo "    B1: zone RTT explains write latency breakdown"
echo "    B2 vs B3: write/read ratio shows replication cost"
echo "    B4: flat curve proves O(1) scalability"
echo "    B5: recovery time with zero data loss"
echo "    B6: availability table (CP tradeoff)"
echo "    B7: throughput saturation under concurrency"
echo "    B8: login floor from PBKDF2 security cost"