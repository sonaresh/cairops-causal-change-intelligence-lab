$ErrorActionPreference = 'Stop'

# ============================================================
# CAIROps Paper 6 - EKS Bootstrap
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " CAIROps AWS Experimental Lab - Bootstrap"
Write-Host "============================================================"
Write-Host ""

# ------------------------------------------------------------
# Resolve repository paths
# ------------------------------------------------------------

$Root = Split-Path -Parent (
    Split-Path -Parent $MyInvocation.MyCommand.Path
)

$Tf = Join-Path $Root 'infra\terraform'
$Lab = Join-Path $Root '.lab'

New-Item `
    -ItemType Directory `
    -Force `
    -Path $Lab | Out-Null

# ------------------------------------------------------------
# Read Terraform outputs
# ------------------------------------------------------------

Write-Host "[1/9] Reading Terraform outputs..."

Push-Location $Tf

try {
    terraform output -json |
        Out-File `
            -FilePath (Join-Path $Lab 'outputs.json') `
            -Encoding utf8

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform outputs."
    }

    $Region = terraform output -raw region

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform region output."
    }

    $Cluster = terraform output -raw cluster_name

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform cluster_name output."
    }
}
finally {
    Pop-Location
}

Write-Host "AWS Region : $Region"
Write-Host "EKS Cluster: $Cluster"

# ------------------------------------------------------------
# Validate AWS identity
# ------------------------------------------------------------

Write-Host ""
Write-Host "[2/9] Validating AWS identity..."

aws sts get-caller-identity

if ($LASTEXITCODE -ne 0) {
    throw "AWS authentication validation failed."
}

# ------------------------------------------------------------
# Configure kubectl
# ------------------------------------------------------------

Write-Host ""
Write-Host "[3/9] Updating kubeconfig..."

aws eks update-kubeconfig `
    --region $Region `
    --name $Cluster

if ($LASTEXITCODE -ne 0) {
    throw "Unable to update kubeconfig."
}

Write-Host ""
Write-Host "Current Kubernetes context:"
kubectl config current-context

Write-Host ""
Write-Host "Validating EKS worker nodes..."

kubectl get nodes -o wide

if ($LASTEXITCODE -ne 0) {
    throw "Unable to communicate with the EKS cluster."
}

# ------------------------------------------------------------
# Install / validate Metrics Server
# ------------------------------------------------------------

Write-Host ""
Write-Host "[4/9] Installing Metrics Server..."

helm repo add metrics-server `
    https://kubernetes-sigs.github.io/metrics-server/ `
    --force-update

if ($LASTEXITCODE -ne 0) {
    throw "Unable to add Metrics Server Helm repository."
}

helm repo update

if ($LASTEXITCODE -ne 0) {
    throw "Helm repository update failed."
}

helm upgrade `
    --install metrics-server `
    metrics-server/metrics-server `
    --namespace kube-system `
    --wait `
    --timeout 5m

if ($LASTEXITCODE -ne 0) {
    throw "Metrics Server installation failed."
}

# ------------------------------------------------------------
# Create CAIROps namespace
# ------------------------------------------------------------

Write-Host ""
Write-Host "[5/9] Creating CAIROps namespace..."

$NamespaceFile = Join-Path $Root 'k8s\base\namespace.yaml'

if (-not (Test-Path $NamespaceFile)) {
    throw "Namespace manifest not found: $NamespaceFile"
}

kubectl apply -f $NamespaceFile

if ($LASTEXITCODE -ne 0) {
    throw "Unable to create CAIROps namespace."
}

# ------------------------------------------------------------
# Create CloudWatch configuration JSON
# ------------------------------------------------------------

Write-Host ""
Write-Host "[6/9] Preparing CloudWatch Observability configuration..."

$CloudWatchConfigFile = Join-Path $Lab 'cloudwatch-observability-config.json'

@'
{
  "otelContainerInsights": {
    "enabled": true
  }
}
'@ | Set-Content `
    -Path $CloudWatchConfigFile `
    -Encoding ascii

if (-not (Test-Path $CloudWatchConfigFile)) {
    throw "Unable to create CloudWatch configuration file."
}

Write-Host "CloudWatch configuration:"
Get-Content $CloudWatchConfigFile

# AWS CLI works more reliably with forward slashes in file:// URIs.
$CloudWatchConfigPath = $CloudWatchConfigFile.Replace('\', '/')
$CloudWatchConfigUri = "file://$CloudWatchConfigPath"

# ------------------------------------------------------------
# Create / validate CloudWatch Observability add-on
# ------------------------------------------------------------

Write-Host ""
Write-Host "[7/9] Validating Amazon CloudWatch Observability add-on..."

$AddonStatus = $null
$AddonConfiguration = $null

$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$AddonStatus = aws eks describe-addon `
    --cluster-name $Cluster `
    --addon-name amazon-cloudwatch-observability `
    --region $Region `
    --query 'addon.status' `
    --output text 2>$null

