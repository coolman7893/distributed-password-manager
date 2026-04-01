package chunk

import (
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"time"

	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
	"github.com/coolman7893/distributed-password-manager/pkg/protocol"
)

// Server is a chunk server that stores encrypted password data.
type Server struct {
	ID         string
	Addr       string // Listen address (e.g., ":9001")
	RegAddr    string // Registration address advertised to master (e.g., "10.128.0.5:9001")
	MasterAddr string
	Store      *Store
	TLSConfig  *tls.Config
}

func (s *Server) Start() error {
	listener, err := tls.Listen("tcp", s.Addr, s.TLSConfig)
	if err != nil {
		return err
	}
	log.Printf("[chunk %s] listening on %s", s.ID, s.Addr)

	go s.registerAndHeartbeat()

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("[chunk %s] accept error: %v", s.ID, err)
			continue
		}
		go s.handleConn(conn)
	}
}

func (s *Server) handleConn(conn net.Conn) {
	defer conn.Close()

	msg, err := protocol.Receive(conn)
	if err != nil {
		log.Printf("[chunk %s] receive error: %v", s.ID, err)
		return
	}

	switch req := msg.(type) {
	case protocol.WriteRequest:
		s.handleWrite(conn, req)
	case protocol.ReadRequest:
		s.handleRead(conn, req)
	case protocol.DeleteRequest:
		s.handleDelete(conn, req)
	case protocol.ReplicateRequest:
		s.handleReplicate(conn, req)
	case protocol.ListKeysRequest:
		s.handleListKeys(conn, req)
	default:
		log.Printf("[chunk %s] unknown message type: %T", s.ID, msg)
	}
}

func (s *Server) handleWrite(conn net.Conn, req protocol.WriteRequest) {
	// Save locally
	if err := s.Store.Put(req.Key, req.Value, req.SeqNum); err != nil {
		protocol.Send(conn, protocol.WriteResponse{OK: false, Err: err.Error()})
		return
	}
	log.Printf("[chunk %s] wrote key=%s seq=%d", s.ID, req.Key, req.SeqNum)

	// Get replica addresses from master
	replicas := s.getReplicaAddrs(req.Key)

	// Replicate to each replica
	for _, addr := range replicas {
		if err := s.replicateTo(addr, req.Key, req.Value, req.SeqNum, false); err != nil {
			log.Printf("[chunk %s] replicate to %s failed: %v", s.ID, addr, err)
		}
	}

	protocol.Send(conn, protocol.WriteResponse{OK: true, SeqNum: req.SeqNum})
}

func (s *Server) handleRead(conn net.Conn, req protocol.ReadRequest) {
	entry, ok := s.Store.Get(req.Key)
	if !ok {
		protocol.Send(conn, protocol.ReadResponse{OK: false})
		return
	}
	protocol.Send(conn, protocol.ReadResponse{
		Value:  entry.Value,
		OK:     true,
		SeqNum: entry.SeqNum,
	})
}

func (s *Server) handleDelete(conn net.Conn, req protocol.DeleteRequest) {
	if err := s.Store.Delete(req.Key, req.SeqNum); err != nil {
		protocol.Send(conn, protocol.DeleteResponse{OK: false, Err: err.Error()})
		return
	}
	log.Printf("[chunk %s] deleted key=%s seq=%d", s.ID, req.Key, req.SeqNum)

	replicas := s.getReplicaAddrs(req.Key)
	for _, addr := range replicas {
		if err := s.replicateTo(addr, req.Key, nil, req.SeqNum, true); err != nil {
			log.Printf("[chunk %s] replicate delete to %s failed: %v", s.ID, addr, err)
		}
	}

	protocol.Send(conn, protocol.DeleteResponse{OK: true})
}

func (s *Server) handleReplicate(conn net.Conn, req protocol.ReplicateRequest) {
	var err error
	if req.Delete {
		err = s.Store.Delete(req.Key, req.SeqNum)
	} else {
		err = s.Store.Put(req.Key, req.Value, req.SeqNum)
	}
	if err != nil {
		protocol.Send(conn, protocol.ReplicateResponse{OK: false, Err: err.Error()})
		return
	}
	log.Printf("[chunk %s] replicated key=%s seq=%d delete=%v", s.ID, req.Key, req.SeqNum, req.Delete)
	protocol.Send(conn, protocol.ReplicateResponse{OK: true})
}

