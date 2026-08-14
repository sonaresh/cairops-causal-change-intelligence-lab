param(
    [string]$Profile = "aicir-lab",
    [string]$Region = "us-east-1",
    [int]$Requests = 120
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path ".").Path
$Scenario = "E2"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

$OutDir = Join-Path $Root "evidence\engineering-prechecks\E2\$Stamp"
New-Item -ItemType Directory -Force $OutDir | Out-Null

Write-Host ""
Write-Host "============================================================"
Write-Host " CAIROps E2 Engineering Validation"
Write-Host " Output: $OutDir"
Write-Host "============================================================"
Write-Host ""

# ------------------------------------------------------------
# Resolve evidence bucket from Terraform/runtime outputs
# ------------------------------------------------------------

$OutputsPath = Join-Path $Root ".lab\outputs.json"

if (-not (Test-Path $OutputsPath)) {
    throw "Missing .lab\outputs.json"
}

$Outputs = Get-Content $OutputsPath -Raw | ConvertFrom-Json

$Bucket = $null

if ($Outputs.evidence_bucket) {
    if ($Outputs.evidence_bucket.value) {
        $Bucket = $Outputs.evidence_bucket.value
    } else {
        $Bucket = [string]$Outputs.evidence_bucket
    }
}

if (-not $Bucket -and $Outputs.evidence_bucket_name) {
    if ($Outputs.evidence_bucket_name.value) {
        $Bucket = $Outputs.evidence_bucket_name.value
    } else {
        $Bucket = [string]$Outputs.evidence_bucket_name
    }
}

# Known fallback from current deployed research lab.
if (-not $Bucket) {
    $Bucket = "cairops-p6-research-evidence-62056b9e"
}

Write-Host "Evidence bucket: $Bucket"
Write-Host ""

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Get-RunIdFromOutput {
    param(
        [string[]]$Lines,
        [string]$Condition
    )

    $Pattern = '"run_id"\s*:\s*"(E2-' + [regex]::Escape($Condition) + '-[^"]+)"'

    foreach ($Line in $Lines) {
        $Match = [regex]::Match($Line, $Pattern)
        if ($Match.Success) {
            return $Match.Groups[1].Value
        }
    }

    return $null
}

function Save-KubernetesSnapshot {
    param(
        [string]$Condition,
        [string]$RunId,
        [string]$Dir
    )

    $Snapshot = Join-Path $Dir "kubernetes-$Condition.txt"

    @(
        "RUN_ID=$RunId"
        "CONDITION=$Condition"
        "TIMESTAMP=$(Get-Date -Format o)"
        ""
        "=== FRONTEND DEPLOYMENT ==="
        (kubectl get deployment frontend -n cairops-lab -o wide 2>&1 | Out-String)
        ""
        "=== FRONTEND PODS ==="
        (kubectl get pods -n cairops-lab -l app=frontend -o wide 2>&1 | Out-String)
        ""
        "=== RESOURCE USAGE ==="
        (kubectl top pods -n cairops-lab -l app=frontend 2>&1 | Out-String)
    ) | Set-Content $Snapshot -Encoding utf8
}

function Download-CanonicalEvidence {
    param(
        [string]$RunId,
        [string]$RunDir
    )

    New-Item -ItemType Directory -Force $RunDir | Out-Null

    aws s3 sync `
        "s3://$Bucket/runs/$RunId/" `
        "$RunDir" `
        --region $Region `
        --profile $Profile `
        --only-show-errors

    $Prediction = Join-Path $RunDir "prediction-decision.json"
    $Outcome = Join-Path $RunDir "outcome.json"

    if (-not (Test-Path $Prediction)) {
        throw "Missing prediction-decision.json for $RunId"
    }

    if (-not (Test-Path $Outcome)) {
        throw "Missing outcome.json for $RunId"
    }
}

function Test-E2Condition {
    param(
        [string]$Condition,
        [string]$RunDir
    )

    $Prediction = Get-Content `
        (Join-Path $RunDir "prediction-decision.json") `
        -Raw | ConvertFrom-Json

    $OutcomeEvidence = Get-Content `
        (Join-Path $RunDir "outcome.json") `
        -Raw | ConvertFrom-Json

    $S = [double]$Prediction.factors.S
    $Risk = [double]$Prediction.risk
    $Guard = [string]$Prediction.guard_action

    $ActualFailure = [int]$OutcomeEvidence.outcome.actual_failure
    $ErrorRate = [double]$OutcomeEvidence.observation.error_rate
    $P95 = [double]$OutcomeEvidence.observation.p95_latency_ms
    $SloViolation = [bool]$OutcomeEvidence.observation.slo_violation
    $Incident = [bool]$OutcomeEvidence.observation.incident
    $InterventionSuccess = [int]$OutcomeEvidence.outcome.intervention_success

    $Summary = [ordered]@{
        condition = $Condition
        severity_S = $S
        risk = $Risk
        guard_action = $Guard
        actual_failure = $ActualFailure
        error_rate = $ErrorRate
        p95_latency_ms = $P95
        slo_violation = $SloViolation
        incident = $Incident
        intervention_success = $InterventionSuccess
    }

    $Summary |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            (Join-Path $RunDir "engineering-summary.json") `
            -Encoding utf8

    Write-Host ""
    Write-Host "[$Condition]"
    Write-Host "  S                 = $S"
    Write-Host "  Risk              = $Risk"
    Write-Host "  Guard             = $Guard"
    Write-Host "  Actual failure    = $ActualFailure"
    Write-Host "  Error rate        = $ErrorRate"
    Write-Host "  p95 latency (ms)  = $P95"
    Write-Host "  SLO violation     = $SloViolation"
    Write-Host "  Incident          = $Incident"
    Write-Host "  Intervention      = $InterventionSuccess"

    switch ($Condition) {

        "safe" {
            if ($S -gt 0.05) {
                throw "E2 SAFE failed: expected S approximately 0, got $S"
            }

            if ($ActualFailure -ne 0 -or $SloViolation -or $Incident) {
                throw "E2 SAFE failed: safe condition was unhealthy."
            }
        }

        "failure" {
            if ($S -lt 0.90) {
                throw "E2 FAILURE failed scientific gate: expected S >= 0.90 for 2 -> 1 replica proposal, got $S"
            }

            if ($ActualFailure -ne 1) {
                throw "E2 FAILURE failed: expected actual_failure=1."
            }

            if (-not $SloViolation -and -not $Incident) {
                throw "E2 FAILURE failed: no measurable SLO violation or incident."
            }
        }

        "governed" {
            if ($S -lt 0.90) {
                throw "E2 GOVERNED failed scientific gate: same risky proposal should retain S >= 0.90, got $S"
            }

            if ($ActualFailure -ne 0) {
                throw "E2 GOVERNED failed: governed condition still failed."
            }

            if ($SloViolation -or $Incident) {
                throw "E2 GOVERNED failed: mitigation did not preserve SLO health."
            }

            if ($Guard -eq "ALLOW") {
                throw "E2 GOVERNED failed: risky proposal was simply ALLOWed."
            }
        }
    }

    return $Summary
}

