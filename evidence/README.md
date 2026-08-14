# CAIROps Experiment E1 Evidence

## Experiment
E1 — Bad EKS Deployment / Progressive Memory Exhaustion

## Purpose
This directory preserves reproducible experimental evidence for the CAIROps
research manuscript and associated research-provenance documentation.

## Frozen Experimental Design
- Conditions: SAFE, FAILURE, GOVERNED
- Valid trials per condition: 5
- Accepted final runs: 15
- Baseline requests: 40
- Experimental requests: 120
- Concurrency: 4
- Client timeout: 3 seconds

## Final Experimental Result
- SAFE: 0 incidents / 5 trials
- FAILURE: 5 incidents / 5 trials
- GOVERNED: 0 incidents / 5 trials
- Successful governed interventions: 5 / 5

Mean uncontrolled failure error rate: 41.83%.

The observed 100% prevention rate applies only to the frozen E1 experimental
sample and is not claimed as a universal production prevention rate.

## Evidence Classes

### Final accepted research evidence
accepted-runs/E1/

### Engineering and precheck evidence
engineering-prechecks/E1/

Engineering/precheck runs are preserved for transparency but excluded from
final statistical analysis.

### Excluded final attempts
excluded-runs/E1-exclusions.json

Runs aborted by the baseline-health gate before change injection are excluded
from outcome statistics.

### Frozen configuration
experiment-freezes/E1-v2-final-freeze.json

### Scientific summary
summaries/E1-summary.json

### Research provenance
eb1a/E1-provenance-manifest.json

### Integrity
checksums/SHA256SUMS.txt

Raw accepted evidence was originally written to Amazon S3 and subsequently
exported locally. SHA-256 hashes are used for integrity verification.
