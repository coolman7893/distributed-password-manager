#!/bin/bash
# =============================================================================
# benchmark_internal.sh — Run ON the master VM via SSH
#
# This isolates INTERNAL GCP latency (master→chunks) from external
# client-facing latency. The difference lets you decompose write latency:
#
#   total write latency = your_ISP→GCP + internal GCP hops
#
# Usage: 
#   gcloud compute ssh pwm-master --zone=us-central1-a \
#     --project=YOUR_PROJECT \
#     --command="bash /tmp/benchmark_internal.sh" 
#
# Or copy and paste after SSHing in:
#   gcloud compute ssh pwm-master --zone=us-central1-a --project=YOUR_PROJECT
#   bash benchmark_internal.sh
# =============================================================================

set -euo pipefail

CLIENT="./client"
CERTS="-cert ./client-cert.pem -key ./client-key.pem -ca ./ca-cert.pem"
MASTER_ADDR="localhost:9000"
MASTER_HTTP="localhost:8443"
CMD="$CLIENT -master $MASTER_ADDR -http $MASTER_HTTP $CERTS"

run_client() {
  echo -e "$1" | $CMD 2>/dev/null
}

echo "════════════════════════════════════════════════"
echo " INTERNAL GCP BENCHMARK (running ON master VM)"
echo "════════════════════════════════════════════════"
echo " This measures latency EXCLUDING your ISP→GCP hop"
echo ""

# Setup
run_client "register\ninternaluser\nInternalPass123!\nexit" || true

# ── Internal write latency ────────────────────────────────────────────────────
echo "── Write Latency (internal, 20 trials) ──"
WRITE_TIMES=()
for i in $(seq 1 20); do
  START=$(date +%s%N)
  run_client "login\ninternaluser\nInternalPass123!\nsave\ninternal-write-${i}\nuser\npass\nexit"
  END=$(date +%s%N)
  MS=$(( (END - START) / 1000000 ))
  WRITE_TIMES+=("$MS")
  printf "  trial %2d: %d ms\n" "$i" "$MS"
done

WSUM=0; WMIN=${WRITE_TIMES[0]}; WMAX=${WRITE_TIMES[0]}
for t in "${WRITE_TIMES[@]}"; do
  WSUM=$((WSUM + t))
  (( t < WMIN )) && WMIN=$t
  (( t > WMAX )) && WMAX=$t
done
WMEAN=$((WSUM / ${#WRITE_TIMES[@]}))
IFS=$'\n' SW=($(sort -n <<< "${WRITE_TIMES[*]}")); unset IFS
WP95=${SW[$(( ${#SW[@]} * 95 / 100 ))]}

echo "  Mean: ${WMEAN}ms  Min: ${WMIN}ms  Max: ${WMAX}ms  p95: ${WP95}ms"

# ── Internal read latency ─────────────────────────────────────────────────────
echo ""
echo "── Read Latency (internal, 20 trials) ──"
run_client "login\ninternaluser\nInternalPass123!\nsave\ninternal-stable\nuser\nreadpass\nexit"

READ_TIMES=()
for i in $(seq 1 20); do
  START=$(date +%s%N)
  run_client "login\ninternaluser\nInternalPass123!\nget\ninternal-stable\nexit"
  END=$(date +%s%N)
  MS=$(( (END - START) / 1000000 ))
  READ_TIMES+=("$MS")
  printf "  trial %2d: %d ms\n" "$i" "$MS"
done

RSUM=0; RMIN=${READ_TIMES[0]}; RMAX=${READ_TIMES[0]}
for t in "${READ_TIMES[@]}"; do
  RSUM=$((RSUM + t))
  (( t < RMIN )) && RMIN=$t
  (( t > RMAX )) && RMAX=$t
done
RMEAN=$((RSUM / ${#READ_TIMES[@]}))

echo "  Mean: ${RMEAN}ms  Min: ${RMIN}ms  Max: ${RMAX}ms"

echo ""
echo "════════════════════════════════════════════════"
echo " INTERNAL SUMMARY (no ISP hop, pure GCP zones)"
echo "════════════════════════════════════════════════"
echo "  Internal write latency mean: ${WMEAN} ms"
echo "  Internal write latency p95:  ${WP95} ms"
echo "  Internal read latency mean:  ${RMEAN} ms"
echo ""
echo " Compare these to your external benchmark numbers."
echo " Difference = your ISP→GCP round-trip overhead."
