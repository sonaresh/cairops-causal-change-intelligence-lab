$ErrorActionPreference = 'Stop'

# ============================================================
# CAIROps Paper 6 - Build and Push Container Images
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " CAIROps AWS Experimental Lab - Build & Push"
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
# Validate required tools
# ------------------------------------------------------------

Write-Host "[1/8] Validating required tools..."

$RequiredCommands = @(
    'terraform',
    'aws',
    'docker'
)

foreach ($Command in $RequiredCommands) {

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command '$Command' was not found in PATH."
    }

    Write-Host "Found: $Command"
}

# ------------------------------------------------------------
# Validate Docker Engine
# ------------------------------------------------------------

Write-Host ""
Write-Host "[2/8] Validating Docker Engine..."

docker version | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Docker Engine is not running. Start Docker Desktop and retry."
}

$DockerOSType = docker info `
    --format '{{.OSType}}'

if ($LASTEXITCODE -ne 0) {
    throw "Unable to query Docker Engine."
}

$DockerArchitecture = docker info `
    --format '{{.Architecture}}'

if ($LASTEXITCODE -ne 0) {
    throw "Unable to determine Docker architecture."
}

Write-Host "Docker OS          : $DockerOSType"
Write-Host "Docker Architecture: $DockerArchitecture"

if ($DockerOSType -ne 'linux') {
    throw "Docker must be running Linux containers for the CAIROps EKS lab."
}

# ------------------------------------------------------------
# Read Terraform outputs
# ------------------------------------------------------------

Write-Host ""
Write-Host "[3/8] Reading Terraform outputs..."

Push-Location $Tf

try {

    $ReposJson = terraform output -json ecr_repositories

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform ECR repository outputs."
    }

    $Repos = $ReposJson | ConvertFrom-Json

    $Region = terraform output -raw region

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform region output."
    }
}
finally {
    Pop-Location
}

if (-not $Region) {
    throw "AWS region is empty."
}

Write-Host "AWS Region: $Region"

Write-Host ""
Write-Host "ECR repositories:"

foreach ($svc in @('frontend', 'service-a', 'service-b')) {

    $repo = $Repos.$svc

    if (-not $repo) {
        throw "Terraform output does not contain an ECR repository for '$svc'."
    }

    Write-Host "  $svc -> $repo"
}

# ------------------------------------------------------------
# Validate AWS identity
# ------------------------------------------------------------

Write-Host ""
Write-Host "[4/8] Validating AWS identity..."

$IdentityJson = aws sts get-caller-identity

if ($LASTEXITCODE -ne 0) {
    throw "AWS authentication failed. Run AWS SSO login and retry."
}

$Identity = $IdentityJson | ConvertFrom-Json
$Account = $Identity.Account

if (-not $Account) {
    throw "Unable to determine AWS account ID."
}

Write-Host "AWS Account: $Account"
Write-Host "AWS ARN    : $($Identity.Arn)"

# ------------------------------------------------------------
# Authenticate Docker to Amazon ECR
# ------------------------------------------------------------

Write-Host ""
Write-Host "[5/8] Authenticating Docker to Amazon ECR..."

$Registry = "$Account.dkr.ecr.$Region.amazonaws.com"

$EcrPassword = aws ecr get-login-password `
    --region $Region

if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve Amazon ECR login password."
}

if (-not $EcrPassword) {
    throw "Amazon ECR returned an empty login password."
}

$EcrPassword |
    docker login `
        --username AWS `
        --password-stdin `
        $Registry

if ($LASTEXITCODE -ne 0) {
    throw "Docker login to Amazon ECR failed."
}

Write-Host "ECR authentication successful."

# ------------------------------------------------------------
# Generate immutable experiment image tag
# ------------------------------------------------------------

Write-Host ""
Write-Host "[6/8] Generating immutable experiment tag..."

$GitTag = $null

try {

    $GitTag = (
        git -C $Root rev-parse --short HEAD 2>$null
    ).Trim()

}
catch {
    $GitTag = $null
}

if (-not $GitTag) {

    $GitTag = (
        Get-Date
    ).ToUniversalTime().ToString(
        'yyyyMMddTHHmmssZ'
    )
}

Write-Host "Experiment image tag: $GitTag"

