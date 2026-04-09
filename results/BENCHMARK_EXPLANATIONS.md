# Benchmark Results Explanations

## B1: Cross-Zone Network RTT (`b1_zone_rtt.txt`)

**What:** Ping-based RTT measurements across GCP zones (master in us-central1-a, chunks in us-east1-c, us-west4-a, us-central1-b).

**Methodology:**

- SSH into each VM, ping 10 times to target, extract average RTT
- Measures both master→chunk and chunk→chunk latencies

**Why:** Network latency is the primary bottleneck for distributed password manager operations; this baseline explains write/read latency.

**Results:** master→chunk1: 33.5ms, master→chunk2: 47.2ms, master→chunk3: 0.8ms, chunk1→chunk2: 176.8ms, local→master: 65ms.

---

## B2: Password Write (Save) Operations (`b2_write_latency.csv`)

**What:** 30 trials of login + save (credential encryption + 3-way replication to all chunks).

**Methodology:**

- Client calls `login` + `save` command
- Measure end-to-end latency from send to response received
- Repeat with unique credentials to avoid cache effects

**Why:** Write is the slowest operation because it blocks until all 3 chunk replicas acknowledge; shows cost of durability vs. read-only operations.

**Results:** Values ~1110ms average show replication overhead dominates network round-trip cost.

---

## B3: Password Read (Get) Operations (`b3_read_latency.csv`)

**What:** 30 trials of login + get (retrieve + decrypt credential from primary chunk).

**Methodology:**

- Client calls `login` + `get` on pre-written test credential
- Measure round-trip latency for single-replica read

**Why:** Read is faster than write because system returns from first replica answer; shows eventual consistency benefit in practice.

**Results:** Values ~750ms average show ~30% faster than writes but still dominated by ISP→GCP round-trip.

---

## B4: Operation Latency vs Vault Size (`b4_scalability.csv`)

**What:** Write and read latency measured at vault sizes 1, 10, 25, 50, 100 entries per user.

**Methodology:**

- Pre-populate user vault to target size
- Execute single write and single read
- Record both latencies

**Why:** Each entry stored as separate file; O(1) per-entry design means latency should NOT increase with vault size (tests this assumption).

**Results:** Flat line across all sizes confirms design: ~1200ms write, ~700ms read regardless of vault size.

---

## B5: Recovery Time After Chunk Server Failure (`b5_recovery.csv`)

**What:** Recovery latency after stopping chunk2, writing 1/5/10/20 entries offline, restarting chunk2, polling `/health` endpoint.

**Methodology:**

- Kill chunk2 via `systemctl stop`
- Write missed entries (lost from failed node)
- Restart chunk2 via `systemctl start`
- Measure time until `/health` reports 3 chunks alive
- Verify data written during outage is readable

**Why:** Write-Ahead Log (WAL) replay must catch failed node up; verifies zero data loss and maximum recovery time.

**Results:** ~47,000ms show WAL replay takes 47 seconds even with small miss count; all data verified intact ✓

---

## B6: Read/Write Success Under Node Failure (`b6_availability.csv`)

**What:** 5 read and 5 write operations executed while (a) replica-down (chunk2) and (b) primary-down (chunk1).

**Methodology:**

- Stop target chunk via `systemctl stop`
- Wait 9s for master to detect failure
- Execute 5 `get` operations (read)
- Execute 5 `save` operations (write)
- Count successes, then restart chunk

**Why:** Demonstrates CP model (Consistency-Partition tolerance): replica loss = no impact, PRIMARY loss = writes fail (quorum broken).

**Results:**

- **Replica down:** 5/5 reads ✓, 5/5 writes ✓ (still quorum)
- **Primary down:** 5/5 reads ✓, 0/5 writes ✗ (no quorum, writes rejected)

---

## B7: Write Throughput Under Concurrent Load (`b7_concurrent.csv`)

**What:** 5, 10, and 20 concurrent client processes each execute login + save in parallel, measure batch completion time.

**Methodology:**

- Spawn N background processes with unique save commands
- Wait for all to complete
- Measure total wall clock time
- Calculate ops/sec = N × 1000 / time

**Why:** Shows system efficiency under realistic load; saturation point indicates server bottleneck (master or chunks).

**Results:**

- 5 clients: 1.8s for batch = 2.7 ops/sec
- 10 clients: 2.6s for batch = 3.8 ops/sec
- 20 clients: 4.2s for batch = 4.7 ops/sec (saturation)

---

## B8: Authentication Latency (`b8_login_latency.csv`)

**What:** 10 trials of login command (bcrypt password hash validation + PBKDF2 100K key derivation rounds).

**Methodology:**

- Client calls `login` command
- Measure round-trip time for credential validation and session establishment
- Repeat multiple times to show consistency

**Why:** Authentication intentionally slow via 100K PBKDF2 iterations to resist brute-force; demonstrates security-latency tradeoff.

**Results:** Values ~530ms average show PBKDF2 accounts for ~50% of write latency (1100ms write − 530ms login ≈ 570ms for replication/encryption).
