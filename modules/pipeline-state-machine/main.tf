# Explicit State Machine Module for CodePipeline orchestration
# This module replaces implicit state logic with declarative Step Functions workflows
# that improve UX, DX, and AX without breaking existing pipelines

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Centralized exit code definitions
# These replace magic numbers scattered across buildspecs and Lambda code
locals {
  # Standardized exit code meanings across all deployment tools
  exit_codes = {
    NO_CHANGES    = "0" # Succeeded with empty diff/plan - skip deploy
    CHANGES_FOUND = "1" # Succeeded with changes - continue to deploy
    ERROR         = "2" # Error during diff/plan - pipeline fails
  }

  # Terraform has different exit codes - we normalize them here
  terraform_exit_codes = {
    NO_CHANGES    = "0" # Succeeded with empty plan
    ERROR         = "1" # Error during plan
    CHANGES_FOUND = "2" # Succeeded with non-empty plan
  }

  # CDK exit codes (already matches our standard)
  cdk_exit_codes = {
    NO_CHANGES    = "0" # Succeeded with empty diff
    CHANGES_FOUND = "1" # Succeeded with changes
    ERROR         = "2" # Error during diff
  }

  # Stage names used across pipelines
  stage_names = {
    cdk       = { plan = "Diff", deploy = "Deploy" }
    terraform = { plan = "Plan", deploy = "Apply" }
  }
}

# Step Functions IAM role for state machine execution
resource "aws_iam_role" "pipeline_state_machine" {
  count = var.create_state_machines ? 1 : 0
  name  = "StepFunctions-PipelineOrchestration-${var.pipeline_type}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "states.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
  tags = var.tags
}

