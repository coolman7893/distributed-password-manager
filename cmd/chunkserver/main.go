package main

import (
	"flag"
	"log"
	"strings"

	"github.com/coolman7893/distributed-password-manager/pkg/chunk"
	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
)

func main() {
	id := flag.String("id", "chunk1", "Chunk server ID")
	addr := flag.String("addr", ":9001", "Listen address")
	masterAddr := flag.String("master", "localhost:9000", "Master address")
	masters := flag.String("masters", "", "Comma-separated master addresses for failover (optional)")
	dataDir := flag.String("data", "./data/chunk1", "Data directory")
	certFile := flag.String("cert", "certs/server-cert.pem", "TLS cert")
	keyFile := flag.String("key", "certs/server-key.pem", "TLS key")
	caFile := flag.String("ca", "certs/ca-cert.pem", "CA cert")
	flag.Parse()

	tlsCfg, err := appCrypto.LoadTLSConfig(*certFile, *keyFile, *caFile, true)
	if err != nil {
		log.Fatalf("TLS config: %v", err)
	}

	store, err := chunk.NewStore(*dataDir)
	if err != nil {
		log.Fatalf("Store init: %v", err)
	}

	masterAddrs := []string{}
	if strings.TrimSpace(*masters) != "" {
		for _, candidate := range strings.Split(*masters, ",") {
			candidate = strings.TrimSpace(candidate)
			if candidate != "" {
				masterAddrs = append(masterAddrs, candidate)
			}
		}
	}

	srv := &chunk.Server{
		ID:          *id,
		Addr:        *addr,
		MasterAddr:  *masterAddr,
		MasterAddrs: masterAddrs,
		Store:       store,
		TLSConfig:   tlsCfg,
	}
	log.Fatal(srv.Start())
}
