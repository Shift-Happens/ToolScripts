# main.tf - Moduł konfiguracji podstawowych zabezpieczeń w AWS

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

# Zmienne wejściowe
variable "environment" {
  description = "Środowisko, dla którego wdrażane są zabezpieczenia (np. dev, test, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID VPC, w którym będą wdrażane zabezpieczenia"
  type        = string
}

variable "enable_guardduty" {
  description = "Czy włączyć AWS GuardDuty"
  type        = bool
  default     = true
}

variable "enable_securityhub" {
  description = "Czy włączyć AWS Security Hub"
  type        = bool
  default     = true
}

variable "enable_config" {
  description = "Czy włączyć AWS Config"
  type        = bool
  default     = true
}

variable "enable_inspector" {
  description = "Czy włączyć AWS Inspector"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Czy włączyć VPC Flow Logs"
  type        = bool
  default     = true
}

variable "flow_logs_retention" {
  description = "Czas przechowywania VPC Flow Logs (w dniach)"
  type        = number
  default     = 90
}

variable "flow_logs_traffic_type" {
  description = "Typ ruchu do logowania (ACCEPT, REJECT, ALL)"
  type        = string
  default     = "ALL"
  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_logs_traffic_type)
    error_message = "Dozwolone wartości to: ACCEPT, REJECT, ALL."
  }
}

variable "default_security_group_ingress" {
  description = "Lista reguł ingress dla domyślnej grupy bezpieczeństwa"
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
  default = []
}

variable "default_security_group_egress" {
  description = "Lista reguł egress dla domyślnej grupy bezpieczeństwa"
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
  default = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
      description = "Allow all outbound traffic"
    }
  ]
}

variable "password_policy" {
  description = "Konfiguracja polityki haseł dla konta"
  type = object({
    minimum_password_length        = number
    require_lowercase_characters   = bool
    require_uppercase_characters   = bool
    require_numbers                = bool
    require_symbols                = bool
    allow_users_to_change_password = bool
    hard_expiry                    = bool
    max_password_age               = number
    password_reuse_prevention      = number
  })
  default = {
    minimum_password_length        = 14
    require_lowercase_characters   = true
    require_uppercase_characters   = true
    require_numbers                = true
    require_symbols                = true
    allow_users_to_change_password = true
    hard_expiry                    = false
    max_password_age               = 90
    password_reuse_prevention      = 24
  }
}

variable "tags" {
  description = "Tagi do przypisania wszystkim zasobom"
  type        = map(string)
  default     = {}
}

locals {
  common_tags = merge(
    var.tags,
    {
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  )
}

# Konfiguracja AWS Config (monitorowanie zgodności)
resource "aws_config_configuration_recorder" "main" {
  count = var.enable_config ? 1 : 0
  
  name     = "security-baseline-recorder"
  role_arn = aws_iam_role.config[0].arn
  
  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  count = var.enable_config ? 1 : 0
  
  name           = "security-baseline-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config[0].bucket
  s3_key_prefix  = "config"
  sns_topic_arn  = aws_sns_topic.security_alerts[0].arn
  
  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  count = var.enable_config ? 1 : 0
  
  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true
  
  depends_on = [aws_config_delivery_channel.main]
}

# Bucked S3 dla AWS Config
resource "aws_s3_bucket" "config" {
  count = var.enable_config ? 1 : 0
  
  bucket = "config-${data.aws_caller_identity.current.account_id}-${var.environment}"
  
  tags = merge(
    local.common_tags,
    {
      Name = "AWS-Config-Bucket"
    }
  )
}

resource "aws_s3_bucket_public_access_block" "config" {
  count = var.enable_config ? 1 : 0
  
  bucket = aws_s3_bucket.config[0].id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  count = var.enable_config ? 1 : 0
  
  bucket = aws_s3_bucket.config[0].id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  count = var.enable_config ? 1 : 0
  
  bucket = aws_s3_bucket.config[0].id
  
  rule {
    id     = "expire-old-records"
    status = "Enabled"
    
    expiration {
      days = 730
    }
  }
}

# Rola IAM dla AWS Config
resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0
  
  name = "aws-config-role-${var.environment}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "config" {
  count = var.enable_config ? 1 : 0
  
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  count = var.enable_config ? 1 : 0
  
  name   = "config-s3-access"
  role   = aws_iam_role.config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:PutObject"
        ]
        Effect = "Allow"
        Resource = [
          "${aws_s3_bucket.config[0].arn}/config/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        ]
        Condition = {
          StringLike = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Action = [
          "s3:GetBucketAcl"
        ]
        Effect   = "Allow"
        Resource = aws_s3_bucket.config[0].arn
      }
    ]
  })
}

# AWS GuardDuty (wykrywanie zagrożeń)
resource "aws_guardduty_detector" "main" {
  count = var.enable_guardduty ? 1 : 0
  
  enable = true
  
  finding_publishing_frequency = "SIX_HOURS"
  
  tags = local.common_tags
}

# AWS Security Hub (centrum bezpieczeństwa)
resource "aws_securityhub_account" "main" {
  count = var.enable_securityhub ? 1 : 0
}

