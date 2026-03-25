package master

import "sync"

// Metadata tracks the primary chunk server and the global sequence counter.
type Metadata struct {
	mu        sync.RWMutex
	primary   string // chunkID of current primary
	preferred string // configured preferred primary for auto-failback
	seqNum    uint64 // global sequence counter
	epoch     uint64 // fencing epoch for single active master
}

func NewMetadata(primaryID string, epoch uint64) *Metadata {
	return &Metadata{primary: primaryID, preferred: primaryID, epoch: epoch}
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

func (m *Metadata) Epoch() uint64 {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.epoch
}

func (m *Metadata) PreferredPrimaryID() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.preferred
}

func (m *Metadata) SetPrimary(newPrimaryID string) (uint64, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if newPrimaryID == "" || newPrimaryID == m.primary {
		return m.epoch, false
	}
	m.primary = newPrimaryID
	m.epoch++
	return m.epoch, true
}
