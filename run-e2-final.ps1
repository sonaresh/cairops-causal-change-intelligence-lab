param(
    [int]$AcceptedTriplets = 5
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path ".").Path
$FreezeFile = Join-Path $Root "evidence\experiment-freezes\E2-v1-final-freeze.json"

if (-not (Test-Path $FreezeFile)) {
    throw "Freeze manifest not found: $FreezeFile. Run freeze-e2-final.ps1 first."
}

$Freeze = Get-Content $FreezeFile -Raw | ConvertFrom-Json

if ($Freeze.status -ne "FROZEN_FOR_FINAL_TRIALS") {
    throw "E2 freeze manifest is not marked FROZEN_FOR_FINAL_TRIALS."
}

$FinalRoot = Join-Path $Root "evidence\final-runs\E2"
$ExcludedRoot = Join-Path $Root "evidence\excluded-runs\E2"

New-Item -ItemType Directory -Force -Path $FinalRoot | Out-Null
New-Item -ItemType Directory -Force -Path $ExcludedRoot | Out-Null

function Assert-FreezeIntegrity {

    foreach ($entry in $Freeze.frozen_files) {

        $relative = $entry.path.Replace("/", "\")
        $full = Join-Path $Root $relative

        if (-not (Test-Path $full)) {
            throw "Frozen file missing: $($entry.path)"
        }

        $actual = (Get-FileHash -Algorithm SHA256 -Path $full).Hash.ToLower()
        $expected = ([string]$entry.sha256).ToLower()

        if ($actual -ne $expected) {
            throw (
                "FREEZE_INTEGRITY_FAILURE: $($entry.path)`n" +
                "Expected: $expected`n" +
                "Actual:   $actual`n" +
                "Do not continue final trials. Create a new freeze version if this change was intentional."
            )
        }
    }
}

function Invoke-FinalCondition {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Condition,
        [Parameter(Mandatory=$true)]
        [int]$Trial
    )

    $attempt = 0

    while ($true) {

        $attempt += 1
        Assert-FreezeIntegrity

        $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
        $logName = "trial-$Trial-$Condition-attempt-$attempt-$stamp.log"
        $logPath = Join-Path $FinalRoot $logName

        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host "E2 FINAL | Trial $Trial | $Condition | Attempt $attempt" -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Cyan

        $output = & python .\experiments\runner.py `
            --scenario E2 `
            --condition $Condition `
            --requests 120 2>&1

        $exitCode = $LASTEXITCODE

        $output | Tee-Object -FilePath $logPath

        $joined = ($output | Out-String)

        if ($exitCode -eq 0) {

            if ($joined -notmatch '"run_id"\s*:\s*"E2-') {
                throw "Runner exited 0 but run_id was not found. Inspect $logPath"
            }

            Write-Host "Accepted final run: Trial $Trial / $Condition" -ForegroundColor Green

            return [ordered]@{
                trial = $Trial
                condition = $Condition
                attempt = $attempt
                status = "ACCEPTED"
                log = $logPath.Replace($Root + "\", "").Replace("\", "/")
            }
        }

        if ($joined -match "BASELINE_INVALID") {

            $excludedName = "excluded-trial-$Trial-$Condition-attempt-$attempt-$stamp.log"
            $excludedPath = Join-Path $ExcludedRoot $excludedName

            Move-Item -Force $logPath $excludedPath

            Write-Host (
                "Baseline-invalid attempt excluded before mutation; retrying same condition. " +
                "Evidence preserved at $excludedPath"
            ) -ForegroundColor Yellow

            continue
        }

        throw (
            "FINAL_RUN_FAILURE: Trial $Trial / $Condition failed for a reason other than BASELINE_INVALID. " +
            "Final collection stopped. Inspect $logPath"
        )
    }
}

Assert-FreezeIntegrity

$FreezeSha = (Get-FileHash -Algorithm SHA256 -Path $FreezeFile).Hash.ToLower()

$Session = [ordered]@{
    experiment_id = "E2"
    freeze_id = $Freeze.freeze_id
    freeze_sha256 = $FreezeSha
    started_utc = (Get-Date).ToUniversalTime().ToString("o")
    requested_accepted_triplets = $AcceptedTriplets
    accepted_runs = @()
}

for ($trial = 1; $trial -le $AcceptedTriplets; $trial++) {

    foreach ($condition in @("safe", "failure", "governed")) {

        $result = Invoke-FinalCondition `
            -Condition $condition `
            -Trial $trial

        $Session.accepted_runs += $result

        $SessionFile = Join-Path $FinalRoot "E2-final-session.json"

        $Session | ConvertTo-Json -Depth 10 | Set-Content `
            -Path $SessionFile `
            -Encoding UTF8
    }
}

$Session.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
$Session.accepted_run_count = $Session.accepted_runs.Count
$Session.status = "COMPLETE"

$SessionFile = Join-Path $FinalRoot "E2-final-session.json"

$Session | ConvertTo-Json -Depth 10 | Set-Content `
    -Path $SessionFile `
    -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "E2 FINAL COLLECTION COMPLETE" -ForegroundColor Green
Write-Host "Accepted runs: $($Session.accepted_run_count)" -ForegroundColor Green
Write-Host "Session manifest: $SessionFile" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
