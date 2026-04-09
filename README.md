# Distributed Password Manager on a GFS-like Fault Tolerant System

A fault-tolerant password manager built on a distributed storage layer inspired by the [Google File System (GFS)](https://research.google/pubs/pub51/). Passwords are encrypted client-side with AES-256-GCM before being replicated across three chunk servers, so the servers never see plaintext credentials. The system continues operating even when chunk servers crash, and crashed servers automatically recover missed writes on restart.

Built for **CMPT 756 — Distributed and Cloud Systems**.

---

## Architecture

```text
  Client (CLI)
       │
       │  TLS 1.3 (gob-encoded messages)
       ▼
┌──────────────────────────────────┐
│         MASTER NODE (:9000)      │
│  • Chunk server registry         │
│  • Heartbeat monitor (6s timeout)│
│  • Primary lease tracking        │
│  • Write-ahead log (WAL)         │
│  • Sequence number assignment    │
│  (stores NO password data)       │
└──────┬───────────┬───────────┬───┘
       │           │           │
       ▼           ▼           ▼
  ┌─────────┐ ┌─────────┐ ┌─────────┐
  │ CHUNK1  │ │ CHUNK2  │ │ CHUNK3  │
  │(primary)│ │(replica)│ │(replica)│
  │ :9001   │ │ :9002   │ │ :9003   │
  └─────────┘ └─────────┘ └─────────┘
       │           ▲           ▲
       └───────────┴───────────┘
         Primary replicates
         writes with seq numbers
```

### Components

| Component              | Role                                                                                                                                                                                                       |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Master Node**        | Lightweight coordinator. Tracks which chunk servers are alive via heartbeats, assigns sequence numbers, maintains a WAL for crash recovery. Stores no password data.                                       |
| **Chunk Servers (×3)** | Store encrypted password blobs on disk. The primary receives writes and replicates to the other two. Replicas only accept writes from the primary with sequence numbers newer than what they already have. |
| **Client (CLI)**       | Interactive command-line tool. Encrypts passwords locally with AES-256-GCM before sending to storage. Decrypts locally on retrieval. The vault key never leaves the client.                                |

---

## Security Design

| Layer                      | Mechanism                                                                            |
| -------------------------- | ------------------------------------------------------------------------------------ |
| **Password hashing**       | bcrypt (cost 10) for user master passwords                                           |
| **Vault key derivation**   | PBKDF2-HMAC-SHA256 (100,000 iterations) from master password + random salt           |
| **Entry encryption**       | AES-256-GCM with random nonce — encrypted client-side before data leaves the machine |
| **Transport**              | Mutual TLS 1.3 on every connection (server ↔ server and client ↔ server)             |
| **Zero-knowledge storage** | Chunk servers only store encrypted blobs; they cannot read passwords                 |

---

## Project Structure

```text
distributed-password-manager/
├── cmd/
│   ├── master/main.go          # Master node entry point
│   ├── chunkserver/main.go     # Chunk server entry point
│   └── client/main.go          # Interactive CLI client
├── pkg/
│   ├── protocol/               # Shared gob message types + codec
│   │   ├── messages.go
│   │   └── codec.go
│   ├── crypto/                 # TLS, AES-256-GCM, bcrypt, PBKDF2
│   │   ├── hash.go
│   │   ├── tls.go
│   │   └── vault.go
│   ├── master/                 # Master node logic
│   │   ├── registry.go         # Chunk health tracking + heartbeat monitor
│   │   ├── metadata.go         # Primary lease + global sequence counter
│   │   ├── wal.go              # Write-ahead log for crash recovery
│   │   └── server.go           # Network handler
│   ├── chunk/                  # Chunk server logic
│   │   ├── store.go            # On-disk key-value store (JSON per key)
│   │   └── server.go           # Write, read, replicate, heartbeat
│   ├── auth/                   # User registration + login
│   │   └── auth.go
│   └── vault/                  # Client-side encrypt/decrypt + CRUD
│       └── vault.go
├── scripts/
│   ├── deploy-gcp.sh           # Automated GCP deployment (4 VMs across 3 zones)
│   ├── teardown-gcp.sh         # Clean up GCP resources
│   ├── connect.sh              # SSH helper for VM access and logs
│   ├── show-deployment-info.sh # Display deployment details and IPs
│   ├── show_status.py          # Python: real-time deployment status monitoring
│   ├── benchmark_gcp.sh        # Run performance benchmarks on GCP deployment
│   ├── benchmark_internal.sh   # Run performance benchmarks locally
│   ├── test_correctness.ps1    # PowerShell: automated correctness testing
│   ├── gen-certs.ps1/.sh       # Certificate generation (Windows/Linux/macOS)
│   └── (legacy scripts)        # Deprecated/replaced scripts
├── results/
│   ├── BENCHMARK_EXPLANATIONS.md # Detailed benchmark methodology & results analysis
│   ├── b1_zone_rtt.txt         # Network latency across zones
│   ├── b2_write_latency.csv    # Password write operation latency
│   ├── b3_read_latency.csv     # Password read operation latency
│   ├── b4_scalability.csv      # Latency vs vault size
│   ├── b5_recovery.csv         # Failure recovery performance
│   ├── b6_availability.csv     # Multi-zone availability metrics
│   ├── b7_concurrent.csv       # Concurrent operation performance
│   └── b8_login_latency.csv    # Login operation latency
├── web/                        # React frontend
│   ├── src/
│   ├── public/
│   ├── package.json
│   ├── tsconfig.json
│   └── vite.config.ts
├── certs/                      # TLS certificates (generated, gitignored)
├── data/                       # Runtime data (gitignored)
├── bin/                        # Compiled binaries
│   ├── windows/
│   └── linux/
├── Dockerfile
├── docker-compose.yml
├── go.mod
├── go.sum
├── requirements.txt            # Python dependencies for monitoring
└── gen-certs.ps1/.sh           # Certificate generation (Windows/Linux/macOS)
```

---

## Getting Started

### Prerequisites

- **Go 1.26.1+**
- **Node.js 20+** (for frontend build/dev)
- **OpenSSL** (included with [Git for Windows](https://gitforwindows.org/))

### 1. Clone the repository

```bash
git clone https://github.com/coolman7893/distributed-password-manager.git
cd distributed-password-manager
```

### 2. Generate TLS certificates

**Windows (PowerShell):**

```powershell
.\gen-certs.ps1
```

**Linux/macOS:**

```bash
bash gen-certs.sh
```

This creates mutual TLS certificates in `certs/`.

### 3. Build the binaries

```bash
mkdir -p bin
go build -o ./bin/master.exe ./cmd/master
go build -o ./bin/chunk.exe ./cmd/chunkserver
go build -o ./bin/client.exe ./cmd/client
```

On Linux/macOS, omit the `.exe` extension.

### 4. Start the system

Open **four** terminals:

**Terminal 1 — Master:**

```bash
./bin/master.exe -addr :9000 -primary chunk1 \
  -wal ./data/master/wal.json \
  -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem
```

**Terminal 2 — Chunk Server 1 (primary):**

```bash
./bin/chunk.exe -id chunk1 -addr :9001 -master localhost:9000 \
  -data ./data/chunk1 \
  -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem
```

**Terminal 3 — Chunk Server 2:**

```bash
./bin/chunk.exe -id chunk2 -addr :9002 -master localhost:9000 \
  -data ./data/chunk2 \
  -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem
```

**Terminal 4 — Chunk Server 3:**

```bash
./bin/chunk.exe -id chunk3 -addr :9003 -master localhost:9000 \
  -data ./data/chunk3 \
  -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem
```

### 5. Start the Frontend (optional)

```bash
cd web
npm install
npm run build
npm run dev
```

Open <http://localhost:3000> in your browser.

Notes:

- The built frontend is also served by the master on `https://localhost:8443` (default `-http` in `cmd/master/main.go`).
- The master HTTPS REST/web endpoint accepts normal HTTPS clients (no browser client certificate setup required).
- For straightforward local validation, the CLI flow below is recommended.
- If CLI and web logins disagree, make sure all services were restarted from freshly built `./bin/*` binaries.

### 6. Quick End-to-End CLI Validation (recommended)

In a fifth terminal:

```bash
./bin/client.exe -master localhost:9000 \
  -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem
```

Then run: `register`, `login`, `save`, `get`, `list`, `delete`.

### 7. Use the Web Interface

- **Register**: Create a new account with username and master password
- **Login**: Authenticate to access your vault
- **Save**: Store a new password entry (site, username, password)
- **Get**: Retrieve a password by site name
- **List**: View all stored sites
- **Delete**: Remove a password entry
- **Logout**: End session

---

## Fault Tolerance Demonstrations

### Test 1: Replica Failure + Recovery

1. Save a few passwords normally
2. Kill one replica (e.g., chunk3): `Stop-Process` or `kill`
3. Save more passwords — **writes still succeed** via the primary and remaining replica
4. Restart chunk3 — it re-registers with the master and **automatically recovers missed writes**
5. Master log shows: `sending N recovery entries to chunk chunk3`

### Test 2: Primary Failure

1. Kill the primary (chunk1)
2. Attempt to save — client reports: `primary unavailable — writes temporarily disabled`
3. Attempt to read — **reads still work** from chunk2 or chunk3
4. Restart chunk1 — writes resume immediately

### Test 3: Concurrent Writes

1. Open multiple client instances simultaneously
2. Save different passwords from each client at the same time
3. Run `list` — all entries are present with no data loss or corruption

### Test 4: Data Replication Verification

1. Save a password
2. Check each chunk server's `data/` directory — all three contain the same encrypted entry file
3. The encrypted contents are identical across replicas

---

## How It Works

### Write Path

1. Client encrypts the password entry with AES-256-GCM using a key derived from the master password
2. Client asks the master: "Who is the primary?"
3. Master responds with the primary address, replica addresses, and a new sequence number
4. Client sends the encrypted blob to the primary chunk server
5. Primary saves to disk, then replicates to both replicas with the sequence number
6. Replicas only apply the write if the sequence number is newer than what they have
7. Client notifies the master to record the write in the WAL (for future crash recovery)

### Read Path

1. Client asks the master for any healthy chunk server
2. Master returns a healthy chunk address (round-robin)
3. Client reads the encrypted blob from that chunk
4. Client decrypts locally with the vault key

### Crash Recovery

1. When a chunk server restarts, it re-registers with the master, reporting its last sequence number
2. The master checks its WAL and sends all entries with sequence numbers greater than what the chunk has
3. The chunk applies the missed writes and is fully caught up

### Heartbeat Monitoring

- Each chunk server sends a heartbeat to the master every **2 seconds**
- If the master doesn't receive a heartbeat for **6 seconds**, it marks the chunk as **DEAD**
- Dead chunks are excluded from read routing and replica lists

---

## Google Cloud Deployment

Automated deployment to Google Cloud Platform (GCP) with 4 VMs across 3 availability zones for high fault tolerance.

### GCP Prerequisites

Before running the deployment script, ensure you have:

- **Google Cloud SDK** (`gcloud` CLI) — [Install here](https://cloud.google.com/sdk/docs/install)
  - After installation, initialize and authenticate:

    ```bash
    gcloud init
    gcloud auth login
    ```

- **Go 1.22+** — [Install here](https://go.dev)
- **OpenSSL** — Usually pre-installed on Linux/macOS; included with [Git for Windows](https://gitforwindows.org/)
- **Node.js 20+** and **npm** (optional, for building the React frontend)
- **Active GCP project** with billing enabled
- **Appropriate IAM permissions** (Compute Instance Admin, Firewall Admin, Service Account User)

### Quick Start

1. **Set your GCP project:**

   ```bash
   export GCP_PROJECT=your-project-id
   ```

2. **Run the deployment script:**

   ```bash
   bash scripts/deploy-gcp.sh
   ```

The script will:

- Build Linux binaries for master, chunk servers, and client
- Build the React frontend (if Node.js available)
- Generate TLS certificates with subject alternative names (SANs) for all VM IPs
- Create 4 GCE VMs across 3 zones
- Set up firewall rules for internal and external traffic
- Upload binaries and certificates to all VMs
- Install and start systemd services on each VM
- Serve the frontend on the master HTTPS endpoint
- Provide connection commands and deployment summary

### Architecture Across Zones

```text
┌───────────────────────────────────────────────────────────────────┐
│                   Google Cloud Platform                           │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│     us-central1-a           us-east1-c            us-west4-a      │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐  │
│  │   MASTER VM     │   │   CHUNK1 VM     │   │   CHUNK2 VM     │  │
│  │   (e2-micro)    │   │   (e2-micro)    │   │   (e2-micro)    │  │
│  │ :9000 (gob)     │   │ :9001 (primary) │   │ :9002 (replica) │  │
│  │ :8443 (HTTPS)   │   │                 │   │                 │  │
│  │ + Web UI        │   │ Replicates from │   │ Receives from   │  │
│  │                 │   │ master, stores  │   │ primary, stores │  │
│  │ Stores:         │   │ encrypted data  │   │ encrypted data  │  │
│  │ - users.json    │   │                 │   │                 │  │
│  │ - WAL           │   │                 │   │                 │  │
│  │ - Sequence #s   │   │                 │   │                 │  │
│  └─────────────────┘   └─────────────────┘   └─────────────────┘  │
│                                                                   │
│                            us-central1-b                          │
│                        ┌─────────────────┐                        │
│                        │   CHUNK3 VM     │                        │
│                        │   (e2-micro)    │                        │
│                        │ :9003 (replica) │                        │
│                        │                 │                        │
│                        │ Receives from   │                        │
│                        │ primary, stores │                        │
│                        │ encrypted data  │                        │
│                        └─────────────────┘                        │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Deployment Configuration

| Setting        | Default    | Description                                                              |
| -------------- | ---------- | ------------------------------------------------------------------------ |
| `GCP_PROJECT`  | (required) | Your GCP project ID                                                      |
| `MACHINE_TYPE` | `e2-micro` | VM machine type (can override)                                           |
| `VM_PREFIX`    | `pwm`      | Prefix for VM names (pwm-master, pwm-chunk1, etc.)                       |
| `MASTER_PORT`  | `9000`     | Master gob port (internal only)                                          |
| `HTTP_PORT`    | `8443`     | Master HTTPS web UI port (public)                                        |
| **Zones**      | Fixed      | Master in us-central1-a; chunks in us-east1-c, us-west4-a, us-central1-b |

### After Deployment

The script displays connection commands. You can:

**Access the Web UI:**

```bash
https://<MASTER_EXTERNAL_IP>:8443
```

(Accept the self-signed certificate warning in your browser)

**Connect with CLI client:**

```bash
./bin/linux/client -master <MASTER_EXTERNAL_IP>:9000 \
  -cert certs/client-cert.pem \
  -key certs/client-key.pem \
  -ca certs/ca-cert.pem
```

**View live logs:**

```bash
bash scripts/connect.sh logs      # Master logs
bash scripts/connect.sh logs1     # Chunk1 logs
bash scripts/connect.sh logs2     # Chunk2 logs
bash scripts/connect.sh logs3     # Chunk3 logs
```

Or directly:

```bash
gcloud compute ssh pwm-master --zone=us-central1-a \
  --command="sudo journalctl -u pwm-master -f"
```

**Get deployment info:**

```bash
bash scripts/show-deployment-info.sh
```

**SSH into VMs:**

```bash
bash scripts/connect.sh <vm-number>  # 0=master, 1/2/3=chunks
# or
gcloud compute ssh pwm-master --zone=us-central1-a
```

### Benchmarking

After deployment, run benchmarks to measure performance:

```bash
bash scripts/benchmark_gcp.sh
```

This measures:

- **B1**: Network latency across zones
- **B2**: Password write latency (save + replicate)
- **B3**: Password read latency (single replica)
- **B4**: Latency vs vault size scalability
- **B5**: Recovery performance after failures
- **B6**: Multi-zone availability metrics
- **B7**: Concurrent operation performance
- **B8**: Login operation latency

Results are saved to `results/` with [detailed explanations](results/BENCHMARK_EXPLANATIONS.md).

### Cleanup

To remove all GCP resources and stop incurring charges:

```bash
bash scripts/teardown-gcp.sh
```

This deletes all VMs and firewall rules but preserves local certs and binaries.

---

## Local Testing (Docker Compose Alternative)

If deployment to GCP is not feasible, test locally with Docker Compose:

```bash
docker compose up --build
```

This starts the master and 3 chunk servers on a single machine in containers. Useful for development and correctness testing.

After the services start, you can:

- Access the web UI at `https://localhost:8443` (accept the self-signed cert warning)
- Connect a CLI client with `./bin/linux/client -master localhost:9000 -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem`
- Run correctness tests via `bash scripts/test_correctness.ps1` (Windows) or adapt for your shell

---

## Performance Benchmarks

Detailed results from GCP deployment are available in [results/BENCHMARK_EXPLANATIONS.md](results/BENCHMARK_EXPLANATIONS.md).

Key findings:

- **Write latency**: ~1110ms average (dominated by 3-way replication and network RTT)
- **Read latency**: ~750ms average (single replica read is 30% faster than writes)
- **Network impact**: Cross-zone RTT ranges from 0.8ms (same zone) to 176.8ms (opposite coasts)
- **Scalability**: Linear performance degradation as vault size increases
- **Recovery**: Crashed servers automatically recover missed writes within seconds

---

## Web UI & REST API

The master node exposes both a **REST API** and **static web UI** via HTTPS on port 8443 (configurable with `-http` flag).

### Public Endpoints

| Endpoint         | Method | Purpose                                      |
| ---------------- | ------ | -------------------------------------------- |
| `/auth/register` | POST   | User registration (username + password)      |
| `/auth/login`    | POST   | User authentication (returns session cookie) |
| `/`              | GET    | Serve React web UI (index.html)              |

### Example Usage

**Register:**

```bash
curl -k -X POST https://localhost:8443/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"mypassword"}'
```

**Login:**

```bash
curl -k -X POST https://localhost:8443/auth/login \
  -H "Content-Type: application/json" \
  -c cookies.txt \
  -d '{"username":"testuser","password":"mypassword"}'
```

**Web UI:**
Simply open `https://localhost:8443` in a browser and accept the self-signed certificate.

### Frontend Architecture

The React frontend (in `web/`) provides:

- Interactive user registration and login
- Password vault management (save, retrieve, list, delete)
- Session-based authentication
- Encrypted client-side operations (same AES-256-GCM encryption as CLI)

The built frontend is served by the master and interacts with the same REST endpoints used by the CLI client.

---

## Key Design Decisions

| Problem                        | Solution                                                                              |
| ------------------------------ | ------------------------------------------------------------------------------------- |
| Master knows chunk health      | Heartbeats every 2s; dead after 6s of silence                                         |
| Write ordering across replicas | Master assigns global sequence numbers; replicas reject stale writes                  |
| Crashed server recovery        | WAL on master; chunk reports last seq on re-register; master replays missed entries   |
| Data confidentiality           | AES-256-GCM encryption on client before data leaves the machine                       |
| Transport security             | Mutual TLS 1.3 on all connections                                                     |
| Password authentication        | bcrypt hash on disk; vault key derived via PBKDF2, held in memory only during session |
| CLI & Web interop              | Both share same user store (users.json on master) and REST auth endpoints             |

---

## Tech Stack

- **Language:** Go 1.22+
- **Serialization:** Go's built-in `encoding/gob` over TCP
- **Encryption:** AES-256-GCM (vault), bcrypt (passwords), PBKDF2-HMAC-SHA256 (key derivation)
- **Transport:** TLS 1.3 with mutual authentication
- **Storage:** JSON files on disk (one per key per chunk server)
- **Deployment:** Native binaries, Docker Compose, or Google Cloud VMs

---

## License

This project was built for academic purposes as part of CMPT 756.