function Invoke-E2Condition {
    param(
        [string]$Condition
    )

    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host "Running E2 engineering condition: $Condition"
    Write-Host "------------------------------------------------------------"

    $ConsoleFile = Join-Path $OutDir "$Condition-console.txt"

    $Lines = & python `
        ".\experiments\runner.py" `
        --scenario E2 `
        --condition $Condition `
        --requests $Requests 2>&1 |
        Tee-Object -FilePath $ConsoleFile

    $ExitCode = $LASTEXITCODE

    $Lines | ForEach-Object {
        Write-Host $_
    }

    if ($ExitCode -ne 0) {
        throw "runner.py returned exit code $ExitCode for E2 $Condition"
    }

    $RunId = Get-RunIdFromOutput `
        -Lines $Lines `
        -Condition $Condition

    if (-not $RunId) {
        throw "Could not determine run_id for E2 $Condition"
    }

    Write-Host ""
    Write-Host "Run ID: $RunId"

    $RunDir = Join-Path $OutDir $RunId

    Download-CanonicalEvidence `
        -RunId $RunId `
        -RunDir $RunDir

    Save-KubernetesSnapshot `
        -Condition $Condition `
        -RunId $RunId `
        -Dir $RunDir

    return Test-E2Condition `
        -Condition $Condition `
        -RunDir $RunDir
}

# ------------------------------------------------------------
# Preflight
# ------------------------------------------------------------

Write-Host "Preflight: validating Python..."
python -m py_compile .\lambda\cairops_core\handler.py
python -m py_compile .\experiments\runner.py

Write-Host "Preflight: checking cluster..."
kubectl get deployment frontend -n cairops-lab | Out-Host

# ------------------------------------------------------------
# Run engineering triplet
# ------------------------------------------------------------

$Results = @()

try {

    $Results += Invoke-E2Condition -Condition "safe"
    $Results += Invoke-E2Condition -Condition "failure"
    $Results += Invoke-E2Condition -Condition "governed"

    $Final = [ordered]@{
        experiment = "E2"
        mode = "engineering-precheck"
        timestamp = (Get-Date -Format o)
        status = "PASS"
        requests = $Requests
        results = $Results
        note = "Engineering/precheck only. Not part of final frozen research sample."
    }

    $Final |
        ConvertTo-Json -Depth 12 |
        Set-Content `
            (Join-Path $OutDir "E2-engineering-result.json") `
            -Encoding utf8

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " E2 ENGINEERING TRIPLET: PASS"
    Write-Host " SAFE / FAILURE / GOVERNED all satisfied gates."
    Write-Host " Next step: inspect, freeze E2, then run final trials."
    Write-Host "============================================================"
}
catch {

    $Failure = [ordered]@{
        experiment = "E2"
        mode = "engineering-precheck"
        timestamp = (Get-Date -Format o)
        status = "FAIL"
        error = $_.Exception.Message
        results = $Results
        note = "Engineering/precheck only. Do not use as final research evidence."
    }

    $Failure |
        ConvertTo-Json -Depth 12 |
        Set-Content `
            (Join-Path $OutDir "E2-engineering-result.json") `
            -Encoding utf8

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " E2 ENGINEERING TRIPLET: STOPPED"
    Write-Host " $($_.Exception.Message)"
    Write-Host " No final E2 freeze should be created yet."
    Write-Host "============================================================"

    exit 1
}
