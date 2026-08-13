def alternatives(change, base_risk):
    ctype=change.get('type','unknown')
    items=[{'action':'ALLOW','risk':base_risk,'cost':0.05,'delay':0.0,'disruption':0.0,'policy':True}]
    items.append({'action':'CANARY','risk':base_risk*0.45,'cost':0.15,'delay':0.15,'disruption':0.10,'policy':True,'scope':0.10})
    items.append({'action':'VALIDATE','risk':base_risk*0.65,'cost':0.10,'delay':0.35,'disruption':0.05,'policy':True})
    items.append({'action':'BLOCK','risk':0.02,'cost':0.25,'delay':1.0,'disruption':0.50,'policy':True})
    if ctype in {'deployment','resource_limit','hpa_threshold','route_weight','db_parameter','dependency_version'}:
        items.append({'action':'MODIFY','risk':base_risk*0.35,'cost':0.25,'delay':0.25,'disruption':0.15,'policy':True})
    for x in items:
        x['objective']=x['risk']+0.25*x['cost']+0.20*x['delay']+0.15*x['disruption']
    return sorted(items,key=lambda x:x['objective'])
