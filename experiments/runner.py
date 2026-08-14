import argparse
import os
import json
import time
import uuid
import datetime
import subprocess
import urllib.error
import urllib.request

from pathlib import Path
from common import *


ROOT = Path(__file__).resolve().parents[1]


# ============================================================
# Safety acknowledgement
# ============================================================

def ensure_ack(dry):
    if dry:
        return

    if os.getenv("CAIROPS_LAB_ACK") != "YES":
        raise SystemExit(
            "Set CAIROPS_LAB_ACK=YES after confirming "
            "this is a dedicated non-production lab."
        )


# ============================================================
# Restore canonical baseline
# ============================================================

def reset_base():

    patch_env(
        "frontend",
        {
            "MEMORY_MB": "0",
            "CPU_BURN_MS": "0",
        },
    )

    patch_env(
        "service-a",
        {
            "RETRIES": "1",
            "SERVICE_B_URL": "http://service-b:8080/work",
            "HOT_SERVICE_B_URL": "http://service-b-hot:8080/work",
            "ROUTE_HOT_PERCENT": "0",
            "EXPECTED_API_VERSION": "1",
        },
    )

    patch_env(
        "service-b",
        {
            "DELAY_MS": "15",
            "FAIL_RATE": "0",
            "MEMORY_MB": "0",
            "MEMORY_GROWTH_MB": "0",
            "API_VERSION": "1",
            "USE_DB": "0",
            "DB_DELAY_MS": "0",
        },
    )

    scale(
        "frontend",
        2,
    )

    scale(
        "service-a",
        2,
    )

    scale(
        "service-b",
        2,
    )

    set_hpa_bounds(
        "frontend",
        2,
        6,
    )

    hpa_cpu(
        60
    )

    set_resources(
        "frontend",
        "600m",
        "256Mi",
    )

    set_resources(
        "service-b",
        "500m",
        "192Mi",
    )

    # Restore E4 security-group mutation
    # if a previous experiment terminated early.
    sg_change(
        False
    )

    # Restore E5 IAM mutation
    # if a previous experiment terminated early.
    iam_change(
        False,
        f"reset-{int(time.time())}",
        invoke_probe=False,
    )


# ============================================================
# Baseline stabilization
# ============================================================

def stabilize_baseline():
    """
    Wait for canonical Kubernetes workloads to become stable
    after reset/base mutations before measured traffic starts.

    Warm-up traffic is engineering stabilization only. It is not
    included in the official 40-request baseline or experimental
    observation.
    """

    deployments = [
        "frontend",
        "service-a",
        "service-b",
    ]

    for deployment in deployments:

        kubectl(
            [
                "rollout",
                "status",
                f"deployment/{deployment}",
                "-n",
                "cairops-lab",
                "--timeout=120s",
            ]
        )

    # Give kube-proxy/load-balancer paths and application
    # connection pools a short deterministic settling interval.
    time.sleep(
        15
    )

    warmup = measure(
        endpoint(),
        requests_n=20,
        concurrency=4,
        timeout=3,
    )

    print(
        "Baseline warm-up:",
        json.dumps(
            warmup,
            indent=2,
        ),
    )

    return warmup


# ============================================================
# HPA bounds control
# ============================================================

def set_hpa_bounds(
    name,
    min_replicas,
    max_replicas,
):
    """
    Temporarily control HPA replica bounds.

    E2 uses this to isolate replica-reduction behavior from
    automatic HPA recovery.

    reset_base() restores the normal frontend bounds:
        minReplicas = 2
        maxReplicas = 6
    """

    kubectl(
        [
            "patch",
            "hpa",
            name,
            "-n",
            "cairops-lab",
            "--type=merge",
            "-p",
            json.dumps(
                {
                    "spec": {
                        "minReplicas":
                        int(min_replicas),
                        "maxReplicas":
                        int(max_replicas),
                    }
                }
            ),
        ]
    )



# ============================================================
# Kubernetes execution-state verification
# ============================================================

