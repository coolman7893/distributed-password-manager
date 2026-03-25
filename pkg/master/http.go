package master

// http.go — REST API layer bolted onto the master node.
//
// Endpoints:
//   POST   /auth/register
//   POST   /auth/login
//   POST   /auth/logout
//   GET    /vault/list
//   GET    /vault/get?site=…
//   POST   /vault/save
//   DELETE /vault/delete
//   GET    /health
//   GET    /           → serves the built React frontend (web/dist)

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coolman7893/distributed-password-manager/pkg/vault"
)

// ─── session store ────────────────────────────────────────────────────────────

type httpSession struct {
	username  string
	vaultKey  []byte
	createdAt time.Time
}

type sessionStore struct {
	mu       sync.RWMutex
	sessions map[string]*httpSession
}

func newSessionStore() *sessionStore {
	s := &sessionStore{sessions: make(map[string]*httpSession)}
	go func() {
		t := time.NewTicker(10 * time.Minute)
		defer t.Stop()
		for range t.C {
			s.mu.Lock()
			for id, sess := range s.sessions {
				if time.Since(sess.createdAt) > 24*time.Hour {
					delete(s.sessions, id)
				}
			}
			s.mu.Unlock()
		}
	}()
	return s
}

func (s *sessionStore) create(username string, vaultKey []byte) string {
	b := make([]byte, 16)
	rand.Read(b)
	id := hex.EncodeToString(b)
	s.mu.Lock()
	s.sessions[id] = &httpSession{username: username, vaultKey: vaultKey, createdAt: time.Now()}
	s.mu.Unlock()
	return id
}

func (s *sessionStore) get(id string) (*httpSession, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.sessions[id]
	return sess, ok
}

func (s *sessionStore) delete(id string) {
	s.mu.Lock()
	delete(s.sessions, id)
	s.mu.Unlock()
}

// ─── HTTPServer ───────────────────────────────────────────────────────────────

// UserStoreIface is the subset of auth.UserStore used by HTTPServer.
// *auth.UserStore satisfies this interface; declared here to avoid a circular import.
type UserStoreIface interface {
	Register(username, password string) error
	Login(username, password string) (vaultKey []byte, salt []byte, err error)
}

// HTTPServer is the REST + static-file server embedded in the master node.
type HTTPServer struct {
	// Addr is the HTTPS listen address, e.g. ":8443".
	Addr string

	// MasterAddr is the TCP address of the master's gob server, e.g. "localhost:9000".
	MasterAddr string
	// MasterAddrs are candidate endpoints for the single active master.
	MasterAddrs []string

	// TLSConfig is shared with the master (same cert/key/CA).
	TLSConfig *tls.Config

	// UserStore is shared with the master so HTTP register/login hits the same file.
	UserStore UserStoreIface

	// StaticDir is the path to the built React app (web/dist).
	// Leave empty to disable the static file handler.
	StaticDir string

	// RegistryProbe is an optional func the master injects so /health can report
	// live chunk counts without coupling HTTPServer to Registry directly.
	RegistryProbe func() int

	sessions *sessionStore
}

// StartHTTP launches the HTTPS server in a background goroutine.
func (h *HTTPServer) StartHTTP() {
	h.sessions = newSessionStore()

	mux := http.NewServeMux()

	mux.HandleFunc("POST /auth/register", h.handleRegister)
	mux.HandleFunc("POST /auth/login", h.handleLogin)
	mux.HandleFunc("POST /auth/logout", h.handleLogout)
	mux.HandleFunc("GET /vault/list", h.requireSession(h.handleList))
	mux.HandleFunc("GET /vault/get", h.requireSession(h.handleGet))
	mux.HandleFunc("POST /vault/save", h.requireSession(h.handleSave))
	mux.HandleFunc("DELETE /vault/delete", h.requireSession(h.handleDelete))
	mux.HandleFunc("GET /health", h.handleHealth)

	if h.StaticDir != "" {
		fs := http.FileServer(http.Dir(h.StaticDir))
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			if _, err := http.Dir(h.StaticDir).Open(r.URL.Path); err != nil {
				http.ServeFile(w, r, h.StaticDir+"/index.html")
				return
			}
			fs.ServeHTTP(w, r)
		})
	}

	srv := &http.Server{
		Addr:      h.Addr,
		Handler:   corsMiddleware(mux),
		TLSConfig: h.TLSConfig,
	}

	log.Printf("[master:http] listening on https://%s  (static: %q)", h.Addr, h.StaticDir)
	go func() {
		if err := srv.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			log.Printf("[master:http] fatal: %v", err)
		}
	}()
}

