package main

import (
	"crypto/tls"
	"flag"
	"log"
	"os"
	"path/filepath"

	"github.com/coolman7893/distributed-password-manager/pkg/auth"
	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
	"github.com/coolman7893/distributed-password-manager/pkg/master"
)

func main() {
	addr := flag.String("addr", ":9000", "Listen address (gob/TLS)")
	httpAddr := flag.String("http", ":8443", "HTTPS listen address for REST API + web UI (empty to disable)")
	primaryID := flag.String("primary", "chunk1", "Primary chunk ID")
	walPath := flag.String("wal", "./data/master/wal.json", "WAL file path")
	certFile := flag.String("cert", "certs/server-cert.pem", "TLS cert")
	keyFile := flag.String("key", "certs/server-key.pem", "TLS key")
	caFile := flag.String("ca", "certs/ca-cert.pem", "CA cert")
	usersFile := flag.String("users", "./data/users.json", "User store path")
	staticDir := flag.String("static", "./web/dist", "Path to built React frontend (web/dist)")
	flag.Parse()

	// Ensure data directory exists
	if err := os.MkdirAll(filepath.Dir(*walPath), 0700); err != nil {
		log.Fatalf("Create data dir: %v", err)
	}

	tlsCfg, err := appCrypto.LoadTLSConfig(*certFile, *keyFile, *caFile, true)
	if err != nil {
		log.Fatalf("TLS: %v", err)
	}

	wal, err := master.NewWAL(*walPath)
	if err != nil {
		log.Fatalf("WAL: %v", err)
	}

	userStore, err := auth.NewUserStore(*usersFile)
	if err != nil {
		log.Fatalf("User store: %v", err)
	}

	registry := master.NewRegistry()

	srv := &master.Server{
		Addr:      *addr,
		Registry:  registry,
		Meta:      master.NewMetadata(*primaryID),
		WAL:       wal,
		TLSConfig: tlsCfg,
	}

	// Start the REST API + web UI server if -http is set.
	if *httpAddr != "" {
		// Keep strict mTLS for the gob server, but allow normal HTTPS clients
		// (browser + Vite proxy) on the REST/web endpoint.
		httpTLSCfg := tlsCfg.Clone()
		httpTLSCfg.ClientAuth = tls.NoClientCert
		httpTLSCfg.ClientCAs = nil

		httpSrv := &master.HTTPServer{
			Addr:       *httpAddr,
			MasterAddr: "localhost" + *addr,
			TLSConfig:  httpTLSCfg,
			UserStore:  userStore,
			StaticDir:  *staticDir,
			RegistryProbe: func() int {
				return len(registry.AliveChunks())
			},
		}
		httpSrv.StartHTTP()
	}

	log.Fatal(srv.Start())
}
