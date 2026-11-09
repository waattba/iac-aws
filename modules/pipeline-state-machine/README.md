# Pipeline State Machine Module

This module replaces **implicit state machines** scattered across the iac-aws repository with **explicit, self-documenting Step Functions orchestration** that elevates UX, DX, and AX.

## The Problem: Implicit State Machines

The iac-aws repository had 5 implicit state machines:

1. **CDK Pipeline Flow**: Source → Diff → Implicit check → (Skip Deploy if no changes)
2. **Terraform Pipeline Flow**: Source → Plan → Implicit check → (Skip Apply if no changes)
3. **CDK Exit Code State**: Running → (0=empty, 1=changes, 2=error) → Post-processing
4. **Terraform Exit Code State**: Running → (0=empty, 2=changes, 1=error) → Post-processing
5. **Rejection Recovery**: FAILED → (Lambda implicit) → Transition re-enabled

### Problems with Implicit State Machines

| Experience | Problem | Impact |
|------------|---------|--------|
| **UX** | No visibility into why stages were skipped | Users confused when Deploy/Apply disappears |
| **DX** | Exit code logic scattered across 5+ files | Hard to understand pipeline behavior |
| **AX** | State transitions hidden in Lambda code and buildspecs | Agents can't reason about pipeline state |

## The Solution: Explicit Step Functions

This module creates **visual, code-defined state machines** that:

1. ✅ **Centralize exit code handling** in one place
2. ✅ **Provide structured notifications** with state context
3. ✅ **Create self-documenting workflows** visible in AWS console
4. ✅ **Normalize exit codes** across CDK and Terraform (different conventions)
5. ✅ **Retain CodePipeline compatibility** (no breaking changes)

## State Machine Definitions

### CDK Pipeline State Machine

```
┌─────────────────┐
│ NormalizeExitCode │ ← Takes CDK_DIFF_EXIT_CODE input
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  EvaluateResult  │
└────────┬────────┘
         │
    ┌────┼────┐
    ▼    ▼    ▼
 ┌────┐┌────┐┌────┐
 │  0 ││  1 ││ 2+ │
 │No  ││Has ││Err │
 └─┬──┘└─┬──┘└─┬──┘
   │     │     │
   ▼     ▼     ▼
Skip   Notify  Fail
Deploy Approval
```

### Terraform Pipeline State Machine

```
┌─────────────────┐
│ NormalizeExitCode │ ← Takes TF_PLAN_EXIT_CODE input
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  EvaluateResult  │
└────────┬────────┘
         │
    ┌────┼────┐
    ▼    ▼    ▼
 ┌────┐┌────┐┌────┐
 │  0 ││  2 ││  1 │
 │No  ││Has ││Err │
 └─┬──┘└─┬──┘└─┬──┘
   │     │     │
   ▼     ▼     ▼
Skip   Notify  Fail
Apply  Approval
```

> ⚠️ **Note**: CDK and Terraform use DIFFERENT exit codes:
> - CDK: `0=no changes, 1=changes, 2=error`
> - Terraform: `0=no changes, 2=changes, 1=error`
>
> The state machine **normalizes** these automatically!

### Approval Rejection Recovery State Machine

```
┌───────────────────────┐
│ DeterminePipelineType │
└───────────┬───────────┘
            │
    ┌───────┴───────┐
    ▼               ▼
┌────────┐     ┌────────┐
│ CDK-*  │     │ TF-*   │
└────┬───┘     └───┬────┘
     │             │
     ▼             ▼
┌────────┐     ┌────────┐
│Re-enable│     │Re-enable│
│  Diff   │     │  Plan   │
└────┬────┘     └────┬────┘
     │             │
     └───────┬─────┘
             ▼
     ┌───────────────┐
     │    Notify     │
     └───────────────┘
```

## Usage

### Basic Usage

```hcl
module "cdk_state_machine" {
  source = "../modules/pipeline-state-machine"

  pipeline_type     = "cdk"
  plan_stage_name   = "Diff"
  deploy_stage_name = "Deploy"

  notification_topic_arns = [aws_sns_topic.pipeline_notifications.arn]
  enable_xray             = true

  tags = {
    Environment = "production"
  }
}
```

