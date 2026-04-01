package main

import (
	"flag"
	"log"

	"github.com/coolman7893/distributed-password-manager/pkg/chunk"
	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
)

func main() {
	id := flag.String("id", "chunk1", "Chunk server ID")
	addr := flag.String("addr", ":9001", "Listen address (e.g., :9001)")
	regAddr := flag.String("regaddr", "", "Registration address for master (e.g., 10.128.0.5:9001). If empty, uses -addr")
	masterAddr := flag.String("master", "localhost:9000", "Master address")
	dataDir := flag.String("data", "./data/chunk1", "Data directory")
	certFile := flag.String("cert", "certs/server-cert.pem", "TLS cert")
	keyFile := flag.String("key", "certs/server-key.pem", "TLS key")
	caFile := flag.String("ca", "certs/ca-cert.pem", "CA cert")
	flag.Parse()

	// Use regAddr if provided, otherwise fall back to addr
	registerAddr := *regAddr
	if registerAddr == "" {
		registerAddr = *addr
	}

	tlsCfg, err := appCrypto.LoadTLSConfig(*certFile, *keyFile, *caFile, true)
	if err != nil {
		log.Fatalf("TLS config: %v", err)
	}

	store, err := chunk.NewStore(*dataDir)
	if err != nil {
		log.Fatalf("Store init: %v", err)
	}

	srv := &chunk.Server{
		ID:         *id,
		Addr:       *addr,
		RegAddr:    registerAddr,
		MasterAddr: *masterAddr,
		Store:      store,
		TLSConfig:  tlsCfg,
	}
	log.Fatal(srv.Start())
}