def wait_for_deployment_replicas(
    deployment,
    expected_replicas,
    timeout=120,
):
    """
    Wait until the Deployment spec and Ready replica count both
    equal the expected experimental replica count.

    This prevents the measured observation window from starting
    while Kubernetes/HPA/rolling-update convergence is still in
    progress.
    """

    end = time.time() + timeout
    last_state = None

    while time.time() < end:

        raw = kubectl(
            [
                "get",
                "deployment",
                deployment,
                "-n",
                "cairops-lab",
                "-o",
                "json",
            ]
        )

        state = json.loads(
            raw
        )

        desired = int(
            state.get(
                "spec",
                {}
            ).get(
                "replicas",
                0
            )
            or 0
        )

        ready = int(
            state.get(
                "status",
                {}
            ).get(
                "readyReplicas",
                0
            )
            or 0
        )

        available = int(
            state.get(
                "status",
                {}
            ).get(
                "availableReplicas",
                0
            )
            or 0
        )

        updated = int(
            state.get(
                "status",
                {}
            ).get(
                "updatedReplicas",
                0
            )
            or 0
        )

        last_state = {
            "deployment": deployment,
            "expected_replicas": int(
                expected_replicas
            ),
            "desired_replicas": desired,
            "ready_replicas": ready,
            "available_replicas": available,
            "updated_replicas": updated,
        }

        if (
            desired
            == int(expected_replicas)
            and ready
            == int(expected_replicas)
            and available
            == int(expected_replicas)
            and updated
            == int(expected_replicas)
        ):
            print(
                "Execution replica state:",
                json.dumps(
                    last_state,
                    indent=2,
                ),
            )

            return last_state

        time.sleep(
            2
        )

    raise RuntimeError(
        "REPLICA_STATE_INVALID: deployment did not converge "
        f"to expected replicas within {timeout}s. "
        f"LastState={json.dumps(last_state)}"
    )


def get_hpa_state(
    name,
):
    """
    Capture current HPA bounds and replica status for experiment
    provenance and engineering diagnostics.
    """

    raw = kubectl(
        [
            "get",
            "hpa",
            name,
            "-n",
            "cairops-lab",
            "-o",
            "json",
        ]
    )

    hpa = json.loads(
        raw
    )

    spec = hpa.get(
        "spec",
        {}
    )

    status = hpa.get(
        "status",
        {}
    )

    result = {
        "name": name,
        "min_replicas": spec.get(
            "minReplicas"
        ),
        "max_replicas": spec.get(
            "maxReplicas"
        ),
        "current_replicas": status.get(
            "currentReplicas"
        ),
        "desired_replicas": status.get(
            "desiredReplicas"
        ),
    }

    print(
        "Execution HPA state:",
        json.dumps(
            result,
            indent=2,
        ),
    )

    return result


def verify_execution_state(
    scenario_data,
    actions,
):
    """
    Verify the Kubernetes state actually produced by the selected
    experimental action before outcome measurement begins.

    For scenarios with explicit scale actions, the runner waits
    for the target deployment to converge to that exact replica
    count.

    For scenarios with hpa_bounds, the current HPA state is also
    captured.
    """

    execution_state = {}

    if (
        actions
        and "hpa_bounds"
        in actions
    ):

        hpa = actions[
            "hpa_bounds"
        ]

        execution_state[
            "hpa"
        ] = get_hpa_state(
            hpa[
                "name"
            ]
        )

    if (
        actions
        and "scale"
        in actions
    ):

        scale_action = actions[
            "scale"
        ]

        execution_state[
            "deployment"
        ] = wait_for_deployment_replicas(
            scale_action[
                "deployment"
            ],
            scale_action[
                "replicas"
            ],
        )

    return execution_state


# ============================================================
# E4 - Security Group mutation
# ============================================================