# Policy for Step Functions to invoke Lambda and publish to SNS
resource "aws_iam_role_policy" "pipeline_state_machine" {
  count = var.create_state_machines ? 1 : 0
  name  = "PipelineStateMachinePolicy"
  role  = aws_iam_role.pipeline_state_machine[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeLambda"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          "arn:aws:lambda:*:${data.aws_caller_identity.current.account_id}:function:Pipeline*"
        ]
      },
      {
        Sid    = "PublishToSNS"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = var.notification_topic_arns
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/states/*"
        ]
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policies_exclusive" "pipeline_state_machine" {
  count     = var.create_state_machines ? 1 : 0
  role_name = aws_iam_role.pipeline_state_machine[0].name
  policy_names = [
    aws_iam_role_policy.pipeline_state_machine[0].name
  ]
}

# ASL (Amazon States Language) definition for the pipeline state machine
# This is the key to making the state machine EXPLICIT and self-documenting
locals {
  state_machine_definition = jsonencode({
    Comment = "Explicit state machine for ${var.pipeline_type} pipeline orchestration"
    StartAt = "EvaluatePlanResult"
    States = {
      EvaluatePlanResult = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.exitCode"
            StringEquals = local.exit_codes.NO_CHANGES
            Next         = "NoChangesDetected"
          },
          {
            Variable     = "$.exitCode"
            StringEquals = local.exit_codes.CHANGES_FOUND
            Next         = "ChangesDetected"
          }
        ]
        Default = "PlanError"
      }
      NoChangesDetected = {
        Type    = "Task"
        Resource = "arn:aws:states:::aws-sdk:codepipeline:enableStageTransition"
        Parameters = {
          pipelineName    = "$.pipelineName"
          stageName       = var.deploy_stage_name
          transitionType  = "Inbound"
        }
        Next = "NotifyNoChanges"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "HandleTransitionError"
        }]
      }
      ChangesDetected = {
        Type    = "Task"
        Resource = "arn:aws:states:::aws-sdk:codepipeline:enableStageTransition"
        Parameters = {
          pipelineName    = "$.pipelineName"
          stageName       = var.deploy_stage_name
          transitionType  = "Inbound"
        }
        Next = "NotifyChangesPending"
        ResultPath = "$.enableResult"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "HandleTransitionError"
        }]
      }
      NotifyNoChanges = {
        Type = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.notification_topic_arns[0]
          Message = {
            "Fn::Join" = ["", [
              "Pipeline ", "$.pipelineName", " - No changes detected. Deploy stage ",
              var.deploy_stage_name, " will be skipped."
            ]]
          }
          MessageAttributes = {
            pipelineName = {
              DataType = "String"
              StringValue = "$.pipelineName"
            }
            result = {
              DataType = "String"
              StringValue = "NO_CHANGES"
            }
          }
        }
        Next = "SuccessNoChanges"
      }
      SuccessNoChanges = {
        Type = "Succeed"
        Comment = "Pipeline execution completed - no infrastructure changes required"
      }
      NotifyChangesPending = {
        Type = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.notification_topic_arns[0]
          Message = {
            "Fn::Join" = ["", [
              "Pipeline ", "$.pipelineName", " - Changes detected in ", 
              var.plan_stage_name, ". Awaiting approval before proceeding to ",
              var.deploy_stage_name, "."
            ]]
          }
          MessageAttributes = {
            pipelineName = {
              DataType = "String"
              StringValue = "$.pipelineName"
            }
            result = {
              DataType = "String"
              StringValue = "CHANGES_PENDING_APPROVAL"
            }
          }
        }
        Next = "SuccessChangesPending"
      }
      SuccessChangesPending = {
        Type = "Succeed"
        Comment = "Changes detected - awaiting manual approval"
      }
      PlanError = {
        Type = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.notification_topic_arns[0]
          Message = {
            "Fn::Join" = ["", [
              "Pipeline ", "$.pipelineName", " - ERROR during ", var.plan_stage_name,
              ". Exit code: ", "$.exitCode", ". Please check logs."
            ]]
          }
          MessageAttributes = {
            pipelineName = {
              DataType = "String"
              StringValue = "$.pipelineName"
            }
            result = {
              DataType = "String"
              StringValue = "ERROR"
            }
            exitCode = {
              DataType = "Number"
              StringValue = "$.exitCode"
            }
          }
        }
        Next = "FailPlanError"
      }
      FailPlanError = {
        Type = "Fail"
        Error = "PlanExecutionError"
        Cause = "The plan stage failed with an error exit code"
      }
      HandleTransitionError = {
        Type = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.notification_topic_arns[0]
          Message = {
            "Fn::Join" = ["", [
              "Pipeline ", "$.pipelineName", " - Warning: Could not enable stage transition to ",
              var.deploy_stage_name, ". This may be because the transition is already enabled."
            ]]
          }
          MessageAttributes = {
            pipelineName = {
              DataType = "String"
              StringValue = "$.pipelineName"
            }
            result = {
              DataType = "String"
              StringValue = "TRANSITION_WARNING"
            }
          }
        }
        Next = "SuccessDespiteWarning"
      }
      SuccessDespiteWarning = {
        Type = "Succeed"
        Comment = "Proceeding despite transition enable warning"
      }
    }
  })
}

# State Machine for CDK Pipelines
resource "aws_sfn_state_machine" "cdk_pipeline" {
  count = var.create_state_machines && var.pipeline_type == "cdk" ? 1 : 0
  name  = "CDK-PipelineOrchestrator"
  role_arn = aws_iam_role.pipeline_state_machine[0].arn
  definition = jsonencode({
    Comment = "Explicit state machine for CDK Pipeline orchestration"
    StartAt = "NormalizeExitCode"
    States = {
      NormalizeExitCode = {
        Type = "Pass"
        Parameters = {
          "pipelineName.$" = "$.pipelineName"
          "exitCode.$"    = "$.cdkDiffExitCode"
          "commitId.$"    = "$.commitId"
          "commitMessage.$" = "$.commitMessage"
        }
        ResultPath = "$.normalized"
        Next = "EvaluateResult"
      }
      EvaluateResult = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.normalized.exitCode"
            StringEquals = local.cdk_exit_codes.NO_CHANGES
            Next         = "NoChangesSkipDeploy"
          },
          {
            Variable     = "$.normalized.exitCode"
            StringEquals = local.cdk_exit_codes.CHANGES_FOUND
            Next         = "ChangesProceedToApproval"
          }
        ]
        Default = "PlanFailed"
      }
      NoChangesSkipDeploy = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"      = "NO_CHANGES"
            "pipeline"    = "$.normalized.pipelineName"
            "commitId"    = "$.normalized.commitId"
            "message"     = "No infrastructure changes detected. Deploy stage skipped."
            "details" = {
              "stage"        = local.stage_names.cdk.plan
              "deployStage"  = local.stage_names.cdk.deploy
              "exitCode"     = local.cdk_exit_codes.NO_CHANGES
              "action"       = "SKIP_DEPLOY"
            }
          }
        }
        Next = "Success"
      }
      ChangesProceedToApproval = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"      = "CHANGES_PENDING"
            "pipeline"    = "$.normalized.pipelineName"
            "commitId"    = "$.normalized.commitId"
            "message"     = "Changes detected. Awaiting approval before deploy."
            "details" = {
              "stage"        = local.stage_names.cdk.plan
              "deployStage"  = local.stage_names.cdk.deploy
              "exitCode"     = local.cdk_exit_codes.CHANGES_FOUND
              "action"       = "AWAIT_APPROVAL"
            }
          }
        }
        Next = "Success"
      }
      PlanFailed = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"      = "ERROR"
            "pipeline"    = "$.normalized.pipelineName"
            "commitId"    = "$.normalized.commitId"
            "message"     = "Plan stage failed with errors."
            "details" = {
              "stage"    = local.stage_names.cdk.plan
              "exitCode" = "$.normalized.exitCode"
              "action"   = "FAIL"
            }
          }
        }
        Next = "Failed"
      }
      Success = {
        Type = "Succeed"
      }
      Failed = {
        Type = "Fail"
        Error = "PipelineError"
        Cause = "Plan stage execution failed"
      }
    }
  })

  type = "EXPRESS"
  logging_configuration {
    log_destination = "${aws_cloudwatch_log_group.pipeline_state_machine[0].arn}:*"
    include_execution_data = true
    level = "ALL"
  }

  tracing_configuration {
    enabled = var.enable_xray
  }

  tags = merge(var.tags, {
    PipelineType = "CDK"
    StateMachineVersion = "1.0"
  })
}

# State Machine for Terraform Pipelines
resource "aws_sfn_state_machine" "terraform_pipeline" {
  count = var.create_state_machines && var.pipeline_type == "terraform" ? 1 : 0
  name  = "Terraform-PipelineOrchestrator"
  role_arn = aws_iam_role.pipeline_state_machine[0].arn
  definition = jsonencode({
    Comment = "Explicit state machine for Terraform Pipeline orchestration"
    StartAt = "NormalizeExitCode"
    States = {
      NormalizeExitCode = {
        Type = "Pass"
        Parameters = {
          "pipelineName.$" = "$.pipelineName"
          "exitCode.$"     = "$.tfPlanExitCode"
          "commitId.$"     = "$.commitId"
          "commitMessage.$" = "$.commitMessage"
        }
        ResultPath = "$.normalized"
        Next = "EvaluateResult"
      }
      EvaluateResult = {
        Type = "Choice"
        Choices = [
          {
            # Terraform: 0 = no changes, 2 = changes found, 1 = error
            Variable     = "$.normalized.exitCode"
            StringEquals = local.terraform_exit_codes.NO_CHANGES
            Next         = "NoChangesSkipDeploy"
          },
          {
            Variable     = "$.normalized.exitCode"
            StringEquals = local.terraform_exit_codes.CHANGES_FOUND
            Next         = "ChangesProceedToApproval"
          }
        ]
        Default = "PlanFailed"
      }
      NoChangesSkipDeploy = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"      = "NO_CHANGES"
            "pipeline"    = "$.normalized.pipelineName"
            "commitId"    = "$.normalized.commitId"
            "message"     = "No infrastructure changes detected. Apply stage skipped."
            "details" = {
              "stage"        = local.stage_names.terraform.plan
              "deployStage"  = local.stage_names.terraform.deploy
              "exitCode"     = local.terraform_exit_codes.NO_CHANGES
              "action"       = "SKIP_APPLY"
            }
          }
        }
        ResultSelector = {
          "pipeline.$": "$.Payload.pipeline"
          "action.$": "$.Payload.details.action"
          "result": "SUCCESS_NO_CHANGES"
        }
        ResultPath = "$.stateResult"
        Next = "Success"
      }
      ChangesProceedToApproval = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"      = "CHANGES_PENDING"
            "pipeline"    = "$.normalized.pipelineName"
            "commitId"    = "$.normalized.commitId"
            "message"     = "Changes detected in plan. Awaiting approval before apply."
            "details" = {
              "stage"        = local.stage_names.terraform.plan
              "deployStage"  = local.stage_names.terraform.deploy
              "exitCode"     = local.terraform_exit_codes.CHANGES_FOUND
              "action"       = "AWAIT_APPROVAL"
            }
          }
        }
        ResultSelector = {
          "pipeline.$": "$.Payload.pipeline"
          "action.$": "$.Payload.details.action"
          "result": "PENDING_APPROVAL"
        }
        ResultPath = "$.stateResult"
        Next = "Success"
      }
      PlanFailed = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"      = "ERROR"
            "pipeline"    = "$.normalized.pipelineName"
            "commitId"    = "$.normalized.commitId"
            "message"     = "Terraform plan failed with errors."
            "details" = {
              "stage"    = local.stage_names.terraform.plan
              "exitCode" = "$.normalized.exitCode"
              "action"   = "FAIL"
            }
          }
        }
        Next = "Failed"
      }
      Success = {
        Type = "Succeed"
        Output = {
          "pipeline.$": "$.normalized.pipelineName"
          "commitId.$": "$.normalized.commitId"
          "result.$"  : "$.stateResult.result"
          "action.$"  : "$.stateResult.action"
        }
        Comment = "Pipeline state evaluated successfully"
      }
      Failed = {
        Type = "Fail"
        Error = "PlanExecutionFailed"
        Cause = "Terraform plan stage execution failed with errors"
      }
    }
  })

  type = "EXPRESS"
  logging_configuration {
    log_destination = "${aws_cloudwatch_log_group.pipeline_state_machine[0].arn}:*"
    include_execution_data = true
    level = "ALL"
  }

  tracing_configuration {
    enabled = var.enable_xray
  }

  tags = merge(var.tags, {
    PipelineType = "Terraform"
    StateMachineVersion = "1.0"
  })
}

# State Machine for Approval Rejection Recovery
# This replaces the implicit Lambda handler logic
resource "aws_sfn_state_machine" "approval_rejection_recovery" {
  count = var.create_state_machines ? 1 : 0
  name  = "Pipeline-ApprovalRejectionRecovery"
  role_arn = aws_iam_role.pipeline_state_machine[0].arn
  definition = jsonencode({
    Comment = "Explicit state machine for handling approval rejections"
    StartAt = "DeterminePipelineType"
    States = {
      DeterminePipelineType = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.pipelineName"
            StringMatches = "CDK-*"
            Next         = "HandleCDKRejection"
          },
          {
            Variable     = "$.pipelineName"
            StringMatches = "TF-*"
            Next         = "HandleTerraformRejection"
          }
        ]
        Default = "UnknownPipelineType"
      }
      HandleCDKRejection = {
        Type = "Task"
        Resource = "arn:aws:states:::aws-sdk:codepipeline:enableStageTransition"
        Parameters = {
          pipelineName    = "$.pipelineName"
          stageName       = local.stage_names.cdk.plan
          transitionType  = "Inbound"
        }
        Next = "NotifyCDKRejectionHandled"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "HandleRecoveryError"
        }]
      }
      HandleTerraformRejection = {
        Type = "Task"
        Resource = "arn:aws:states:::aws-sdk:codepipeline:enableStageTransition"
        Parameters = {
          pipelineName    = "$.pipelineName"
          stageName       = local.stage_names.terraform.plan
          transitionType  = "Inbound"
        }
        Next = "NotifyTerraformRejectionHandled"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "HandleRecoveryError"
        }]
      }
      NotifyCDKRejectionHandled = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"   = "REJECTION_HANDLED"
            "pipeline" = "$.pipelineName"
            "message"  = "Approval rejected for CDK pipeline. Diff stage transition re-enabled."
            "details"  = {
              "stage"  = local.stage_names.cdk.plan
              "action" = "RE_ENABLE_TRANSITION"
            }
          }
        }
        ResultPath = "$.notificationResult"
        Next = "Success"
      }
      NotifyTerraformRejectionHandled = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"   = "REJECTION_HANDLED"
            "pipeline" = "$.pipelineName"
            "message"  = "Approval rejected for Terraform pipeline. Plan stage transition re-enabled."
            "details"  = {
              "stage"  = local.stage_names.terraform.plan
              "action" = "RE_ENABLE_TRANSITION"
            }
          }
        }
        ResultPath = "$.notificationResult"
        Next = "Success"
      }
      HandleRecoveryError = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"   = "RECOVERY_WARNING"
            "pipeline" = "$.pipelineName"
            "message"  = "Could not re-enable stage transition. Manual intervention may be required."
            "details"  = {
              "error"  = "$.error.Cause"
            }
          }
        }
        Next = "Success"
      }
      UnknownPipelineType = {
        Type = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.notification_lambda_arn
          Payload = {
            "status"   = "WARNING"
            "pipeline" = "$.pipelineName"
            "message"  = "Unknown pipeline type - no action taken."
          }
        }
        Next = "Success"
      }
      Success = {
        Type = "Succeed"
      }
    }
  })

  type = "EXPRESS"
  logging_configuration {
    log_destination = "${aws_cloudwatch_log_group.pipeline_state_machine[0].arn}:*"
    include_execution_data = true
    level = "ALL"
  }

  tracing_configuration {
    enabled = var.enable_xray
  }

  tags = merge(var.tags, {
    StateMachineVersion = "1.0"
    Purpose = "ApprovalRejectionRecovery"
  })
}

# CloudWatch Log Group for state machine execution logs
resource "aws_cloudwatch_log_group" "pipeline_state_machine" {
  count = var.create_state_machines ? 1 : 0
  name              = "/aws/states/pipeline-orchestration"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# Alarms for state machine failures
resource "aws_cloudwatch_metric_alarm" "state_machine_failures" {
  count = var.create_state_machines && var.create_alarms ? 1 : 0
  alarm_name          = "PipelineStateMachine-ExecutionsFailed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Alert when pipeline state machine execution fails"
  dimensions = {
    StateMachineArn = var.pipeline_type == "cdk" ? 
      (length(aws_sfn_state_machine.cdk_pipeline) > 0 ? aws_sfn_state_machine.cdk_pipeline[0].arn : "") :
      (length(aws_sfn_state_machine.terraform_pipeline) > 0 ? aws_sfn_state_machine.terraform_pipeline[0].arn : "")
  }
  alarm_actions = var.alarm_notification_arns
  ok_actions    = var.alarm_notification_arns
  tags          = var.tags
}

# Outputs for downstream consumers
output "exit_codes" {
  description = "Centralized exit code definitions for pipeline orchestration"
  value       = local.exit_codes
}

output "terraform_exit_codes" {
  description = "Terraform-specific exit code definitions (normalized)"
  value       = local.terraform_exit_codes
}

output "cdk_exit_codes" {
  description = "CDK-specific exit code definitions"
  value       = local.cdk_exit_codes
}

output "stage_names" {
  description = "Stage name mappings for consistency"
  value       = local.stage_names
}

output "state_machine_arn_cdk" {
  description = "ARN of the CDK pipeline state machine"
  value       = length(aws_sfn_state_machine.cdk_pipeline) > 0 ? aws_sfn_state_machine.cdk_pipeline[0].arn : null
}

output "state_machine_arn_terraform" {
  description = "ARN of the Terraform pipeline state machine"
  value       = length(aws_sfn_state_machine.terraform_pipeline) > 0 ? aws_sfn_state_machine.terraform_pipeline[0].arn : null
}

output "state_machine_arn_rejection_recovery" {
  description = "ARN of the approval rejection recovery state machine"
  value       = length(aws_sfn_state_machine.approval_rejection_recovery) > 0 ? aws_sfn_state_machine.approval_rejection_recovery[0].arl : null
}

output "log_group_name" {
  description = "Name of the CloudWatch log group for state machine execution logs"
  value       = length(aws_cloudwatch_log_group.pipeline_state_machine) > 0 ? aws_cloudwatch_log_group.pipeline_state_machine[0].name : null
}
