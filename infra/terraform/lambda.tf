locals {
  lambda_env = {
    EPISODES_TABLE  = aws_dynamodb_table.episodes.name
    GRAPH_TABLE     = aws_dynamodb_table.graph.name
    DECISIONS_TABLE = aws_dynamodb_table.decisions.name
    EVIDENCE_BUCKET = aws_s3_bucket.evidence.bucket
    PROJECT         = local.name
  }
}

data "archive_file" "normalizer" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/change_normalizer"
  output_path = "${path.module}/.build/change_normalizer.zip"
}
data "archive_file" "core" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/cairops_core"
  output_path = "${path.module}/.build/cairops_core.zip"
}
data "archive_file" "verifier" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/outcome_verifier"
  output_path = "${path.module}/.build/outcome_verifier.zip"
}
data "archive_file" "iam_probe" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/iam_probe"
  output_path = "${path.module}/.build/iam_probe.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "lambda_data" {
  name = "${local.name}-data"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Scan", "dynamodb:Query"], Resource = [aws_dynamodb_table.episodes.arn, aws_dynamodb_table.graph.arn, aws_dynamodb_table.decisions.arn] },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.evidence.arn}/*" },
      { Effect = "Allow", Action = ["states:StartExecution"], Resource = "*" }
    ]
  })
}

resource "aws_lambda_function" "normalizer" {
  function_name    = "${local.name}-change-normalizer"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.normalizer.output_path
  source_code_hash = data.archive_file.normalizer.output_base64sha256
  timeout          = 30
  environment { variables = merge(local.lambda_env, { STATE_MACHINE_ARN = aws_sfn_state_machine.workflow.arn }) }
}
resource "aws_lambda_function" "core" {
  function_name    = "${local.name}-core"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.core.output_path
  source_code_hash = data.archive_file.core.output_base64sha256
  timeout          = 30
  environment { variables = local.lambda_env }
}
resource "aws_lambda_function" "verifier" {
  function_name    = "${local.name}-outcome-verifier"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.verifier.output_path
  source_code_hash = data.archive_file.verifier.output_base64sha256
  timeout          = 30
  environment { variables = local.lambda_env }
}

resource "aws_iam_role" "iam_probe" {
  name = "${local.name}-iam-probe-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "iam_probe_basic" {
  role       = aws_iam_role.iam_probe.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "iam_probe_s3" {
  name   = "${local.name}-iam-probe-s3"
  role   = aws_iam_role.iam_probe.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.evidence.arn}/iam-probe/*" }] })
}
resource "aws_lambda_function" "iam_probe" {
  function_name    = "${local.name}-iam-probe"
  role             = aws_iam_role.iam_probe.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.iam_probe.output_path
  source_code_hash = data.archive_file.iam_probe.output_base64sha256
  timeout          = 15
  environment { variables = { EVIDENCE_BUCKET = aws_s3_bucket.evidence.bucket } }
}