# ------------------------------------------------------------
# Build and push application images
# ------------------------------------------------------------

Write-Host ""
Write-Host "[7/8] Building and pushing CAIROps images..."

$Images = @{}

$Services = @(
    'frontend',
    'service-a',
    'service-b'
)

foreach ($svc in $Services) {

    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host "Processing service: $svc"
    Write-Host "------------------------------------------------------------"

    $repo = $Repos.$svc
    $BuildContext = Join-Path $Root "app\$svc"

    if (-not (Test-Path $BuildContext)) {
        throw "Build context does not exist: $BuildContext"
    }

    $Dockerfile = Join-Path $BuildContext 'Dockerfile'

    if (-not (Test-Path $Dockerfile)) {
        throw "Dockerfile not found: $Dockerfile"
    }

    $image = "${repo}:$GitTag"

    Write-Host "Build context: $BuildContext"
    Write-Host "Image        : $image"

    # --------------------------------------------------------
    # Build
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Building $svc..."

    docker build `
        --pull `
        --platform linux/amd64 `
        --tag $image `
        $BuildContext

    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed for service '$svc'."
    }

    Write-Host "Build completed for $svc."

    # --------------------------------------------------------
    # Validate image locally
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Validating local image..."

    docker image inspect $image | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Built Docker image could not be inspected: $image"
    }

    $ImageArchitecture = docker image inspect `
        $image `
        --format '{{.Architecture}}'

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to determine image architecture for '$svc'."
    }

    $ImageOS = docker image inspect `
        $image `
        --format '{{.Os}}'

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to determine image OS for '$svc'."
    }

    Write-Host "Image OS          : $ImageOS"
    Write-Host "Image Architecture: $ImageArchitecture"

    if ($ImageOS -ne 'linux') {
        throw "Image '$svc' is not a Linux container image."
    }

    if ($ImageArchitecture -ne 'amd64') {
        throw "Image '$svc' architecture is '$ImageArchitecture'; expected 'amd64'."
    }

    # --------------------------------------------------------
    # Push
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Pushing $svc to Amazon ECR..."

    docker push $image

    if ($LASTEXITCODE -ne 0) {
        throw "Docker push failed for service '$svc'."
    }

    Write-Host "Push completed for $svc."

    $Images[$svc] = $image
}

# ------------------------------------------------------------
# Verify images in Amazon ECR
# ------------------------------------------------------------

Write-Host ""
Write-Host "[8/8] Verifying images in Amazon ECR..."

foreach ($svc in $Services) {

    $RepositoryName = "cairops-p6-research/$svc"

    Write-Host ""
    Write-Host "Checking ECR image: ${RepositoryName}:$GitTag"

    $ImageDigest = aws ecr describe-images `
        --repository-name $RepositoryName `
        --image-ids "imageTag=$GitTag" `
        --region $Region `
        --query 'imageDetails[0].imageDigest' `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to verify image '$svc' in Amazon ECR."
    }

    if (-not $ImageDigest -or $ImageDigest -eq 'None') {
        throw "Image '${svc}:$GitTag' was not found in Amazon ECR."
    }

    Write-Host "Verified digest: $ImageDigest"
}

# ------------------------------------------------------------
# Save experiment image metadata
# ------------------------------------------------------------

$ImagesFile = Join-Path $Lab 'images.json'

$Images |
    ConvertTo-Json |
    Out-File `
        -FilePath $ImagesFile `
        -Encoding utf8

if (-not (Test-Path $ImagesFile)) {
    throw "Unable to write image metadata file."
}

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host " CAIROps Container Build & Push Complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "AWS Account    : $Account"
Write-Host "AWS Region     : $Region"
Write-Host "Docker Platform: linux/amd64"
Write-Host "Experiment Tag : $GitTag"
Write-Host ""

foreach ($svc in $Services) {
    Write-Host "$svc : $($Images[$svc])"
}

Write-Host ""
Write-Host "Image metadata:"
Write-Host "  $ImagesFile"
Write-Host ""
Write-Host "All three CAIROps images were successfully:"
Write-Host "  - built"
Write-Host "  - architecture validated"
Write-Host "  - pushed to Amazon ECR"
Write-Host "  - verified in Amazon ECR"
Write-Host ""