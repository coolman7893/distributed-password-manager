package auth

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
)

// User represents a registered user account.
type User struct {
	Username     string `json:"username"`
	PasswordHash []byte `json:"password_hash"`
	Salt         []byte `json:"salt"`
}

// UserStore manages user accounts persisted to a JSON file.
type UserStore struct {
	mu    sync.RWMutex
	path  string
	users map[string]*User
}

func NewUserStore(path string) (*UserStore, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &UserStore{path: path, users: make(map[string]*User)}
	data, err := os.ReadFile(path)
	if err == nil && len(data) > 0 {
		json.Unmarshal(data, &s.users)
	}
	return s, nil
}

func (s *UserStore) Register(username, password string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.users[username]; exists {
		return fmt.Errorf("user already exists")
	}

	hash, err := appCrypto.HashPassword(password)
	if err != nil {
		return err
	}

	salt, err := appCrypto.GenerateSalt()
	if err != nil {
		return err
	}

	s.users[username] = &User{
		Username:     username,
		PasswordHash: hash,
		Salt:         salt,
	}
	return s.persist()
}

// Login verifies the password and returns the derived vault key.
func (s *UserStore) Login(username, password string) (vaultKey []byte, salt []byte, err error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	user, ok := s.users[username]
	if !ok {
		return nil, nil, fmt.Errorf("user not found")
	}

	if err := appCrypto.CheckPassword(user.PasswordHash, password); err != nil {
		return nil, nil, fmt.Errorf("invalid password")
	}

	key := appCrypto.DeriveKey(password, user.Salt)
	return key, user.Salt, nil
}

// GetUser returns the user struct for the given username.
func (s *UserStore) GetUser(username string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	user, ok := s.users[username]
	if !ok {
		return nil, fmt.Errorf("user not found")
	}

	return user, nil
}

func (s *UserStore) persist() error {
	data, err := json.Marshal(s.users)
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0600)
}