def sg_change(revoke):

    outputs = load_outputs()

    dependency_sg = outputs[
        "dependency_sg_id"
    ]["value"]

    node_sg = outputs[
        "node_security_group_id"
    ]["value"]

    region = outputs[
        "region"
    ]["value"]

    response = aws(
        [
            "ec2",
            "describe-security-groups",
            "--group-ids",
            dependency_sg,
            "--region",
            region,
            "--output",
            "json",
        ]
    )

    rules = json.loads(
        response
    )["SecurityGroups"][0][
        "IpPermissions"
    ]

    matching = [
        rule
        for rule in rules
        if (
            rule.get("FromPort") == 8080
            and any(
                pair.get("GroupId")
                == node_sg
                for pair in rule.get(
                    "UserIdGroupPairs",
                    [],
                )
            )
        )
    ]

    permission = json.dumps(
        [
            {
                "IpProtocol": "tcp",
                "FromPort": 8080,
                "ToPort": 8080,
                "UserIdGroupPairs": [
                    {
                        "GroupId": node_sg
                    }
                ],
            }
        ]
    )

    if revoke:

        if matching:

            aws(
                [
                    "ec2",
                    "revoke-security-group-ingress",
                    "--group-id",
                    dependency_sg,
                    "--ip-permissions",
                    permission,
                    "--region",
                    region,
                ],
                check=False,
            )

    else:

        if not matching:

            aws(
                [
                    "ec2",
                    "authorize-security-group-ingress",
                    "--group-id",
                    dependency_sg,
                    "--ip-permissions",
                    permission,
                    "--region",
                    region,
                ],
                check=False,
            )


# ============================================================
# E5 - IAM mutation
# ============================================================

def iam_change(
    deny,
    run_id,
    invoke_probe=True,
):

    outputs = load_outputs()

    role = outputs[
        "iam_probe_role_name"
    ]["value"]

    region = outputs[
        "region"
    ]["value"]

    if deny:

        policy = json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Deny",
                        "Action": "s3:PutObject",
                        "Resource": "*",
                    }
                ],
            }
        )

        aws(
            [
                "iam",
                "put-role-policy",
                "--role-name",
                role,
                "--policy-name",
                "CAIROpsExperimentDeny",
                "--policy-document",
                policy,
            ]
        )

    else:

        aws(
            [
                "iam",
                "delete-role-policy",
                "--role-name",
                role,
                "--policy-name",
                "CAIROpsExperimentDeny",
            ],
            check=False,
        )

    if invoke_probe:

        time.sleep(
            2
        )

        return measure_iam_probe(
            run_id
        )


# ============================================================
# IAM probe measurement
# ============================================================

def measure_iam_probe(run_id):

    outputs = load_outputs()

    function_name = outputs[
        "iam_probe_function"
    ]["value"]

    region = outputs[
        "region"
    ]["value"]

    output_file = (
        ROOT
        / ".lab"
        / f"iam-probe-{run_id}.json"
    )

    process = subprocess.run(
        [
            "aws",
            "lambda",
            "invoke",
            "--function-name",
            function_name,
            "--region",
            region,
            "--cli-binary-format",
            "raw-in-base64-out",
            "--payload",
            json.dumps(
                {
                    "run_id": run_id
                }
            ),
            str(
                output_file
            ),
        ],
        text=True,
        capture_output=True,
    )

    metadata = {}

    try:

        metadata = json.loads(
            process.stdout
            or "{}"
        )

    except Exception:

        pass

    payload = {}

    if output_file.exists():

        try:

            payload = json.loads(
                output_file.read_text()
            )

        except Exception:

            payload = {
                "raw": output_file.read_text(
                    errors="ignore"
                )
            }

    failed = (
        process.returncode != 0
        or bool(
            metadata.get(
                "FunctionError"
            )
        )
        or (
            "errorMessage"
            in payload
        )
    )

    return {
        "requests": 1,
        "errors": int(
            failed
        ),
        "error_rate": float(
            failed
        ),
        "p95_latency_ms": 0,
        "mean_latency_ms": 0,
        "incident": failed,
        "slo_violation": failed,
        "lambda_metadata": metadata,
        "lambda_payload": payload,
    }


# ============================================================
# E4 external dependency
# ============================================================

def use_dependency_endpoint():

    outputs = load_outputs()

    ip = outputs[
        "dependency_private_ip"
    ]["value"]

    patch_env(
        "service-a",
        {
            "SERVICE_B_URL": (
                f"http://{ip}:8080/work"
            ),
            "RETRIES": "0",
        },
    )


