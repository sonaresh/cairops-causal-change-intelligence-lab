import hashlib
import json
import os
import time
import uuid

import boto3
from decimal import Decimal


# ============================================================
# AWS clients / resources
# ============================================================

ddb = boto3.resource("dynamodb")
sfn = boto3.client("stepfunctions")
s3 = boto3.client("s3")

episodes = ddb.Table(
    os.environ["EPISODES_TABLE"]
)

EVIDENCE_BUCKET = os.environ[
    "EVIDENCE_BUCKET"
]

STATE_MACHINE_ARN = os.environ[
    "STATE_MACHINE_ARN"
]


# ============================================================
# Event parsing
# ============================================================

def _body(event):
    """
    Normalize supported invocation formats.

    Supported inputs:
      - API Gateway-style {"body": ...}
      - EventBridge-style {"detail": ...}
      - direct dictionary invocation
    """

    if (
        isinstance(event, dict)
        and "body" in event
    ):
        body = event["body"]

        if isinstance(body, str):
            return json.loads(body)

        return body or {}

    if (
        isinstance(event, dict)
        and "detail" in event
    ):
        return event["detail"]

    return event or {}


# ============================================================
# Serialization helpers
# ============================================================

def _ddb_safe(value):
    """
    Convert floating-point values recursively into Decimal
    instances for DynamoDB compatibility.
    """

    if isinstance(value, float):
        return Decimal(
            str(value)
        )

    if isinstance(value, dict):
        return {
            k: _ddb_safe(v)
            for k, v
            in value.items()
        }

    if isinstance(value, list):
        return [
            _ddb_safe(v)
            for v in value
        ]

    return value


def _json_safe(value):
    """
    Convert Decimal values recursively into standard JSON
    compatible Python values.
    """

    if isinstance(value, Decimal):
        return float(value)

    if isinstance(value, dict):
        return {
            k: _json_safe(v)
            for k, v
            in value.items()
        }

    if isinstance(value, list):
        return [
            _json_safe(v)
            for v in value
        ]

    return value


def _safe_run_id(run_id):
    """
    Prevent a run ID from accidentally creating unintended S3
    path structures.
    """

    return (
        str(run_id)
        .replace("/", "_")
        .replace("\\", "_")
    )


# ============================================================
# Immutable evidence persistence
# ============================================================

def _write_evidence(
    run_id,
    filename,
    record
):
    """
    Persist canonical evidence to S3.

    A SHA-256 digest is stored in object metadata so exported
    experiment artifacts can later be integrity verified.
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
                    "unknown"
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


# ============================================================
# Lambda handler
# ============================================================

def handler(event, context):
    """
    Normalize a CAIROps change event into the canonical
    ChangeRecord consumed by the governed workflow.

    IMPORTANT:
    Proposal-derived risk fields must be preserved without
    condition-specific alteration. In particular:

      - diff
      - risk_context
      - scope
      - validation_confidence
      - reversibility
      - business_criticality
      - state
      - expected_path

    E2 requires risk_context to preserve:
      current_replicas
      minimum_safe_replicas

    Without that context, replica-reduction severity cannot be
    derived correctly from the proposed change.
    """

    x = _body(
        event
    )

    if not isinstance(
        x,
        dict
    ):
        raise ValueError(
            "CAIROps change normalizer expects a JSON object."
        )

    run_id = (
        x.get("run_id")
        or
        (
            f"run-"
            f"{int(time.time())}-"
            f"{uuid.uuid4().hex[:8]}"
        )
    )

    # --------------------------------------------------------
    # Canonical ChangeRecord
    # --------------------------------------------------------

    change = {
        "run_id": run_id,

        "scenario_id": x.get(
            "scenario_id",
            "UNKNOWN"
        ),

        "condition": x.get(
            "condition",
            "unknown"
        ),

        "type": x.get(
            "type",
            "unknown"
        ),

        "target": x.get(
            "target",
            "unknown"
        ),

        # Preserve the complete proposed change.
        #
        # Example E2:
        # {
        #   "patch_env": {...},
        #   "scale": {
        #       "deployment": "frontend",
        #       "replicas": 1
        #   }
        # }
        "diff": x.get(
            "diff",
            {}
        ),

        # CRITICAL E2 FIX:
        # Preserve proposal interpretation context.
        #
        # Example:
        # {
        #   "current_replicas": 2,
        #   "minimum_safe_replicas": 2
        # }
        "risk_context": x.get(
            "risk_context",
            {}
        ),

        "scope": x.get(
            "scope",
            1.0
        ),

        "timestamp": x.get(
            "timestamp",
            time.time()
        ),

        "validation_confidence": x.get(
            "validation_confidence",
            0.5
        ),

        "reversibility": x.get(
            "reversibility",
            0.5
        ),

        "business_criticality": x.get(
            "business_criticality",
            0.5
        ),

        "state": x.get(
            "state",
            {}
        ),

        "expected_path": x.get(
            "expected_path",
            []
        ),

        "record_type": "ChangeRecord"
    }

    # --------------------------------------------------------
    # Defensive structural validation
    # --------------------------------------------------------

    if not isinstance(
        change["diff"],
        dict
    ):
        raise ValueError(
            "ChangeRecord diff must be a JSON object."
        )

    if not isinstance(
        change["risk_context"],
        dict
    ):
        raise ValueError(
            "ChangeRecord risk_context must be a JSON object."
        )

    if not isinstance(
        change["state"],
        dict
    ):
        raise ValueError(
            "ChangeRecord state must be a JSON object."
        )

    if not isinstance(
        change["expected_path"],
        list
    ):
        raise ValueError(
            "ChangeRecord expected_path must be a JSON array."
        )

    # --------------------------------------------------------
    # Persist canonical ChangeRecord to DynamoDB
    # --------------------------------------------------------

    safe_change = _ddb_safe(
        change
    )

    episodes.put_item(
        Item=safe_change
    )

    # --------------------------------------------------------
    # Persist immutable ChangeRecord evidence to S3
    # --------------------------------------------------------

    change_evidence = _write_evidence(
        run_id=run_id,
        filename="change.json",
        record=change
    )

    # --------------------------------------------------------
    # Start governed CAIROps workflow
    # --------------------------------------------------------

    payload = _json_safe(
        safe_change
    )

    execution_name = (
        run_id
        .replace("_", "-")
        .replace("/", "-")
    )[:80]

    response = sfn.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        name=execution_name,
        input=json.dumps(
            payload
        )
    )

    # --------------------------------------------------------
    # Return provenance information
    # --------------------------------------------------------

    return {
        "statusCode": 202,

        "body": json.dumps({
            "run_id": run_id,

            "execution_arn": response[
                "executionArn"
            ],

            "change_evidence": {
                "bucket": change_evidence[
                    "bucket"
                ],
                "key": change_evidence[
                    "key"
                ],
                "sha256": change_evidence[
                    "sha256"
                ]
            }
        })
    }
