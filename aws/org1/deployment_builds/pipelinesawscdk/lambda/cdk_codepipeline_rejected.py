"""
Lambda handler for CDK CodePipeline rejected/failed events.

DEPRECATION NOTICE: This handler implements an IMPLICIT state machine.
For new implementations, use the Step Functions workflow defined in:
- modules/pipeline-state-machine/
- aws_sfn_state_machine.approval_rejection_recovery

This handler re-enables the Diff stage transition when an approval is rejected
or a build fails. This prevents the next queued execution from wiping the Diff
output before it can be reviewed.

Stage Transition Pattern (Implicit State Machine):
┌─────────────────┐
│   FAILED State  │ ← Trigger: CloudWatch Event
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Check Prefix   │ CDK-* ?
└────────┬────────┘
         │
    ┌────┴────┐
    ▼         ▼
┌──────┐  ┌──────┐
│Match │  │No Match│
└──┬───┘  └──┬───┘
   │         │
   ▼         ▼
┌────────┐ ┌──────┐
│Re-enable│ │Skip  │
│ Diff   │ │      │
└──┬─────┘ └──────┘
   │
   ▼
┌────────┐
│ Done   │
└────────┘

Explicit Alternative:
The Step Functions workflow at modules/pipeline-state-machine/main.tf
provides the same logic with:
- Visual workflow in AWS Console
- Centralized logging in CloudWatch
- X-Ray tracing support
- Structured notifications
"""

import logging
import json
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

client = boto3.client("codepipeline")

# Configuration constants for the stage transition pattern
# NOTE: These are duplicated in the state machine module for consistency.
# Future enhancement: Read these from a central configuration source.
TARGET_STAGE_NAME = "Diff"
TRANSITION_TYPE_INBOUND = "Inbound"
PIPELINE_PREFIX = "CDK-"
FAILED_STATE = "FAILED"


def lambda_handler(event, context):
    """
    Handle CodePipeline FAILED events by re-enabling stage transitions.
    
    This function implements an implicit state machine that:
    1. Receives SNS notification from CloudWatch Events
    2. Checks if the pipeline matches CDK-* prefix
    3. Re-enables the Diff stage transition
    4. Logs the result for observability
    
    Args:
        event: SNS event triggering the Lambda
        context: Lambda execution context
        
    Returns:
        str: Empty JSON object (historical, kept for compatibility)
    """
    pipeline_states_handled = []
    
    for i in event["Records"]:
        msg = json.loads(i["Sns"]["Message"])
        detail = msg["detail"]
        
        logger.info(f"Processing event: {json.dumps(detail)}")
        
        if (
            detail.get("state") == FAILED_STATE
            and detail.get("pipeline", "").startswith(PIPELINE_PREFIX)
        ):
            category = detail["type"]["category"]
            provider = detail["type"]["provider"]
            action = detail["action"]
            state = detail["state"]
            pipeline_name = detail["pipeline"]
            region = detail["region"]
            
            logger.info(f"Action category: {category}")
            logger.info(f"Action provider: {provider}")
            logger.info(f"Action name: {action}")
            logger.info(f"State: {state}")
            logger.info(f"Pipeline: {pipeline_name}")
            logger.info(f"Region: {region}")
            
            stage_name = TARGET_STAGE_NAME
            transition_type = TRANSITION_TYPE_INBOUND
            
            logger.info(
                f"Executing implicit state transition: "
                f"Enable '{transition_type}' transition for stage '{stage_name}' "
                f"in pipeline '{pipeline_name}'..."
            )
            
            try:
                response = client.enable_stage_transition(
                    pipelineName=pipeline_name,
                    stageName=stage_name,
                    transitionType=transition_type,
                )
                logger.info(f"EnableStageTransition response: {response}")
                logger.info(
                    f"[SUCCESS] Transition re-enabled for {pipeline_name}/{stage_name}"
                )
                pipeline_states_handled.append({
                    "pipeline": pipeline_name,
                    "stage": stage_name,
                    "status": "SUCCESS"
                })
            except client.exceptions.PipelineNotFoundException:
                logger.error(f"[ERROR] Pipeline not found: '{pipeline_name}'")
                pipeline_states_handled.append({
                    "pipeline": pipeline_name,
                    "stage": stage_name,
                    "status": "PIPELINE_NOT_FOUND"
                })
            except client.exceptions.StageNotFoundException:
                logger.error(f"[ERROR] Stage '{stage_name}' not found in '{pipeline_name}'")
                pipeline_states_handled.append({
                    "pipeline": pipeline_name,
                    "stage": stage_name,
                    "status": "STAGE_NOT_FOUND"
                })
            except Exception as e:
                logger.error(f"[ERROR] Unexpected error: {e}")
                pipeline_states_handled.append({
                    "pipeline": pipeline_name,
                    "stage": stage_name,
                    "status": "ERROR",
                    "error": str(e)
                })
    
    # Return structured result for state machine integration
    result = {
        "handledPipelines": pipeline_states_handled,
        "implicitStateMachine": "CDK-RejectionRecovery",
        "recommendedAlternative": "StepFunctions Pipeline-ApprovalRejectionRecovery"
    }
    logger.info(f"Lambda result: {json.dumps(result)}")
    return json.dumps(result)
