param(
    [string]$AwsProfile = "aicir-lab",
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path ".").Path
$FreezeDir = Join-Path $Root "evidence\experiment-freezes"
$FreezeFile = Join-Path $FreezeDir "E2-v1-final-freeze.json"

New-Item -ItemType Directory -Force -Path $FreezeDir | Out-Null

function Get-HashRecord {
    param(
        [Parameter(Mandatory=$true)]
        [string]$RelativePath
    )

    $FullPath = Join-Path $Root $RelativePath

    if (-not (Test-Path $FullPath)) {
        throw "Required freeze file not found: $RelativePath"
    }

    $Hash = (Get-FileHash -Algorithm SHA256 -Path $FullPath).Hash.ToLower()

    return [ordered]@{
        path = $RelativePath.Replace("\", "/")
        sha256 = $Hash
    }
}

Write-Host "Validating E2 scenario..." -ForegroundColor Cyan

$scenarioCheck = python -c @"
import yaml, json
from pathlib import Path
p = Path(r'experiments/scenarios/E2.yaml')
x = yaml.safe_load(p.read_text())
assert x['id'] == 'E2'
assert x['type'] == 'replica_reduction'
assert x['risk_context']['current_replicas'] == 2
assert x['risk_context']['minimum_safe_replicas'] == 2
assert x['safe']['patch_env']['CPU_BURN_MS'] == '200'
assert x['failure']['patch_env']['CPU_BURN_MS'] == '200'
assert x['governed']['patch_env']['CPU_BURN_MS'] == '200'
assert x['safe']['hpa_bounds']['min_replicas'] == 2
assert x['safe']['hpa_bounds']['max_replicas'] == 2
assert x['failure']['hpa_bounds']['min_replicas'] == 1
assert x['failure']['hpa_bounds']['max_replicas'] == 1
assert x['governed']['hpa_bounds']['min_replicas'] == 2
assert x['governed']['hpa_bounds']['max_replicas'] == 2
assert x['safe']['scale']['replicas'] == 2
assert x['failure']['scale']['replicas'] == 1
assert x['governed']['scale']['replicas'] == 2
print(json.dumps(x))
"@

if ($LASTEXITCODE -ne 0) {
    throw "E2 scenario validation failed."
}

$Scenario = $scenarioCheck | ConvertFrom-Json

Write-Host "Validating runner syntax..." -ForegroundColor Cyan
python -m py_compile .\experiments\runner.py
if ($LASTEXITCODE -ne 0) {
    throw "runner.py syntax validation failed."
}

Write-Host "Capturing Git provenance..." -ForegroundColor Cyan

$GitCommit = (git rev-parse HEAD).Trim()
$GitBranch = (git rev-parse --abbrev-ref HEAD).Trim()
$GitStatus = git status --porcelain

$WorkingTreeClean = [string]::IsNullOrWhiteSpace(($GitStatus -join "`n"))

Write-Host "Capturing AWS/EKS provenance..." -ForegroundColor Cyan

$AccountId = (aws sts get-caller-identity `
    --profile $AwsProfile `
    --query Account `
    --output text).Trim()

$ClusterName = "cairops-p6-research"

$ClusterVersion = (aws eks describe-cluster `
    --name $ClusterName `
    --region $Region `
    --profile $AwsProfile `
    --query "cluster.version" `
    --output text).Trim()

$ClusterArn = (aws eks describe-cluster `
    --name $ClusterName `
    --region $Region `
    --profile $AwsProfile `
    --query "cluster.arn" `
    --output text).Trim()

$KubectlVersion = ""
try {
    $KubectlVersion = (kubectl version --client -o json | ConvertFrom-Json).clientVersion.gitVersion
} catch {
    $KubectlVersion = "unavailable"
}

$PythonVersion = (python --version 2>&1).ToString().Trim()

$Files = @(
    Get-HashRecord "experiments\scenarios\E2.yaml"
    Get-HashRecord "experiments\runner.py"
    Get-HashRecord "experiments\common.py"
)

# Include Lambda source files when present.
$OptionalFiles = @(
    "lambda\change_normalizer\handler.py",
    "lambda\core\handler.py",
    "lambda\outcome_verifier\handler.py"
)

foreach ($f in $OptionalFiles) {
    $full = Join-Path $Root $f
    if (Test-Path $full) {
        $Files += Get-HashRecord $f
    }
}

$Freeze = [ordered]@{
    freeze_id = "E2-v1-final"
    experiment_id = "E2"
    experiment_name = "Replica Reduction / Capacity Shortage"
    status = "FROZEN_FOR_FINAL_TRIALS"
    freeze_timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")

    methodology = [ordered]@{
        design = "SAFE / FAILURE / GOVERNED"
        accepted_trials_per_condition = 5
        accepted_triplets = 5
        total_accepted_final_runs = 15
        baseline_requests = 40
        observation_requests = 120
        concurrency = 4
        request_timeout_seconds = 3
        slo_p95_latency_ms = 600
        incident_p95_latency_ms = 1200
        incident_error_rate = 0.20
        slo_error_rate = 0.05
        baseline_invalid_policy = "Abort before experimental mutation; exclude from accepted final sample."
        tuning_policy = "No parameter, threshold, runner, normalizer, core, verifier, or scenario changes after this freeze."
        warmup_policy = "Warm-up traffic is engineering stabilization only and is not part of the official baseline or final observation sample."
    }

    frozen_e2_configuration = [ordered]@{
        change_type = "replica_reduction"
        target = "deployment/frontend"
        expected_path = @(
            "replica_reduction",
            "queueing",
            "api_latency",
            "slo_violation"
        )
        risk_context = [ordered]@{
            current_replicas = 2
            minimum_safe_replicas = 2
        }
        workload = [ordered]@{
            CPU_BURN_MS = 200
        }
        safe = [ordered]@{
            hpa_min = 2
            hpa_max = 2
            replicas = 2
        }
        failure = [ordered]@{
            hpa_min = 1
            hpa_max = 1
            replicas = 1
        }
        governed = [ordered]@{
            proposed_replicas = 1
            executed_hpa_min = 2
            executed_hpa_max = 2
            executed_replicas = 2
        }
    }

    engineering_gate_evidence = [ordered]@{
        safe_run = "E2-safe-20260814T211952-42b1c0"
        failure_run = "E2-failure-20260814T211146-5d7ecd"
        governed_run = "E2-governed-20260814T212614-73095d"
        safe_result = [ordered]@{
            p95_latency_ms = 454.04089998919517
            slo_violation = $false
            actual_failure = 0
            guard_action = "ALLOW"
            severity = 0.0
        }
        failure_result = [ordered]@{
            p95_latency_ms = 653.6423999932595
            slo_violation = $true
            actual_failure = 1
            guard_action = "CANARY"
            severity = 1.0
        }
        governed_result = [ordered]@{
            p95_latency_ms = 438.6608999921009
            slo_violation = $false
            actual_failure = 0
            intervention_success = 1
            guard_action = "CANARY"
            severity = 1.0
        }
    }

    provenance = [ordered]@{
        git_commit = $GitCommit
        git_branch = $GitBranch
        working_tree_clean = $WorkingTreeClean
        working_tree_status = @($GitStatus)
        aws_account_id = $AccountId
        aws_region = $Region
        eks_cluster_name = $ClusterName
        eks_cluster_arn = $ClusterArn
        eks_version = $ClusterVersion
        kubectl_client_version = $KubectlVersion
        python_version = $PythonVersion
        aws_profile_used = $AwsProfile
    }

    frozen_files = $Files

    evidence_rules = [ordered]@{
        raw_evidence = "Preserve immutable raw run evidence and AWS-generated evidence."
        accepted_run_rule = "A run counts only if its official baseline passes and the experiment reaches observation/verifier completion."
        excluded_run_rule = "Baseline-invalid or pre-freeze engineering attempts are retained but excluded from final statistical sample."
        post_freeze_change_rule = "Any change to a frozen file/configuration invalidates this freeze and requires a new freeze version before additional accepted final trials."
    }
}

$Freeze | ConvertTo-Json -Depth 12 | Set-Content `
    -Path $FreezeFile `
    -Encoding UTF8

$FreezeSha = (Get-FileHash -Algorithm SHA256 -Path $FreezeFile).Hash.ToLower()

Write-Host ""
Write-Host "E2 freeze created successfully." -ForegroundColor Green
Write-Host "Freeze file: $FreezeFile"
Write-Host "Freeze SHA256: $FreezeSha"
Write-Host "Git commit: $GitCommit"
Write-Host "Working tree clean: $WorkingTreeClean"
Write-Host ""
Write-Host "IMPORTANT: Do not modify frozen E2 files/config after this point." -ForegroundColor Yellow
