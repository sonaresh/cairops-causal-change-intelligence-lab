DEFAULT_EDGES = [
 ('deployment','memory_pressure',0.85,0.90),
 ('memory_pressure','pod_eviction',0.80,0.88),
 ('pod_eviction','retry_rate',0.85,0.92),
 ('retry_rate','api_errors',0.78,0.86),
 ('retry_rate','db_load',0.80,0.86),
 ('db_load','db_saturation',0.78,0.84),
 ('db_saturation','api_latency',0.90,0.94),
 ('api_latency','slo_violation',0.90,0.95),
 ('slo_violation','business_impact',0.90,0.90),
 ('replica_reduction','queueing',0.82,0.88),
 ('queueing','api_latency',0.82,0.86),
 ('hpa_threshold','capacity_saturation',0.76,0.82),
 ('capacity_saturation','api_errors',0.84,0.88),
 ('security_rule','dependency_timeout',0.95,0.95),
 ('dependency_timeout','api_errors',0.88,0.92),
 ('iam_policy','authorization_denied',0.96,0.96),
 ('authorization_denied','service_error',0.90,0.94),
 ('db_parameter','db_latency',0.78,0.80),
 ('db_latency','api_latency',0.86,0.88),
 ('resource_limit','throttling',0.84,0.88),
 ('throttling','retry_rate',0.76,0.82),
 ('route_weight','hot_backend',0.82,0.86),
 ('hot_backend','api_latency',0.80,0.84),
 ('dependency_version','compat_error',0.86,0.88),
 ('compat_error','api_errors',0.90,0.92),
 ('network_latency','dependency_timeout',0.82,0.86),
]

def merged_edges(overrides=None):
    indexed = {(s, t): [s, t, float(e), float(c)] for s, t, e, c in DEFAULT_EDGES}
    for item in overrides or []:
        s = item.get('source')
        t = item.get('target')
        if not s or not t:
            continue
        old = indexed.get((s, t), [s, t, 0.5, 0.5])
        indexed[(s, t)] = [s, t, float(item.get('effect', old[2])), float(item.get('confidence', old[3]))]
    return [tuple(v) for v in indexed.values()]

def adjacency(overrides=None):
    out = {}
    for s, t, effect, confidence in merged_edges(overrides):
        out.setdefault(s, []).append((t, float(effect), float(confidence)))
    return out

def paths(start, targets, max_depth=8, overrides=None):
    adj = adjacency(overrides)
    found = []
    stack = [(start, [start], 1.0)]
    while stack:
        node, path, score = stack.pop()
        if len(path) > max_depth + 1:
            continue
        if node in targets and len(path) > 1:
            found.append((path, score))
        for nxt, effect, confidence in adj.get(node, []):
            if nxt in path:
                continue
            stack.append((nxt, path + [nxt], score * effect * confidence))
    return sorted(found, key=lambda x: x[1], reverse=True)
