from flask import Flask, jsonify
import os, time, requests, random, threading

app = Flask(__name__)
REQ = ERR = 0
LAT = []
lock = threading.Lock()

def record(ms, ok):
    global REQ, ERR, LAT
    with lock:
        REQ += 1
        ERR += 0 if ok else 1
        LAT.append(ms)
        LAT[:] = LAT[-5000:]

@app.get('/healthz')
def health():
    return {'ok': True}

@app.get('/metrics-json')
def metrics():
    with lock:
        xs = sorted(LAT)
        p95 = xs[int(.95 * (len(xs) - 1))] if xs else 0
        return {'requests': REQ, 'errors': ERR, 'error_rate': ERR / max(1, REQ), 'p95_latency_ms': p95}

@app.get('/work')
def work():
    t = time.perf_counter()
    retries = int(os.getenv('RETRIES', '1'))
    normal = os.getenv('SERVICE_B_URL', 'http://service-b:8080/work')
    hot = os.getenv('HOT_SERVICE_B_URL', 'http://service-b-hot:8080/work')
    hot_pct = float(os.getenv('ROUTE_HOT_PERCENT', '0'))
    expected_version = str(os.getenv('EXPECTED_API_VERSION', '1'))
    url = hot if random.random() < hot_pct / 100.0 else normal
    ok = False
    status = 599
    actual_version = None
    for _ in range(retries + 1):
        try:
            r = requests.get(url, timeout=float(os.getenv('TIMEOUT_S', '1.0')))
            status = r.status_code
            actual_version = str(r.headers.get('X-API-Version', '1'))
            if status < 500 and actual_version == expected_version:
                ok = True
                break
            if status < 500 and actual_version != expected_version:
                status = 502
        except Exception:
            pass
    record((time.perf_counter() - t) * 1000, ok)
    return (jsonify({'service': 'a', 'ok': ok, 'downstream_status': status, 'actual_version': actual_version}), 200 if ok else 500)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
