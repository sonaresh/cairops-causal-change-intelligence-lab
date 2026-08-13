from pathlib import Path
import argparse, json
import pandas as pd, numpy as np
import matplotlib.pyplot as plt
from sklearn.metrics import accuracy_score, brier_score_loss
from scipy.stats import wilcoxon
from baselines import rule_score, anomaly_flag, out_of_sample_ml_risk

def load_runs(root):
    rows = []
    for p in Path(root).rglob('*.json'):
        try:
            j = json.loads(p.read_text())
            d = j.get('decision', {})
            b = j.get('baseline', {})
            o = j.get('observation', {})
            top_paths = [x.get('nodes', []) for x in d.get('top_paths', [])]
            expected = j.get('expected_path', [])
            rows.append({
                'run_id': j['run_id'],
                'scenario_id': j['scenario_id'],
                'condition': j['condition'],
                'actual_failure': int(bool(o.get('incident')) or bool(o.get('slo_violation'))),
                'error_rate': o.get('error_rate', 0),
                'p95_latency_ms': o.get('p95_latency_ms', 0),
                'baseline_error_rate': b.get('error_rate', 0),
                'baseline_p95_latency_ms': b.get('p95_latency_ms', 0),
                'cairops_risk': d.get('risk', 0),
                'cairops_confidence': d.get('confidence', 0),
                'guard_action': d.get('guard_action', 'UNKNOWN'),
                'inference_latency_ms': d.get('inference_latency_ms', np.nan),
                'prediction_lead_time_ms_proxy': o.get('prediction_lead_time_ms_proxy', np.nan),
                'change_scope': 0.1 if j['condition'] == 'fixed_canary' else 1.0,
                'validation_confidence': 0.75 if j['condition'] in ('safe', 'governed') else 0.45,
                'reversibility': 0.85,
                'business_criticality': 0.75,
                'top1_path_correct': int(bool(top_paths) and top_paths[0] == expected),
                'top3_path_correct': int(any(path == expected for path in top_paths[:3]))
            })
        except Exception as exc:
            print('skip', p, exc)
    return pd.DataFrame(rows)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--evidence-dir', default='evidence')
    ap.add_argument('--out-dir', default='results')
    args = ap.parse_args()
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    df = load_runs(args.evidence_dir)
    if df.empty:
        raise SystemExit('No evidence JSON found. Run experiments first.')

    df['rule_risk'] = df.apply(rule_score, axis=1)
    df['rule_pred'] = (df.rule_risk >= .65).astype(int)
    df['anomaly_pred'] = df.apply(lambda r: anomaly_flag(r.baseline_error_rate, r.baseline_p95_latency_ms, r.error_rate, r.p95_latency_ms), axis=1)
    df['ml_risk'] = out_of_sample_ml_risk(df)
    df['ml_pred'] = (df.ml_risk.fillna(0) >= .5).astype(int)
    df['cairops_pred'] = (df.cairops_risk >= .65).astype(int)
    df.to_csv(out / 'run_level_metrics.csv', index=False)

    summaries = []
    for name, pred, risk in [
        ('Rules', 'rule_pred', 'rule_risk'),
        ('Anomaly AIOps', 'anomaly_pred', None),
        ('Non-causal ML', 'ml_pred', 'ml_risk'),
        ('CAIROps', 'cairops_pred', 'cairops_risk')
    ]:
        valid = df if risk is None else df[df[risk].notna()]
        summaries.append({
            'system': name,
            'prediction_accuracy': accuracy_score(valid.actual_failure, valid[pred]),
            'brier': brier_score_loss(valid.actual_failure, valid[risk]) if risk else np.nan,
            'n': len(valid)
        })
    summary = pd.DataFrame(summaries)
    summary.to_csv(out / 'system_summary.csv', index=False)

    failure = df[df.condition == 'failure'].groupby('scenario_id').actual_failure.mean()
    governed = df[df.condition == 'governed'].groupby('scenario_id').actual_failure.mean()
    safe = df[df.condition == 'safe']
    aligned = pd.concat([failure.rename('failure'), governed.rename('governed')], axis=1).dropna()
    prevention = ((aligned.failure - aligned.governed).clip(lower=0)).mean() if len(aligned) else np.nan
    false_block = (safe.guard_action == 'BLOCK').mean() if len(safe) else np.nan
    friction = safe.guard_action.isin(['BLOCK', 'APPROVE', 'VALIDATE', 'MODIFY', 'CANARY']).mean() if len(safe) else np.nan
    pd.DataFrame([{
        'cairops_incident_prevention_rate_proxy': prevention,
        'cairops_false_block_rate': false_block,
        'safe_change_intervention_friction_rate': friction
    }]).to_csv(out / 'preventive_metrics.csv', index=False)

    loc = df.groupby('scenario_id').agg(top1_accuracy=('top1_path_correct', 'mean'), top3_accuracy=('top3_path_correct', 'mean'), n=('run_id', 'size')).reset_index()
    loc.to_csv(out / 'causal_localization.csv', index=False)

    if df.cairops_risk.nunique() > 1:
        df['bin'] = pd.cut(df.cairops_risk, bins=np.linspace(0, 1, 6), include_lowest=True)
        cal = df.groupby('bin', observed=True).agg(predicted=('cairops_risk', 'mean'), observed=('actual_failure', 'mean'), n=('actual_failure', 'size')).reset_index()
        cal.to_csv(out / 'calibration.csv', index=False)
        plt.figure(figsize=(6, 5))
        plt.plot([0, 1], [0, 1], '--')
        plt.plot(cal.predicted, cal.observed, 'o-')
        plt.xlabel('Predicted risk')
        plt.ylabel('Observed failure frequency')
        plt.tight_layout()
        plt.savefig(out / 'calibration.png', dpi=200)
        plt.close()

    plt.figure(figsize=(7, 4))
    plt.bar(summary.system, summary.prediction_accuracy)
    plt.ylabel('Prediction accuracy')
    plt.xticks(rotation=20, ha='right')
    plt.tight_layout()
    plt.savefig(out / 'prediction_accuracy.png', dpi=200)
    plt.close()

    piv = df[df.condition.isin(['failure', 'governed'])].pivot_table(index='scenario_id', columns='condition', values='p95_latency_ms', aggfunc='mean').dropna()
    stats = []
    if len(piv) >= 3 and not np.allclose(piv['failure'], piv['governed']):
        stat, p = wilcoxon(piv['failure'], piv['governed'])
        stats.append({'comparison': 'p95 failure vs governed', 'wilcoxon_stat': stat, 'p_value': p, 'n': len(piv)})
    pd.DataFrame(stats).to_csv(out / 'statistical_tests.csv', index=False)

    print('Wrote', out)

if __name__ == '__main__':
    main()
