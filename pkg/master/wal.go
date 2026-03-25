package master

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// WALEntry records a write for crash recovery.
type WALEntry struct {
	Key    string `json:"key"`
	Value  []byte `json:"value"`
	SeqNum uint64 `json:"seq_num"`
	Delete bool   `json:"delete,omitempty"`
}

// WAL is a simple write-ahead log persisted to a JSON file.
type WAL struct {
	mu      sync.Mutex
	path    string
	entries []WALEntry
}

func NewWAL(path string) (*WAL, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	w := &WAL{path: path}
	data, err := os.ReadFile(path)
	if err == nil && len(data) > 0 {
		json.Unmarshal(data, &w.entries)
	}
	return w, nil
}

func (w *WAL) Append(key string, value []byte, seqNum uint64, isDelete bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.entries = append(w.entries, WALEntry{
		Key:    key,
		Value:  value,
		SeqNum: seqNum,
		Delete: isDelete,
	})
	w.persist()
}

func (w *WAL) EntriesAfter(seqNum uint64) []WALEntry {
	w.mu.Lock()
	defer w.mu.Unlock()
	var result []WALEntry
	for _, e := range w.entries {
		if e.SeqNum > seqNum {
			result = append(result, e)
		}
	}
	return result
}

func (w *WAL) MaxSeqNum() uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	var max uint64
	for _, e := range w.entries {
		if e.SeqNum > max {
			max = e.SeqNum
		}
	}
	return max
}

func (w *WAL) persist() {
	data, _ := json.Marshal(w.entries)
	os.WriteFile(w.path, data, 0600)
}
