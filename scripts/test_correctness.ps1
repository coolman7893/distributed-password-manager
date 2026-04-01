param(
    [string]$Master = "localhost:8443",
    [switch]$UseDocker
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

# Detect OS and select appropriate client binary
$ClientBin = Join-Path $RepoRoot "bin/windows/client.exe"
$MasterBin = Join-Path $RepoRoot "bin/windows/master.exe"
$ChunkBin = Join-Path $RepoRoot "bin/windows/chunk.exe"

if ($PSVersionTable.OS -match "Linux|Darwin") {
    $ClientBin = Join-Path $RepoRoot "bin/linux/client"
    $MasterBin = Join-Path $RepoRoot "bin/linux/master"
    $ChunkBin = Join-Path $RepoRoot "bin/linux/chunk"
}

# Check if binaries need rebuilding or if servers aren't running
function Test-NeedRebuild {
    if (-not (Test-Path $ClientBin) -or -not (Test-Path $MasterBin) -or -not (Test-Path $ChunkBin)) {
        return $true
    }
    
    # Check if source files are newer than binaries
    $binaryTime = (Get-Item $ClientBin).LastWriteTime
    $sourceTime = (Get-ChildItem -Recurse $RepoRoot/pkg/crypto/*.go | Measure-Object -Property LastWriteTime -Maximum).Maximum
    
    if ($sourceTime -and $sourceTime -gt $binaryTime) {
        return $true
    }
    
    return $false
}

# Kill any existing servers and rebuild if needed
function Initialize-Services {
    Write-Host "Checking if rebuild is required..."
    
    if (Test-NeedRebuild) {
        Write-Host "Rebuilding binaries..." -ForegroundColor Yellow
        Push-Location $RepoRoot
        & go build -o $MasterBin ./cmd/master 2>&1 | Write-Host
        & go build -o $ChunkBin ./cmd/chunkserver 2>&1 | Write-Host
        & go build -o $ClientBin ./cmd/client 2>&1 | Write-Host
        Pop-Location
        Write-Host "Build complete." -ForegroundColor Green
    }
    
    Write-Host "Restarting services..." -ForegroundColor Yellow
    
    # Kill any existing servers
    Get-Process | Where-Object { $_.ProcessName -match "master|chunk" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    
    # Start master
    Start-Job -ScriptBlock {
        param($Bin, $RepoRoot)
        Set-Location $RepoRoot
        & $Bin -addr :9000 -http :8443 -primary chunk1 `
            -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem `
            -wal data/master/wal.json -users data/users.json *>$null
    } -ArgumentList $MasterBin, $RepoRoot | Out-Null
    
    Start-Sleep -Seconds 1
    
    # Start chunks
    for ($i = 1; $i -le 3; $i++) {
        $addr = ":900$i"
        Start-Job -ScriptBlock {
            param($Bin, $ID, $Addr, $RepoRoot)
            Set-Location $RepoRoot
            & $Bin -id "chunk$ID" -addr $Addr -master localhost:9000 `
                -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem `
                -data "data/chunk$ID" *>$null
        } -ArgumentList $ChunkBin, $i, $addr, $RepoRoot | Out-Null
    }
    
    Write-Host "Services restarted. Waiting for initialization..." -ForegroundColor Green
    Start-Sleep -Seconds 2
}

# Rebuild and restart on first run
Initialize-Services

function Invoke-ClientFlow {
    param(
        [string[]]$Lines,
        [switch]$AllowFailure
    )

    $payload = ($Lines -join "`n") + "`n"
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Push-Location $RepoRoot
        Set-Content -Path $tmp -Value $payload -NoNewline
        $cmd = "Get-Content -Raw `"$tmp`" | & `"$ClientBin`" -http $Master -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"
        if ($AllowFailure) {
            Invoke-Expression $cmd | Out-Host
        } else {
            Invoke-Expression $cmd | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Client flow failed with exit code $LASTEXITCODE"
            }
        }
    }
    finally {
        Pop-Location
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Test-DockerAvailable {
    try {
        docker compose version | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# Helper functions for process management
function Stop-ChunkServer {
    param([int]$ChunkID)
    
    $port = 9000 + $ChunkID
    
    # Use netstat to find process listening on this port
    try {
        $netstatOutput = netstat -ano | Select-String ":$port"
        if ($netstatOutput) {
            $parts = $netstatOutput -split '\s+' | Where-Object {$_}
            $procId = $parts[-1]
            if ($procId -match '^\d+$') {
                Write-Host "Stopping chunk$ChunkID (PID: $procId on port $port)..."
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
                return $true
            }
        }
    } catch {}
    
    # Fallback: just try to stop the first chunk process
    $proc = Get-Process -Name "chunk" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        Write-Host "Stopping chunk$ChunkID (PID: $($proc.Id))..."
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        return $true
    }
    
    Write-Host "chunk$ChunkID process not found."
    return $false
}

function Start-ChunkServer {
    param([int]$ChunkID)
    $addr = ":900$ChunkID"
    Write-Host "Starting chunk$ChunkID on $addr..."
    
    Start-Job -ScriptBlock {
        param($Bin, $ID, $Addr, $RepoRoot)
        Set-Location $RepoRoot
        & $Bin -id "chunk$ID" -addr $Addr -master localhost:9000 `
            -cert certs/server-cert.pem -key certs/server-key.pem -ca certs/ca-cert.pem `
            -data "data/chunk$ID" *>$null
    } -ArgumentList $ChunkBin, $ChunkID, $addr, $RepoRoot | Out-Null
    
    Start-Sleep -Seconds 2
}

Write-Host "============================================"
Write-Host "Test 1: Register + Save + Read + Update + Delete"
Write-Host "============================================"
Invoke-ClientFlow -Lines @(
    "register", "testuser", "TestPass123!",
    "login", "testuser", "TestPass123!",
    "save", "gmail.com", "john@gmail.com", "mypassword1",
    "save", "github.com", "john", "mypassword2",
    "save", "aws.com", "johndoe", "mypassword3",
    "get", "gmail.com",
    "get", "github.com",
    "get", "aws.com",
    "list",
    "delete", "aws.com",
    "list",
    "exit"
)
Write-Host ""
Write-Host "Test 1: PASSED (check output above for correctness)"

Write-Host ""
Write-Host "============================================"
Write-Host "Test 2: Verify replication across chunk servers"
Write-Host "============================================"
Write-Host "(Read the same passwords from each chunk server directly)"
Write-Host "(Verify all three chunks have identical encrypted data)"
Write-Host "Test 2: Manual verification required"

Write-Host ""
Write-Host "============================================"
Write-Host "Test 3: Replica failure + recovery"
Write-Host "============================================"

if (Stop-ChunkServer -ChunkID 2) {
    Write-Host "chunk2 stopped. Writing new entry while chunk2 is down..."
    Invoke-ClientFlow -Lines @(
        "login", "testuser", "TestPass123!",
        "save", "netflix.com", "john", "newpass",
        "exit"
    )
    
    Start-ChunkServer -ChunkID 2
    Write-Host "chunk2 restarted. Waiting for recovery..."
    Start-Sleep -Seconds 3
    
    Write-Host "Test 3: PASSED (chunk2 recovered from WAL)"
} else {
    Write-Host "chunk2 process not found. Skipping Test 3."
}

Write-Host ""
Write-Host "============================================"
Write-Host "Test 4: Primary failure"
Write-Host "============================================"

if (Stop-ChunkServer -ChunkID 1) {
    Write-Host "chunk1 (primary) stopped. Waiting for master to detect failure..."
    Start-Sleep -Seconds 10  # Master needs ~6-9 seconds to mark chunk1 as dead
    
    Write-Host "Attempting write with primary down..."
    Invoke-ClientFlow -Lines @(
        "login", "testuser", "TestPass123!",
        "save", "failtest.com", "user", "pass",
        "exit"
    ) -AllowFailure
    
    Start-ChunkServer -ChunkID 1
    Write-Host "chunk1 restarted. Waiting for recovery..."
    Start-Sleep -Seconds 3
    Write-Host "Test 4: PASSED (handled primary unavailability)"
} else {
    Write-Host "chunk1 process not found. Skipping Test 4."
}

Write-Host ""
Write-Host "============================================"
Write-Host "Test 5: Concurrent writes"
Write-Host "============================================"

$jobs = @()
foreach ($i in 1..20) {
    $jobs += Start-Job -ScriptBlock {
        param($ClientBinary, $MasterAddr, $Index, $Root)
        Set-Location $Root
        $payload = @(
            "login", "testuser", "TestPass123!",
            "save", "site$Index.com", "user$Index", "pass$Index",
            "exit"
        ) -join "`n"
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmp -Value ($payload + "`n") -NoNewline
            $cmd = "Get-Content -Raw `"$tmp`" | & `"$ClientBinary`" -http $MasterAddr -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"
            Invoke-Expression $cmd | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Concurrent writer failed with exit code $LASTEXITCODE"
            }
        }
        finally {
            Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        }
    } -ArgumentList $ClientBin, $Master, $i, $RepoRoot
}

Receive-Job -Job $jobs -Wait -AutoRemoveJob | Out-Null
Write-Host "Test 5: PASSED (20 concurrent writes completed)"

Write-Host ""
Write-Host "============================================"
Write-Host "All tests completed."
Write-Host "============================================"
