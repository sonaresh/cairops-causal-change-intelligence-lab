from flask import Flask, jsonify, make_response
import os
import time
import random
import threading

app = Flask(__name__)

REQ = 0
ERR = 0
LAT = []

lock = threading.Lock()

MEM = []
memory_lock = threading.Lock()

memory_initialized = False


def record(ms, ok):
    global REQ, ERR, LAT

    with lock:
        REQ += 1
        ERR += 0 if ok else 1

        LAT.append(ms)
        LAT[:] = LAT[-5000:]


def grow_memory():
    """
    Controlled experimental memory growth.

    MEMORY_MB represents the maximum amount of experiment
    memory to allocate.

    MEMORY_GROWTH_MB determines how much additional memory
    is allocated per request.

    This allows the pod to start successfully and memory
    pressure to develop during the experiment instead of
    during Kubernetes rollout.
    """

    target_mb = int(
        os.getenv(
            "MEMORY_MB",
            "0"
        )
    )

    growth_mb = int(
        os.getenv(
            "MEMORY_GROWTH_MB",
            "0"
        )
    )

    if target_mb <= 0:
        return

    if growth_mb <= 0:
        return

    with memory_lock:

        current_mb = len(MEM) * growth_mb

        if current_mb >= target_mb:
            return

        MEM.append(
            bytearray(
                growth_mb
                * 1024
                * 1024
            )
        )


@app.get("/healthz")
def health():
    return {
        "ok": True
    }


@app.get("/metrics-json")
def metrics():

    with lock:

        xs = sorted(
            LAT
        )

        p95 = (
            xs[
                int(
                    .95
                    * (
                        len(xs)
                        - 1
                    )
                )
            ]
            if xs
            else 0
        )

        return {
            "requests": REQ,
            "errors": ERR,
            "error_rate": (
                ERR
                / max(
                    1,
                    REQ
                )
            ),
            "p95_latency_ms": p95,
            "allocated_experiment_mb": sum(
                len(x)
                for x in MEM
            )
            / (
                1024
                * 1024
            ),
        }


@app.get("/work")
def work():

    t = time.perf_counter()

    # Controlled memory growth occurs during traffic,
    # not during container startup.
    grow_memory()

    delay = float(
        os.getenv(
            "DELAY_MS",
            "15"
        )
    ) / 1000.0

    fail = float(
        os.getenv(
            "FAIL_RATE",
            "0"
        )
    )

    if os.getenv(
        "USE_DB",
        "0"
    ) == "1":

        try:

            import psycopg2

            db_delay = float(
                os.getenv(
                    "DB_DELAY_MS",
                    "0"
                )
            ) / 1000.0

            conn = psycopg2.connect(
                host="postgres",
                dbname="postgres",
                user="postgres",
                password="cairops-lab-only",
                connect_timeout=2,
            )

            with conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT pg_sleep(%s)",
                        (
                            db_delay,
                        ),
                    )

            conn.close()

        except Exception:
            fail = 1.0

    time.sleep(
        delay
    )

    ok = (
        random.random()
        >= fail
    )

    record(
        (
            time.perf_counter()
            - t
        )
        * 1000,
        ok,
    )

    response = make_response(
        jsonify(
            {
                "service": "b",
                "ok": ok,
            }
        ),
        200 if ok else 500,
    )

    response.headers[
        "X-API-Version"
    ] = str(
        os.getenv(
            "API_VERSION",
            "1"
        )
    )

    return response


if __name__ == "__main__":

    app.run(
        host="0.0.0.0",
        port=8080,
    )