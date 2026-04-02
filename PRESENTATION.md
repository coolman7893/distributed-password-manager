# Distributed Password Manager Presentation
## CMPT 756 — Distributed and Cloud Systems

---

# SLIDE 1: Title & Team

## **Distributed Password Manager on a GFS-like Fault-Tolerant System**

### Team Members:
- [Your Name 1]
- [Your Name 2]
- [Your Name 3]

### Course: CMPT 756 - Distributed and Cloud Systems

### Project Description:
- Fault-tolerant password manager built on a distributed storage layer inspired by Google File System (GFS)
- Master-replica architecture: single master node coordinates three chunk servers storing encrypted password data
- User authentication with bcrypt-hashed master password
- 256-bit AES encryption key derived via PBKDF2 with 100,000 iterations
- Client-side encryption with AES-256-GCM before transmission (zero-knowledge storage)
- Primary chunk server receives all writes and replicates to two replicas using sequence numbers for ordering
- Write-ahead log (WAL) on master enables automatic recovery when crashed servers rejoin
- All communication secured with mutual TLS 1.3

---

# SLIDE 2: System Functionality & Design

## Why a GFS-Inspired Architecture for Password Management?

### The Problem
Password data is **critical and irreplaceable** - if a centralized password store fails or is compromised, users lose access to all their accounts. Unlike typical files that can be recreated, passwords require fault tolerance and high availability above all else.

### What We Adapt from GFS (and Why)
| GFS Concept | Our Adaptation | Rationale |
|-------------|----------------|-----------|
| Master + Chunkservers | Master + 3 Chunk Servers | Separation of metadata (master) from data (chunks) enables independent scaling and prevents single point of failure |
| Replication (3 copies) | 3-way replication | Password data must survive server failures; 3 copies tolerate 1 failure |
| Write-Ahead Log | WAL on master | Enables crash recovery without data loss |
| Primary-based writes | Designated primary chunk | Ensures write ordering across replicas via sequence numbers |
| Heartbeat monitoring | 6-second timeout | Rapid failure detection for high availability |

### How Our Workload Differs from GFS
| Characteristic | GFS | Our System |
|----------------|-----|------------|
| File size | Large (multi-GB) | Small (~1-5 KB per user vault) |
| Access pattern | Sequential, append-heavy | Random read/write by key |
| Optimization goal | High throughput | Low latency, high availability |
| Data criticality | Recoverable | Irreplaceable credentials |

### Target Deployment & Performance
- **Data center setting**: Single region with 3 availability zones (one chunk per zone)
- **Target applications**: Personal/enterprise password vaults, credential sharing
- **Estimated data size**: ~1-5 KB per user (100 passwords x 50 bytes each)
- **Performance needs**: <100ms read latency, <500ms write latency (replication overhead)
- **Availability target**: 99.9% uptime (tolerate any single server failure)

## Purpose
Secure, distributed password management with:
- **Zero-knowledge architecture** - servers store only encrypted blobs
- **Fault tolerance** - system operates even when chunk servers crash
- **Automatic recovery** - crashed servers recover missed writes on restart

## Architecture
```
         Client (CLI / Web)
                │
                │  TLS 1.3 (mutual auth)
                ▼
    ┌───────────────────────────────┐
    │     MASTER NODE (:9000)       │
    │  • Chunk server registry      │
    │  • Heartbeat monitor (6s)     │
    │  • Write-ahead log (WAL)      │
    │  • Sequence number assignment │
    │  • NO password data stored    │
    └───────┬───────┬───────┬───────┘
            │       │       │
            ▼       ▼       ▼
       ┌────────┐ ┌────────┐ ┌────────┐
       │ CHUNK1 │ │ CHUNK2 │ │ CHUNK3 │
       │Primary │ │Replica │ │Replica │
       │ :9001  │ │ :9002  │ │ :9003  │
       └───┬────┘ └────▲───┘ └───▲────┘
           │           │         │
           └───────────┴─────────┘
             Primary → Replicas
             (with sequence numbers)
```

## Current Functionalities
| Feature | Description |
|---------|-------------|
| User Authentication | Register/login with bcrypt-hashed master passwords |
| Password CRUD | Create, read, update, delete encrypted credentials |
| 3-Way Replication | All writes replicated to 3 chunk servers |
| Fault Tolerance | Read/write continues with 2+ alive servers |
| Auto-Recovery | Missed writes synced via WAL on reconnect |
| Web & CLI Interface | React frontend + interactive CLI client |

