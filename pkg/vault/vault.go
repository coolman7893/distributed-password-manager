package vault

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
	"github.com/coolman7893/distributed-password-manager/pkg/protocol"
)

// PasswordEntry is a single stored credential.
type PasswordEntry struct {
	Site     string `json:"site"`
	Username string `json:"username"`
	Password string `json:"password"`
}

// Client is the vault client that encrypts/decrypts on the client side
// and talks to the distributed chunk storage via the master node.
type Client struct {
	MasterAddr string
	// MasterAddrs are candidate endpoints for the single active master.
	MasterAddrs []string
	TLSConfig   *tls.Config
	VaultKey    []byte // derived from master password, in-memory only
	Username    string
	mu          sync.RWMutex
}

// NewClient creates a new vault client.
func NewClient(masterAddr string, tlsConfig *tls.Config, vaultKey []byte, username string) (*Client, error) {
	return &Client{
		MasterAddr:  masterAddr,
		MasterAddrs: []string{masterAddr},
		TLSConfig:   tlsConfig,
		VaultKey:    vaultKey,
		Username:    username,
	}, nil
}

func (c *Client) normalizedMasterAddrs() []string {
	if len(c.MasterAddrs) == 0 {
		if strings.TrimSpace(c.MasterAddr) == "" {
			return nil
		}
		return []string{c.MasterAddr}
	}

	seen := make(map[string]struct{})
	out := make([]string, 0, len(c.MasterAddrs)+1)
	for _, addr := range c.MasterAddrs {
		addr = strings.TrimSpace(addr)
		if addr == "" {
			continue
		}
		if _, ok := seen[addr]; ok {
			continue
		}
		seen[addr] = struct{}{}
		out = append(out, addr)
	}
	if len(out) == 0 && strings.TrimSpace(c.MasterAddr) != "" {
		out = append(out, c.MasterAddr)
	}
	return out
}

func (c *Client) currentMasterAddr() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.MasterAddr
}

func (c *Client) setCurrentMasterAddr(addr string) {
	c.mu.Lock()
	c.MasterAddr = addr
	c.mu.Unlock()
}

func (c *Client) dialAnyMaster() (*tls.Conn, string, error) {
	addrs := c.normalizedMasterAddrs()
	if len(addrs) == 0 {
		return nil, "", fmt.Errorf("no master address configured")
	}

	if current := strings.TrimSpace(c.currentMasterAddr()); current != "" {
		ordered := []string{current}
		for _, addr := range addrs {
			if addr != current {
				ordered = append(ordered, addr)
			}
		}
		addrs = ordered
	}

	var lastErr error
	for _, addr := range addrs {
		conn, err := tls.Dial("tcp", addr, c.TLSConfig)
		if err != nil {
			lastErr = err
			continue
		}
		c.setCurrentMasterAddr(addr)
		return conn, addr, nil
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("unable to connect to any configured master")
	}
	return nil, "", lastErr
}

// Save encrypts a password entry client-side, then writes it through the primary chunk.
func (c *Client) Save(entry PasswordEntry) error {
	plaintext, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	ciphertext, err := appCrypto.Encrypt(c.VaultKey, plaintext)
	if err != nil {
		return err
	}

	key := c.entryKey(entry.Site)

	// Ask master for primary + seq number
	primary, _, seqNum, epoch, err := c.getPrimary(key)
	if err != nil {
		return err
	}
	if primary == "" {
		return fmt.Errorf("primary unavailable — writes temporarily disabled")
	}

	// Write to primary (primary handles replication)
	conn, err := tls.Dial("tcp", primary, c.TLSConfig)
	if err != nil {
		return fmt.Errorf("connect to primary: %w", err)
	}
	defer conn.Close()

	protocol.Send(conn, protocol.WriteRequest{
		Key:    key,
		Value:  ciphertext,
		SeqNum: seqNum,
		Epoch:  epoch,
	})

	resp, err := protocol.Receive(conn)
	if err != nil {
		return err
	}
	writeResp, ok := resp.(protocol.WriteResponse)
	if !ok || !writeResp.OK {
		errMsg := "write failed"
		if ok {
			errMsg = writeResp.Err
		}
		return fmt.Errorf("%s", errMsg)
	}

	// Notify master to record in WAL
	c.notifyMasterWAL(key, ciphertext, seqNum, false, epoch)

	return nil
}

