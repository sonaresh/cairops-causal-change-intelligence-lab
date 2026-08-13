import hashlib
import json
import os
import time

import boto3
from decimal import Decimal

from graph import paths
from risk import ciir, band, clamp
from counterfactual import alternatives
from guard import guard


# ============================================================
# AWS clients / resources
# ============================================================

ddb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

decisions = ddb.Table(
    os.environ["DECISIONS_TABLE"]
)

episodes = ddb.Table(
    os.environ["EPISODES_TABLE"]
)

graph_table = ddb.Table(
    os.environ["GRAPH_TABLE"]
)

EVIDENCE_BUCKET = os.environ[
    "EVIDENCE_BUCKET"
]


# ============================================================
# CAIROps graph mappings
# ============================================================

START_MAP = {
    "deployment": "deployment",
    "replica_reduction": "replica_reduction",
    "hpa_threshold": "hpa_threshold",
    "security_rule": "security_rule",
    "iam_policy": "iam_policy",
    "db_parameter": "db_parameter",
    "resource_limit": "resource_limit",
    "route_weight": "route_weight",
    "dependency_version": "dependency_version",
    "network_latency": "network_latency",
    "combined": "deployment",
    "unseen": "resource_limit",
}

TARGETS = {
    "slo_violation",
    "business_impact",
    "api_errors",
    "service_error",
    "dependency_timeout",
}


# ============================================================
# Utility helpers
# ============================================================

def _json_safe(value):
    """
    Convert DynamoDB Decimal values and nested structures into
    standard JSON-compatible Python values.
    """

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
    """
    Prevent run IDs from accidentally creating unintended S3
    path structures.
    """

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
    """
    Persist canonical experiment evidence to S3.

    The SHA-256 digest is stored as object metadata so experiment
    artifacts can later be validated for integrity.
    """

    safe_record = _json_safe(
        record
    )

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
                    "PredictionDecision"
                )
            ),
            "sha256": sha256,
        },
    )

    return {
        "bucket": EVIDENCE_BUCKET,
        "key": key,
        "sha256": sha256,
    }


# ============================================================
# Dynamic causal graph overrides
# ============================================================

def _graph_overrides():
    """
    Read experiment-learned graph edges from DynamoDB.

    If graph lookup fails, CAIROps continues with the static
    graph rather than failing the prediction path.
    """

    try:

        items = graph_table.scan(
            Limit=200
        ).get(
            "Items",
            []
        )

        return [
            {
                "source": item.get(
                    "source"
                ),
                "target": item.get(
                    "target"
                ),
                "effect": float(
                    item.get(
                        "effect",
                        0.5
                    )
                ),
                "confidence": float(
                    item.get(
                        "confidence",
                        0.5
                    )
                ),
            }
            for item in items
        ]

    except Exception:
        return []


# ============================================================
# CIIR factor calculation
# ============================================================

def _factors(
    change,
    top_path_score
):
    state = (
        change.get("state")
        or {}
    )

    H = clamp(
        state.get(
            "historical_failure_association",
            0.50
        )
    )

    D = clamp(
        state.get(
            "dependency_criticality",
            0.60
        )
    )

    P = clamp(
        top_path_score
    )

    B = clamp(
        float(
            change.get(
                "scope",
                1
            )
        )
        *
        float(
            change.get(
                "business_criticality",
                0.5
            )
        )
    )

    evidence_coverage = clamp(
        state.get(
            "evidence_coverage",
            0.75
        )
    )

    graph_confidence = clamp(
        state.get(
            "graph_confidence",
            0.75
        )
    )

    telemetry_noise = clamp(
        state.get(
            "telemetry_noise",
            0.10
        )
    )

    U = clamp(
        1
        -
        (
            0.55
            * evidence_coverage
            +
            0.45
            * graph_confidence
        )
        +
        0.35
        * telemetry_noise
    )

    V = clamp(
        change.get(
            "validation_confidence",
            0.5
        )
    )

    R = clamp(
        change.get(
            "reversibility",
            0.5
        )
    )

    return {
        "H": H,
        "D": D,
        "P": P,
        "B": B,
        "U": U,
        "V": V,
        "R": R,
    }


# ============================================================
# Lambda handler
# ============================================================

