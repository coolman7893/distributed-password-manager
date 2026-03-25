package chunk

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// Entry is a single stored value with its sequence number.
type Entry struct {
	Value   []byte `json:"value"`
	SeqNum  uint64 `json:"seq_num"`
	Deleted bool   `json:"deleted,omitempty"`
}

// Store is a thread-safe on-disk key-value store for a chunk server.
type Store struct {
	mu      sync.RWMutex
	dir     string
	entries map[string]*Entry
	lastSeq uint64
}

func NewStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &Store{dir: dir, entries: make(map[string]*Entry)}
	if err := s.loadFromDisk(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Put(key string, value []byte, seqNum uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if existing, ok := s.entries[key]; ok && seqNum <= existing.SeqNum {
		return nil // already have this or newer
	}

	e := &Entry{Value: value, SeqNum: seqNum}
	s.entries[key] = e
	if seqNum > s.lastSeq {
		s.lastSeq = seqNum
	}
	return s.persistEntry(key, e)
}

func (s *Store) Delete(key string, seqNum uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if existing, ok := s.entries[key]; ok && seqNum <= existing.SeqNum {
		return nil
	}

	e := &Entry{Value: nil, SeqNum: seqNum, Deleted: true}
	s.entries[key] = e
	if seqNum > s.lastSeq {
		s.lastSeq = seqNum
	}
	return s.persistEntry(key, e)
}

func (s *Store) Get(key string) (*Entry, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	e, ok := s.entries[key]
	if !ok || e.Deleted {
		return nil, false
	}
	return e, true
}

func (s *Store) LastSeqNum() uint64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.lastSeq
}

func (s *Store) KeysWithPrefix(prefix string) []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var keys []string
	for k, e := range s.entries {
		if !e.Deleted && strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	return keys
}

func (s *Store) AllEntries() map[string]*Entry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	cp := make(map[string]*Entry, len(s.entries))
	for k, v := range s.entries {
		cp[k] = v
	}
	return cp
}

// --- Disk persistence ---

func (s *Store) persistEntry(key string, e *Entry) error {
	data, err := json.Marshal(e)
	if err != nil {
		return err
	}
	path := filepath.Join(s.dir, sanitize(key)+".json")
	return os.WriteFile(path, data, 0600)
}

func (s *Store) loadFromDisk() error {
	files, err := filepath.Glob(filepath.Join(s.dir, "*.json"))
	if err != nil {
		return err
	}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		var e Entry
		if err := json.Unmarshal(data, &e); err != nil {
			return fmt.Errorf("corrupt file %s: %w", f, err)
		}
		key := keyFromFilename(f)
		s.entries[key] = &e
		if e.SeqNum > s.lastSeq {
			s.lastSeq = e.SeqNum
		}
	}
	return nil
}

func sanitize(key string) string {
	var b strings.Builder
	for _, c := range key {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '-' || c == '_' {
			b.WriteRune(c)
		} else {
			fmt.Fprintf(&b, "_%02x", c)
		}
	}
	return b.String()
}

func keyFromFilename(path string) string {
	base := filepath.Base(path)
	raw := base[:len(base)-len(".json")]
	return unsanitize(raw)
}

func unsanitize(key string) string {
	var b strings.Builder
	for i := 0; i < len(key); i++ {
		if key[i] == '_' && i+2 < len(key) {
			h := key[i+1 : i+3]
			if v, err := strconv.ParseUint(h, 16, 8); err == nil {
				b.WriteByte(byte(v))
				i += 2
				continue
			}
		}
		b.WriteByte(key[i])
	}
	return b.String()
}
