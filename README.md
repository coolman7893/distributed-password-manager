# Distributed Password Manager on a GFS-like Fault Tolerant System

A fault-tolerant password manager built on a distributed storage layer inspired by the [Google File System (GFS)](https://research.google/pubs/pub51/). Passwords are encrypted client-side with AES-256-GCM before being replicated across three chunk servers, so the servers never see plaintext credentials. The system continues operating even when chunk servers crash, and crashed servers automatically recover missed writes on restart.

Built for **CMPT 756 — Distributed and Cloud Systems**.

---

## Architecture

```
  Client (CLI)
       │
       │  TLS 1.3 (gob-encoded messages)
       ▼
┌─────────────────────────────────┐
│         MASTER NODE (:9000)     │
│  • Chunk server registry        │
│  • Heartbeat monitor (6s timeout)│
│  • Primary lease tracking       │
│  • Write-ahead log (WAL)        │
│  • Sequence number assignment   │
│  (stores NO password data)      │
└──────┬──────────┬──────────┬────┘
       │          │          │
       ▼          ▼          ▼
  ┌────────┐ ┌────────┐ ┌────────┐
  │ CHUNK1 │ │ CHUNK2 │ │ CHUNK3 │
  │(primary)│ │(replica)│ │(replica)│
  │ :9001  │ │ :9002  │ │ :9003  │
  └────────┘ └────────┘ └────────┘
       │          ▲          ▲
       └──────────┴──────────┘
         Primary replicates
         writes with seq numbers
```

### Components

| Component | Role |
|-----------|------|
| **Master Node** | Lightweight coordinator. Tracks which chunk servers are alive via heartbeats, assigns sequence numbers, maintains a WAL for crash recovery. Stores no password data. |
| **Chunk Servers (×3)** | Store encrypted password blobs on disk. The primary receives writes and replicates to the other two. Replicas only accept writes from the primary with sequence numbers newer than what they already have. |
| **Client (CLI)** | Interactive command-line tool. Encrypts passwords locally with AES-256-GCM before sending to storage. Decrypts locally on retrieval. The vault key never leaves the client. |

---

## Security Design

| Layer | Mechanism |
|-------|-----------|
| **Password hashing** | bcrypt (cost 10) for user master passwords |
| **Vault key derivation** | PBKDF2-HMAC-SHA256 (100,000 iterations) from master password + random salt |
| **Entry encryption** | AES-256-GCM with random nonce — encrypted client-side before data leaves the machine |
| **Transport** | Mutual TLS 1.3 on every connection (server ↔ server and client ↔ server) |
| **Zero-knowledge storage** | Chunk servers only store encrypted blobs; they cannot read passwords |

---

## Project Structure

```
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
│   ├── deploy-gcp.sh           # Google Cloud deployment script
│   └── test_correctness.sh     # Automated correctness tests
├── certs/                      # TLS certificates (generated, gitignored)
├── data/                       # Runtime data (gitignored)
├── gen-certs.ps1               # Certificate generation (Windows/PowerShell)
├── gen-certs.sh                # Certificate generation (Linux/macOS)
├── Dockerfile
├── docker-compose.yml
├── go.mod
└── go.sum
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
go build -o master.exe ./cmd/master
go build -o chunk.exe ./cmd/chunkserver
go build -o client.exe ./cmd/client
```

On Linux/macOS, omit the `.exe` extension.

### 4. Start the system

Open **four** terminals:

**Terminal 1 — Master:**
```bash
./master -addr :9000 -primary chunk1 \
  -wal ./data/master/wal.json \
  -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem
```

**Terminal 2 — Chunk Server 1 (primary):**
```bash
./chunk -id chunk1 -addr :9001 -master localhost:9000 \
  -data ./data/chunk1 \
  -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem
```

**Terminal 3 — Chunk Server 2:**
```bash
./chunk -id chunk2 -addr :9002 -master localhost:9000 \
  -data ./data/chunk2 \
  -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem
```

**Terminal 4 — Chunk Server 3:**
```bash
./chunk -id chunk3 -addr :9003 -master localhost:9000 \
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

Open http://localhost:3000 in your browser.

Notes:
- The built frontend is also served by the master on `https://localhost:8443` (default `-http` in `cmd/master/main.go`).
- The master HTTPS REST/web endpoint accepts normal HTTPS clients (no browser client certificate setup required).
- For straightforward local validation, the CLI flow below is recommended.

### 6. Quick End-to-End CLI Validation (recommended)

In a fifth terminal:

```bash
./client -master localhost:9000 \
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

See [scripts/deploy-gcp.sh](scripts/deploy-gcp.sh) for automated deployment to 4 GCE VMs across different zones.

```bash
export GCP_PROJECT=your-project-id
bash scripts/deploy-gcp.sh
```

This creates:
- 1 master VM in `us-central1-a`
- 3 chunk server VMs in `us-east1-b`, `us-west1-a`, `europe-west1-b`

Each chunk server is in a **different zone/region** so a single data center failure only takes down one replica.

---

## Docker Compose (Alternative)

If Docker is available:

```bash
docker compose up --build
```

This starts the master and 3 chunk servers on a single machine for local testing.

---

## Key Design Decisions

| Problem | Solution |
|---------|----------|
| Master knows chunk health | Heartbeats every 2s; dead after 6s of silence |
| Write ordering across replicas | Master assigns global sequence numbers; replicas reject stale writes |
| Crashed server recovery | WAL on master; chunk reports last seq on re-register; master replays missed entries |
| Data confidentiality | AES-256-GCM encryption on client before data leaves the machine |
| Transport security | Mutual TLS 1.3 on all connections |
| Password authentication | bcrypt hash on disk; vault key derived via PBKDF2, held in memory only during session |

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
