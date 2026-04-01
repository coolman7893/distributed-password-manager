package crypto

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"os"
)

// LoadTLSConfig returns a *tls.Config for either server or client use.
func LoadTLSConfig(certFile, keyFile, caFile string, isServer bool) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load key pair: %w", err)
	}

	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("read CA cert: %w", err)
	}
	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to add CA cert")
	}

	cfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
		RootCAs:      caPool,
		ServerName:   "localhost", // default; will be overridden for remote connections
	}

	if isServer {
		cfg.ClientCAs = caPool
		cfg.ClientAuth = tls.RequireAndVerifyClientCert
	}
	return cfg, nil
}

// PrepareClientTLSConfig clones the TLS config and sets the ServerName based on the target address.
// This ensures certificate validation succeeds when connecting to remote hosts with IP addresses or hostnames.
func PrepareClientTLSConfig(cfg *tls.Config, targetAddr string) *tls.Config {
	// Clone the config
	newCfg := cfg.Clone()

	// Extract hostname from address (format: "host:port")
	host, _, err := net.SplitHostPort(targetAddr)
	if err != nil {
		// If we can't split (malformed address), use the whole string as hostname
		host = targetAddr
	}

	// Try to parse as IP address first
	ip := net.ParseIP(host)
	if ip != nil {
		// For IP addresses, use a generic server name that exists in the certificate SANs
		// All our certificates have "localhost" and DNS names in SANs
		newCfg.ServerName = "localhost"
	} else {
		// For hostnames, use the hostname directly
		newCfg.ServerName = host
	}

	// Ensure ServerName is never empty (Go's TLS requires either ServerName or InsecureSkipVerify)
	if newCfg.ServerName == "" {
		newCfg.ServerName = "localhost"
	}

	return newCfg
}
