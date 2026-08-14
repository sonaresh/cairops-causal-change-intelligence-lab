$ErrorActionPreference = 'Stop'

# ============================================================
# CAIROps Paper 6 - Deploy Application to Amazon EKS
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " CAIROps AWS Experimental Lab - Application Deployment"
Write-Host "============================================================"
Write-Host ""

# ------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------

$Root = Split-Path -Parent (
    Split-Path -Parent $MyInvocation.MyCommand.Path
)

$Lab = Join-Path $Root '.lab'
$ImagesFile = Join-Path $Lab 'images.json'

$NamespaceFile = Join-Path $Root 'k8s\base\namespace.yaml'
$AppsFile      = Join-Path $Root 'k8s\base\apps.yaml'
$PostgresFile  = Join-Path $Root 'k8s\base\postgres.yaml'
$ToxiproxyFile = Join-Path $Root 'k8s\base\toxiproxy.yaml'
$HpaFile       = Join-Path $Root 'k8s\base\hpa.yaml'

$RenderedAppsFile = Join-Path $Lab 'rendered-apps.yaml'
$EndpointFile     = Join-Path $Lab 'frontend-endpoint.txt'

# ------------------------------------------------------------
# Validate required commands
# ------------------------------------------------------------

Write-Host "[1/10] Validating required tools..."

foreach ($Command in @('kubectl')) {

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command '$Command' was not found in PATH."
    }

    Write-Host "Found: $Command"
}

# ------------------------------------------------------------
# Validate input files
# ------------------------------------------------------------

Write-Host ""
Write-Host "[2/10] Validating deployment files..."

$RequiredFiles = @(
    $ImagesFile,
    $NamespaceFile,
    $AppsFile,
    $PostgresFile,
    $ToxiproxyFile,
    $HpaFile
)

foreach ($File in $RequiredFiles) {

    if (-not (Test-Path $File)) {
        throw "Required file not found: $File"
    }

    Write-Host "Found: $File"
}

# ------------------------------------------------------------
# Load immutable ECR image metadata
# ------------------------------------------------------------

Write-Host ""
Write-Host "[3/10] Loading immutable container image metadata..."

try {
    $Images = Get-Content `
        -Raw `
        -Path $ImagesFile |
        ConvertFrom-Json
}
catch {
    throw "Unable to parse .lab/images.json: $($_.Exception.Message)"
}

$FrontendImage = $Images.images.frontend.image
$ServiceAImage = $Images.images.'service-a'.image
$ServiceBImage = $Images.images.'service-b'.image

if (-not $FrontendImage) {
    throw "frontend image is missing from images.json."
}

if (-not $ServiceAImage) {
    throw "service-a image is missing from images.json."
}

if (-not $ServiceBImage) {
    throw "service-b image is missing from images.json."
}

Write-Host ""
Write-Host "Container images:"
Write-Host "  frontend  : $FrontendImage"
Write-Host "  service-a : $ServiceAImage"
Write-Host "  service-b : $ServiceBImage"

# ------------------------------------------------------------
# Validate Kubernetes connectivity
# ------------------------------------------------------------

Write-Host ""
Write-Host "[4/10] Validating Kubernetes cluster connectivity..."

$Context = kubectl config current-context

if ($LASTEXITCODE -ne 0) {
    throw "Unable to determine current kubectl context."
}

Write-Host "Current context: $Context"

kubectl get nodes

if ($LASTEXITCODE -ne 0) {
    throw "Unable to communicate with the EKS cluster."
}

# ------------------------------------------------------------
# Apply namespace
# ------------------------------------------------------------

Write-Host ""
Write-Host "[5/10] Preparing CAIROps namespace..."

kubectl apply -f $NamespaceFile

if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply CAIROps namespace."
}

