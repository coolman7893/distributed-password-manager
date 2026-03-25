package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/gorilla/mux"
	"github.com/rs/cors"

	"github.com/coolman7893/distributed-password-manager/pkg/auth"
	"github.com/coolman7893/distributed-password-manager/pkg/crypto"
	"github.com/coolman7893/distributed-password-manager/pkg/vault"
)

type Server struct {
	userStore *auth.UserStore
	jwtSecret []byte
	masterAddr string
	tlsConfig  *tls.Config
	vaultKeys  map[string][]byte // username -> vault key
}

type Claims struct {
	Username string `json:"username"`
	jwt.RegisteredClaims
}

type RegisterRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type SaveRequest struct {
	Site     string `json:"site"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type PasswordEntry struct {
	Site     string `json:"site"`
	Username string `json:"username"`
	Password string `json:"password"`
}

func main() {
	// Initialize user store
	dataDir := "./data"
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		log.Fatal("Failed to create data directory:", err)
	}

	userStore, err := auth.NewUserStore(filepath.Join(dataDir, "users.json"))
	if err != nil {
		log.Fatal("Failed to initialize user store:", err)
	}

	// Load TLS config
	tlsConfig, err := crypto.LoadTLSConfig("certs/client-cert.pem", "certs/client-key.pem", "certs/ca-cert.pem", false)
	if err != nil {
		log.Fatal("Failed to load TLS config:", err)
	}

	server := &Server{
		userStore:  userStore,
		jwtSecret:  []byte("your-secret-key"), // In production, use env var
		masterAddr: "localhost:9000",
		tlsConfig:  tlsConfig,
		vaultKeys:  make(map[string][]byte),
	}

	r := mux.NewRouter()

	// Public routes
	r.HandleFunc("/register", server.registerHandler).Methods("POST")
	r.HandleFunc("/login", server.loginHandler).Methods("POST")

	// Protected routes
	r.HandleFunc("/save", server.authMiddleware(server.saveHandler)).Methods("POST")
	r.HandleFunc("/get/{site}", server.authMiddleware(server.getHandler)).Methods("GET")
	r.HandleFunc("/list", server.authMiddleware(server.listHandler)).Methods("GET")
	r.HandleFunc("/delete/{site}", server.authMiddleware(server.deleteHandler)).Methods("DELETE")

	// CORS
	c := cors.New(cors.Options{
		AllowedOrigins:   []string{"http://localhost:3000"}, // React dev server
		AllowedMethods:   []string{"GET", "POST", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"*"},
		AllowCredentials: true,
	})

	handler := c.Handler(r)

	fmt.Println("Server starting on :8080")
	log.Fatal(http.ListenAndServe(":8080", handler))
}

func (s *Server) registerHandler(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	if err := s.userStore.Register(req.Username, req.Password); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"message": "Registered successfully"})
}

func (s *Server) loginHandler(w http.ResponseWriter, r *http.Request) {
	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	vaultKey, _, err := s.userStore.Login(req.Username, req.Password)
	if err != nil {
		http.Error(w, err.Error(), http.StatusUnauthorized)
		return
	}

	// Store vault key
	s.vaultKeys[req.Username] = vaultKey

	// Create JWT token
	claims := Claims{
		Username: req.Username,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(24 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	tokenString, err := token.SignedString(s.jwtSecret)
	if err != nil {
		http.Error(w, "Failed to create token", http.StatusInternalServerError)
		return
	}

	// Store vault key in memory (in production, use secure session store)
	// For simplicity, we'll derive it on each request

	json.NewEncoder(w).Encode(map[string]string{"token": tokenString})
}

func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			http.Error(w, "Missing token", http.StatusUnauthorized)
			return
		}

		tokenString := strings.TrimPrefix(authHeader, "Bearer ")
		claims := &Claims{}

		token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
			return s.jwtSecret, nil
		})

		if err != nil || !token.Valid {
			http.Error(w, "Invalid token", http.StatusUnauthorized)
			return
		}

		// Add username to context
		r.Header.Set("Username", claims.Username)
		next(w, r)
	}
}

func (s *Server) saveHandler(w http.ResponseWriter, r *http.Request) {
	username := r.Header.Get("Username")

	var req SaveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	vaultKey, ok := s.vaultKeys[username]
	if !ok {
		http.Error(w, "Not logged in", http.StatusUnauthorized)
		return
	}

	// Create vault client
	vaultClient, err := vault.NewClient(s.masterAddr, s.tlsConfig, vaultKey, username)
	if err != nil {
		http.Error(w, "Failed to create vault client", http.StatusInternalServerError)
		return
	}

	entry := vault.PasswordEntry{
		Site:     req.Site,
		Username: req.Username,
		Password: req.Password,
	}

	if err := vaultClient.Save(entry); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]string{"message": "Saved successfully"})
}

func (s *Server) getHandler(w http.ResponseWriter, r *http.Request) {
	username := r.Header.Get("Username")
	vars := mux.Vars(r)
	site := vars["site"]

	vaultKey, ok := s.vaultKeys[username]
	if !ok {
		http.Error(w, "Not logged in", http.StatusUnauthorized)
		return
	}

	// Create vault client
	vaultClient, err := vault.NewClient(s.masterAddr, s.tlsConfig, vaultKey, username)
	if err != nil {
		http.Error(w, "Failed to create vault client", http.StatusInternalServerError)
		return
	}

	entry, err := vaultClient.Get(site)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(entry)
}

func (s *Server) listHandler(w http.ResponseWriter, r *http.Request) {
	username := r.Header.Get("Username")

	vaultKey, ok := s.vaultKeys[username]
	if !ok {
		http.Error(w, "Not logged in", http.StatusUnauthorized)
		return
	}

	// Create vault client
	vaultClient, err := vault.NewClient(s.masterAddr, s.tlsConfig, vaultKey, username)
	if err != nil {
		http.Error(w, "Failed to create vault client", http.StatusInternalServerError)
		return
	}

	sites, err := vaultClient.List()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string][]string{"sites": sites})
}

func (s *Server) deleteHandler(w http.ResponseWriter, r *http.Request) {
	username := r.Header.Get("Username")
	vars := mux.Vars(r)
	site := vars["site"]

	vaultKey, ok := s.vaultKeys[username]
	if !ok {
		http.Error(w, "Not logged in", http.StatusUnauthorized)
		return
	}

	// Create vault client
	vaultClient, err := vault.NewClient(s.masterAddr, s.tlsConfig, vaultKey, username)
	if err != nil {
		http.Error(w, "Failed to create vault client", http.StatusInternalServerError)
		return
	}

	if err := vaultClient.Delete(site); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]string{"message": "Deleted successfully"})
}