func (s *Server) handleListKeys(conn net.Conn, req protocol.ListKeysRequest) {
	keys := s.Store.KeysWithPrefix(req.Prefix)
	protocol.Send(conn, protocol.ListKeysResponse{Keys: keys})
}

// --- replication helper ---

func (s *Server) replicateTo(addr, key string, value []byte, seqNum uint64, isDelete bool) error {
	tlsCfg := appCrypto.PrepareClientTLSConfig(s.TLSConfig, addr)
	rc, err := tls.Dial("tcp", addr, tlsCfg)
	if err != nil {
		return err
	}
	defer rc.Close()

	protocol.Send(rc, protocol.ReplicateRequest{
		Key:    key,
		Value:  value,
		SeqNum: seqNum,
		Delete: isDelete,
	})
	resp, err := protocol.Receive(rc)
	if err != nil {
		return err
	}
	if r, ok := resp.(protocol.ReplicateResponse); ok && !r.OK {
		return fmt.Errorf("replica error: %s", r.Err)
	}
	return nil
}

func (s *Server) getReplicaAddrs(key string) []string {
	tlsCfg := appCrypto.PrepareClientTLSConfig(s.TLSConfig, s.MasterAddr)
	conn, err := tls.Dial("tcp", s.MasterAddr, tlsCfg)
	if err != nil {
		log.Printf("[chunk %s] cannot reach master for replicas: %v", s.ID, err)
		return nil
	}
	defer conn.Close()

	protocol.Send(conn, protocol.GetPrimaryRequest{Key: key})
	resp, err := protocol.Receive(conn)
	if err != nil {
		return nil
	}
	if r, ok := resp.(protocol.GetPrimaryResponse); ok {
		return r.Replicas
	}
	return nil
}

// --- heartbeat ---

func (s *Server) registerAndHeartbeat() {
	s.registerWithMaster()

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		s.sendHeartbeat()
	}
}

func (s *Server) registerWithMaster() {
	for {
		tlsCfg := appCrypto.PrepareClientTLSConfig(s.TLSConfig, s.MasterAddr)
		conn, err := tls.Dial("tcp", s.MasterAddr, tlsCfg)
		if err != nil {
			log.Printf("[chunk %s] failed to connect to master, retrying: %v", s.ID, err)
			time.Sleep(2 * time.Second)
			continue
		}

		protocol.Send(conn, protocol.RegisterChunkRequest{
			ChunkID:    s.ID,
			Addr:       s.RegAddr,
			LastSeqNum: s.Store.LastSeqNum(),
		})

		resp, err := protocol.Receive(conn)
		conn.Close()
		if err != nil {
			log.Printf("[chunk %s] register response error: %v", s.ID, err)
			time.Sleep(2 * time.Second)
			continue
		}

		if recovery, ok := resp.(protocol.RecoveryResponse); ok && len(recovery.Entries) > 0 {
			for _, entry := range recovery.Entries {
				if entry.Delete {
					s.Store.Delete(entry.Key, entry.SeqNum)
				} else {
					s.Store.Put(entry.Key, entry.Value, entry.SeqNum)
				}
			}
			log.Printf("[chunk %s] recovered %d entries from master", s.ID, len(recovery.Entries))
		}
		log.Printf("[chunk %s] registered with master", s.ID)
		return
	}
}

func (s *Server) sendHeartbeat() {
	tlsCfg := appCrypto.PrepareClientTLSConfig(s.TLSConfig, s.MasterAddr)
	conn, err := tls.Dial("tcp", s.MasterAddr, tlsCfg)
	if err != nil {
		log.Printf("[chunk %s] heartbeat failed: %v", s.ID, err)
		return
	}
	defer conn.Close()
	protocol.Send(conn, protocol.HeartbeatMsg{ChunkID: s.ID, Addr: s.RegAddr})
}