$NamespaceStatus = kubectl get namespace cairops-lab `
    -o jsonpath='{.status.phase}'

if ($LASTEXITCODE -ne 0) {
    throw "Unable to validate cairops-lab namespace."
}

if ($NamespaceStatus -ne 'Active') {
    throw "Namespace cairops-lab is not Active. Current state: $NamespaceStatus"
}

Write-Host "Namespace cairops-lab: Active"

# ------------------------------------------------------------
# Render application manifest with immutable images
# ------------------------------------------------------------

Write-Host ""
Write-Host "[6/10] Rendering application manifest..."

$Manifest = Get-Content `
    -Raw `
    -Path $AppsFile

if (-not $Manifest.Contains('FRONTEND_IMAGE')) {
    throw "FRONTEND_IMAGE placeholder was not found in apps.yaml."
}

if (-not $Manifest.Contains('SERVICE_A_IMAGE')) {
    throw "SERVICE_A_IMAGE placeholder was not found in apps.yaml."
}

if (-not $Manifest.Contains('SERVICE_B_IMAGE')) {
    throw "SERVICE_B_IMAGE placeholder was not found in apps.yaml."
}

$Manifest = $Manifest.Replace(
    'FRONTEND_IMAGE',
    $FrontendImage
)

$Manifest = $Manifest.Replace(
    'SERVICE_A_IMAGE',
    $ServiceAImage
)

$Manifest = $Manifest.Replace(
    'SERVICE_B_IMAGE',
    $ServiceBImage
)

# Ensure no unresolved image placeholders remain.
if (
    $Manifest.Contains('FRONTEND_IMAGE') -or
    $Manifest.Contains('SERVICE_A_IMAGE') -or
    $Manifest.Contains('SERVICE_B_IMAGE')
) {
    throw "Rendered application manifest still contains unresolved image placeholders."
}

# Write UTF-8 without BOM.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $RenderedAppsFile,
    $Manifest,
    $Utf8NoBom
)

if (-not (Test-Path $RenderedAppsFile)) {
    throw "Unable to create rendered Kubernetes application manifest."
}

Write-Host "Rendered manifest:"
Write-Host "  $RenderedAppsFile"

# ------------------------------------------------------------
# Kubernetes client-side manifest validation
# ------------------------------------------------------------

Write-Host ""
Write-Host "Validating rendered application manifest..."

kubectl apply `
    --dry-run=client `
    -f $RenderedAppsFile `
    -o name

if ($LASTEXITCODE -ne 0) {
    throw "Rendered apps manifest failed Kubernetes client-side validation."
}

kubectl apply `
    --dry-run=client `
    -f $PostgresFile `
    -o name

if ($LASTEXITCODE -ne 0) {
    throw "PostgreSQL manifest failed Kubernetes client-side validation."
}

kubectl apply `
    --dry-run=client `
    -f $ToxiproxyFile `
    -o name

if ($LASTEXITCODE -ne 0) {
    throw "Toxiproxy manifest failed Kubernetes client-side validation."
}

kubectl apply `
    --dry-run=client `
    -f $HpaFile `
    -o name

if ($LASTEXITCODE -ne 0) {
    throw "HPA manifest failed Kubernetes client-side validation."
}

# ------------------------------------------------------------
# Deploy application components
# ------------------------------------------------------------

Write-Host ""
Write-Host "[7/10] Deploying CAIROps application components..."

Write-Host ""
Write-Host "Deploying application services..."

kubectl apply -f $RenderedAppsFile

if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy CAIROps application services."
}

Write-Host ""
Write-Host "Deploying PostgreSQL..."

kubectl apply -f $PostgresFile

if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy PostgreSQL."
}

Write-Host ""
Write-Host "Deploying Toxiproxy..."

kubectl apply -f $ToxiproxyFile

if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy Toxiproxy."
}

Write-Host ""
Write-Host "Deploying Horizontal Pod Autoscalers..."

kubectl apply -f $HpaFile

if ($LASTEXITCODE -ne 0) {
    throw "Failed to deploy HPA configuration."
}

# ------------------------------------------------------------
# Wait for deployments
# ------------------------------------------------------------

Write-Host ""
Write-Host "[8/10] Waiting for deployments..."

$ExpectedDeployments = @(
    'frontend',
    'service-a',
    'service-b',
    'service-b-hot',
    'postgres',
    'toxiproxy'
)

foreach ($Deployment in $ExpectedDeployments) {

    Write-Host ""
    Write-Host "Checking deployment: $Deployment"

    kubectl get deployment $Deployment `
        -n cairops-lab `
        -o name 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Expected deployment '$Deployment' was not created."
    }

    kubectl rollout status `
        "deployment/$Deployment" `
        -n cairops-lab `
        --timeout=300s

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host "Deployment diagnostics for ${Deployment}:"
        kubectl describe deployment $Deployment -n cairops-lab
        kubectl get pods -n cairops-lab -o wide

        throw "Deployment '$Deployment' failed to complete its rollout."
    }

    Write-Host "Deployment ready: $Deployment"
}

# ------------------------------------------------------------
# Validate pods, services and HPA
# ------------------------------------------------------------

Write-Host ""
Write-Host "[9/10] Validating CAIROps application resources..."

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "Pods"
Write-Host "------------------------------------------------------------"

kubectl get pods `
    -n cairops-lab `
    -o wide

if ($LASTEXITCODE -ne 0) {
    throw "Unable to list CAIROps pods."
}

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "Deployments"
Write-Host "------------------------------------------------------------"

kubectl get deployments `
    -n cairops-lab

if ($LASTEXITCODE -ne 0) {
    throw "Unable to list CAIROps deployments."
}

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "Services"
Write-Host "------------------------------------------------------------"

kubectl get services `
    -n cairops-lab

