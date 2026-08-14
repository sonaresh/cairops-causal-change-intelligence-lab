param(
    [int]$AcceptedTriplets = 5
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path ".").Path
$FreezeFile = Join-Path $Root "evidence\experiment-freezes\E2-v1-final-freeze.json"
$FinalRoot = Join-Path $Root "evidence\final-runs\E2"
$ExcludedRoot = Join-Path $Root "evidence\excluded-runs\E2"
$SessionFile = Join-Path $FinalRoot "E2-final-session.json"

if (-not (Test-Path $FreezeFile)) {
    throw "Freeze manifest not found: $FreezeFile"
}

$Freeze = Get-Content $FreezeFile -Raw | ConvertFrom-Json

if ($Freeze.status -ne "FROZEN_FOR_FINAL_TRIALS") {
    throw "Freeze manifest is not FROZEN_FOR_FINAL_TRIALS."
}

New-Item -ItemType Directory -Force -Path $FinalRoot | Out-Null
New-Item -ItemType Directory -Force -Path $ExcludedRoot | Out-Null

function Assert-FreezeIntegrity {
    foreach ($entry in $Freeze.frozen_files) {
        $full = Join-Path $Root ($entry.path.Replace("/", "\"))
        if (-not (Test-Path $full)) {
            throw "Frozen file missing: $($entry.path)"
        }
        $actual = (Get-FileHash -Algorithm SHA256 -Path $full).Hash.ToLower()
        $expected = ([string]$entry.sha256).ToLower()
        if ($actual -ne $expected) {
            throw "FREEZE_INTEGRITY_FAILURE: $($entry.path)"
        }
    }
}

function Save-Session {
    param($Session)
    $Session | ConvertTo-Json -Depth 12 | Set-Content -Path $SessionFile -Encoding UTF8
}

function Invoke-PythonRunner {
    param([string]$Condition)

    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & python .\experiments\runner.py `
            --scenario E2 `
            --condition $Condition `
            --requests 120 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $saved
    }

    [pscustomobject]@{
        Output = @($output)
        ExitCode = $code
    }
}

function Invoke-FinalCondition {
    param(
        [string]$Condition,
        [int]$Trial
    )

    $attempt = 0

    while ($true) {
        $attempt++
        Assert-FreezeIntegrity

        $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
        $logPath = Join-Path $FinalRoot "trial-$Trial-$Condition-attempt-$attempt-$stamp.log"

        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host "E2 FINAL | Trial $Trial | $Condition | Attempt $attempt" -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Cyan

        $r = Invoke-PythonRunner -Condition $Condition
        $r.Output | Tee-Object -FilePath $logPath
        $joined = ($r.Output | Out-String)

        if ($r.ExitCode -eq 0) {
            Write-Host "Accepted final run: Trial $Trial / $Condition" -ForegroundColor Green
            return [pscustomobject]@{
                trial = $Trial
                condition = $Condition
                attempt = $attempt
                status = "ACCEPTED"
                log = $logPath.Replace($Root + "\", "").Replace("\", "/")
            }
        }

        if ($joined -match "BASELINE_INVALID") {
            $excluded = Join-Path $ExcludedRoot "excluded-trial-$Trial-$Condition-attempt-$attempt-$stamp.log"
            Move-Item -Force $logPath $excluded
            Write-Host "Baseline-invalid attempt excluded; retrying same condition." -ForegroundColor Yellow
            continue
        }

        $failed = Join-Path $ExcludedRoot "failed-trial-$Trial-$Condition-attempt-$attempt-$stamp.log"
        Move-Item -Force $logPath $failed
        throw "FINAL_RUN_FAILURE: inspect $failed"
    }
}

Assert-FreezeIntegrity
$FreezeSha = (Get-FileHash -Algorithm SHA256 -Path $FreezeFile).Hash.ToLower()

if (Test-Path $SessionFile) {
    Write-Host "Existing E2 final session found. Resuming." -ForegroundColor Yellow
    $old = Get-Content $SessionFile -Raw | ConvertFrom-Json
    $existing = @($old.accepted_runs)

    $Session = [ordered]@{
        experiment_id = "E2"
        freeze_id = $Freeze.freeze_id
        freeze_sha256 = $FreezeSha
        started_utc = $old.started_utc
        resumed_utc = (Get-Date).ToUniversalTime().ToString("o")
        requested_accepted_triplets = $AcceptedTriplets
        accepted_runs = $existing
        status = "IN_PROGRESS"
    }
}
else {
    $Session = [ordered]@{
        experiment_id = "E2"
        freeze_id = $Freeze.freeze_id
        freeze_sha256 = $FreezeSha
        started_utc = (Get-Date).ToUniversalTime().ToString("o")
        requested_accepted_triplets = $AcceptedTriplets
        accepted_runs = @()
        status = "IN_PROGRESS"
    }
}

function Test-Accepted {
    param([int]$Trial, [string]$Condition)

    foreach ($x in @($Session.accepted_runs)) {
        if (
            [int]$x.trial -eq $Trial -and
            [string]$x.condition -eq $Condition -and
            [string]$x.status -eq "ACCEPTED"
        ) {
            return $true
        }
    }
    return $false
}

Save-Session $Session

for ($trial = 1; $trial -le $AcceptedTriplets; $trial++) {
    foreach ($condition in @("safe", "failure", "governed")) {

        if (Test-Accepted -Trial $trial -Condition $condition) {
            Write-Host "Skipping already accepted: Trial $trial / $condition" -ForegroundColor DarkGray
            continue
        }

        $accepted = Invoke-FinalCondition -Condition $condition -Trial $trial
        $Session.accepted_runs = @($Session.accepted_runs) + @($accepted)
        Save-Session $Session
    }
}

$Session.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
$Session.accepted_run_count = @($Session.accepted_runs).Count
$Session.status = "COMPLETE"
Save-Session $Session

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "E2 FINAL COLLECTION COMPLETE" -ForegroundColor Green
Write-Host "Accepted runs: $($Session.accepted_run_count)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