# ============================================================
# E10 Toxiproxy
# ============================================================

def toxiproxy(ms):

    process = subprocess.Popen(
        [
            "kubectl",
            "port-forward",
            "svc/toxiproxy",
            "8474:8474",
            "-n",
            "cairops-lab",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:

        time.sleep(
            2
        )

        def req(
            method,
            path,
            obj=None,
        ):

            data = (
                json.dumps(
                    obj
                ).encode()
                if obj is not None
                else None
            )

            request = urllib.request.Request(
                (
                    "http://127.0.0.1:8474"
                    + path
                ),
                data=data,
                method=method,
                headers={
                    "Content-Type":
                    "application/json"
                },
            )

            try:

                urllib.request.urlopen(
                    request,
                    timeout=3,
                ).read()

            except urllib.error.HTTPError as exc:

                if exc.code not in (
                    404,
                    409,
                ):
                    raise

        req(
            "POST",
            "/proxies",
            {
                "name": "service-b",
                "listen": "0.0.0.0:8666",
                "upstream": "service-b:8080",
            },
        )

        req(
            "DELETE",
            "/proxies/service-b/toxics/latency",
        )

        if ms > 0:

            req(
                "POST",
                "/proxies/service-b/toxics",
                {
                    "name": "latency",
                    "type": "latency",
                    "stream": "downstream",
                    "toxicity": 1.0,
                    "attributes": {
                        "latency": int(
                            ms
                        ),
                        "jitter": 20,
                    },
                },
            )

        patch_env(
            "service-a",
            {
                "SERVICE_B_URL":
                "http://toxiproxy:8666/work"
            },
        )

    finally:

        process.terminate()


# ============================================================
# Apply experiment actions
# ============================================================

def apply_actions(
    actions,
    run_id,
):

    if not actions:
        return

    actions = json.loads(
        json.dumps(
            actions
        )
    )

    # --------------------------------------------------------
    # HPA bounds first
    #
    # E2 must constrain autoscaling before the replica mutation
    # is executed so the HPA cannot undo the experiment.
    # --------------------------------------------------------

    if "hpa_bounds" in actions:

        item = actions[
            "hpa_bounds"
        ]

        set_hpa_bounds(
            item[
                "name"
            ],
            item[
                "min_replicas"
            ],
            item[
                "max_replicas"
            ],
        )

    # --------------------------------------------------------
    # Environment mutation
    # --------------------------------------------------------

    if "patch_env" in actions:

        item = actions[
            "patch_env"
        ]

        deployment = item.pop(
            "deployment"
        )

        patch_env(
            deployment,
            item,
        )

    # --------------------------------------------------------
    # Explicit replica count after HPA has been constrained
    # --------------------------------------------------------

    if "scale" in actions:

        item = actions[
            "scale"
        ]

        scale(
            item[
                "deployment"
            ],
            item[
                "replicas"
            ],
        )

    if "set_resources" in actions:

        item = actions[
            "set_resources"
        ]

        set_resources(
            item[
                "deployment"
            ],
            item[
                "cpu"
            ],
            item[
                "memory"
            ],
        )

    if "hpa_cpu" in actions:

        hpa_cpu(
            actions[
                "hpa_cpu"
            ]
        )

    if actions.get(
        "use_dependency_endpoint"
    ):

        use_dependency_endpoint()

    if actions.get(
        "sg_revoke"
    ) is not None:

        sg_change(
            bool(
                actions[
                    "sg_revoke"
                ]
            )
        )

    if actions.get(
        "iam_deny"
    ) is not None:

        iam_change(
            bool(
                actions[
                    "iam_deny"
                ]
            ),
            run_id,
            invoke_probe=False,
        )

    if (
        "toxiproxy_latency_ms"
        in actions
    ):

        toxiproxy(
            actions[
                "toxiproxy_latency_ms"
            ]
        )


# ============================================================
# Publish proposed change to EventBridge
# ============================================================

def publish_change(
    scenario_data,
    condition,
    run_id,
):

    outputs = load_outputs()

    region = outputs[
        "region"
    ]["value"]

    event_bus = outputs[
        "event_bus"
    ]["value"]

    scope = (
        0.10
        if condition
        == "fixed_canary"
        else 1.0
    )

    validation_confidence = 0.70

    if condition in {
        "failure",
        "governed",
        "fixed_canary",
    }:
        proposed_diff = scenario_data.get(
            "failure",
            {},
        )
    else:
        proposed_diff = scenario_data.get(
            "safe",
            scenario_data.get(
                "baseline",
                {},
            ),
        )

    detail = {
        "run_id": run_id,
        "scenario_id": scenario_data[
            "id"
        ],
        "condition": condition,
        "type": scenario_data[
            "type"
        ],
        "target": scenario_data[
            "target"
        ],
        "diff": proposed_diff,
        "risk_context": scenario_data.get(
            "risk_context",
            {},
        ),
        "scope": scope,
        "validation_confidence": (
            validation_confidence
        ),
        "reversibility": 0.85,
        "business_criticality": 0.75,
        "expected_path": scenario_data[
            "expected_path"
        ],
        "state": {
            "historical_failure_association": 0.55,
            "dependency_criticality": 0.70,
            "evidence_coverage": 0.80,
            "graph_confidence": 0.80,
            "telemetry_noise": 0.10,
        },
    }

    entries = json.dumps(
        [
            {
                "Source": "cairops.lab",
                "DetailType": "CAIROpsChange",
                "Detail": json.dumps(
                    detail
                ),
                "EventBusName": event_bus,
            }
        ]
    )

    aws(
        [
            "events",
            "put-events",
            "--region",
            region,
            "--entries",
            entries,
        ]
    )

    return detail


# ============================================================
# DynamoDB conversion
# ============================================================

def _ddb_decode(value):

    if not isinstance(
        value,
        dict,
    ):
        return value

    if "S" in value:
        return value["S"]

    if "N" in value:
        return float(
            value["N"]
        )

    if "BOOL" in value:
        return value["BOOL"]

    if "NULL" in value:
        return None

    if "L" in value:
        return [
            _ddb_decode(v)
            for v in value[
                "L"
            ]
        ]

    if "M" in value:
        return {
            k: _ddb_decode(v)
            for k, v
            in value[
                "M"
            ].items()
        }

    return {
        k: _ddb_decode(v)
        for k, v
        in value.items()
    }


# ============================================================
# Retrieve CAIROps prediction/decision
# ============================================================

def get_decision(run_id, timeout=90):
    o = load_outputs()

    table = o['decisions_table']['value']
    region = o['region']['value']

    end = time.time() + timeout
    last_raw = None

    while time.time() < end:
        raw = aws(
            [
                'dynamodb',
                'get-item',
                '--table-name',
                table,
                '--key',
                json.dumps(
                    {
                        'run_id': {
                            'S': run_id
                        }
                    }
                ),
                '--region',
                region,
                '--consistent-read',
                '--output',
                'json'
            ],
            check=False
        )

        last_raw = raw

        if raw and raw.strip():
            try:
                response = json.loads(raw)
            except json.JSONDecodeError:
                print(
                    f'Waiting for valid DynamoDB response '
                    f'for run_id={run_id}. Raw response: {raw!r}'
                )
                time.sleep(2)
                continue

            item = response.get('Item')

            if item:
                return _ddb_decode(item)

        time.sleep(2)

    raise TimeoutError(
        f'Decision not found for run_id={run_id} '
        f'within {timeout}s. Last response={last_raw!r}'
    )


# ============================================================
# Outcome verification
# ============================================================

def invoke_verifier(
    run_id,
    condition,
    expected_path,
    observation,
):

    outputs = load_outputs()

    function_name = outputs[
        "outcome_verifier_function"
    ]["value"]

    region = outputs[
        "region"
    ]["value"]

    output_file = (
        ROOT
        / ".lab"
        / f"verifier-{run_id}.json"
    )

    payload = {
        "run_id": run_id,
        "condition": condition,
        "expected_path": expected_path,
        "observation": observation,
    }

    aws(
        [
            "lambda",
            "invoke",
            "--function-name",
            function_name,
            "--region",
            region,
            "--cli-binary-format",
            "raw-in-base64-out",
            "--payload",
            json.dumps(
                payload
            ),
            str(
                output_file
            ),
        ]
    )

    if output_file.exists():

        return json.loads(
            output_file.read_text()
        )

    return {}


# ============================================================
# Measure scenario
# ============================================================

def observe(
    scenario_data,
    run_id,
    requests_n,
):

    if (
        scenario_data[
            "id"
        ]
        == "E5"
    ):

        return measure_iam_probe(
            run_id
        )

    return measure(
        endpoint(),
        requests_n=requests_n,
    )


# ============================================================
# Main experiment runner
# ============================================================

def main():

    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--scenario",
        required=True,
    )

    parser.add_argument(
        "--condition",
        choices=[
            "safe",
            "failure",
            "governed",
            "fixed_canary",
        ],
        required=True,
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
    )

    parser.add_argument(
        "--requests",
        type=int,
        default=120,
    )

    args = parser.parse_args()

    ensure_ack(
        args.dry_run
    )

    scenario_data = scenario(
        args.scenario
    )

    run_id = (
        f"{args.scenario}-"
        f"{args.condition}-"
        f"{datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')}-"
        f"{uuid.uuid4().hex[:6]}"
    )

    print(
        json.dumps(
            {
                "run_id": run_id,
                "scenario": scenario_data,
                "condition": args.condition,
            },
            indent=2,
        )
    )

    if args.dry_run:
        return

    # --------------------------------------------------------
    # 1. Restore environment
    # --------------------------------------------------------

    reset_base()

    # Wait for reset-induced Kubernetes rollouts and warm the
    # application before the official baseline is measured.
    stabilize_baseline()

    # --------------------------------------------------------
    # 2. Apply scenario-specific baseline if configured
    # --------------------------------------------------------

    if scenario_data.get(
        "baseline"
    ):

        apply_actions(
            scenario_data.get(
                "baseline"
            ),
            run_id
            + "-baseline",
        )

        # Scenario-specific baseline actions may themselves
        # trigger a rollout or endpoint cold state.
        stabilize_baseline()

    # --------------------------------------------------------
    # 3. Measure official baseline
    # --------------------------------------------------------

    baseline = observe(
        scenario_data,
        run_id
        + "-baseline",
        40,
    )

    # --------------------------------------------------------
    # Baseline validity gate
    #
    # Never execute an experimental mutation against an
    # already-unhealthy baseline. Such a run is invalid for
    # causal attribution and must be aborted before the change.
    # --------------------------------------------------------

    if (
        baseline.get(
            "incident",
            False
        )
        or baseline.get(
            "slo_violation",
            False
        )
        or baseline.get(
            "error_rate",
            0
        ) > 0
    ):
        raise RuntimeError(
            "BASELINE_INVALID: experiment aborted before "
            f"change injection. Baseline={json.dumps(baseline)}"
        )

    # --------------------------------------------------------
    # 4. Restore canonical base
    # --------------------------------------------------------

    reset_base()

    # reset_base() can trigger fresh rollout activity. Ensure
    # the experiment begins from a settled canonical state
    # before CAIROps receives the proposed change.
    stabilize_baseline()

    # --------------------------------------------------------
    # 5. Publish proposed change to CAIROps
    # --------------------------------------------------------

    decision_started = (
        time.time()
    )

    publish_change(
        scenario_data,
        args.condition,
        run_id,
    )

    # --------------------------------------------------------
    # 6. Wait for CAIROps governed decision
    # --------------------------------------------------------

    decision = get_decision(
        run_id
    )

    decision_received = (
        time.time()
    )

    print(
        "CAIROps decision:",
        json.dumps(
            decision,
            indent=2,
        ),
    )

    # --------------------------------------------------------
    # 7. Determine experiment action
    # --------------------------------------------------------

    if args.condition == "safe":

        actions = scenario_data.get(
            "safe",
            scenario_data.get(
                "baseline",
                {},
            ),
        )

    else:

        actions = scenario_data.get(
            "failure",
            {},
        )

    # Governed condition:
    # CAIROps can replace the risky action with the safer
    # intervention specified in the scenario.
    if args.condition == "governed":

        governed_actions = {
            "CANARY",
            "MODIFY",
            "VALIDATE",
            "BLOCK",
            "APPROVE",
        }

        if (
            decision.get(
                "guard_action"
            )
            in governed_actions
        ):

            actions = scenario_data.get(
                "governed",
                {},
            )

        else:

            actions = scenario_data.get(
                "failure",
                {},
            )

    elif (
        args.condition
        == "fixed_canary"
    ):

        actions = scenario_data.get(
            "governed",
            {},
        )

    # --------------------------------------------------------
    # 8. Apply experimental change
    # --------------------------------------------------------

    apply_actions(
        actions,
        run_id,
    )

    # --------------------------------------------------------
    # Verify actual executed Kubernetes state
    # --------------------------------------------------------

    execution_state = verify_execution_state(
        scenario_data,
        actions,
    )

    action_completed = (
        time.time()
    )

    # --------------------------------------------------------
    # 9. Measure resulting system state
    # --------------------------------------------------------

    observation = observe(
        scenario_data,
        run_id,
        args.requests,
    )

    # --------------------------------------------------------
    # 10. Verify experiment outcome
    # --------------------------------------------------------

    verifier = invoke_verifier(
        run_id,
        args.condition,
        scenario_data[
            "expected_path"
        ],
        observation,
    )

    # --------------------------------------------------------
    # 11. Timing measurements
    # --------------------------------------------------------

    observation[
        "prediction_to_action_complete_ms"
    ] = (
        action_completed
        - decision_received
    ) * 1000

    if (
        observation.get(
            "first_error_elapsed_ms"
        )
        is not None
    ):

        observation[
            "prediction_lead_time_ms_proxy"
        ] = (
            (
                action_completed
                - decision_received
            )
            * 1000
        ) + observation[
            "first_error_elapsed_ms"
        ]

    # --------------------------------------------------------
    # 12. Complete experiment record
    # --------------------------------------------------------

    record = {
        "run_id": run_id,
        "scenario_id": scenario_data[
            "id"
        ],
        "condition": args.condition,
        "change_type": scenario_data[
            "type"
        ],
        "expected_path": scenario_data[
            "expected_path"
        ],
        "decision": decision,
        "baseline": baseline,
        "observation": observation,
        "verifier": verifier,
        "execution_state": execution_state,
        "timing": {
            "decision_request_epoch":
            decision_started,

            "decision_received_epoch":
            decision_received,

            "action_completed_epoch":
            action_completed,
        },
        "timestamp": time.time(),
    }

    # --------------------------------------------------------
    # 13. Save local evidence
    # --------------------------------------------------------

    output_directory = (
        ROOT
        / "evidence"
        / scenario_data[
            "id"
        ]
    )

    output_directory.mkdir(
        parents=True,
        exist_ok=True,
    )

    evidence_file = (
        output_directory
        / f"{run_id}.json"
    )

    evidence_file.write_text(
        json.dumps(
            record,
            indent=2,
        )
    )

    # --------------------------------------------------------
    # 14. Archive experiment evidence to S3
    # --------------------------------------------------------

    outputs = load_outputs()

    aws(
        [
            "s3",
            "cp",
            str(
                evidence_file
            ),
            (
                f"s3://"
                f"{outputs['evidence_bucket']['value']}"
                f"/runs/"
                f"{scenario_data['id']}/"
                f"{evidence_file.name}"
            ),
            "--region",
            outputs[
                "region"
            ]["value"],
        ]
    )

    # --------------------------------------------------------
    # 15. Print experiment record
    # --------------------------------------------------------

    print(
        json.dumps(
            record,
            indent=2,
        )
    )

    # --------------------------------------------------------
    # 16. Restore environment after experiment
    # --------------------------------------------------------

    reset_base()


if __name__ == "__main__":
    main()
