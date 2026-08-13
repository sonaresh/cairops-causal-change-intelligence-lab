import hashlib
import json
import os
import time
import uuid

import boto3
from decimal import Decimal


ddb = boto3.resource("dynamodb")
sfn = boto3.client("stepfunctions")
s3 = boto3.client("s3")

episodes = ddb.Table(os.environ["EPISODES_TABLE"])

EVIDENCE_BUCKET = os.environ["EVIDENCE_BUCKET"]
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def _body(event):
    if isinstance(event, dict) and "body" in event:
        body = event["body"]

        if isinstance(body, str):
            return json.loads(body)

        return body or {}

    if isinstance(event, dict) and "detail" in event:
        return event["detail"]

    return event or {}


def _ddb_safe(value):
    if isinstance(value, float):
        return Decimal(str(value))

    if isinstance(value, dict):
        return {
            k: _ddb_safe(v)
            for k, v in value.items()
        }

    if isinstance(value, list):
        return [
            _ddb_safe(v)
            for v in value
        ]

    return value


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
    return str(run_id).replace("/", "_").replace("\\", "_")


def _write_evidence(run_id, filename, record):
    safe_record = _json_safe(record)

    body = json.dumps(
        safe_record,
        indent=2,
        sort_keys=True,
        separators=(",", ": ")
    ).encode("utf-8")

    sha256 = hashlib.sha256(body).hexdigest()

    safe_id = _safe_run_id(run_id)
    key = f"runs/{safe_id}/{filename}"

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


def handler(event, context):
    x = _body(event)

    run_id = (
        x.get("run_id")
        or f"run-{int(time.time())}-{uuid.uuid4().hex[:8]}"
    )

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
        "diff": x.get(
            "diff",
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
    # Persist canonical ChangeRecord to DynamoDB
    # --------------------------------------------------------

    safe_change = _ddb_safe(change)

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
        input=json.dumps(payload)
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