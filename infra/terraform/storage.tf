resource "aws_s3_bucket" "evidence" {
  bucket        = "${local.name}-evidence-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket                  = aws_s3_bucket.evidence.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    id     = "expire-research-evidence"
    status = "Enabled"
    filter {}

    expiration {
      days = var.evidence_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.evidence_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.evidence]
}

resource "aws_dynamodb_table" "episodes" {
  name         = "${local.name}-episodes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "run_id"

  attribute {
    name = "run_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "graph" {
  name         = "${local.name}-graph"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "edge_id"

  attribute {
    name = "edge_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "decisions" {
  name         = "${local.name}-decisions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "run_id"

  attribute {
    name = "run_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_ecr_repository" "repos" {
  for_each = toset(["frontend", "service-a", "service-b"])

  name         = "${local.name}/${each.value}"
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