if ($LASTEXITCODE -ne 0) {
    throw "Unable to list CAIROps services."
}

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "Horizontal Pod Autoscalers"
Write-Host "------------------------------------------------------------"

kubectl get hpa `
    -n cairops-lab

if ($LASTEXITCODE -ne 0) {
    throw "Unable to list CAIROps HPAs."
}

# ------------------------------------------------------------
# Wait for frontend AWS LoadBalancer
# ------------------------------------------------------------

Write-Host ""
Write-Host "[10/10] Waiting for frontend LoadBalancer..."

$FrontendServiceType = kubectl get svc frontend `
    -n cairops-lab `
    -o jsonpath='{.spec.type}'

if ($LASTEXITCODE -ne 0) {
    throw "Unable to query frontend service."
}

Write-Host "Frontend service type: $FrontendServiceType"

if ($FrontendServiceType -ne 'LoadBalancer') {
    throw "Frontend service is '$FrontendServiceType'; expected 'LoadBalancer'."
}

$Deadline = (Get-Date).AddMinutes(15)
$FrontendAddress = $null

do {

    $HostName = kubectl get svc frontend `
        -n cairops-lab `
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' `
        2>$null

    if ($HostName) {
        $FrontendAddress = $HostName
        break
    }

    $IPAddress = kubectl get svc frontend `
        -n cairops-lab `
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' `
        2>$null

    if ($IPAddress) {
        $FrontendAddress = $IPAddress
        break
    }

    Write-Host "Waiting for AWS LoadBalancer address..."
    Start-Sleep -Seconds 15

}
while ((Get-Date) -lt $Deadline)

if (-not $FrontendAddress) {

    Write-Host ""
    Write-Host "Frontend service diagnostics:"

    kubectl describe svc frontend `
        -n cairops-lab

    throw "Timed out waiting for frontend LoadBalancer address."
}

$FrontendEndpoint = "http://$FrontendAddress/"

Write-Host ""
Write-Host "Frontend endpoint:"
Write-Host "  $FrontendEndpoint"

$FrontendEndpoint |
    Set-Content `
        -Path $EndpointFile `
        -Encoding ascii

# ------------------------------------------------------------
# Endpoint readiness test
# ------------------------------------------------------------

Write-Host ""
Write-Host "Testing frontend endpoint..."

$EndpointReady = $false
$HttpStatus = $null
$EndpointDeadline = (Get-Date).AddMinutes(5)

do {

    try {

        $Response = Invoke-WebRequest `
            -Uri $FrontendEndpoint `
            -Method Get `
            -TimeoutSec 15 `
            -UseBasicParsing

        $HttpStatus = [int]$Response.StatusCode

        if (
            $HttpStatus -ge 200 -and
            $HttpStatus -lt 500
        ) {
            $EndpointReady = $true
            break
        }
    }
    catch {

        Write-Host "Frontend not reachable yet. Retrying..."
    }

    Start-Sleep -Seconds 10

}
while ((Get-Date) -lt $EndpointDeadline)

if (-not $EndpointReady) {

    Write-Host ""
    Write-Host "WARNING: LoadBalancer exists but frontend HTTP readiness test did not succeed."
    Write-Host "Continuing with Kubernetes diagnostics."
    Write-Host ""

    kubectl get pods -n cairops-lab -o wide
    kubectl describe svc frontend -n cairops-lab
}
else {

    Write-Host "Frontend HTTP response: $HttpStatus"
    Write-Host "Frontend endpoint reachable."
}

# ------------------------------------------------------------
# Final comprehensive state
# ------------------------------------------------------------

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "Final CAIROps Kubernetes State"
Write-Host "------------------------------------------------------------"

kubectl get all `
    -n cairops-lab `
    -o wide

if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve final Kubernetes state."
}

# ------------------------------------------------------------
# Deployment summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host " CAIROps Application Deployment Complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "Namespace        : cairops-lab"
Write-Host "Frontend         : Deployed"
Write-Host "Service A        : Deployed"
Write-Host "Service B        : Deployed"
Write-Host "Service B Hot    : Deployed"
Write-Host "PostgreSQL       : Deployed"
Write-Host "Toxiproxy        : Deployed"
Write-Host "HPA              : Deployed"
Write-Host "Frontend Endpoint: $FrontendEndpoint"
Write-Host ""
Write-Host "Immutable images:"
Write-Host "  frontend  : $FrontendImage"
Write-Host "  service-a : $ServiceAImage"
Write-Host "  service-b : $ServiceBImage"
Write-Host ""
Write-Host "Deployment evidence:"
Write-Host "  $RenderedAppsFile"
Write-Host "  $EndpointFile"
Write-Host ""
Write-Host "============================================================"
Write-Host ""