def handler(change, context):

    start_time = time.perf_counter()

    # --------------------------------------------------------
    # Validate canonical input
    # --------------------------------------------------------

    if not isinstance(change, dict):
        raise ValueError(
            "CAIROps core expects a JSON object."
        )

    if "run_id" not in change:
        raise ValueError(
            "CAIROps core input is missing run_id."
        )

    run_id = change["run_id"]

    scenario_id = change.get(
        "scenario_id"
    )

    condition = change.get(
        "condition"
    )

    change_type = change.get(
        "type",
        "unknown"
    )

    # --------------------------------------------------------
    # Identify causal starting node
    # --------------------------------------------------------

    start_node = START_MAP.get(
        change_type,
        change_type
    )

    # --------------------------------------------------------
    # Calculate ranked causal paths
    # --------------------------------------------------------

    ranked = paths(
        start_node,
        TARGETS,
        max_depth=8,
        overrides=_graph_overrides(),
    )

    top_path_score = (
        ranked[0][1]
        if ranked
        else 0.10
    )

    # --------------------------------------------------------
    # Calculate CIIR factors
    # --------------------------------------------------------

    factors = _factors(
        change,
        top_path_score
    )

    # --------------------------------------------------------
    # Compute incident risk
    # --------------------------------------------------------

    risk = ciir(
        factors
    )

    confidence = clamp(
        1
        - factors["U"]
    )

    # --------------------------------------------------------
    # Counterfactual intervention evaluation
    # --------------------------------------------------------

    candidate_alternatives = alternatives(
        change,
        risk
    )

    # --------------------------------------------------------
    # Governed Change Guard
    # --------------------------------------------------------

    action, reason = guard(
        risk,
        confidence,
        candidate_alternatives,
        float(
            change.get(
                "business_criticality",
                0.5
            )
        ),
        float(
            change.get(
                "reversibility",
                0.5
            )
        ),
    )

    inference_latency_ms = (
        time.perf_counter()
        - start_time
    ) * 1000

    # --------------------------------------------------------
    # Canonical PredictionDecision record
    # --------------------------------------------------------

    prediction = {
        "run_id": run_id,
        "scenario_id": scenario_id,
        "condition": condition,

        "risk": round(
            risk,
            6
        ),

        "risk_band": band(
            risk
        ),

        "confidence": round(
            confidence,
            6
        ),

        "factors": {
            key: round(
                value,
                6
            )
            for key, value
            in factors.items()
        },

        "top_paths": [
            {
                "nodes": path,
                "score": round(
                    score,
                    8
                ),
            }
            for path, score
            in ranked[:3]
        ],

        "alternatives": (
            candidate_alternatives[:5]
        ),

        "guard_action": action,

        "guard_reason": reason,

        "inference_latency_ms": round(
            inference_latency_ms,
            3
        ),

        "record_type": (
            "PredictionDecision"
        ),

        "timestamp": int(
            time.time()
        ),
    }

    # --------------------------------------------------------
    # DynamoDB-safe representation
    # --------------------------------------------------------

    ddb_prediction = json.loads(
        json.dumps(
            prediction
        ),
        parse_float=Decimal
    )

    # --------------------------------------------------------
    # Persist complete decision
    # --------------------------------------------------------

    decisions.put_item(
        Item=ddb_prediction
    )

    # --------------------------------------------------------
    # Update experiment episode
    # --------------------------------------------------------

    episodes.update_item(
        Key={
            "run_id": run_id
        },

        UpdateExpression=(
            "SET "
            "prediction_risk=:r, "
            "guard_action=:a, "
            "prediction_confidence=:c, "
            "prediction_paths=:p"
        ),

        ExpressionAttributeValues={
            ":r": Decimal(
                str(
                    prediction[
                        "risk"
                    ]
                )
            ),

            ":a": action,

            ":c": Decimal(
                str(
                    prediction[
                        "confidence"
                    ]
                )
            ),

            ":p": ddb_prediction[
                "top_paths"
            ],
        },
    )

    # --------------------------------------------------------
    # Persist immutable prediction evidence
    # --------------------------------------------------------

    evidence = _write_evidence(
        run_id=run_id,
        filename=(
            "prediction-decision.json"
        ),
        record=prediction,
    )

    # --------------------------------------------------------
    # Add evidence provenance to return object
    # --------------------------------------------------------

    prediction[
        "evidence"
    ] = {
        "bucket": evidence[
            "bucket"
        ],
        "key": evidence[
            "key"
        ],
        "sha256": evidence[
            "sha256"
        ],
    }

    return prediction