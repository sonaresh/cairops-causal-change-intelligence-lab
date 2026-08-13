resource "aws_iam_role" "sfn" {
  name = "${local.name}-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "${local.name}-sfn"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.core.arn]
    }]
  })
}

resource "aws_sfn_state_machine" "workflow" {
  name     = "${local.name}-governed-workflow"
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "CAIROps pre-change governed decision workflow"
    StartAt = "EvaluateChange"
    States = {
      EvaluateChange = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.core.arn
          "Payload.$"  = "$"
        }
        OutputPath = "$.Payload"
        End        = true
      }
    }
  })
}

resource "aws_cloudwatch_event_bus" "cairops" {
  name = "${local.name}-bus"
}

resource "aws_cloudwatch_event_rule" "change" {
  name           = "${local.name}-change-rule"
  event_bus_name = aws_cloudwatch_event_bus.cairops.name
  event_pattern = jsonencode({
    source        = ["cairops.lab"]
    "detail-type" = ["CAIROpsChange"]
  })
}

resource "aws_cloudwatch_event_target" "normalizer" {
  rule           = aws_cloudwatch_event_rule.change.name
  event_bus_name = aws_cloudwatch_event_bus.cairops.name
  arn            = aws_lambda_function.normalizer.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.normalizer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.change.arn
}

resource "aws_apigatewayv2_api" "ingest" {
  name          = "${local.name}-ingest"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "ingest" {
  api_id                 = aws_apigatewayv2_api.ingest.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.normalizer.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ingest" {
  api_id             = aws_apigatewayv2_api.ingest.id
  route_key          = "POST /change"
  target             = "integrations/${aws_apigatewayv2_integration.ingest.id}"
  authorization_type = "AWS_IAM"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.ingest.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.normalizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ingest.execution_arn}/*/*"
}
