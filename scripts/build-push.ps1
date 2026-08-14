$ErrorActionPreference = 'Stop'

# ============================================================
# CAIROps Paper 6 - Build and Push Container Images
#
# Windows + Docker Desktop ECR authentication workaround
#
# IMPORTANT:
# - Does NOT use `docker login`
# - Uses AWS ECR authorization token directly in a temporary
#   Docker config
# - Builds immutable linux/amd64 images
# - Verifies local image architecture
# - Pushes all images to ECR
# - Verifies ECR digests
# - Saves .lab/images.json
# - Removes temporary Docker credentials when complete
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
# Preserve original Docker configuration environment
# ------------------------------------------------------------

$OriginalDockerConfig = $env:DOCKER_CONFIG

# Temporary Docker auth directory used only by this script.
$DockerConfigDir = Join-Path $Lab 'docker-auth-temp'

# ------------------------------------------------------------
# Validate required tools
# ------------------------------------------------------------

Write-Host "[1/8] Validating required tools..."

$RequiredCommands = @(
    'terraform',
    'aws',
    'docker',
    'git'
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
    throw "Unable to query Docker Engine OS type."
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

# x86_64 and amd64 both represent the required architecture here.
if (
    $DockerArchitecture -ne 'x86_64' -and
    $DockerArchitecture -ne 'amd64'
) {
    Write-Warning "Docker reports architecture '$DockerArchitecture'. Images will still be explicitly built for linux/amd64."
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

    $Cluster = terraform output -raw cluster_name

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform cluster output."
    }
}
finally {
    Pop-Location
}

if (-not $Region) {
    throw "AWS region is empty."
}

Write-Host "AWS Region : $Region"
Write-Host "EKS Cluster: $Cluster"

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
# Prepare Docker authentication for Amazon ECR
#
# IMPORTANT:
#
# Docker Desktop / Docker Engine on this Windows environment
# returns HTTP 400 during `docker login`.
#
# AWS ECR itself has already been proven to accept the AWS
# authorization token.
#
# Therefore we write that ECR Basic-auth token directly into
# an isolated Docker config rather than calling docker login.
# ------------------------------------------------------------

Write-Host ""
Write-Host "[5/8] Preparing Amazon ECR Docker authentication..."

$Registry = "$Account.dkr.ecr.$Region.amazonaws.com"

Write-Host "ECR Registry: $Registry"

# Retrieve the ECR authorization token.
#
# authorizationToken is already Base64(AWS:<password>), which is
# exactly the value Docker expects in auths.<registry>.auth.

$AuthorizationToken = aws ecr get-authorization-token `
    --region $Region `
    --query 'authorizationData[0].authorizationToken' `
    --output text

if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve ECR authorization token."
}

if (-not $AuthorizationToken) {
    throw "Amazon ECR returned an empty authorization token."
}

$ProxyEndpoint = aws ecr get-authorization-token `
    --region $Region `
    --query 'authorizationData[0].proxyEndpoint' `
    --output text

if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve ECR proxy endpoint."
}

$ExpectedProxyEndpoint = "https://$Registry"

if ($ProxyEndpoint -ne $ExpectedProxyEndpoint) {
    throw "ECR proxy endpoint mismatch. Expected '$ExpectedProxyEndpoint' but received '$ProxyEndpoint'."
}

Write-Host "ECR authorization token retrieved."
Write-Host "ECR proxy endpoint validated."

# Remove previous temporary credential directory.

if (Test-Path $DockerConfigDir) {

    Remove-Item `
        -Path $DockerConfigDir `
        -Recurse `
        -Force
}

New-Item `
    -ItemType Directory `
    -Force `
    -Path $DockerConfigDir | Out-Null

$DockerConfigObject = @{
    auths = @{
        $Registry = @{
            auth = $AuthorizationToken
        }
    }
}

$DockerConfigJson = $DockerConfigObject |
    ConvertTo-Json -Depth 5

$DockerConfigFile = Join-Path `
    $DockerConfigDir `
    'config.json'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $DockerConfigFile,
    $DockerConfigJson,
    $Utf8NoBom
)