// ─── middleware ───────────────────────────────────────────────────────────────

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin == "" {
			origin = "*"
		}
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type ctxKey string

const ctxSession ctxKey = "session"

func (h *HTTPServer) requireSession(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("vault_session")
		if err != nil {
			jsonError(w, "not authenticated", http.StatusUnauthorized)
			return
		}
		sess, ok := h.sessions.get(cookie.Value)
		if !ok {
			jsonError(w, "session expired", http.StatusUnauthorized)
			return
		}
		ctx := context.WithValue(r.Context(), ctxSession, sess)
		next(w, r.WithContext(ctx))
	}
}

func sessionFrom(r *http.Request) *httpSession {
	s, _ := r.Context().Value(ctxSession).(*httpSession)
	return s
}

// ─── auth handlers ────────────────────────────────────────────────────────────

func (h *HTTPServer) handleRegister(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Username == "" || body.Password == "" {
		jsonError(w, "username and password required", http.StatusBadRequest)
		return
	}
	if err := h.UserStore.Register(body.Username, body.Password); err != nil {
		jsonError(w, err.Error(), http.StatusConflict)
		return
	}
	jsonOK(w, map[string]string{"message": "registered successfully"})
}

func (h *HTTPServer) handleLogin(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	vaultKey, _, err := h.UserStore.Login(body.Username, body.Password)
	if err != nil {
		jsonError(w, "invalid credentials", http.StatusUnauthorized)
		return
	}
	id := h.sessions.create(body.Username, vaultKey)
	http.SetCookie(w, &http.Cookie{
		Name:     "vault_session",
		Value:    id,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   86400,
	})
	jsonOK(w, map[string]string{"message": "logged in", "username": body.Username})
}

func (h *HTTPServer) handleLogout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("vault_session"); err == nil {
		h.sessions.delete(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: "vault_session", Value: "", Path: "/", MaxAge: -1})
	jsonOK(w, map[string]string{"message": "logged out"})
}

// ─── vault handlers ───────────────────────────────────────────────────────────

func (h *HTTPServer) newVaultClient(sess *httpSession) *vault.Client {
	client := &vault.Client{
		MasterAddr: h.MasterAddr,
		TLSConfig:  h.TLSConfig,
		VaultKey:   sess.vaultKey,
		Username:   sess.username,
	}
	if len(h.MasterAddrs) > 0 {
		client.MasterAddrs = h.MasterAddrs
	}
	return client
}

func (h *HTTPServer) handleList(w http.ResponseWriter, r *http.Request) {
	sites, err := h.newVaultClient(sessionFrom(r)).List()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if sites == nil {
		sites = []string{}
	}
	jsonOK(w, map[string]interface{}{"sites": sites})
}

func (h *HTTPServer) handleGet(w http.ResponseWriter, r *http.Request) {
	site := r.URL.Query().Get("site")
	if site == "" {
		jsonError(w, "site query param required", http.StatusBadRequest)
		return
	}
	entry, err := h.newVaultClient(sessionFrom(r)).Get(site)
	if err != nil {
		jsonError(w, err.Error(), http.StatusNotFound)
		return
	}
	jsonOK(w, entry)
}

func (h *HTTPServer) handleSave(w http.ResponseWriter, r *http.Request) {
	var body vault.PasswordEntry
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Site == "" || body.Username == "" || body.Password == "" {
		jsonError(w, "site, username and password required", http.StatusBadRequest)
		return
	}
	if err := h.newVaultClient(sessionFrom(r)).Save(body); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"message": "saved"})
}

func (h *HTTPServer) handleDelete(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Site string `json:"site"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Site == "" {
		jsonError(w, "site required", http.StatusBadRequest)
		return
	}
	if err := h.newVaultClient(sessionFrom(r)).Delete(body.Site); err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"message": "deleted"})
}

// ─── health ───────────────────────────────────────────────────────────────────

func (h *HTTPServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	chunks := 0
	if h.RegistryProbe != nil {
		chunks = h.RegistryProbe()
	}
	jsonOK(w, map[string]interface{}{"status": "ok", "chunks": chunks})
}

// ─── helpers ─────────────────────────────────────────────────────────────────

func jsonOK(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
