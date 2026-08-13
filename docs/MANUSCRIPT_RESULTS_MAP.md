# Manuscript results map

| Manuscript result | Generated evidence |
|---|---|
| Table 8 prevention rate | `results/preventive_metrics.csv` + run-level evidence |
| Table 8 false-block rate | safe-run Guard actions |
| Table 8 lead time | add CloudWatch first-symptom timestamp to the final run protocol |
| Table 9 Top-1/Top-3 causal path | `decision.top_paths` compared with `expected_path` |
| Calibration | `results/calibration.csv`, `calibration.png` |
| Prediction accuracy | `results/system_summary.csv` |
| Intervention success | governed condition vs failure control |
| Business/SLO impact reduction | failure vs governed error-rate and p95 delta |
| Inference latency | `decision.inference_latency_ms` |
| Computational overhead | CloudWatch Lambda duration + EKS resource metrics |

Before publication, extend the analyzer to compute confidence intervals and the exact statistical tests stated in Section 10.5 using the final repetition count.