---

# SLIDE 3: Implementation Details

## Technology Stack
| Layer | Technology |
|-------|------------|
| Language | Go 1.26.1 |
| Frontend | React + TypeScript + Vite |
| Transport | TLS 1.3 with mutual authentication |
| Serialization | Go's `encoding/gob` |
| Deployment | Docker Compose / Google Cloud |

## Security Implementation
| Layer | Mechanism |
|-------|-----------|
| Master Password | bcrypt (cost 10) |
| Vault Key | PBKDF2-HMAC-SHA256 (100,000 iterations) |
| Entry Encryption | AES-256-GCM with random nonce |
| Transport | Mutual TLS 1.3 (client to server, server to server) |
| Zero-Knowledge | Encryption happens client-side before transmission |

## Replication & Consistency
- **Primary-Based Replication**: Designated primary chunk receives all writes
- **Sequence Numbers**: Global counter assigned by master ensures ordering
- **WAL (Write-Ahead Log)**: Master logs all operations for crash recovery
- **Stale Write Rejection**: Replicas reject writes with lower sequence numbers

## Fault Tolerance Mechanisms
1. **Heartbeat Monitoring**: Master checks chunks every 3s, marks dead after 6s
2. **Automatic Failover**: Reads distributed across healthy replicas
3. **Recovery Protocol**: Crashed servers request missed entries from WAL on restart
4. **Idempotent Operations**: Sequence numbers prevent duplicate/reordered writes

---

# SLIDE 4: Results & Technical Challenges

## Metrics & Measurements

| Metric | Target | Achieved |
|--------|--------|----------|
| **Replication Factor** | 3 | 3 (all writes to 3 chunks) |
| **Fault Tolerance Level** | Survive 1 failure | ✓ System operates with 2/3 servers |
| **Recovery Time** | < 10s | ~2-3s (reconnect + WAL sync) |
| **Encryption Standard** | AES-256 | AES-256-GCM |
| **Key Derivation Iterations** | 100,000 | 100,000 (PBKDF2) |

## Correctness Validation
- **Test Suite**: Automated tests for write, read, delete, crash recovery
- **Consistency Check**: Verified all 3 chunks hold identical data after operations
- **Crash Recovery Test**: Confirmed data integrity after simulated failures

## Technical Challenges

| Challenge | Solution |
|-----------|----------|
| **Ordering Writes Across Replicas** | Implemented global sequence counter at master; replicas reject stale writes |
| **Detecting Server Failures** | Heartbeat protocol with 6-second timeout; health monitor runs every 3 seconds |
| **Recovering Missed Writes** | WAL stores all operations; chunk servers report last sequence on reconnect |
| **Mutual TLS in Dynamic Cluster** | Pre-generated certificates with wildcard SAN; runtime hostname resolution |
| **Client-Side Encryption** | PBKDF2 key derivation + AES-256-GCM; key never leaves client |

## Future Improvements
- Primary election (currently static)
- WAL compaction / garbage collection
- Enhanced monitoring dashboard
- Multi-datacenter replication

---

# Speaker Notes (Timing Guide)

## Slide 1 (~30 seconds)
- Introduce project name and team members
- Briefly state: "Distributed password manager inspired by Google File System"

## Slide 2 (~90-120 seconds)
- **Start with WHY**: "Why use GFS architecture for passwords? Password data is critical and irreplaceable - we need fault tolerance above all else"
- **What we take from GFS**: Master/chunk separation, 3-way replication, WAL, primary-based writes
- **How we differ**: Small files (~1-5KB), random access not sequential, optimize for latency not throughput
- **Deployment**: 3 availability zones, <100ms reads, 99.9% availability target
- Walk through architecture diagram: client -> master -> chunk servers
- Highlight: zero-knowledge storage, 3-way replication

## Slide 3 (~60-90 seconds)
- Focus on security: client-side encryption with AES-256-GCM
- Explain replication: primary-based with sequence numbers for ordering
- Mention: WAL for crash recovery, heartbeats for failure detection

## Slide 4 (~60-90 seconds)
- Show metrics: achieved 3-way replication, survives 1 server failure
- Discuss challenges: ordering writes (solved with sequence numbers), crash recovery (solved with WAL)
- If time: mention future work