if (-not (Test-Path $DockerConfigFile)) {
    throw "Unable to create temporary Docker authentication configuration."
}

# Tell Docker CLI to use the isolated credential configuration.

$env:DOCKER_CONFIG = $DockerConfigDir

Write-Host "Temporary Docker configuration created."
Write-Host "Docker config directory: $DockerConfigDir"

# ------------------------------------------------------------
# Verify Docker can authenticate to ECR
#
# We deliberately ask for an image tag that should not exist.
#
# Success criterion:
#   "no such manifest" / "manifest unknown"
#
# Failure criterion:
#   unauthorized / no basic auth credentials
# ------------------------------------------------------------

Write-Host ""
Write-Host "Validating Docker -> ECR authenticated access..."

$FrontendRepo = $Repos.frontend

$AuthTestImage = "${FrontendRepo}:cairops-auth-check-does-not-exist"

$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$AuthTestOutput = (
    docker manifest inspect $AuthTestImage 2>&1 |
        Out-String
)

$AuthTestExitCode = $LASTEXITCODE

$ErrorActionPreference = $PreviousErrorActionPreference

if (
    $AuthTestOutput -match '(?i)unauthorized' -or
    $AuthTestOutput -match '(?i)no basic auth credentials' -or
    $AuthTestOutput -match '(?i)authentication required'
) {
    throw "Docker authentication to Amazon ECR failed.`n$AuthTestOutput"
}

if (
    $AuthTestOutput -match '(?i)no such manifest' -or
    $AuthTestOutput -match '(?i)manifest unknown'
) {
    Write-Host "Docker authenticated successfully to Amazon ECR."
}
elseif ($AuthTestExitCode -eq 0) {
    Write-Host "Docker authenticated successfully to Amazon ECR."
}
else {

    Write-Warning "Docker authentication test returned an unexpected response:"
    Write-Warning $AuthTestOutput

    Write-Host "Continuing because no authentication failure was detected."
}

# ------------------------------------------------------------
# Generate immutable experiment image tag
# ------------------------------------------------------------

Write-Host ""
Write-Host "[6/8] Generating immutable experiment tag..."

$GitTag = $null

$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$GitOutput = git -C $Root rev-parse --short HEAD 2>$null
$GitExitCode = $LASTEXITCODE

$ErrorActionPreference = $PreviousErrorActionPreference

if (
    $GitExitCode -eq 0 -and
    $GitOutput
) {
    $GitTag = $GitOutput.Trim()
}

