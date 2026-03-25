package master

import (
	"crypto/tls"
	"log"
	"net"
	"sort"
	"sync/atomic"

	"github.com/coolman7893/distributed-password-manager/pkg/protocol"
)

// Server is the master node that coordinates chunk servers and clients.
type Server struct {
	Addr      string
	Registry  *Registry
	Meta      *Metadata
	WAL       *WAL
	TLSConfig *tls.Config
	readIdx   uint64 // for round-robin reads
}

func (s *Server) Start() error {
	// Restore sequence counter from WAL
	s.Meta.SetSeqNum(s.WAL.MaxSeqNum())

	listener, err := tls.Listen("tcp", s.Addr, s.TLSConfig)
	if err != nil {
		return err
	}
	log.Printf("[master] listening on %s (primary=%s)", s.Addr, s.Meta.PrimaryID())

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("[master] accept error: %v", err)
			continue
		}
		go s.handleConn(conn)
	}
}

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()

	msg, err := protocol.Receive(conn)
	if err != nil {
		return
	}

	switch req := msg.(type) {
	case protocol.HeartbeatMsg:
		s.Registry.Heartbeat(req.ChunkID, req.Addr, req.LastSeq)
		s.electPrimaryIfNeeded()

	case protocol.RegisterChunkRequest:
		s.handleRegister(conn, req)

	case protocol.GetPrimaryRequest:
		s.handleGetPrimary(conn, req)

	case protocol.GetChunkRequest:
		s.handleGetChunk(conn, req)

	case protocol.ListKeysRequest:
		s.handleListKeys(conn, req)

	case protocol.WALNotify:
		s.handleWALNotify(req)

	default:
		log.Printf("[master] unknown message: %T", msg)
	}
}

func choosePrimaryCandidate(alive []*ChunkInfo) *ChunkInfo {
	if len(alive) == 0 {
		return nil
	}

	ordered := append([]*ChunkInfo(nil), alive...)
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].LastSeq != ordered[j].LastSeq {
			return ordered[i].LastSeq > ordered[j].LastSeq
		}
		return ordered[i].ID < ordered[j].ID
	})
	return ordered[0]
}

func (s *Server) electPrimaryIfNeeded() (string, []string) {
	alive := s.Registry.AliveChunks()
	if len(alive) == 0 {
		return "", nil
	}

	currentPrimary := s.Meta.PrimaryID()
	preferredPrimary := s.Meta.PreferredPrimaryID()

	aliveByID := make(map[string]*ChunkInfo, len(alive))
	for _, c := range alive {
		aliveByID[c.ID] = c
	}

	if currentPrimary != "" {
		if _, ok := aliveByID[currentPrimary]; !ok {
			candidate := choosePrimaryCandidate(alive)
			if candidate != nil {
				if epoch, changed := s.Meta.SetPrimary(candidate.ID); changed {
					log.Printf("[master] PRIMARY_PROMOTED old=%s new=%s reason=primary-down epoch=%d candidateLastSeq=%d", currentPrimary, candidate.ID, epoch, candidate.LastSeq)
				}
			}
		}
	}

	// Auto-failback: if preferred primary is alive and not currently selected,
	// promote it back immediately.
	if preferredPrimary != "" && preferredPrimary != s.Meta.PrimaryID() {
		if preferred, ok := aliveByID[preferredPrimary]; ok {
			old := s.Meta.PrimaryID()
			if epoch, changed := s.Meta.SetPrimary(preferred.ID); changed {
				log.Printf("[master] PRIMARY_FAILBACK old=%s new=%s reason=preferred-recovered epoch=%d preferredLastSeq=%d", old, preferred.ID, epoch, preferred.LastSeq)
			}
		}
	}

	primaryID := s.Meta.PrimaryID()
	var primaryAddr string
	var replicas []string
	for _, c := range alive {
		if c.ID == primaryID {
			primaryAddr = c.Addr
		} else {
			replicas = append(replicas, c.Addr)
		}
	}

	return primaryAddr, replicas
}

func (s *Server) handleRegister(conn net.Conn, req protocol.RegisterChunkRequest) {
	s.Registry.Register(req.ChunkID, req.Addr, req.LastSeqNum)

	// Send missed writes for recovery
	missed := s.WAL.EntriesAfter(req.LastSeqNum)
	var entries []protocol.RecoveryEntry
	for _, e := range missed {
		entries = append(entries, protocol.RecoveryEntry{
			Key:    e.Key,
			Value:  e.Value,
			SeqNum: e.SeqNum,
			Delete: e.Delete,
		})
	}
	log.Printf("[master] sending %d recovery entries to chunk %s", len(entries), req.ChunkID)
	protocol.Send(conn, protocol.RecoveryResponse{Entries: entries})
}

func (s *Server) handleGetPrimary(conn net.Conn, req protocol.GetPrimaryRequest) {
	primaryAddr, replicas := s.electPrimaryIfNeeded()
	primaryID := s.Meta.PrimaryID()

	if primaryAddr == "" {
		log.Printf("[master] primary %s is DOWN — writes unavailable", primaryID)
		protocol.Send(conn, protocol.GetPrimaryResponse{PrimaryAddr: ""})
		return
	}

	seqNum := s.Meta.NextSeqNum()

	// Record in WAL (value will be filled by the notify call after write succeeds)
	protocol.Send(conn, protocol.GetPrimaryResponse{
		PrimaryAddr: primaryAddr,
		Replicas:    replicas,
		SeqNum:      seqNum,
		Epoch:       s.Meta.Epoch(),
	})
}

func (s *Server) handleGetChunk(conn net.Conn, req protocol.GetChunkRequest) {
	s.electPrimaryIfNeeded()

	alive := s.Registry.AliveChunks()
	if len(alive) == 0 {
		protocol.Send(conn, protocol.GetChunkResponse{OK: false})
		return
	}
	// Round-robin across alive chunks
	idx := atomic.AddUint64(&s.readIdx, 1)
	chosen := alive[int(idx)%len(alive)]
	protocol.Send(conn, protocol.GetChunkResponse{Addr: chosen.Addr, OK: true})
}

func (s *Server) handleListKeys(conn net.Conn, req protocol.ListKeysRequest) {
	s.electPrimaryIfNeeded()

	// Forward to any alive chunk
	alive := s.Registry.AliveChunks()
	if len(alive) == 0 {
		protocol.Send(conn, protocol.ListKeysResponse{})
		return
	}

	chunkAddr := alive[0].Addr
	chunkConn, err := tls.Dial("tcp", chunkAddr, s.TLSConfig)
	if err != nil {
		protocol.Send(conn, protocol.ListKeysResponse{})
		return
	}
	defer chunkConn.Close()

	protocol.Send(chunkConn, protocol.ListKeysRequest{Prefix: req.Prefix})
	resp, err := protocol.Receive(chunkConn)
	if err != nil {
		protocol.Send(conn, protocol.ListKeysResponse{})
		return
	}
	protocol.Send(conn, resp)
}

func (s *Server) handleWALNotify(req protocol.WALNotify) {
	if req.Epoch != s.Meta.Epoch() {
		log.Printf("[master] ignored stale WAL notify key=%s seq=%d epoch=%d current=%d", req.Key, req.SeqNum, req.Epoch, s.Meta.Epoch())
		return
	}
	s.WAL.Append(req.Key, req.Value, req.SeqNum, req.Delete)
	log.Printf("[master] WAL recorded key=%s seq=%d delete=%v", req.Key, req.SeqNum, req.Delete)
}
