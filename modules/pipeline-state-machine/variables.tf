variable "create_state_machines" {
  description = "Whether to create the state machine resources"
  type        = bool
  default     = true
}

variable "pipeline_type" {
  description = "Type of pipeline this state machine is for (cdk or terraform)"
  type        = string
  validation {
    condition     = contains(["cdk", "terraform"], var.pipeline_type)
    error_message = "pipeline_type must be either 'cdk' or 'terraform'"
  }
}

variable "plan_stage_name" {
  description = "Name of the plan/diff stage in the pipeline"
  type        = string
  default     = "Plan"
}

variable "deploy_stage_name" {
  description = "Name of the deploy/apply stage in the pipeline"
  type        = string
  default     = "Deploy"
}

variable "notification_topic_arns" {
  description = "ARNs of SNS topics for state change notifications"
  type        = list(string)
  default     = []
}

variable "notification_lambda_arn" {
  description = "ARN of Lambda function for sending notifications"
  type        = string
  default     = ""
}

variable "enable_xray" {
  description = "Enable X-Ray tracing for state machines"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "ARN of KMS key for CloudWatch log encryption"
  type        = string
  default     = null
}

variable "create_alarms" {
  description = "Whether to create CloudWatch alarms for state machine failures"
  type        = bool
  default     = true
}

variable "alarm_notification_arns" {
  description = "ARNs of SNS topics for alarm notifications"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
