output "region" { value = var.region }
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "evidence_bucket" { value = aws_s3_bucket.evidence.bucket }
output "episodes_table" { value = aws_dynamodb_table.episodes.name }
output "graph_table" { value = aws_dynamodb_table.graph.name }
output "decisions_table" { value = aws_dynamodb_table.decisions.name }
output "event_bus" { value = aws_cloudwatch_event_bus.cairops.name }
output "api_endpoint" { value = aws_apigatewayv2_api.ingest.api_endpoint }
output "state_machine_arn" { value = aws_sfn_state_machine.workflow.arn }
output "dependency_private_ip" { value = aws_instance.dependency.private_ip }
output "dependency_sg_id" { value = aws_security_group.dependency.id }
output "node_security_group_id" { value = module.eks.node_security_group_id }
output "iam_probe_function" { value = aws_lambda_function.iam_probe.function_name }
output "iam_probe_role_name" { value = aws_iam_role.iam_probe.name }
output "outcome_verifier_function" { value = aws_lambda_function.verifier.function_name }
output "ecr_repositories" { value = { for k, v in aws_ecr_repository.repos : k => v.repository_url } }
output "cloudwatch_role_arn" { value = aws_iam_role.cloudwatch_observability.arn }
