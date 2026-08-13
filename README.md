# CAIROps AWS Experimental Lab

This repository implements the experimental prototype for **CAIROps: A Causal Change Intelligence Framework for Predicting, Explaining, and Preventing Enterprise Cloud Incidents**.

The repository is designed to generate **measured** evidence for manuscript Sections 9–11. It does not ship precomputed or fabricated research results.

> **Pre-deployment note (2026-08-12):** Use this audited revision, then regenerate `tfplan`. Do not apply a plan created from an older revision. See `docs/PRE_DEPLOYMENT_AUDIT.md`.

## Research mapping

| Manuscript element | Implementation |
|---|---|
| Change Intelligence | `lambda/change_normalizer/` |
| Causal Change Graph | `lambda/cairops_core/graph.py` + DynamoDB graph table |
| CIIR risk model | `lambda/cairops_core/risk.py` |
| Counterfactual evaluation | `lambda/cairops_core/counterfactual.py` |
| Governed Change Guard | `lambda/cairops_core/guard.py` |
| Outcome learning | `lambda/outcome_verifier/` |
| Episode store | DynamoDB `episodes` table |
| Evidence store | Versioned S3 bucket |
| Governed workflow | AWS Step Functions |
| Experimental execution | Amazon EKS namespace `cairops-lab` |
| Telemetry | CloudWatch OTel Container Insights + app `/metrics` endpoints |
| E1-E12 | `experiments/scenarios/` + `experiments/runner.py` |
| Baselines | `analysis/baselines.py` |
| Result aggregation | `analysis/analyze.py` |

The design follows the manuscript's evidence schema: ChangeRecord, StateSnapshot, Prediction, Decision, TelemetryWindow, Outcome, and LearningUpdate.

## Safety boundary

Run this only in a **dedicated non-production AWS account or sandbox**. The experiment runner refuses to start unless `CAIROPS_LAB_ACK=YES` is set. It mutates only resources tagged/named for this lab and the Kubernetes namespace `cairops-lab`.

The lab intentionally creates failures in synthetic workloads. Do not point it at production clusters, production IAM roles, or shared security groups.

## Approximate AWS resources

- VPC + 2 public subnets
- EKS cluster + 2 managed EC2 worker nodes
- ECR repositories for 4 images
- DynamoDB tables: episodes, graph, decisions
- S3 evidence bucket with versioning
- Lambda: change normalizer, CAIROps core, outcome verifier, IAM probe
- EventBridge custom bus
- API Gateway HTTP endpoint (optional ingestion path)
- Step Functions state machine
- Dedicated EC2 dependency endpoint + dedicated security group for E4
- CloudWatch log groups / OTel Container Insights add-on

EKS and EC2 incur hourly charges. Destroy the lab after experiments.

## Prerequisites on Windows / VS Code PowerShell

- AWS CLI v2
- Terraform >= 1.6
- kubectl
- Helm 3
- Docker Desktop
- Python 3.11+
- An AWS IAM principal able to create the resources above

Verify:

```powershell
aws sts get-caller-identity
terraform version
kubectl version --client
helm version
docker version
python --version
```

## Phase 1 - Configure Terraform

```powershell
cd .\infra\terraform
Copy-Item terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set your current public IP `/32` for EKS API access.

```powershell
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

## Phase 2 - Configure kubectl and observability

```powershell
cd ..\..
.\scripts\bootstrap.ps1
```

The bootstrap script:

1. updates kubeconfig,
2. installs metrics-server,
3. creates the lab namespace,
4. enables the Amazon CloudWatch Observability add-on with OTel Container Insights,
5. writes Terraform outputs to `.lab/outputs.json`.

AWS documents OTel Container Insights for EKS through the `amazon-cloudwatch-observability` add-on. This repo uses the add-on rather than a custom collector deployment.

## Phase 3 - Build and deploy the synthetic application

```powershell
.\scripts\build-push.ps1
.\scripts\deploy-app.ps1
kubectl get pods -n cairops-lab
```

Expected deployments:

- `frontend`
- `service-a`
- `service-b`
- `postgres`
- `toxiproxy`

## Phase 4 - Smoke test CAIROps

```powershell
$env:CAIROPS_LAB_ACK='YES'
python .\experiments\runner.py --scenario E1 --condition safe --dry-run
python .\experiments\runner.py --scenario E1 --condition safe
```

Evidence is written to local `evidence/` and uploaded to S3.

## Phase 5 - Run the experiment matrix

Recommended research protocol:

- `safe`: normal control
- `failure`: unmitigated failure-inducing change
- `governed`: CAIROps recommendation is applied when feasible
- `fixed_canary`: optional fixed 10% canary baseline for E1/E8/E9

Start with 5 repetitions to validate collection, then use 20-30 repetitions per condition for the final manuscript if cost/time allows.

```powershell
$env:CAIROPS_LAB_ACK='YES'
python .\experiments\run_matrix.py --repetitions 5
```

## Experiment scenarios

| ID | Change | Failure mechanism |
|---|---|---|
| E1 | Application version | Memory growth -> eviction/restarts -> retries |
| E2 | Replica reduction | Capacity shortage -> queueing -> latency |
| E3 | HPA threshold | Late scale-out -> saturation/errors |
| E4 | Dedicated security-group rule | Dependency connectivity loss -> timeout |
| E5 | Dedicated IAM probe policy | Authorization failure |
| E6 | PostgreSQL configuration/workload parameter | DB latency increase |
| E7 | CPU/memory limits | Throttling/restarts -> retries |
| E8 | Route weight | Traffic imbalance -> hot backend |
| E9 | Dependency version | Compatibility errors |
| E10 | Toxiproxy network latency | Cross-service latency -> timeout |
| E11 | Combined E1 + E2 | Cascading failure |
| E12 | Unseen CPU throttling + retry pattern | Generalization test |

## Baselines

`analysis/baselines.py` implements:

- Rule baseline: static threshold/policy score.
- Anomaly baseline: post-execution z-score detection from runtime telemetry.
- Non-causal ML baseline: logistic regression trained **only on collected labeled runs**.
- CAIROps: causal graph + CIIR + counterfactual + Guard.

Do not train or tune the ML baseline on E12. `analysis/analyze.py` keeps E12 as a held-out generalization scenario.

## Generate manuscript results

After enough runs:

```powershell
python .\analysis\analyze.py --evidence-dir .\evidence --out-dir .\results
```

Outputs:

- `results/run_level_metrics.csv`
- `results/system_summary.csv`
- `results/calibration.csv`
- `results/causal_localization.csv`
- `results/statistical_tests.csv`
- PNG plots for prevention/false-block, lead time, calibration, localization, impact reduction, and latency

These outputs are intended to populate manuscript Tables 8-9 and the measured result figures.

## Destroy

```powershell
.\scripts\destroy.ps1
```

The script deletes Kubernetes load-balancer resources first, then runs Terraform destroy.

## Important research rule

Never manually type a desired result into `evidence/` or `results/`. Every quantitative manuscript claim should be traceable to a run manifest, raw observation, and analysis output.
