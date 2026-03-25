package master

import "sync"

// Metadata tracks the primary chunk server and the global sequence counter.
type Metadata struct {
	mu      sync.RWMutex
	primary string // chunkID of current primary
	seqNum  uint64 // global sequence counter
}

func NewMetadata(primaryID string) *Metadata {
	return &Metadata{primary: primaryID}
}

func (m *Metadata) PrimaryID() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.primary
}

func (m *Metadata) NextSeqNum() uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.seqNum++
	return m.seqNum
}

func (m *Metadata) CurrentSeqNum() uint64 {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.seqNum
}

func (m *Metadata) SetSeqNum(n uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if n > m.seqNum {
		m.seqNum = n
	}
}
