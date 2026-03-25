# Distributed Password Manager on a GFS-like Fault Tolerant System

A distributed password manager inspired by Google File System ideas, with client-side encryption and replicated storage across chunk servers.

Current implementation includes:

- master endpoint failover for CLI and chunk servers
- master epoch fencing to reject stale leader writes
- automatic chunk primary promotion when primary fails
- automatic failback to preferred primary when it recovers
- frontend API failover between two master HTTP gateways in dev mode
- clear UI state when auth is up but storage backend is unavailable

Built for CMPT 756 Distributed and Cloud Systems.

---

## Architecture Overview

```
                CLI / Web Client
                        |
                        | HTTPS (REST) and TLS (gob)
                        v
         +-------------------------------+
         | Active Master (9000 / 8443)  |
         | - chunk registry + liveness  |
         | - seq number allocator       |
         | - epoch + primary selection  |
         | - WAL                         |
         +-------------------------------+
                 ^                \
                 | failover list   \ standby endpoint
         +-------------------------------+
         | Standby Master (9100 / 9443) |
         +-------------------------------+

                chunk1   chunk2   chunk3
                 9001     9002     9003
                  |         |         |
                  +---------+---------+
                    replicated encrypted data
```

Notes:

- Master stores metadata, liveness, WAL, and sequencing. It does not store plaintext passwords.
- Chunk servers store encrypted entries on disk.
- Clients encrypt and decrypt locally.

---

## Security Model

- password hashing: bcrypt
- key derivation: PBKDF2-HMAC-SHA256
- entry encryption: AES-256-GCM (client-side)
- gob transport between nodes: mTLS, TLS 1.3
- HTTP gateway transport: TLS 1.2+ for browser compatibility

---

## Major Features Implemented

### 1) Master endpoint failover

- chunk server and CLI support a list of candidate masters via -masters
- on connectivity loss, they try next endpoint and re-register

### 2) Primary chunk automatic re-election

- when primary chunk is down, master promotes a new primary automatically
- election rule: highest LastSeq, tie-break by chunk ID

### 3) Automatic failback

- preferred primary from startup flag -primary is tracked
- when that chunk recovers and is healthy, master fails back automatically

### 4) Epoch fencing

- write path includes epoch values
- stale epoch writes are rejected on chunk servers

### 5) Frontend failover (dev mode)

- Vite proxies:
  - /m1 -> https://localhost:8443
  - /m2 -> https://localhost:9443
- web API client retries between both targets and remembers last healthy one

### 6) Storage unavailable UX

- login can still work when chunks are down (auth is master-backed)
- vault screen clearly shows storage backend unavailable (0 healthy chunks)
- write actions are disabled while no healthy chunks are available

---

## Project Structure

```
cmd/
  master/main.go
  chunkserver/main.go
  client/main.go
pkg/
  auth/
  chunk/
  crypto/
  master/
  protocol/
  vault/
scripts/
  demo_auto_failover.ps1
  test_correctness.ps1
  test_correctness.sh
  deploy-gcp.sh
web/
  src/
  vite.config.ts
```

---

## Prerequisites

- Go 1.22+
- Node.js 20+
- certificates generated in certs/

Generate certs:

Windows:

```powershell
.\gen-certs.ps1
```

Linux or macOS:

```bash
bash gen-certs.sh
```

---

## Build

Windows:

```powershell
go build -o .\bin\master.exe .\cmd\master
go build -o .\bin\chunk.exe .\cmd\chunkserver
go build -o .\bin\client.exe .\cmd\client
```

---

## Run: Single-Master Basic Mode

Master:

```powershell
.\bin\master.exe -addr :9000 -primary chunk1 -wal .\data\master\wal.json -http :8443 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem -users .\data\users.json
```

Chunk servers:

```powershell
.\bin\chunk.exe -id chunk1 -addr :9001 -master localhost:9000 -data .\data\chunk1 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem
.\bin\chunk.exe -id chunk2 -addr :9002 -master localhost:9000 -data .\data\chunk2 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem
.\bin\chunk.exe -id chunk3 -addr :9003 -master localhost:9000 -data .\data\chunk3 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem
```

CLI:

```powershell
.\bin\client.exe -master localhost:9000 -cert .\certs\client-cert.pem -key .\certs\client-key.pem -ca .\certs\ca-cert.pem
```

---

## Run: Failover Mode (Active + Standby Masters)

Master 1 (active):

```powershell
.\bin\master.exe -addr :9000 -primary chunk1 -epoch 100 -wal .\data\master\wal-shared.json -users .\data\users.json -http :8443 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem
```

Master 2 (standby endpoint):

```powershell
.\bin\master.exe -addr :9100 -primary chunk1 -epoch 200 -wal .\data\master\wal-shared.json -users .\data\users.json -http :9443 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem
```

Chunk servers (with candidate masters):

```powershell
.\bin\chunk.exe -id chunk1 -addr :9001 -master localhost:9000 -masters localhost:9000,localhost:9100 -data .\data\chunk1 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem
.\bin\chunk.exe -id chunk2 -addr :9002 -master localhost:9000 -masters localhost:9000,localhost:9100 -data .\data\chunk2 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem
.\bin\chunk.exe -id chunk3 -addr :9003 -master localhost:9000 -masters localhost:9000,localhost:9100 -data .\data\chunk3 -cert .\certs\server-cert.pem -key .\certs\server-key.pem -ca .\certs\ca-cert.pem
```

CLI (with candidate masters):

```powershell
.\bin\client.exe -master localhost:9000 -masters localhost:9000,localhost:9100 -cert .\certs\client-cert.pem -key .\certs\client-key.pem -ca .\certs\ca-cert.pem
```

Kill active master only:

```powershell
$pid9000 = (Get-NetTCPConnection -LocalPort 9000 -State Listen).OwningProcess
Stop-Process -Id $pid9000 -Force
```

Expected:

- chunk servers re-register to master2
- CLI continues working via fallback
- UI continues in dev mode via /m2 proxy path

---

## Frontend

Run dev server:

```powershell
cd .\web
npm install
npm run dev
```

Open:

- http://localhost:3000

Important behavior:

- login can succeed even if chunks are down
- vault data operations require healthy chunk servers
- UI now shows explicit storage unavailable status instead of silent empty list

---

## Scripts

- scripts/demo_auto_failover.ps1
  - starts active and standby masters, starts chunks, performs client operations
  - kills active master and verifies continued reads

- scripts/test_correctness.ps1 and scripts/test_correctness.sh
  - CRUD, replication, failure scenarios, and concurrency checks

- scripts/deploy-gcp.sh
  - deploys topology to GCP VMs

---

## Health and Troubleshooting

Health probes:

```powershell
curl.exe -k https://localhost:8443/health
curl.exe -k https://localhost:9443/health
```

If neither responds:

- master process is not running or failed startup

If login works but vault looks empty:

- check chunk health
- with no healthy chunks, this is expected and now shown in UI

If UI fails while CLI works during failover:

- restart Vite after config changes
- ensure masters are on 8443 and 9443

---

## Current Limitations

- HTTP auth sessions are in-memory per master process
- after master switch, web users may need to log in again
- docker-compose.yml currently describes a single-master topology (not dual-master failover mode)

---

## License

Academic project for CMPT 756.
