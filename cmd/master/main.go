package main

import (
	"flag"
	"log"
	"os"
	"path/filepath"

	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
	"github.com/coolman7893/distributed-password-manager/pkg/master"
)

func main() {
	addr := flag.String("addr", ":9000", "Listen address")
	primaryID := flag.String("primary", "chunk1", "Primary chunk ID")
	walPath := flag.String("wal", "./data/master/wal.json", "WAL file path")
	certFile := flag.String("cert", "certs/server-cert.pem", "TLS cert")
	keyFile := flag.String("key", "certs/server-key.pem", "TLS key")
	caFile := flag.String("ca", "certs/ca-cert.pem", "CA cert")
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

	srv := &master.Server{
		Addr:      *addr,
		Registry:  master.NewRegistry(),
		Meta:      master.NewMetadata(*primaryID),
		WAL:       wal,
		TLSConfig: tlsCfg,
	}
	log.Fatal(srv.Start())
}
