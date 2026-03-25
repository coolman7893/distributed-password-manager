package master

import (
	"crypto/tls"
	"log"
	"net"
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
		s.Registry.Heartbeat(req.ChunkID, req.Addr)

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
	primaryID := s.Meta.PrimaryID()
	alive := s.Registry.AliveChunks()

	var primaryAddr string
	var replicas []string
	for _, c := range alive {
		if c.ID == primaryID {
			primaryAddr = c.Addr
		} else {
			replicas = append(replicas, c.Addr)
		}
	}

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
	})
}

func (s *Server) handleGetChunk(conn net.Conn, req protocol.GetChunkRequest) {
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
	s.WAL.Append(req.Key, req.Value, req.SeqNum, req.Delete)
	log.Printf("[master] WAL recorded key=%s seq=%d delete=%v", req.Key, req.SeqNum, req.Delete)
}
