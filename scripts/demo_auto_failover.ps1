param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$User = "testuser",
    [string]$Pass = "TestPass123!",
    [switch]$Rebuild
)

$ErrorActionPreference = "Stop"

function Stop-Ports {
    param([int[]]$Ports)
    foreach ($p in $Ports) {
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        if ($conn) {
            try {
                Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
            } catch {
            }
        }
    }
}

function Wait-Listening {
    param(
        [int]$Port,
        [int]$TimeoutSec = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($conn) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Invoke-ClientFlow {
    param(
        [string[]]$Lines,
        [switch]$AllowFailure
    )

    $payload = ($Lines -join "`n") + "`n"
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tmp -Value $payload -NoNewline
        $cmd = "Get-Content -Raw `"$tmp`" | .\\bin\\client.exe -master localhost:9000 -masters localhost:9000,localhost:9100 -cert .\\certs\\client-cert.pem -key .\\certs\\client-key.pem -ca .\\certs\\ca-cert.pem"
        if ($AllowFailure) {
            Invoke-Expression $cmd
        } else {
            $output = Invoke-Expression $cmd
            if ($LASTEXITCODE -ne 0) {
                throw "Client flow failed with exit code $LASTEXITCODE"
            }
            return ($output | Out-String)
        }
    } finally {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

Push-Location $RepoRoot
try {
    if ($Rebuild) {
        Write-Host "[1/7] Building binaries..."
        go build -o .\\bin\\master.exe .\\cmd\\master
        go build -o .\\bin\\chunk.exe .\\cmd\\chunkserver
        go build -o .\\bin\\client.exe .\\cmd\\client
    }

    Write-Host "[2/7] Clearing old listeners on failover demo ports..."
    Stop-Ports -Ports @(9000, 9100, 9001, 9002, 9003, 8443, 9443)

    $logDir = Join-Path $RepoRoot "data\\logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    Write-Host "[3/7] Starting active master (:9000, epoch=100) and standby master (:9100, epoch=200)..."
    Start-Process -FilePath ".\\bin\\master.exe" -ArgumentList @(
        "-addr", ":9000",
        "-primary", "chunk1",
        "-epoch", "100",
        "-wal", ".\\data\\master\\wal-shared.json",
        "-users", ".\\data\\users.json",
        "-http", ":8443",
        "-cert", ".\\certs\\server-cert.pem",
        "-key", ".\\certs\\server-key.pem",
        "-ca", ".\\certs\\ca-cert.pem"
    ) -RedirectStandardOutput (Join-Path $logDir "master-9000.log") -RedirectStandardError (Join-Path $logDir "master-9000.err.log") | Out-Null

    Start-Process -FilePath ".\\bin\\master.exe" -ArgumentList @(
        "-addr", ":9100",
        "-primary", "chunk1",
        "-epoch", "200",
        "-wal", ".\\data\\master\\wal-shared.json",
        "-users", ".\\data\\users.json",
        "-http", ":9443",
        "-cert", ".\\certs\\server-cert.pem",
        "-key", ".\\certs\\server-key.pem",
        "-ca", ".\\certs\\ca-cert.pem"
    ) -RedirectStandardOutput (Join-Path $logDir "master-9100.log") -RedirectStandardError (Join-Path $logDir "master-9100.err.log") | Out-Null

    if (-not (Wait-Listening -Port 9000 -TimeoutSec 20)) { throw "master :9000 did not start" }
    if (-not (Wait-Listening -Port 9100 -TimeoutSec 20)) { throw "master :9100 did not start" }

    Write-Host "[4/7] Starting chunk servers..."
    Start-Process -FilePath ".\\bin\\chunk.exe" -ArgumentList @(
        "-id", "chunk1",
        "-addr", ":9001",
        "-master", "localhost:9000",
        "-masters", "localhost:9000,localhost:9100",
        "-data", ".\\data\\chunk1",
        "-cert", ".\\certs\\server-cert.pem",
        "-key", ".\\certs\\server-key.pem",
        "-ca", ".\\certs\\ca-cert.pem"
    ) -RedirectStandardOutput (Join-Path $logDir "chunk1.log") -RedirectStandardError (Join-Path $logDir "chunk1.err.log") | Out-Null

    Start-Process -FilePath ".\\bin\\chunk.exe" -ArgumentList @(
        "-id", "chunk2",
        "-addr", ":9002",
        "-master", "localhost:9000",
        "-masters", "localhost:9000,localhost:9100",
        "-data", ".\\data\\chunk2",
        "-cert", ".\\certs\\server-cert.pem",
        "-key", ".\\certs\\server-key.pem",
        "-ca", ".\\certs\\ca-cert.pem"
    ) -RedirectStandardOutput (Join-Path $logDir "chunk2.log") -RedirectStandardError (Join-Path $logDir "chunk2.err.log") | Out-Null

    Start-Process -FilePath ".\\bin\\chunk.exe" -ArgumentList @(
        "-id", "chunk3",
        "-addr", ":9003",
        "-master", "localhost:9000",
        "-masters", "localhost:9000,localhost:9100",
        "-data", ".\\data\\chunk3",
        "-cert", ".\\certs\\server-cert.pem",
        "-key", ".\\certs\\server-key.pem",
        "-ca", ".\\certs\\ca-cert.pem"
    ) -RedirectStandardOutput (Join-Path $logDir "chunk3.log") -RedirectStandardError (Join-Path $logDir "chunk3.err.log") | Out-Null

    if (-not (Wait-Listening -Port 9001 -TimeoutSec 20)) { throw "chunk1 did not start" }
    if (-not (Wait-Listening -Port 9002 -TimeoutSec 20)) { throw "chunk2 did not start" }
    if (-not (Wait-Listening -Port 9003 -TimeoutSec 20)) { throw "chunk3 did not start" }

    Start-Sleep -Seconds 2

    Write-Host "[5/7] Baseline save/get through active master..."
    Invoke-ClientFlow -AllowFailure -Lines @(
        "register", $User, $Pass,
        "exit"
    ) | Out-Null

    $before = Invoke-ClientFlow -Lines @(
        "login", $User, $Pass,
        "save", "auto-failover-check.com", "user", "pass",
        "get", "auto-failover-check.com",
        "exit"
    )

    Write-Host "[6/7] Killing only active master on :9000 (standby remains up)..."
    $old = Get-NetTCPConnection -LocalPort 9000 -State Listen -ErrorAction SilentlyContinue
    if ($old) {
        Stop-Process -Id $old.OwningProcess -Force
    } else {
        throw "No process listening on :9000"
    }

    Start-Sleep -Seconds 8

    Write-Host "[7/7] Verifying read still works after automatic failover..."
    $after = Invoke-ClientFlow -Lines @(
        "login", $User, $Pass,
        "get", "auto-failover-check.com",
        "exit"
    )

    if ($after -match "Error: no healthy chunk available") {
        throw "Failover check failed: still no healthy chunk available after master switch"
    }

    Write-Host ""
    Write-Host "AUTO FAILOVER DEMO: PASS"
    Write-Host "- Active master :9000 was killed"
    Write-Host "- Standby :9100 continued serving through chunk/client fallback"
    Write-Host "- Logs in data\\logs"
} finally {
    Pop-Location
}
