#!/bin/bash
# Generate a self-signed CA, then server & client certs signed by it
set -e
CERT_DIR="./certs"
mkdir -p "$CERT_DIR"

# 1. CA key + cert
openssl genrsa -out "$CERT_DIR/ca-key.pem" 4096
openssl req -new -x509 -days 365 -key "$CERT_DIR/ca-key.pem" \
  -out "$CERT_DIR/ca-cert.pem" -subj "/CN=DistPWM-CA"

# 2. Server key + cert (used by master & chunk servers)
openssl genrsa -out "$CERT_DIR/server-key.pem" 2048
openssl req -new -key "$CERT_DIR/server-key.pem" \
  -out "$CERT_DIR/server.csr" -subj "/CN=localhost"
openssl x509 -req -days 365 -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" \
  -CAcreateserial -out "$CERT_DIR/server-cert.pem" \
  -extfile <(echo "subjectAltName=DNS:localhost,IP:127.0.0.1")

# 3. Client key + cert
openssl genrsa -out "$CERT_DIR/client-key.pem" 2048
openssl req -new -key "$CERT_DIR/client-key.pem" \
  -out "$CERT_DIR/client.csr" -subj "/CN=client"
openssl x509 -req -days 365 -in "$CERT_DIR/client.csr" \
  -CA "$CERT_DIR/ca-cert.pem" -CAkey "$CERT_DIR/ca-key.pem" \
  -CAcreateserial -out "$CERT_DIR/client-cert.pem"

rm -f "$CERT_DIR"/*.csr "$CERT_DIR"/*.srl
echo "Certificates generated in $CERT_DIR"