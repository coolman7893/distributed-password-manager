# Generate self-signed TLS certificates for the Distributed Password Manager
# Run from the project root: .\gen-certs.ps1

$ErrorActionPreference = "Stop"
$CERT_DIR = ".\certs"

# Use Git for Windows openssl if system openssl isn't on PATH
$openssl = "openssl"
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    $gitOpenssl = "C:\Program Files\Git\usr\bin\openssl.exe"
    if (Test-Path $gitOpenssl) {
        $openssl = $gitOpenssl
    } else {
        Write-Host "ERROR: openssl not found. Install Git for Windows or add openssl to PATH." -ForegroundColor Red
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $CERT_DIR | Out-Null

Write-Host "Generating CA key + cert..."
& $openssl genrsa -out "$CERT_DIR\ca-key.pem" 4096 2>$null
& $openssl req -new -x509 -days 365 -key "$CERT_DIR\ca-key.pem" `
  -out "$CERT_DIR\ca-cert.pem" -subj "/CN=DistPWM-CA"

# Create a temp SAN config file (PowerShell can't use process substitution like bash)
$sanConfig = @"
[req]
distinguished_name = req_dn
[req_dn]
[v3_ext]
subjectAltName=DNS:localhost,DNS:master,DNS:chunk1,DNS:chunk2,DNS:chunk3,IP:127.0.0.1
"@
$sanFile = "$CERT_DIR\san.cnf"
Set-Content -Path $sanFile -Value $sanConfig

Write-Host "Generating server key + cert..."
& $openssl genrsa -out "$CERT_DIR\server-key.pem" 2048 2>$null
& $openssl req -new -key "$CERT_DIR\server-key.pem" `
  -out "$CERT_DIR\server.csr" -subj "/CN=localhost"
& $openssl x509 -req -days 365 -in "$CERT_DIR\server.csr" `
  -CA "$CERT_DIR\ca-cert.pem" -CAkey "$CERT_DIR\ca-key.pem" `
  -CAcreateserial -out "$CERT_DIR\server-cert.pem" `
  -extfile $sanFile -extensions v3_ext

Write-Host "Generating client key + cert..."
& $openssl genrsa -out "$CERT_DIR\client-key.pem" 2048 2>$null
& $openssl req -new -key "$CERT_DIR\client-key.pem" `
  -out "$CERT_DIR\client.csr" -subj "/CN=client"
& $openssl x509 -req -days 365 -in "$CERT_DIR\client.csr" `
  -CA "$CERT_DIR\ca-cert.pem" -CAkey "$CERT_DIR\ca-key.pem" `
  -CAcreateserial -out "$CERT_DIR\client-cert.pem"

# Clean up temp files
Remove-Item -Force "$CERT_DIR\*.csr", "$CERT_DIR\*.srl", $sanFile -ErrorAction SilentlyContinue

Write-Host "Certificates generated in $CERT_DIR" -ForegroundColor Green
