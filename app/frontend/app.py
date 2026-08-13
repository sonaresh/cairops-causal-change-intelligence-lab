from flask import Flask, jsonify
import os, time, requests, threading

app = Flask(__name__)
REQ = ERR = 0
LAT = []
lock = threading.Lock()
MEM = []

def record(ms, ok):
    global REQ, ERR, LAT
    with lock:
        REQ += 1
        ERR += 0 if ok else 1
        LAT.append(ms)
        LAT[:] = LAT[-5000:]

def allocate():
    mb = int(os.getenv('MEMORY_MB', '0'))
    if mb > 0:
        MEM.append(bytearray(mb * 1024 * 1024))

allocate()

@app.get('/healthz')
def health():
    return {'ok': True}

@app.get('/metrics-json')
def metrics():
    with lock:
        xs = sorted(LAT)
        p95 = xs[int(.95 * (len(xs) - 1))] if xs else 0
        return {'requests': REQ, 'errors': ERR, 'error_rate': ERR / max(1, REQ), 'p95_latency_ms': p95}

@app.get('/')
def root():
    burn_ms = int(os.getenv('CPU_BURN_MS', '0'))
    if burn_ms > 0:
        end = time.perf_counter() + burn_ms / 1000.0
        x = 1
        while time.perf_counter() < end:
            x = (x * 1664525 + 1013904223) & 0xFFFFFFFF
    t = time.perf_counter()
    url = os.getenv('SERVICE_A_URL', 'http://service-a:8080/work')
    ok = False
    status = 599
    try:
        r = requests.get(url, timeout=float(os.getenv('TIMEOUT_S', '1.5')))
        status = r.status_code
        ok = status < 500
    except Exception:
        pass
    record((time.perf_counter() - t) * 1000, ok)
    return (jsonify({'service': 'frontend', 'ok': ok, 'downstream_status': status}), 200 if ok else 500)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
