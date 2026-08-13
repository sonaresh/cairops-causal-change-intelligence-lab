$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Tf = Join-Path $Root 'infra\terraform'
$Archive = Join-Path $Root ("evidence-archive-" + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Force -Path $Archive | Out-Null

Push-Location $Tf
$Region = terraform output -raw region
$Bucket = terraform output -raw evidence_bucket
terraform output -json | Out-File -Encoding utf8 (Join-Path $Archive 'terraform-outputs.json')
Pop-Location

aws s3 sync "s3://$Bucket/runs/" (Join-Path $Archive 'runs') --region $Region
if (Test-Path (Join-Path $Root 'evidence')) { Copy-Item -Recurse -Force (Join-Path $Root 'evidence') (Join-Path $Archive 'local-evidence') }
if (Test-Path (Join-Path $Root 'results')) { Copy-Item -Recurse -Force (Join-Path $Root 'results') (Join-Path $Archive 'results') }

kubectl delete namespace cairops-lab --wait=true --timeout=300s 2>$null
Start-Sleep -Seconds 20
Push-Location $Tf
terraform destroy -auto-approve
Pop-Location
Write-Host "Evidence archived before teardown at: $Archive"