$DescribeAddonExitCode = $LASTEXITCODE

$ErrorActionPreference = $PreviousErrorActionPreference

if ($DescribeAddonExitCode -ne 0) {

    Write-Host "CloudWatch Observability add-on is not installed."
    Write-Host "Creating add-on with OTel Container Insights enabled..."

    aws eks create-addon `
        --cluster-name $Cluster `
        --addon-name amazon-cloudwatch-observability `
        --region $Region `
        --configuration-values $CloudWatchConfigUri

    if ($LASTEXITCODE -ne 0) {
        throw "CloudWatch Observability add-on creation failed."
    }

}
else {

    Write-Host "CloudWatch Observability add-on already exists."
    Write-Host "Current status: $AddonStatus"

    $AddonConfiguration = aws eks describe-addon `
        --cluster-name $Cluster `
        --addon-name amazon-cloudwatch-observability `
        --region $Region `
        --query 'addon.configurationValues' `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve CloudWatch add-on configuration."
    }

    Write-Host "Current CloudWatch configuration:"
    Write-Host $AddonConfiguration

    # If OTel is already configured, do not perform an unnecessary update.
    if (
        $AddonConfiguration -match 'otelContainerInsights' -and
        $AddonConfiguration -match 'true'
    ) {
        Write-Host ""
        Write-Host "OTel Container Insights is already enabled."
        Write-Host "Skipping unnecessary CloudWatch add-on update."
    }
    else {

        Write-Host ""
        Write-Host "OTel Container Insights configuration not detected."
        Write-Host "Updating CloudWatch Observability add-on..."

        aws eks update-addon `
            --cluster-name $Cluster `
            --addon-name amazon-cloudwatch-observability `
            --region $Region `
            --configuration-values $CloudWatchConfigUri `
            --resolve-conflicts PRESERVE

        if ($LASTEXITCODE -ne 0) {
            throw "CloudWatch Observability add-on update failed."
        }
    }
}

# ------------------------------------------------------------
# Wait for CloudWatch add-on
# ------------------------------------------------------------

Write-Host ""
Write-Host "[8/9] Waiting for CloudWatch Observability add-on..."

$Deadline = (Get-Date).AddMinutes(10)

do {

    Start-Sleep -Seconds 10

    $Status = aws eks describe-addon `
        --cluster-name $Cluster `
        --addon-name amazon-cloudwatch-observability `
        --region $Region `
        --query 'addon.status' `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query CloudWatch add-on status."
    }

    Write-Host "CloudWatch add-on status: $Status"

    if (
        $Status -eq 'DEGRADED' -or
        $Status -eq 'CREATE_FAILED' -or
        $Status -eq 'UPDATE_FAILED'
    ) {
        throw "CloudWatch add-on failed with status: $Status"
    }

}
while (
    $Status -ne 'ACTIVE' -and
    (Get-Date) -lt $Deadline
)

if ($Status -ne 'ACTIVE') {
    throw "Timed out waiting for amazon-cloudwatch-observability add-on."
}

# ------------------------------------------------------------
# Final validation
# ------------------------------------------------------------

Write-Host ""
Write-Host "[9/9] Performing final bootstrap validation..."

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "CloudWatch Observability Pods"
Write-Host "------------------------------------------------------------"

kubectl get pods -n amazon-cloudwatch

if ($LASTEXITCODE -ne 0) {
    throw "Unable to query CloudWatch Observability pods."
}

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "Metrics Server"
Write-Host "------------------------------------------------------------"

kubectl get deployment metrics-server -n kube-system

if ($LASTEXITCODE -ne 0) {
    throw "Metrics Server validation failed."
}

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "CAIROps Namespace"
Write-Host "------------------------------------------------------------"

kubectl get namespace cairops-lab

if ($LASTEXITCODE -ne 0) {
    throw "CAIROps namespace validation failed."
}

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "EKS Nodes"
Write-Host "------------------------------------------------------------"

kubectl get nodes

if ($LASTEXITCODE -ne 0) {
    throw "EKS node validation failed."
}

Write-Host ""
Write-Host "============================================================"
Write-Host " CAIROps Bootstrap Complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "Cluster                  : $Cluster"
Write-Host "Region                   : $Region"
Write-Host "CAIROps namespace        : cairops-lab"
Write-Host "Metrics Server           : Installed"
Write-Host "CloudWatch Observability : $Status"
Write-Host "OTel Container Insights  : Enabled"
Write-Host ""
Write-Host "Bootstrap artifacts:"
Write-Host "  $Lab"
Write-Host ""