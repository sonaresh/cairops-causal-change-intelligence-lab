from pathlib import Path
import json, subprocess, time, urllib.request, yaml, statistics
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / '.lab'

def run(cmd, check=True, capture=True):
    p = subprocess.run(cmd, shell=isinstance(cmd, str), text=True, capture_output=capture)
    if check and p.returncode != 0:
        raise RuntimeError(f"Command failed: {cmd}\n{p.stdout}\n{p.stderr}")
    return p.stdout.strip()

def load_outputs():
    return json.loads((LAB / 'outputs.json').read_text())

def scenario(sid):
    return yaml.safe_load((ROOT / 'experiments' / 'scenarios' / f'{sid}.yaml').read_text())

def kubectl(args, check=True):
    return run(['kubectl'] + args, check=check)

def aws(args, check=True):
    return run(['aws'] + args, check=check)

def wait_rollout(dep):
    kubectl(['rollout', 'status', f'deployment/{dep}', '-n', 'cairops-lab', '--timeout=240s'])

def patch_env(dep, kv):
    args = ['set', 'env', f'deployment/{dep}', '-n', 'cairops-lab'] + [f'{k}={v}' for k, v in kv.items()]
    kubectl(args)
    wait_rollout(dep)

def scale(dep, n):
    kubectl(['scale', f'deployment/{dep}', '-n', 'cairops-lab', f'--replicas={n}'])
    wait_rollout(dep)

def set_resources(dep, cpu, memory):
    kubectl([
        'set', 'resources', f'deployment/{dep}', '-n', 'cairops-lab',
        '--limits', f'cpu={cpu},memory={memory}',
        '--requests', 'cpu=50m,memory=64Mi'
    ])
    wait_rollout(dep)

def hpa_cpu(n):
    patch = json.dumps({'spec': {'metrics': [{'type': 'Resource', 'resource': {'name': 'cpu', 'target': {'type': 'Utilization', 'averageUtilization': int(n)}}}]}})
    kubectl(['patch', 'hpa', 'frontend', '-n', 'cairops-lab', '--type=merge', '-p', patch])

def endpoint(timeout=300):
    end = time.time() + timeout
    while time.time() < end:
        host = kubectl(['get', 'svc', 'frontend', '-n', 'cairops-lab', '-o', 'jsonpath={.status.loadBalancer.ingress[0].hostname}'], check=False)
        if host:
            return f'http://{host}/'
        time.sleep(5)
    raise TimeoutError('Frontend LoadBalancer hostname not available')

def _one_request(url, timeout):
    t = time.perf_counter()
    ok = False
    status = 599
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            status = r.status
            ok = status < 500
    except Exception:
        ok = False
    return (time.perf_counter() - t) * 1000, ok, status

def measure(url, requests_n=120, timeout=3, concurrency=12):
    latencies = []
    errors = 0
    first_error_ms = None
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(_one_request, url, timeout) for _ in range(requests_n)]
        for future in as_completed(futures):
            latency, ok, _ = future.result()
            latencies.append(latency)
            if not ok:
                errors += 1
                if first_error_ms is None:
                    first_error_ms = (time.perf_counter() - started) * 1000
    xs = sorted(latencies)
    p95 = xs[int(.95 * (len(xs) - 1))] if xs else 0
    error_rate = errors / max(1, requests_n)
    return {
        'requests': requests_n,
        'concurrency': concurrency,
        'errors': errors,
        'error_rate': error_rate,
        'p95_latency_ms': p95,
        'mean_latency_ms': statistics.mean(latencies) if latencies else 0,
        'first_error_elapsed_ms': first_error_ms,
        'incident': error_rate >= 0.20 or p95 >= 1200,
        'slo_violation': error_rate >= 0.05 or p95 >= 600
    }
