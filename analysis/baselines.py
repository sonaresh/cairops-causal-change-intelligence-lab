import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import LeaveOneGroupOut

FEATURES = [
    'change_scope','validation_confidence','reversibility',
    'business_criticality','baseline_error_rate','baseline_p95_latency_ms'
]

def rule_score(row):
    score = 0.0
    score += 0.35 if row.get('change_scope', 1) >= 0.8 else 0.10
    score += 0.25 if row.get('business_criticality', .5) >= .7 else 0.10
    score += 0.20 if row.get('validation_confidence', .5) < .6 else 0.0
    score += 0.20 if row.get('reversibility', .5) < .5 else 0.0
    return min(1.0, score)

def anomaly_flag(base_err, base_p95, obs_err, obs_p95):
    return int(obs_err > max(0.05, base_err + 0.10) or obs_p95 > max(600, base_p95 * 2.5))

def out_of_sample_ml_risk(df):
    """Leave-one-scenario-out predictions for E1-E11; E12 is held out and predicted by a model trained on E1-E11."""
    risks = np.full(len(df), np.nan, dtype=float)
    base = df[df['scenario_id'] != 'E12'].copy()
    logo = LeaveOneGroupOut()
    X = base[FEATURES].fillna(0).values
    y = base['actual_failure'].astype(int).values
    groups = base['scenario_id'].values
    for train_idx, test_idx in logo.split(X, y, groups):
        if len(set(y[train_idx])) < 2:
            continue
        model = LogisticRegression(max_iter=2000, class_weight='balanced', random_state=42)
        model.fit(X[train_idx], y[train_idx])
        target_rows = base.iloc[test_idx].index.to_numpy()
        risks[target_rows] = model.predict_proba(X[test_idx])[:, 1]
    e12 = df[df['scenario_id'] == 'E12']
    if not e12.empty and len(set(y)) >= 2:
        final_model = LogisticRegression(max_iter=2000, class_weight='balanced', random_state=42)
        final_model.fit(X, y)
        risks[e12.index.to_numpy()] = final_model.predict_proba(e12[FEATURES].fillna(0).values)[:, 1]
    return risks
