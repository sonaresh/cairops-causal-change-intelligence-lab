import hashlib
import json
import os
import time

import boto3
from decimal import Decimal


ddb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

episodes = ddb.Table(
    os.environ["EPISODES_TABLE"]
)

graph = ddb.Table(
    os.environ["GRAPH_TABLE"]
)

EVIDENCE_BUCKET = os.environ[
    "EVIDENCE_BUCKET"
]


def clip(x):
    return max(
        0.0,
        min(
            1.0,
            float(x)
        )
    )


def _json_safe(value):
    if isinstance(value, Decimal):
        return float(value)

    if isinstance(value, dict):
        return {
            k: _json_safe(v)
            for k, v in value.items()
        }

    if isinstance(value, list):
        return [
            _json_safe(v)
            for v in value
        ]

    return value


def _safe_run_id(run_id):
    return (
        str(run_id)
        .replace("/", "_")
        .replace("\\", "_")
    )


def _write_evidence(
    run_id,
    filename,
    record
):
    safe_record = _json_safe(record)

    body = json.dumps(
        safe_record,
        indent=2,
        sort_keys=True,
        separators=(",", ": ")
    ).encode("utf-8")

    sha256 = hashlib.sha256(
        body
    ).hexdigest()

    safe_id = _safe_run_id(
        run_id
    )

    key = (
        f"runs/"
        f"{safe_id}/"
        f"{filename}"
    )

    s3.put_object(
        Bucket=EVIDENCE_BUCKET,
        Key=key,
        Body=body,
        ContentType="application/json",
        Metadata={
            "run-id": safe_id,
            "record-type": str(
                safe_record.get(
                    "record_type",
                    "Outcome"
                )
            ),
            "sha256": sha256
        }
    )

    return {
        "bucket": EVIDENCE_BUCKET,
        "key": key,
        "sha256": sha256
    }


def _update_edge(
    source,
    target,
    supported
):
    edge_id = (
        f"{source}->{target}"
    )

    current = graph.get_item(
        Key={
            "edge_id": edge_id
        }
    ).get(
        "Item",
        {}
    )

    confidence = float(
        current.get(
            "confidence",
            Decimal("0.50")
        )
    )

    support = int(
        current.get(
            "support_count",
            0
        )
    )

    contradiction = int(
        current.get(
            "contradiction_count",
            0
        )
    )

    if supported:
        support += 1

        confidence = clip(
            confidence
            + 0.05
            * (
                1
                - confidence
            )
        )

    else:
        contradiction += 1

        confidence = clip(
            confidence
            - 0.04
            * confidence
        )

    graph.put_item(
        Item={
            "edge_id": edge_id,
            "source": source,
            "target": target,
            "effect": Decimal(
                str(
                    current.get(
                        "effect",
                        Decimal("0.75")
                    )
                )
            ),
            "confidence": Decimal(
                str(
                    round(
                        confidence,
                        6
                    )
                )
            ),
            "support_count": support,
            "contradiction_count": (
                contradiction
            ),
            "last_validation_time": int(
                time.time()
            ),
            "provenance": (
                "controlled_experiment"
            )
        }
    )


def handler(event, context):
    run_id = event["run_id"]

    observation = event.get(
        "observation",
        {}
    )

    actual_failure = 1 if (
        bool(
            observation.get(
                "incident",
                False
            )
        )
        or bool(
            observation.get(
                "slo_violation",
                False
            )
        )
    ) else 0

    episode = episodes.get_item(
        Key={
            "run_id": run_id
        }
    ).get(
        "Item",
        {}
    )

    risk = float(
        episode.get(
            "prediction_risk",
            0.0
        )
    )

    action = episode.get(
        "guard_action",
        "UNKNOWN"
    )

    condition = event.get(
        "condition"
    )

    expected_path = event.get(
        "expected_path",
        []
    )

    # --------------------------------------------------------
    # Determine whether controlled experiment validates
    # or contradicts causal edges
    # --------------------------------------------------------

    full_risky_execution = (
        condition == "failure"
    )

    supported = bool(
        actual_failure
        and full_risky_execution
    )

    contradicted = bool(
        (not actual_failure)
        and full_risky_execution
    )

    graph_updates = []

    if supported or contradicted:

        for source, target in zip(
            expected_path,
            expected_path[1:]
        ):

            _update_edge(
                source,
                target,
                supported=supported
            )

            graph_updates.append({
                "source": source,
                "target": target,
                "supported": supported,
                "contradicted": contradicted
            })

    # --------------------------------------------------------
    # Construct measured outcome
    # --------------------------------------------------------

    outcome = {
        "actual_failure": (
            actual_failure
        ),
        "prediction_error": Decimal(
            str(
                round(
                    abs(
                        risk
                        - actual_failure
                    ),
                    6
                )
            )
        ),
        "intervention_success": int(
            condition == "governed"
            and actual_failure == 0
        ),
        "observed_latency_ms": Decimal(
            str(
                observation.get(
                    "p95_latency_ms",
                    0
                )
            )
        ),
        "error_rate": Decimal(
            str(
                observation.get(
                    "error_rate",
                    0
                )
            )
        ),
        "timestamp": int(
            time.time()
        ),
        "record_type": "Outcome"
    }

    # --------------------------------------------------------
    # Persist measured outcome into episode
    # --------------------------------------------------------

    episodes.update_item(
        Key={
            "run_id": run_id
        },
        UpdateExpression=(
            "SET "
            "actual_failure=:f, "
            "outcome=:o"
        ),
        ExpressionAttributeValues={
            ":f": actual_failure,
            ":o": outcome
        }
    )

    # --------------------------------------------------------
    # Build immutable outcome evidence
    # --------------------------------------------------------

    evidence_record = {
        "run_id": run_id,
        "scenario_id": event.get(
            "scenario_id",
            episode.get(
                "scenario_id",
                "UNKNOWN"
            )
        ),
        "condition": condition,
        "guard_action": action,
        "prediction_risk": risk,
        "expected_path": (
            expected_path
        ),
        "observation": observation,
        "outcome": _json_safe(
            outcome
        ),
        "graph_updates": (
            graph_updates
        ),
        "record_type": (
            "OutcomeEvidence"
        ),
        "evidence_timestamp": int(
            time.time()
        )
    }

    outcome_evidence = _write_evidence(
        run_id=run_id,
        filename="outcome.json",
        record=evidence_record
    )

    # --------------------------------------------------------
    # Return measured result
    # --------------------------------------------------------

    response = {
        "run_id": run_id,
        "guard_action": action,
        **{
            k: (
                float(v)
                if isinstance(
                    v,
                    Decimal
                )
                else v
            )
            for k, v
            in outcome.items()
        },
        "evidence": {
            "bucket": outcome_evidence[
                "bucket"
            ],
            "key": outcome_evidence[
                "key"
            ],
            "sha256": outcome_evidence[
                "sha256"
            ]
        }
    }

    return response