### With Terraform Pipelines

```hcl
module "terraform_state_machine" {
  source = "../modules/pipeline-state-machine"

  pipeline_type     = "terraform"
  plan_stage_name   = "Plan"
  deploy_stage_name = "Apply"

  notification_topic_arns = [aws_sns_topic.pipeline_notifications.arn]
  enable_xray             = true

  tags = {
    Environment = "production"
  }
}
```

## Benefits

### User Experience (UX)
- ✅ **Clear notifications**: Users see exactly why a stage was skipped
- ✅ **Visual workflow**: Step Functions console shows execution path
- ✅ **Consistent behavior**: Same state logic across CDK and Terraform

### Developer Experience (DX)
- ✅ **Single source of truth**: Exit codes defined in one module
- ✅ **Type safety**: Terraform validates state machine JSON
- ✅ **Observable**: CloudWatch Logs + X-Ray tracing built-in
- ✅ **Testable**: State machines can be tested independently

### Agent Experience (AX)
- ✅ **Self-documenting**: ASL definitions are human-readable
- ✅ **Complete visibility**: Agents can see all state transitions
- ✅ **No hidden logic**: Everything is in the code, no implicit behavior

## Outputs

| Output | Description |
|--------|-------------|
| `exit_codes` | Centralized exit code definitions |
| `terraform_exit_codes` | Terraform-specific exit codes (normalized) |
| `cdk_exit_codes` | CDK-specific exit codes |
| `stage_names` | Stage name mappings for consistency |
| `state_machine_arn_cdk` | ARN of CDK state machine |
| `state_machine_arn_terraform` | ARN of Terraform state machine |
| `state_machine_arn_rejection_recovery` | ARN of rejection recovery state machine |
| `log_group_name` | CloudWatch log group for execution logs |

## Migration Guide

### Step 1: Deploy State Machines

```bash
# The module creates state machines without affecting existing pipelines
cd aws/org1/deployment_builds
terraform apply -target=module.cdk_state_machine
terraform apply -target=module.terraform_state_machine
```

### Step 2: Integrate with CodePipeline (Optional)

To use the state machines in CodePipeline, add a new stage:

```hcl
stage {
  name = "Evaluate"
  
  action {
    name            = "EvaluateState"
    category        = "Build"
    owner           = "AWS"
    provider        = "CodeBuild"
    input_artifacts = ["PlanOutput"]
    version         = "1"
    
    configuration = {
      ProjectName = "StateMachineInvoker"
      EnvironmentVariables = jsonencode([
        {
          name  = "STATE_MACHINE_ARN"
          value = module.cdk_state_machine.state_machine_arn_cdk
        }
      ])
    }
  }
}
```

### Step 3: Validate

1. Check CloudWatch Logs for state machine execution
2. Verify notifications are sent to SNS
3. Review X-Ray traces for execution flow

## Architecture Decision Records

### ADR 1: Express vs Standard Workflows

**Decision**: Use Express Workflows for pipeline orchestration

**Rationale**:
- Pipeline evaluations are short-lived (< 5 minutes)
- Lower cost for high-frequency executions
- Sufficient for orchestration logic (thin wrapper around API calls)

### ADR 2: Normalized Exit Codes

**Decision**: Create a unified exit code schema

**Rationale**:
- CDK: `0=empty, 1=changes, 2=error`
- Terraform: `0=empty, 2=changes, 1=error`
- Normalized: All tools map to `0=empty, 1=changes, 2=error`
- Prevents cognitive load when switching between tools

### ADR 3: Non-Breaking Integration

**Decision**: Keep CodePipeline as the runner

**Rationale**:
- No disruption to existing workflows
- Gradual migration possible
- State machines provide visibility without replacing infrastructure
- Can be integrated as optional enhancement

## Notes for AI Agents

When working with this module:

1. **Exit codes are normalized**: Don't look at buildspec exit codes—check `local.exit_codes`
2. **State machines are EXPRESS type**: Short execution, use CloudWatch Logs for debugging
3. **All state transitions are visible**: Open Step Functions console to see execution
4. **Notifications go to SNS**: Hook into SNS topics for custom notification logic