// Get reads a password entry from any healthy chunk, decrypts client-side.
func (c *Client) Get(site string) (*PasswordEntry, error) {
	key := c.entryKey(site)

	addr, err := c.getChunk(key)
	if err != nil {
		return nil, err
	}

	conn, err := tls.Dial("tcp", addr, c.TLSConfig)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	protocol.Send(conn, protocol.ReadRequest{Key: key})

	resp, err := protocol.Receive(conn)
	if err != nil {
		return nil, err
	}
	readResp, ok := resp.(protocol.ReadResponse)
	if !ok || !readResp.OK {
		return nil, fmt.Errorf("entry not found")
	}

	plaintext, err := appCrypto.Decrypt(c.VaultKey, readResp.Value)
	if err != nil {
		return nil, fmt.Errorf("decryption failed (wrong master password?): %w", err)
	}

	var entry PasswordEntry
	if err := json.Unmarshal(plaintext, &entry); err != nil {
		return nil, err
	}
	return &entry, nil
}

// Delete removes a password entry.
func (c *Client) Delete(site string) error {
	key := c.entryKey(site)

	primary, _, seqNum, epoch, err := c.getPrimary(key)
	if err != nil {
		return err
	}
	if primary == "" {
		return fmt.Errorf("primary unavailable")
	}

	conn, err := tls.Dial("tcp", primary, c.TLSConfig)
	if err != nil {
		return err
	}
	defer conn.Close()

	protocol.Send(conn, protocol.DeleteRequest{Key: key, SeqNum: seqNum, Epoch: epoch})

	resp, err := protocol.Receive(conn)
	if err != nil {
		return err
	}
	delResp, ok := resp.(protocol.DeleteResponse)
	if !ok || !delResp.OK {
		return fmt.Errorf("delete failed")
	}

	c.notifyMasterWAL(key, nil, seqNum, true, epoch)
	return nil
}

// List returns all site names stored for this user.
func (c *Client) List() ([]string, error) {
	prefix := c.Username + "/"

	conn, _, err := c.dialAnyMaster()
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	protocol.Send(conn, protocol.ListKeysRequest{Prefix: prefix})
	resp, err := protocol.Receive(conn)
	if err != nil {
		return nil, err
	}

	listResp, ok := resp.(protocol.ListKeysResponse)
	if !ok {
		return nil, fmt.Errorf("unexpected response")
	}

	var sites []string
	for _, k := range listResp.Keys {
		after := strings.TrimPrefix(k, prefix)
		if after != "" {
			sites = append(sites, after)
		}
	}
	return sites, nil
}

// --- helpers ---

func (c *Client) entryKey(site string) string {
	return c.Username + "/" + site
}

func (c *Client) getPrimary(key string) (string, []string, uint64, uint64, error) {
	conn, _, err := c.dialAnyMaster()
	if err != nil {
		return "", nil, 0, 0, err
	}
	defer conn.Close()

	protocol.Send(conn, protocol.GetPrimaryRequest{Key: key})
	resp, err := protocol.Receive(conn)
	if err != nil {
		return "", nil, 0, 0, err
	}
	r, ok := resp.(protocol.GetPrimaryResponse)
	if !ok {
		return "", nil, 0, 0, fmt.Errorf("unexpected response from master")
	}
	return r.PrimaryAddr, r.Replicas, r.SeqNum, r.Epoch, nil
}

func (c *Client) getChunk(key string) (string, error) {
	conn, _, err := c.dialAnyMaster()
	if err != nil {
		return "", err
	}
	defer conn.Close()

	protocol.Send(conn, protocol.GetChunkRequest{Key: key})
	resp, err := protocol.Receive(conn)
	if err != nil {
		return "", err
	}
	r, ok := resp.(protocol.GetChunkResponse)
	if !ok || !r.OK {
		return "", fmt.Errorf("no healthy chunk available")
	}
	return r.Addr, nil
}

// notifyMasterWAL tells the master to record the write in its WAL.
// This uses a separate message type — the master handles it via GetPrimary
// but we record the data by sending a write notification.
// For simplicity we re-use the WAL append path on the master side.
func (c *Client) notifyMasterWAL(key string, value []byte, seqNum uint64, isDelete bool, epoch uint64) {
	conn, _, err := c.dialAnyMaster()
	if err != nil {
		return
	}
	defer conn.Close()

	protocol.Send(conn, protocol.WALNotify{
		Key:    key,
		Value:  value,
		SeqNum: seqNum,
		Delete: isDelete,
		Epoch:  epoch,
	})
}
