package master

import (
	"log"
	"sync"
	"time"
)

// ChunkInfo holds the state of a registered chunk server.
type ChunkInfo struct {
	ID       string
	Addr     string
	LastBeat time.Time
	Alive    bool
	LastSeq  uint64
}

// Registry tracks all chunk servers and their health via heartbeats.
type Registry struct {
	mu     sync.RWMutex
	chunks map[string]*ChunkInfo
}

func NewRegistry() *Registry {
	r := &Registry{chunks: make(map[string]*ChunkInfo)}
	go r.monitorHealth()
	return r
}

func (r *Registry) Register(id, addr string, lastSeq uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.chunks[id] = &ChunkInfo{
		ID:       id,
		Addr:     addr,
		LastBeat: time.Now(),
		Alive:    true,
		LastSeq:  lastSeq,
	}
	log.Printf("[master] registered chunk %s at %s (lastSeq=%d)", id, addr, lastSeq)
}

func (r *Registry) Heartbeat(id, addr string, lastSeq uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if c, ok := r.chunks[id]; ok {
		wasDown := !c.Alive
		c.LastBeat = time.Now()
		c.Alive = true
		c.Addr = addr
		if lastSeq > c.LastSeq {
			c.LastSeq = lastSeq
		}
		if wasDown {
			log.Printf("[master] chunk %s is back ALIVE", id)
		}
		return
	}

	// Accept first heartbeat as implicit registration so a fresh master
	// can rebuild liveness even if explicit RegisterChunk is delayed.
	r.chunks[id] = &ChunkInfo{
		ID:       id,
		Addr:     addr,
		LastBeat: time.Now(),
		Alive:    true,
		LastSeq:  lastSeq,
	}
	log.Printf("[master] inferred chunk %s at %s from heartbeat", id, addr)
}

func (r *Registry) AliveChunks() []*ChunkInfo {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var result []*ChunkInfo
	for _, c := range r.chunks {
		if c.Alive {
			result = append(result, c)
		}
	}
	return result
}

func (r *Registry) GetChunk(id string) (*ChunkInfo, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	c, ok := r.chunks[id]
	return c, ok
}

// monitorHealth marks chunks as dead if no heartbeat for 6 seconds.
func (r *Registry) monitorHealth() {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		r.mu.Lock()
		for _, c := range r.chunks {
			if c.Alive && time.Since(c.LastBeat) > 6*time.Second {
				c.Alive = false
				log.Printf("[master] chunk %s marked DEAD (no heartbeat)", c.ID)
			}
		}
		r.mu.Unlock()
	}
}
