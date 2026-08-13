def guard(risk, confidence, alternatives, criticality, reversibility):
    if confidence < 0.45:
        return 'VALIDATE','insufficient_evidence'
    if risk < 0.35:
        return ('ALLOW' if confidence>=0.70 else 'OBSERVE'),'low_risk'
    best=alternatives[0]['action'] if alternatives else 'APPROVE'
    if risk < 0.75:
        if best in {'CANARY','MODIFY','VALIDATE'}: return best,'safer_alternative'
        return 'APPROVE','moderate_risk'
    if criticality >= 0.80 and risk >= 0.85 and confidence >= 0.80 and reversibility < 0.50:
        return 'BLOCK','high_risk_critical_low_reversibility'
    if best in {'CANARY','MODIFY','VALIDATE'}: return best,'high_risk_but_mitigatable'
    return 'APPROVE','high_risk_requires_human'