if (-not $GitTag) {

    $GitTag = (
        Get-Date
    ).ToUniversalTime().ToString(
        'yyyyMMddTHHmmssZ'
    )

    Write-Warning "Git commit SHA unavailable. Using timestamp tag."
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

try {

    foreach ($svc in $Services) {

        Write-Host ""
        Write-Host "------------------------------------------------------------"
        Write-Host "Processing service: $svc"
        Write-Host "------------------------------------------------------------"

        $repo = $Repos.$svc

        if (-not $repo) {
            throw "Missing ECR repository URI for '$svc'."
        }

        $BuildContext = Join-Path `
            $Root `
            "app\$svc"

        if (-not (Test-Path $BuildContext)) {
            throw "Build context does not exist: $BuildContext"
        }

        $Dockerfile = Join-Path `
            $BuildContext `
            'Dockerfile'

        if (-not (Test-Path $Dockerfile)) {
            throw "Dockerfile not found: $Dockerfile"
        }

        $image = "${repo}:$GitTag"

        Write-Host "Build context: $BuildContext"
        Write-Host "Image        : $image"

        # ----------------------------------------------------
        # Build
        # ----------------------------------------------------

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

        # ----------------------------------------------------
        # Validate local image
        # ----------------------------------------------------

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

        # ----------------------------------------------------
        # Push
        # ----------------------------------------------------

        Write-Host ""
        Write-Host "Pushing $svc to Amazon ECR..."

        docker push $image

        if ($LASTEXITCODE -ne 0) {
            throw "Docker push failed for service '$svc'."
        }

        Write-Host "Push completed for $svc."

        $Images[$svc] = $image
    }

    # --------------------------------------------------------
    # Verify images in Amazon ECR
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "[8/8] Verifying images in Amazon ECR..."

    $ImageEvidence = @{}

    foreach ($svc in $Services) {

        $repo = $Repos.$svc

        # Example:
        #
        # 276...amazonaws.com/cairops-p6-research/frontend
        #
        # becomes:
        #
        # cairops-p6-research/frontend

        $RepositoryName = (
            $repo -split '/', 2
        )[1]

        if (-not $RepositoryName) {
            throw "Unable to derive ECR repository name from URI: $repo"
        }

        Write-Host ""
        Write-Host "Checking ECR image:"
        Write-Host "  Repository: $RepositoryName"
        Write-Host "  Tag       : $GitTag"

        $ImageDetailsJson = aws ecr describe-images `
            --repository-name $RepositoryName `
            --image-ids "imageTag=$GitTag" `
            --region $Region `
            --query 'imageDetails[0]' `
            --output json

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to verify image '$svc' in Amazon ECR."
        }

        if (-not $ImageDetailsJson) {
            throw "Amazon ECR returned no image details for '$svc'."
        }

        $ImageDetails = $ImageDetailsJson |
            ConvertFrom-Json

        $ImageDigest = $ImageDetails.imageDigest

        if (
            -not $ImageDigest -or
            $ImageDigest -eq 'None'
        ) {
            throw "Image '${svc}:$GitTag' was not found in Amazon ECR."
        }

        Write-Host "Verified digest: $ImageDigest"

        $ImageEvidence[$svc] = @{
            image      = $Images[$svc]
            repository = $RepositoryName
            tag        = $GitTag
            digest     = $ImageDigest
        }
    }

    # --------------------------------------------------------
    # Save immutable experiment image metadata
    # --------------------------------------------------------

    $ImagesFile = Join-Path `
        $Lab `
        'images.json'

    $ImageMetadata = @{
        generated_at_utc = (
            Get-Date
        ).ToUniversalTime().ToString('o')

        aws_account = $Account
        aws_region  = $Region
        eks_cluster = $Cluster

        platform = 'linux/amd64'

        experiment_tag = $GitTag

        images = $ImageEvidence
    }

    $ImagesJson = $ImageMetadata |
        ConvertTo-Json -Depth 10

    [System.IO.File]::WriteAllText(
        $ImagesFile,
        $ImagesJson,
        $Utf8NoBom
    )

    if (-not (Test-Path $ImagesFile)) {
        throw "Unable to write image metadata file."
    }

    # --------------------------------------------------------
    # Final summary
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " CAIROps Container Build & Push Complete"
    Write-Host "============================================================"
    Write-Host ""
    Write-Host "AWS Account    : $Account"
    Write-Host "AWS Region     : $Region"
    Write-Host "EKS Cluster    : $Cluster"
    Write-Host "Docker Platform: linux/amd64"
    Write-Host "Experiment Tag : $GitTag"
    Write-Host ""

    foreach ($svc in $Services) {

        Write-Host "$svc"
        Write-Host "  Image : $($Images[$svc])"
        Write-Host "  Digest: $($ImageEvidence[$svc].digest)"
    }

    Write-Host ""
    Write-Host "Image metadata:"
    Write-Host "  $ImagesFile"
    Write-Host ""
    Write-Host "All three CAIROps images were successfully:"
    Write-Host "  - built"
    Write-Host "  - validated as linux/amd64"
    Write-Host "  - pushed to Amazon ECR"
    Write-Host "  - verified by immutable ECR digest"
    Write-Host ""
}
finally {

    # --------------------------------------------------------
    # Remove temporary ECR credential material
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "Cleaning temporary Docker ECR credentials..."

    if ($OriginalDockerConfig) {
        $env:DOCKER_CONFIG = $OriginalDockerConfig
    }
    else {
        Remove-Item `
            Env:DOCKER_CONFIG `
            -ErrorAction SilentlyContinue
    }

    if (Test-Path $DockerConfigDir) {

        Remove-Item `
            -Path $DockerConfigDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host "Temporary Docker credentials removed."
}