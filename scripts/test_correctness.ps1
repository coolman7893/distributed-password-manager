param(
    [string]$Master = "localhost:9000",
    [switch]$UseDocker
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

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
        $cmd = "Get-Content -Raw `"$tmp`" | go run ./cmd/client -master $Master -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"
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

$dockerReady = $UseDocker.IsPresent -or (Test-DockerAvailable)

Write-Host ""
Write-Host "============================================"
Write-Host "Test 3: Replica failure + recovery"
Write-Host "============================================"
if ($dockerReady) {
    Write-Host "Stopping chunk2..."
    docker compose stop chunk2 | Out-Host
    Start-Sleep -Seconds 3

    Write-Host "Writing new entry while chunk2 is down..."
    Invoke-ClientFlow -Lines @(
        "login", "testuser", "TestPass123!",
        "save", "netflix.com", "john", "newpass",
        "exit"
    )

    Write-Host "Restarting chunk2..."
    docker compose start chunk2 | Out-Host
    Start-Sleep -Seconds 6

    Write-Host "Test 3: Check chunk2 logs for 'recovered N entries'"
    docker compose logs chunk2 --tail=10 | Out-Host
}
else {
    Write-Host "Docker not available. Skipping automated Test 3."
    Write-Host "Manual: stop chunk2 process, run a save, restart chunk2, inspect logs."
}

Write-Host ""
Write-Host "============================================"
Write-Host "Test 4: Primary failure"
Write-Host "============================================"
if ($dockerReady) {
    Write-Host "Stopping chunk1 (primary)..."
    docker compose stop chunk1 | Out-Host
    Start-Sleep -Seconds 5

    Write-Host "Attempting write (should fail with 'primary unavailable')..."
    Invoke-ClientFlow -Lines @(
        "login", "testuser", "TestPass123!",
        "save", "failtest.com", "user", "pass",
        "exit"
    ) -AllowFailure

    Write-Host "Restarting chunk1..."
    docker compose start chunk1 | Out-Host
    Start-Sleep -Seconds 5

    Write-Host "Test 4: PASSED if write reported primary unavailable"
}
else {
    Write-Host "Docker not available. Skipping automated Test 4."
    Write-Host "Manual: stop chunk1 process, attempt save, verify read still works, restart chunk1."
}

Write-Host ""
Write-Host "============================================"
Write-Host "Test 5: Concurrent writes"
Write-Host "============================================"

$jobs = @()
foreach ($i in 1..20) {
    $jobs += Start-Job -ScriptBlock {
        param($MasterAddr, $Index, $Root)
        Set-Location $Root
        $payload = @(
            "login", "testuser", "TestPass123!",
            "save", "site$Index.com", "user$Index", "pass$Index",
            "exit"
        ) -join "`n"
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmp -Value ($payload + "`n") -NoNewline
            $cmd = "Get-Content -Raw `"$tmp`" | go run ./cmd/client -master $MasterAddr -cert certs/client-cert.pem -key certs/client-key.pem -ca certs/ca-cert.pem"
            Invoke-Expression $cmd | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Concurrent writer failed with exit code $LASTEXITCODE"
            }
        }
        finally {
            Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        }
    } -ArgumentList $Master, $i, $RepoRoot
}

Receive-Job -Job $jobs -Wait -AutoRemoveJob | Out-Null
Write-Host "Test 5: PASSED (20 concurrent writes completed)"

Write-Host ""
Write-Host "============================================"
Write-Host "All tests completed."
Write-Host "============================================"
