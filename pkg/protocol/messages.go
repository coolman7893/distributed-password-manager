package protocol

import "encoding/gob"

func init() {
	gob.Register(HeartbeatMsg{})
	gob.Register(WriteRequest{})
	gob.Register(WriteResponse{})
	gob.Register(ReadRequest{})
	gob.Register(ReadResponse{})
	gob.Register(DeleteRequest{})
	gob.Register(DeleteResponse{})
	gob.Register(ReplicateRequest{})
	gob.Register(ReplicateResponse{})
	gob.Register(GetPrimaryRequest{})
	gob.Register(GetPrimaryResponse{})
	gob.Register(GetChunkRequest{})
	gob.Register(GetChunkResponse{})
	gob.Register(RegisterChunkRequest{})
	gob.Register(RegisterChunkResponse{})
	gob.Register(RecoveryResponse{})
	gob.Register(ListKeysRequest{})
	gob.Register(ListKeysResponse{})
	gob.Register(WALNotify{})
}

// --- Heartbeat ---

type HeartbeatMsg struct {
	ChunkID string
	Addr    string
}

// --- Chunk registration ---

type RegisterChunkRequest struct {
	ChunkID    string
	Addr       string
	LastSeqNum uint64
}

type RegisterChunkResponse struct {
	OK bool
}

// --- Master: who is the primary for writes? ---

type GetPrimaryRequest struct {
	Key string
}

type GetPrimaryResponse struct {
	PrimaryAddr string
	Replicas    []string
	SeqNum      uint64 // next sequence number assigned by master
}

// --- Master: give me a healthy chunk to READ from ---

type GetChunkRequest struct {
	Key string
}

type GetChunkResponse struct {
	Addr string
	OK   bool
}

// --- Write to primary chunk server ---

type WriteRequest struct {
	Key    string
	Value  []byte
	SeqNum uint64
}

type WriteResponse struct {
	OK     bool
	SeqNum uint64
	Err    string
}

// --- Delete ---

type DeleteRequest struct {
	Key    string
	SeqNum uint64
}

type DeleteResponse struct {
	OK  bool
	Err string
}

// --- Primary → Replica replication ---

type ReplicateRequest struct {
	Key    string
	Value  []byte
	SeqNum uint64
	Delete bool
}

type ReplicateResponse struct {
	OK  bool
	Err string
}

// --- Read ---

type ReadRequest struct {
	Key string
}

type ReadResponse struct {
	Value  []byte
	OK     bool
	SeqNum uint64
}

// --- Recovery ---

type RecoveryEntry struct {
	Key    string
	Value  []byte
	SeqNum uint64
	Delete bool
}

type RecoveryResponse struct {
	Entries []RecoveryEntry
}

// --- List keys ---

type ListKeysRequest struct {
	Prefix string
}

type ListKeysResponse struct {
	Keys []string
}

// --- WAL notification (client → master after successful write) ---

type WALNotify struct {
	Key    string
	Value  []byte
	SeqNum uint64
	Delete bool
}