# Włączenie standardów bezpieczeństwa w Security Hub
resource "aws_securityhub_standards_subscription" "cis" {
  count = var.enable_securityhub ? 1 : 0
  
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/cis-aws-foundations-benchmark/v/1.2.0"
  
  depends_on = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "aws_best_practices" {
  count = var.enable_securityhub ? 1 : 0
  
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"
  
  depends_on = [aws_securityhub_account.main]
}

# AWS Inspector (skanowanie podatności)
resource "aws_inspector_assessment_template" "main" {
  count = var.enable_inspector ? 1 : 0
  
  name       = "security-baseline-inspector-template"
  target_arn = aws_inspector_assessment_target.main[0].arn
  duration   = 3600
  
  rules_package_arns = [
    "arn:aws:inspector:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rulespackage/0-gEjTy7T7",
    "arn:aws:inspector:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rulespackage/0-rExsr2X8",
    "arn:aws:inspector:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rulespackage/0-JJOtZiqQ",
    "arn:aws:inspector:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rulespackage/0-vg5GGHSD"
  ]
}

resource "aws_inspector_assessment_target" "main" {
  count = var.enable_inspector ? 1 : 0
  
  name = "security-baseline-inspector-target"
}

# VPC Flow Logs
resource "aws_flow_log" "main" {
  count = var.enable_flow_logs ? 1 : 0
  
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  log_destination_type = "cloud-watch-logs"
  traffic_type         = var.flow_logs_traffic_type
  vpc_id               = var.vpc_id
  iam_role_arn         = aws_iam_role.flow_logs[0].arn
  
  tags = merge(
    local.common_tags,
    {
      Name = "vpc-flow-logs-${var.environment}"
    }
  )
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  
  name              = "/aws/vpc/flowlogs/${var.environment}"
  retention_in_days = var.flow_logs_retention
  
  tags = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  
  name = "vpc-flow-logs-role-${var.environment}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0
  
  name   = "vpc-flow-logs-policy"
  role   = aws_iam_role.flow_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# SNS Topic dla alertów bezpieczeństwa
resource "aws_sns_topic" "security_alerts" {
  count = 1
  
  name = "security-alerts-${var.environment}"
  
  tags = local.common_tags
}

# Polityka konfiguracji haseł
resource "aws_iam_account_password_policy" "strict" {
  minimum_password_length        = var.password_policy.minimum_password_length
  require_lowercase_characters   = var.password_policy.require_lowercase_characters
  require_uppercase_characters   = var.password_policy.require_uppercase_characters
  require_numbers                = var.password_policy.require_numbers
  require_symbols                = var.password_policy.require_symbols
  allow_users_to_change_password = var.password_policy.allow_users_to_change_password
  hard_expiry                    = var.password_policy.hard_expiry
  max_password_age               = var.password_policy.max_password_age
  password_reuse_prevention      = var.password_policy.password_reuse_prevention
}

# Konfiguracja domyślnej grupy bezpieczeństwa
resource "aws_default_security_group" "default" {
  vpc_id = var.vpc_id
  
  dynamic "ingress" {
    for_each = var.default_security_group_ingress
    content {
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
      description = ingress.value.description
    }
  }
  
  dynamic "egress" {
    for_each = var.default_security_group_egress
    content {
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
      description = egress.value.description
    }
  }
  
  tags = merge(
    local.common_tags,
    {
      Name = "default-sg-${var.environment}"
    }
  )
}

# CloudTrail (audyt działań API)
resource "aws_cloudtrail" "main" {
  name                          = "security-baseline-trail-${var.environment}"
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  s3_key_prefix                 = "prefix"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  
  event_selector {
    read_write_type           = "All"
    include_management_events = true
    
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::"]
    }
  }
  
  tags = local.common_tags
}

# Bucket S3 dla CloudTrail
resource "aws_s3_bucket" "cloudtrail" {
  count = 1
  
  bucket = "cloudtrail-${data.aws_caller_identity.current.account_id}-${var.environment}"
  
  tags = merge(
    local.common_tags,
    {
      Name = "AWS-CloudTrail-Bucket"
    }
  )
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count = 1
  
  bucket = aws_s3_bucket.cloudtrail[0].id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count = 1
  
  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail[0].arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail[0].arn}/prefix/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count = 1
  
  bucket = aws_s3_bucket.cloudtrail[0].id
  
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Alerty CloudWatch dla działań administratora
resource "aws_cloudwatch_log_metric_filter" "root_login" {
  name           = "root-login-${var.environment}"
  pattern        = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
  log_group_name = "aws/cloudtrail"
  
  metric_transformation {
    name      = "RootAccountUsage"
    namespace = "SecurityBaseline"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "root_login" {
  alarm_name          = "root-account-usage-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "RootAccountUsage"
  namespace           = "SecurityBaseline"
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "This metric monitors root account usage"
  alarm_actions       = [aws_sns_topic.security_alerts[0].arn]
}

# Alerty dla nieautoryzowanego dostępu
resource "aws_cloudwatch_log_metric_filter" "unauthorized_api_calls" {
  name           = "unauthorized-api-calls-${var.environment}"
  pattern        = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"
  log_group_name = "aws/cloudtrail"
  
  metric_transformation {
    name      = "UnauthorizedAPICalls"
    namespace = "SecurityBaseline"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "unauthorized_api_calls" {
  alarm_name          = "unauthorized-api-calls-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "UnauthorizedAPICalls"
  namespace           = "SecurityBaseline"
  period              = "60"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "This metric monitors unauthorized API calls"
  alarm_actions       = [aws_sns_topic.security_alerts[0].arn]
}

# Pomocnicze elementy
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Outputs
output "guardduty_detector_id" {
  description = "ID detektora GuardDuty"
  value       = var.enable_guardduty ? aws_guardduty_detector.main[0].id : null
}

output "security_alerts_topic_arn" {
  description = "ARN tematu SNS dla alertów bezpieczeństwa"
  value       = aws_sns_topic.security_alerts[0].arn
}

output "cloudtrail_bucket_id" {
  description = "ID bucketa S3 dla CloudTrail"
  value       = aws_s3_bucket.cloudtrail[0].id
}

output "flow_logs_group_name" {
  description = "Nazwa grupy CloudWatch Logs dla Flow Logs"
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_logs[0].name : null
}
