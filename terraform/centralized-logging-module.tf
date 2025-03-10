# main.tf - Centralna platforma logowania z Grafaną

#Jak korzystać z modułu:
#hclCopymodule "centralized_logging" {
#  source = "./modules/centralized-logging-platform"
#  
#  name_prefix = "org-name"
#  environment = "production"
#  
#  vpc_id     = module.vpc.vpc_id
#  subnet_ids = module.vpc.private_subnets
#  
#  # Konfiguracja OpenSearch
#  enable_opensearch        = true
#  opensearch_instance_type = "r6g.xlarge.search"
#  opensearch_instance_count = 3
#  opensearch_ebs_volume_size = 200
#  
#  # Konfiguracja Grafana
#  enable_grafana = true
#  admin_users    = ["arn:aws:iam::123456789012:user/admin1"]
#  reader_users   = ["arn:aws:iam::123456789012:user/reader1"]
#  
#  # Konfiguracja Prometheus
#  enable_prometheus = true
#  
#  # Konfiguracja alertów
#  enable_alerting = true
#  alert_notification_emails = [
#    "devops@example.com",
#    "alerts@example.com"
#  ]
#  
#  # Fluent Bit dla EC2
#  enable_fluentbit = true
#  
#  # Retencja logów (w dniach)
#  retention_days = 90
#  
#  tags = {
#    Project     = "Infrastructure"
#    CostCenter  = "IT"
#    Environment = "Production"
#  }
#}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

# Zmienne wejściowe
variable "name_prefix" {
  description = "Prefiks nazwy dla wszystkich zasobów"
  type        = string
  default     = "centralized-logging"
}

variable "environment" {
  description = "Środowisko (np. dev, test, prod)"
  type        = string
}

variable "vpc_id" {
  description = "ID VPC, w którym będzie wdrożona platforma logowania"
  type        = string
}

variable "subnet_ids" {
  description = "Lista ID podsieci, w których będą wdrożone komponenty platformy"
  type        = list(string)
}

variable "enable_opensearch" {
  description = "Czy włączyć Amazon OpenSearch Service (ElasticSearch)"
  type        = bool
  default     = true
}

variable "enable_grafana" {
  description = "Czy włączyć Amazon Managed Grafana"
  type        = bool
  default     = true
}

variable "opensearch_instance_type" {
  description = "Typ instancji dla OpenSearch"
  type        = string
  default     = "r6g.large.search"
}

variable "opensearch_instance_count" {
  description = "Liczba instancji dla OpenSearch"
  type        = number
  default     = 2
}

variable "opensearch_ebs_volume_size" {
  description = "Rozmiar woluminu EBS dla OpenSearch (w GB)"
  type        = number
  default     = 100
}

variable "opensearch_version" {
  description = "Wersja OpenSearch"
  type        = string
  default     = "OpenSearch_2.5"
}

variable "retention_days" {
  description = "Liczba dni przechowywania logów"
  type        = number
  default     = 90
}

variable "admin_users" {
  description = "Lista IAM ARN użytkowników z dostępem administratora do Grafany"
  type        = list(string)
  default     = []
}

variable "reader_users" {
  description = "Lista IAM ARN użytkowników z dostępem read-only do Grafany"
  type        = list(string)
  default     = []
}

variable "log_subscription_filter_pattern" {
  description = "Wzorzec filtrowania dla subskrypcji CloudWatch Logs"
  type        = string
  default     = ""  # Pusty wzorzec oznacza wszystkie logi
}

variable "enable_fluentbit" {
  description = "Czy włączyć Fluent Bit na instancjach EC2"
  type        = bool
  default     = true
}

variable "fluentbit_ec2_iam_role_name" {
  description = "Nazwa roli IAM dla EC2 używających Fluent Bit"
  type        = string
  default     = "FluentBitEC2Role"
}

variable "enable_cloudwatch_logs_subscription" {
  description = "Czy włączyć automatyczną subskrypcję logów CloudWatch do OpenSearch"
  type        = bool
  default     = true
}

variable "enable_prometheus" {
  description = "Czy włączyć Amazon Managed Service for Prometheus"
  type        = bool
  default     = true
}

variable "enable_alerting" {
  description = "Czy włączyć alerty dla platformy logowania"
  type        = bool
  default     = true
}

variable "alert_notification_emails" {
  description = "Lista adresów email do powiadomień o alertach"
  type        = list(string)
  default     = []
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
      Service     = "logging-platform"
    }
  )
  
  opensearch_domain_name = "${var.name_prefix}-domain-${var.environment}"
  
  prometheus_workspace_name = "${var.name_prefix}-prometheus-${var.environment}"
  
  grafana_workspace_name = "${var.name_prefix}-grafana-${var.environment}"
  
  log_group_prefix = "/aws/${var.name_prefix}"
}

# Grupa bezpieczeństwa dla OpenSearch
resource "aws_security_group" "opensearch" {
  count = var.enable_opensearch ? 1 : 0
  
  name        = "${var.name_prefix}-opensearch-sg-${var.environment}"
  description = "Security group for OpenSearch domain"
  vpc_id      = var.vpc_id
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
    description = "HTTPS access from within VPC"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
  
  tags = merge(
    local.common_tags,
    {
      Name = "${var.name_prefix}-opensearch-sg-${var.environment}"
    }
  )
}

# Polityka dostępu dla OpenSearch
data "aws_iam_policy_document" "opensearch_access_policy" {
  count = var.enable_opensearch ? 1 : 0
  
  statement {
    effect    = "Allow"
    actions   = ["es:*"]
    resources = ["arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${local.opensearch_domain_name}/*"]
    
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    
    condition {
      test     = "IpAddress"
      variable = "aws:SourceIp"
      values   = ["10.0.0.0/8"]
    }
  }
}

# Domena OpenSearch
resource "aws_opensearch_domain" "main" {
  count = var.enable_opensearch ? 1 : 0
  
  domain_name    = local.opensearch_domain_name
  engine_version = var.opensearch_version
  
  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = var.opensearch_instance_count
    zone_awareness_enabled = true
    
    zone_awareness_config {
      availability_zone_count = min(var.opensearch_instance_count, length(var.subnet_ids))
    }
  }
  
  vpc_options {
    subnet_ids         = slice(var.subnet_ids, 0, min(var.opensearch_instance_count, length(var.subnet_ids)))
    security_group_ids = [aws_security_group.opensearch[0].id]
  }
  
  ebs_options {
    ebs_enabled = true
    volume_size = var.opensearch_ebs_volume_size
    volume_type = "gp3"
  }
  
  encrypt_at_rest {
    enabled = true
  }
  
  node_to_node_encryption {
    enabled = true
  }
  
  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }
  
  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_logs[0].arn
    log_type                 = "INDEX_SLOW_LOGS"
    enabled                  = true
  }
  
  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_logs[0].arn
    log_type                 = "SEARCH_SLOW_LOGS"
    enabled                  = true
  }
  
  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_logs[0].arn
    log_type                 = "ES_APPLICATION_LOGS"
    enabled                  = true
  }
  
  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true
    
    master_user_options {
      master_user_name     = "admin"
      master_user_password = random_password.opensearch_master[0].result
    }
  }
  
  access_policies = data.aws_iam_policy_document.opensearch_access_policy[0].json
  
  tags = local.common_tags
  
  depends_on = [aws_cloudwatch_log_group.opensearch_logs]
}

# Grupa logów CloudWatch dla OpenSearch
resource "aws_cloudwatch_log_group" "opensearch_logs" {
  count = var.enable_opensearch ? 1 : 0
  
  name              = "${local.log_group_prefix}/opensearch"
  retention_in_days = var.retention_days
  
  tags = local.common_tags
}

# Hasło dla użytkownika głównego OpenSearch
resource "random_password" "opensearch_master" {
  count = var.enable_opensearch ? 1 : 0
  
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# AWS Managed Grafana
resource "aws_grafana_workspace" "main" {
  count = var.enable_grafana ? 1 : 0
  
  name        = local.grafana_workspace_name
  description = "Centralized logging platform - Grafana workspace"
  
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  
  data_sources = ["CLOUDWATCH", "PROMETHEUS", "OPENSEARCH"]
  
  notification_destinations = var.enable_alerting ? ["SNS"] : []
  
  role_arn = aws_iam_role.grafana[0].arn
  
  vpc_configuration {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.grafana[0].id]
  }
  
  tags = local.common_tags
}

# Grupa bezpieczeństwa dla Grafana
resource "aws_security_group" "grafana" {
  count = var.enable_grafana ? 1 : 0
  
  name        = "${var.name_prefix}-grafana-sg-${var.environment}"
  description = "Security group for Grafana workspace"
  vpc_id      = var.vpc_id
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
  
  tags = merge(
    local.common_tags,
    {
      Name = "${var.name_prefix}-grafana-sg-${var.environment}"
    }
  )
}

# Polityka licencyjności dla Grafana
resource "aws_grafana_workspace_license_association" "enterprise" {
  count = var.enable_grafana ? 1 : 0
  
  workspace_id = aws_grafana_workspace.main[0].id
  license_type = "ENTERPRISE"
}

# Rola IAM dla Grafana
resource "aws_iam_role" "grafana" {
  count = var.enable_grafana ? 1 : 0
  
  name = "${var.name_prefix}-grafana-role-${var.environment}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "grafana.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

# Polityka IAM dla Grafana
resource "aws_iam_policy" "grafana" {
  count = var.enable_grafana ? 1 : 0
  
  name        = "${var.name_prefix}-grafana-policy-${var.environment}"
  description = "Policy for Amazon Managed Grafana"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:DescribeAlarms",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "es:ESHttpGet",
          "es:ESHttpPost",
          "es:ESHttpPut"
        ]
        Effect   = "Allow"
        Resource = var.enable_opensearch ? "${aws_opensearch_domain.main[0].arn}/*" : "*"
      },
      {
        Action = [
          "aps:QueryMetrics",
          "aps:GetMetricMetadata",
          "aps:GetSeries",
          "aps:GetLabels"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "sns:Publish"
        ]
        Effect   = "Allow"
        Resource = var.enable_alerting ? aws_sns_topic.alerts[0].arn : "*"
      }
    ]
  })
}

# Dołączenie polityki do roli Grafana
resource "aws_iam_role_policy_attachment" "grafana" {
  count = var.enable_grafana ? 1 : 0
  
  role       = aws_iam_role.grafana[0].name
  policy_arn = aws_iam_policy.grafana[0].arn
}

# Zarządzanie użytkownikami Grafana
resource "aws_grafana_role_association" "admin_users" {
  count = var.enable_grafana ? length(var.admin_users) : 0
  
  role         = "ADMIN"
  user_ids     = [var.admin_users[count.index]]
  workspace_id = aws_grafana_workspace.main[0].id
}

resource "aws_grafana_role_association" "reader_users" {
  count = var.enable_grafana ? length(var.reader_users) : 0
  
  role         = "VIEWER"
  user_ids     = [var.reader_users[count.index]]
  workspace_id = aws_grafana_workspace.main[0].id
}

# Amazon Managed Service for Prometheus
resource "aws_prometheus_workspace" "main" {
  count = var.enable_prometheus ? 1 : 0
  
  alias = local.prometheus_workspace_name
  
  tags = local.common_tags
}

# Rola IAM dla Fluent Bit na EC2
resource "aws_iam_role" "fluentbit_ec2" {
  count = var.enable_fluentbit ? 1 : 0
  
  name = var.fluentbit_ec2_iam_role_name
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

# Polityka IAM dla Fluent Bit na EC2
resource "aws_iam_policy" "fluentbit_ec2" {
  count = var.enable_fluentbit ? 1 : 0
  
  name        = "${var.name_prefix}-fluentbit-policy-${var.environment}"
  description = "Policy for Fluent Bit on EC2 instances"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "es:ESHttpPost",
          "es:ESHttpPut"
        ]
        Effect   = "Allow"
        Resource = var.enable_opensearch ? "${aws_opensearch_domain.main[0].arn}/*" : "*"
      },
      {
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Dołączenie polityki do roli Fluent Bit
resource "aws_iam_role_policy_attachment" "fluentbit_ec2" {
  count = var.enable_fluentbit ? 1 : 0
  
  role       = aws_iam_role.fluentbit_ec2[0].name
  policy_arn = aws_iam_policy.fluentbit_ec2[0].arn
}

# Profil instancji dla Fluent Bit
resource "aws_iam_instance_profile" "fluentbit_ec2" {
  count = var.enable_fluentbit ? 1 : 0
  
  name = "${var.name_prefix}-fluentbit-profile-${var.environment}"
  role = aws_iam_role.fluentbit_ec2[0].name
  
  tags = local.common_tags
}

# Funkcja Lambda do przesyłania logów CloudWatch do OpenSearch
resource "aws_lambda_function" "logs_to_opensearch" {
  count = var.enable_cloudwatch_logs_subscription && var.enable_opensearch ? 1 : 0
  
  function_name    = "${var.name_prefix}-logs-to-opensearch-${var.environment}"
  description      = "Forward CloudWatch Logs to OpenSearch"
  filename         = "${path.module}/lambda/logs_to_opensearch.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/logs_to_opensearch.zip")
  role             = aws_iam_role.logs_to_opensearch[0].arn
  handler          = "index.handler"
  runtime          = "nodejs16.x"
  timeout          = 60
  memory_size      = 256
  
  environment {
    variables = {
      OPENSEARCH_ENDPOINT = "https://${aws_opensearch_domain.main[0].endpoint}"
      INDEX_PREFIX        = "cwl-"
    }
  }
  
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda[0].id]
  }
  
  tags = local.common_tags
}

# Grupa bezpieczeństwa dla Lambda
resource "aws_security_group" "lambda" {
  count = var.enable_cloudwatch_logs_subscription && var.enable_opensearch ? 1 : 0
  
  name        = "${var.name_prefix}-lambda-sg-${var.environment}"
  description = "Security group for Lambda functions"
  vpc_id      = var.vpc_id
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
  
  tags = merge(
    local.common_tags,
    {
      Name = "${var.name_prefix}-lambda-sg-${var.environment}"
    }
  )
}

# Rola IAM dla Lambda
resource "aws_iam_role" "logs_to_opensearch" {
  count = var.enable_cloudwatch_logs_subscription && var.enable_opensearch ? 1 : 0
  
  name = "${var.name_prefix}-logs-to-opensearch-role-${var.environment}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  tags = local.common_tags
}

# Polityka IAM dla Lambda
resource "aws_iam_policy" "logs_to_opensearch" {
  count = var.enable_cloudwatch_logs_subscription && var.enable_opensearch ? 1 : 0
  
  name        = "${var.name_prefix}-logs-to-opensearch-policy-${var.environment}"
  description = "Policy for Lambda to forward logs to OpenSearch"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "es:ESHttpPost",
          "es:ESHttpPut"
        ]
        Effect   = "Allow"
        Resource = "${aws_opensearch_domain.main[0].arn}/*"
      }
    ]
  })
}

# Dołączenie polityki do roli Lambda
resource "aws_iam_role_policy_attachment" "logs_to_opensearch" {
  count = var.enable_cloudwatch_logs_subscription && var.enable_opensearch ? 1 : 0
  
  role       = aws_iam_role.logs_to_opensearch[0].name
  policy_arn = aws_iam_policy.logs_to_opensearch[0].arn
}

# Zezwolenie dla CloudWatch Logs na wywoływanie Lambda
resource "aws_lambda_permission" "cloudwatch_logs" {
  count = var.enable_cloudwatch_logs_subscription && var.enable_opensearch ? 1 : 0
  
  statement_id  = "AllowExecutionFromCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.logs_to_opensearch[0].function_name
  principal     = "logs.${data.aws_region.current.name}.amazonaws.com"
}

# Grupa logów CloudWatch dla przechowywania zbieranych logów
resource "aws_cloudwatch_log_group" "collected_logs" {
  name              = "${local.log_group_prefix}/collected-logs"
  retention_in_days = var.retention_days
  
  tags = local.common_tags
}

# SNS Topic dla alertów
resource "aws_sns_topic" "alerts" {
  count = var.enable_alerting ? 1 : 0
  
  name = "${var.name_prefix}-alerts-${var.environment}"
  
  tags = local.common_tags
}

# Subskrypcje SNS dla alertów
resource "aws_sns_topic_subscription" "email_alerts" {
  count = var.enable_alerting ? length(var.alert_notification_emails) : 0
  
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_notification_emails[count.index]
}

# Dashboard CloudWatch dla monitorowania platformy logowania
resource "aws_cloudwatch_dashboard" "logging_platform" {
  dashboard_name = "${var.name_prefix}-dashboard-${var.environment}"
  
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          metrics = var.enable_opensearch ? [
            [ "AWS/ES", "ClusterStatus.green", "DomainName", local.opensearch_domain_name, { yAxis = "right" } ],
            [ ".", "ClusterStatus.yellow", ".", ".", { yAxis = "right" } ],
            [ ".", "ClusterStatus.red", ".", ".", { yAxis = "right" } ],
            [ ".", "CPUUtilization", ".", ".", { stat = "Average" } ],
            [ ".", "JVMMemoryPressure", ".", ".", { stat = "Average" } ]
          ] : []
          region  = data.aws_region.current.name
          title   = "OpenSearch Cluster Status"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          metrics = var.enable_opensearch ? [
            [ "AWS/ES", "SearchableDocuments", "DomainName", local.opensearch_domain_name ],
            [ ".", "SearchRate", ".", "." ],
            [ ".", "IndexingRate", ".", "." ]
          ] : []
          region  = data.aws_region.current.name
          title   = "OpenSearch Documents and Operations"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          metrics = var.enable_grafana ? [
            [ "AWS/ManagedGrafana", "ActiveUserCount", "GrafanaWorkspaceId", aws_grafana_workspace.main[0].id ],
            [ ".", "DashboardCount", ".", "." ]
          ] : []
          region  = data.aws_region.current.name
          title   = "Grafana Usage"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          metrics = [
            [ "AWS/Logs", "IncomingLogEvents", "LogGroupName", "${local.log_group_prefix}/collected-logs" ],
            [ ".", "IncomingBytes", ".", "." ]
          ]
          region  = data.aws_region.current.name
          title   = "CloudWatch Logs Ingestion"
          period  = 300
        }
      }
    ]
  })
}

# Alarmy CloudWatch dla monitorowania stanu platformy
resource "aws_cloudwatch_metric_alarm" "opensearch_cluster_red" {
  count = var.enable_opensearch && var.enable_alerting ? 1 : 0
  
  alarm_name          = "${var.name_prefix}-opensearch-cluster-red-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ClusterStatus.red"
  namespace           = "AWS/ES"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "0"
  alarm_description   = "This alarm monitors OpenSearch cluster red status"
  
  dimensions = {
    DomainName = local.opensearch_domain_name
  }
  
  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]
  
  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "opensearch_cpu_high" {
  count = var.enable_opensearch && var.enable_alerting ? 1 : 0
  
  alarm_name          = "${var.name_prefix}-opensearch-cpu-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ES"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm monitors OpenSearch CPU utilization"
  
  dimensions = {
    DomainName = local.opensearch_domain_name
  }
  
  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]
  
  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "opensearch_disk_space" {
  count = var.enable_opensearch && var.enable_alerting ? 1 : 0
  
  alarm_name          = "${var.name_prefix}-opensearch-disk-space-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/ES"
  period              = "60"
  statistic           = "Minimum"
  threshold           = "20480"  # 20 GB in MB
  alarm_description   = "This alarm monitors OpenSearch free storage space"
  
  dimensions = {
    DomainName = local.opensearch_domain_name
  }
  
  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]
  
  tags = local.common_tags
}

# Prosty ConfigMap dla Fluent Bit (do użycia w Kubernetes)
resource "aws_ssm_parameter" "fluentbit_config" {
  count = var.enable_fluentbit && var.enable_opensearch ? 1 : 0
  
  name  = "/${var.name_prefix}/${var.environment}/fluentbit/config"
  type  = "String"
  value = jsonencode({
    service = {
      flush        = 5
      daemon       = "off"
      log_level    = "info"
      http_server  = "on"
      http_listen  = "0.0.0.0"
      http_port    = 2020
      storage_path = "/var/log/flb-storage/"
    }
    input = {
      system = {
        name       = "tail"
        path       = "/var/log/messages,/var/log/syslog"
        parser     = "syslog"
        tag        = "system.*"
      }
      application = {
        name       = "tail"
        path       = "/var/log/application/*.log"
        multiline  = "on"
        parser     = "docker"
        tag        = "application.*"
      }
    }
    filter = {
      kubernetes = {
        name           = "kubernetes"
        match          = "*"
        kube_url       = "https://kubernetes.default.svc.cluster.local:443"
        kube_ca_file   = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        kube_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      }
      ec2 = {
        name           = "aws"
        match          = "*"
        imds_version   = "v2"
      }
    }
    output = var.enable_opensearch ? {
      opensearch = {
        name            = "es"
        match           = "*"
        host            = aws_opensearch_domain.main[0].endpoint
        port            = 443
        tls             = "on"
        index           = "fluentbit"
        type            = "_doc"
        logstash_format = "on"
        logstash_prefix = "logs"
        time_key        = "@timestamp"
        include_tag_key = "on"
        tag_key         = "tag"
      }
    } : {
      cloudwatch = {
        name           = "cloudwatch"
        match          = "*"
        region         = data.aws_region.current.name
        log_group_name = aws_cloudwatch_log_group.collected_logs.name
        log_stream_prefix = "fluentbit-"
        auto_create_group = "false"
      }
    }
  })
  
  tags = local.common_tags
}

# Zasoby dla dashboardów Grafana
# To jest szablon dashboardu, który będzie dostępny do importu w Grafana
resource "aws_ssm_parameter" "grafana_dashboard_infrastructure" {
  count = var.enable_grafana ? 1 : 0
  
  name  = "/${var.name_prefix}/${var.environment}/grafana/dashboards/infrastructure"
  type  = "String"
  value = jsonencode({
    "annotations": {
      "list": [
        {
          "builtIn": 1,
          "datasource": "-- Grafana --",
          "enable": true,
          "hide": true,
          "iconColor": "rgba(0, 211, 255, 1)",
          "name": "Annotations & Alerts",
          "type": "dashboard"
        }
      ]
    },
    "editable": true,
    "gnetId": null,
    "graphTooltip": 0,
    "id": null,
    "links": [],
    "panels": [
      {
        "aliasColors": {},
        "bars": false,
        "dashLength": 10,
        "dashes": false,
        "datasource": "CloudWatch",
        "fieldConfig": {
          "defaults": {
            "custom": {}
          },
          "overrides": []
        },
        "fill": 1,
        "fillGradient": 0,
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 0
        },
        "hiddenSeries": false,
        "id": 2,
        "legend": {
          "avg": false,
          "current": false,
          "max": false,
          "min": false,
          "show": true,
          "total": false,
          "values": false
        },
        "lines": true,
        "linewidth": 1,
        "nullPointMode": "null",
        "options": {
          "alertThreshold": true
        },
        "percentage": false,
        "pluginVersion": "7.4.0",
        "pointradius": 2,
        "points": false,
        "renderer": "flot",
        "seriesOverrides": [],
        "spaceLength": 10,
        "stack": false,
        "steppedLine": false,
        "targets": [
          {
            "alias": "CPU Utilization",
            "dimensions": {},
            "expression": "",
            "id": "",
            "matchExact": true,
            "metricName": "CPUUtilization",
            "namespace": "AWS/EC2",
            "period": "",
            "refId": "A",
            "region": "default",
            "statistics": [
              "Average"
            ]
          }
        ],
        "thresholds": [],
        "timeFrom": null,
        "timeRegions": [],
        "timeShift": null,
        "title": "EC2 CPU Utilization",
        "tooltip": {
          "shared": true,
          "sort": 0,
          "value_type": "individual"
        },
        "type": "graph",
        "xaxis": {
          "buckets": null,
          "mode": "time",
          "name": null,
          "show": true,
          "values": []
        },
        "yaxes": [
          {
            "format": "percent",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          },
          {
            "format": "short",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          }
        ],
        "yaxis": {
          "align": false,
          "alignLevel": null
        }
      },
      {
        "aliasColors": {},
        "bars": false,
        "dashLength": 10,
        "dashes": false,
        "datasource": "CloudWatch",
        "fieldConfig": {
          "defaults": {
            "custom": {}
          },
          "overrides": []
        },
        "fill": 1,
        "fillGradient": 0,
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 0
        },
        "hiddenSeries": false,
        "id": 3,
        "legend": {
          "avg": false,
          "current": false,
          "max": false,
          "min": false,
          "show": true,
          "total": false,
          "values": false
        },
        "lines": true,
        "linewidth": 1,
        "nullPointMode": "null",
        "options": {
          "alertThreshold": true
        },
        "percentage": false,
        "pluginVersion": "7.4.0",
        "pointradius": 2,
        "points": false,
        "renderer": "flot",
        "seriesOverrides": [],
        "spaceLength": 10,
        "stack": false,
        "steppedLine": false,
        "targets": [
          {
            "alias": "Network In",
            "dimensions": {},
            "expression": "",
            "id": "",
            "matchExact": true,
            "metricName": "NetworkIn",
            "namespace": "AWS/EC2",
            "period": "",
            "refId": "A",
            "region": "default",
            "statistics": [
              "Average"
            ]
          },
          {
            "alias": "Network Out",
            "dimensions": {},
            "expression": "",
            "id": "",
            "matchExact": true,
            "metricName": "NetworkOut",
            "namespace": "AWS/EC2",
            "period": "",
            "refId": "B",
            "region": "default",
            "statistics": [
              "Average"
            ]
          }
        ],
        "thresholds": [],
        "timeFrom": null,
        "timeRegions": [],
        "timeShift": null,
        "title": "EC2 Network Traffic",
        "tooltip": {
          "shared": true,
          "sort": 0,
          "value_type": "individual"
        },
        "type": "graph",
        "xaxis": {
          "buckets": null,
          "mode": "time",
          "name": null,
          "show": true,
          "values": []
        },
        "yaxes": [
          {
            "format": "bytes",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          },
          {
            "format": "short",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          }
        ],
        "yaxis": {
          "align": false,
          "alignLevel": null
        }
      },
      {
        "aliasColors": {},
        "bars": false,
        "dashLength": 10,
        "dashes": false,
        "datasource": "CloudWatch",
        "fieldConfig": {
          "defaults": {
            "custom": {}
          },
          "overrides": []
        },
        "fill": 1,
        "fillGradient": 0,
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 8
        },
        "hiddenSeries": false,
        "id": 4,
        "legend": {
          "avg": false,
          "current": false,
          "max": false,
          "min": false,
          "show": true,
          "total": false,
          "values": false
        },
        "lines": true,
        "linewidth": 1,
        "nullPointMode": "null",
        "options": {
          "alertThreshold": true
        },
        "percentage": false,
        "pluginVersion": "7.4.0",
        "pointradius": 2,
        "points": false,
        "renderer": "flot",
        "seriesOverrides": [],
        "spaceLength": 10,
        "stack": false,
        "steppedLine": false,
        "targets": [
          {
            "alias": "CPU Utilization",
            "dimensions": {},
            "expression": "",
            "id": "",
            "matchExact": true,
            "metricName": "CPUUtilization",
            "namespace": "AWS/RDS",
            "period": "",
            "refId": "A",
            "region": "default",
            "statistics": [
              "Average"
            ]
          }
        ],
        "thresholds": [],
        "timeFrom": null,
        "timeRegions": [],
        "timeShift": null,
        "title": "RDS CPU Utilization",
        "tooltip": {
          "shared": true,
          "sort": 0,
          "value_type": "individual"
        },
        "type": "graph",
        "xaxis": {
          "buckets": null,
          "mode": "time",
          "name": null,
          "show": true,
          "values": []
        },
        "yaxes": [
          {
            "format": "percent",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          },
          {
            "format": "short",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          }
        ],
        "yaxis": {
          "align": false,
          "alignLevel": null
        }
      },
      {
        "aliasColors": {},
        "bars": false,
        "dashLength": 10,
        "dashes": false,
        "datasource": "CloudWatch",
        "fieldConfig": {
          "defaults": {
            "custom": {}
          },
          "overrides": []
        },
        "fill": 1,
        "fillGradient": 0,
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 8
        },
        "hiddenSeries": false,
        "id": 5,
        "legend": {
          "avg": false,
          "current": false,
          "max": false,
          "min": false,
          "show": true,
          "total": false,
          "values": false
        },
        "lines": true,
        "linewidth": 1,
        "nullPointMode": "null",
        "options": {
          "alertThreshold": true
        },
        "percentage": false,
        "pluginVersion": "7.4.0",
        "pointradius": 2,
        "points": false,
        "renderer": "flot",
        "seriesOverrides": [],
        "spaceLength": 10,
        "stack": false,
        "steppedLine": false,
        "targets": [
          {
            "alias": "Free Storage Space",
            "dimensions": {},
            "expression": "",
            "id": "",
            "matchExact": true,
            "metricName": "FreeStorageSpace",
            "namespace": "AWS/RDS",
            "period": "",
            "refId": "A",
            "region": "default",
            "statistics": [
              "Average"
            ]
          }
        ],
        "thresholds": [],
        "timeFrom": null,
        "timeRegions": [],
        "timeShift": null,
        "title": "RDS Free Storage Space",
        "tooltip": {
          "shared": true,
          "sort": 0,
          "value_type": "individual"
        },
        "type": "graph",
        "xaxis": {
          "buckets": null,
          "mode": "time",
          "name": null,
          "show": true,
          "values": []
        },
        "yaxes": [
          {
            "format": "bytes",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          },
          {
            "format": "short",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          }
        ],
        "yaxis": {
          "align": false,
          "alignLevel": null
        }
      },
      {
        "aliasColors": {},
        "bars": false,
        "dashLength": 10,
        "dashes": false,
        "datasource": "CloudWatch",
        "fieldConfig": {
          "defaults": {
            "custom": {}
          },
          "overrides": []
        },
        "fill": 1,
        "fillGradient": 0,
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 16
        },
        "hiddenSeries": false,
        "id": 6,
        "legend": {
          "avg": false,
          "current": false,
          "max": false,
          "min": false,
          "show": true,
          "total": false,
          "values": false
        },
        "lines": true,
        "linewidth": 1,
        "nullPointMode": "null",
        "options": {
          "alertThreshold": true
        },
        "percentage": false,
        "pluginVersion": "7.4.0",
        "pointradius": 2,
        "points": false,
        "renderer": "flot",
        "seriesOverrides": [],
        "spaceLength": 10,
        "stack": false,
        "steppedLine": false,
        "targets": [
          {
            "alias": "Memory Utilization",
            "dimensions": {},
            "expression": "",
            "id": "",
            "matchExact": true,
            "metricName": "MemoryUtilization",
            "namespace": "AWS/ECS",
            "period": "",
            "refId": "A",
            "region": "default",
            "statistics": [
              "Average"
            ]
          }
        ],
        "thresholds": [],
        "timeFrom": null,
        "timeRegions": [],
        "timeShift": null,
        "title": "ECS Memory Utilization",
        "tooltip": {
          "shared": true,
          "sort": 0,
          "value_type": "individual"
        },
        "type": "graph",
        "xaxis": {
          "buckets": null,
          "mode": "time",
          "name": null,
          "show": true,
          "values": []
        },
        "yaxes": [
          {
            "format": "percent",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          },
          {
            "format": "short",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          }
        ],
        "yaxis": {
          "align": false,
          "alignLevel": null
        }
      },
      {
        "aliasColors": {},
        "bars": false,
        "dashLength": 10,
        "dashes": false,
        "datasource": "CloudWatch",
        "fieldConfig": {
          "defaults": {
            "custom": {}
          },
          "overrides": []
        },
        "fill": 1,
        "fillGradient": 0,
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 16
        },
        "hiddenSeries": false,
        "id": 7,
        "legend": {
          "avg": false,
          "current": false,
          "max": false,
          "min": false,
          "show": true,
          "total": false,
          "values": false
        },
        "lines": true,
        "linewidth": 1,
        "nullPointMode": "null",
        "options": {
          "alertThreshold": true
        },
        "percentage": false,
        "pluginVersion": "7.4.0",
        "pointradius": 2,
        "points": false,
        "renderer": "flot",
        "seriesOverrides": [],
        "spaceLength": 10,
        "stack": false,
        "steppedLine": false,
        "targets": [
          {
            "alias": "CPU Utilization",
            "dimensions": {},
            "expression": "",
            "id": "",
            "matchExact": true,
            "metricName": "CPUUtilization",
            "namespace": "AWS/ECS",
            "period": "",
            "refId": "A",
            "region": "default",
            "statistics": [
              "Average"
            ]
          }
        ],
        "thresholds": [],
        "timeFrom": null,
        "timeRegions": [],
        "timeShift": null,
        "title": "ECS CPU Utilization",
        "tooltip": {
          "shared": true,
          "sort": 0,
          "value_type": "individual"
        },
        "type": "graph",
        "xaxis": {
          "buckets": null,
          "mode": "time",
          "name": null,
          "show": true,
          "values": []
        },
        "yaxes": [
          {
            "format": "percent",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          },
          {
            "format": "short",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          }
        ],
        "yaxis": {
          "align": false,
          "alignLevel": null
        }
      }
    ],
    "refresh": "5m",
    "schemaVersion": 27,
    "style": "dark",
    "tags": [
      "aws",
      "infrastructure",
      "cloudwatch"
    ],
    "templating": {
      "list": []
    },
    "time": {
      "from": "now-6h",
      "to": "now"
    },
    "timepicker": {},
    "timezone": "",
    "title": "AWS Infrastructure Overview",
    "uid": "aws-infrastructure",
    "version": 1
  })
  
  tags = local.common_tags
}

# Dashboard dla logów aplikacji
resource "aws_ssm_parameter" "grafana_dashboard_logs" {
  count = var.enable_grafana && var.enable_opensearch ? 1 : 0
  
  name  = "/${var.name_prefix}/${var.environment}/grafana/dashboards/logs"
  type  = "String"
  value = jsonencode({
    "annotations": {
      "list": [
        {
          "builtIn": 1,
          "datasource": "-- Grafana --",
          "enable": true,
          "hide": true,
          "iconColor": "rgba(0, 211, 255, 1)",
          "name": "Annotations & Alerts",
          "type": "dashboard"
        }
      ]
    },
    "editable": true,
    "gnetId": null,
    "graphTooltip": 0,
    "id": null,
    "links": [],
    "panels": [
      {
        "datasource": "OpenSearch",
        "fieldConfig": {
          "defaults": {
            "custom": {}
          },
          "overrides": []
        },
        "gridPos": {
          "h": 8,
          "w": 24,
          "x": 0,
          "y": 0
        },
        "id": 2,
        "options": {
          "showLabels": false,
          "showTime": true,
          "sortOrder": "Descending",
          "wrapLogMessage": true
        },
        "pluginVersion": "7.4.0",
        "targets": [
          {
            "bucketAggs": [],
            "metrics": [
              {
                "id": "1",
                "type": "logs"
              }
            ],
            "query": "level:error OR level:warn",
            "refId": "A",
            "timeField": "@timestamp"
          }
        ],
        "timeFrom": null,
        "timeShift": null,
        "title": "Error and Warning Logs",
        "type": "logs"
      },
      {
        "datasource": "OpenSearch",
        "fieldConfig": {
          "defaults": {
            "custom": {
              "align": null,
              "filterable": false
            },
            "mappings": [],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "red",
                  "value": 80
                }
              ]
            }
          },
          "overrides": []
        },
        "gridPos": {
          "h": 9,
          "w": 12,
          "x": 0,
          "y": 8
        },
        "id": 4,
        "options": {
          "colorMode": "value",
          "graphMode": "area",
          "justifyMode": "auto",
          "orientation": "auto",
          "reduceOptions": {
            "calcs": [
              "mean"
            ],
            "fields": "",
            "values": false
          },
          "textMode": "auto"
        },
        "pluginVersion": "7.4.0",
        "targets": [
          {
            "bucketAggs": [
              {
                "field": "@timestamp",
                "id": "2",
                "settings": {
                  "interval": "auto",
                  "min_doc_count": 0,
                  "trimEdges": 0
                },
                "type": "date_histogram"
              }
            ],
            "metrics": [
              {
                "field": "select field",
                "id": "1",
                "type": "count"
              }
            ],
            "query": "level:error",
            "refId": "A",
            "timeField": "@timestamp"
          }
        ],
        "timeFrom": null,
        "timeShift": null,
        "title": "Error Count",
        "type": "stat"
      },
      {
        "aliasColors": {},
        "bars": false,
        "dashLength": 10,
        "dashes": false,
        "datasource": "OpenSearch",
        "fieldConfig": {
          "defaults": {
            "custom": {}
          },
          "overrides": []
        },
        "fill": 1,
        "fillGradient": 0,
        "gridPos": {
          "h": 9,
          "w": 12,
          "x": 12,
          "y": 8
        },
        "hiddenSeries": false,
        "id": 5,
        "legend": {
          "avg": false,
          "current": false,
          "max": false,
          "min": false,
          "show": true,
          "total": false,
          "values": false
        },
        "lines": true,
        "linewidth": 1,
        "nullPointMode": "null",
        "options": {
          "alertThreshold": true
        },
        "percentage": false,
        "pluginVersion": "7.4.0",
        "pointradius": 2,
        "points": false,
        "renderer": "flot",
        "seriesOverrides": [],
        "spaceLength": 10,
        "stack": false,
        "steppedLine": false,
        "targets": [
          {
            "bucketAggs": [
              {
                "field": "@timestamp",
                "id": "2",
                "settings": {
                  "interval": "auto",
                  "min_doc_count": 0,
                  "trimEdges": 0
                },
                "type": "date_histogram"
              }
            ],
            "metrics": [
              {
                "field": "select field",
                "id": "1",
                "type": "count"
              }
            ],
            "query": "level:error OR level:warn OR level:info",
            "refId": "A",
            "timeField": "@timestamp"
          }
        ],
        "thresholds": [],
        "timeFrom": null,
        "timeRegions": [],
        "timeShift": null,
        "title": "Log Levels Over Time",
        "tooltip": {
          "shared": true,
          "sort": 0,
          "value_type": "individual"
        },
        "type": "graph",
        "xaxis": {
          "buckets": null,
          "mode": "time",
          "name": null,
          "show": true,
          "values": []
        },
        "yaxes": [
          {
            "format": "short",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          },
          {
            "format": "short",
            "label": null,
            "logBase": 1,
            "max": null,
            "min": null,
            "show": true
          }
        ],
        "yaxis": {
          "align": false,
          "alignLevel": null
        }
      },
      {
        "datasource": "OpenSearch",
        "fieldConfig": {
          "defaults": {
            "custom": {
              "align": null,
              "filterable": false
            },
            "mappings": [],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "red",
                  "value": 80
                }
              ]
            }
          },
          "overrides": []
        },
        "gridPos": {
          "h": 8,
          "w": 24,
          "x": 0,
          "y": 17
        },
        "id": 6,
        "options": {
          "showLabels": false,
          "showTime": true,
          "sortOrder": "Descending",
          "wrapLogMessage": true
        },
        "pluginVersion": "7.4.0",
        "targets": [
          {
            "bucketAggs": [],
            "metrics": [
              {
                "id": "1",
                "type": "logs"
              }
            ],
            "query": "",
            "refId": "A",
            "timeField": "@timestamp"
          }
        ],
        "timeFrom": null,
        "timeShift": null,
        "title": "All Logs",
        "type": "logs"
      }
    ],
    "refresh": "10s",
    "schemaVersion": 27,
    "style": "dark",
    "tags": [
      "logs",
      "opensearch",
      "applications"
    ],
    "templating": {
      "list": []
    },
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "timepicker": {},
    "timezone": "",
    "title": "Application Logs",
    "uid": "app-logs",
    "version": 1
  })
  
  tags = local.common_tags
}

# Pomocnicze elementy
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Tworzenie obiektu userdata dla EC2 z instalacją Fluent Bit
data "template_file" "fluent_bit_userdata" {
  count = var.enable_fluentbit ? 1 : 0
  
  template = <<-EOF
    #!/bin/bash
    # Instalacja Fluent Bit na Amazon Linux 2
    
    # Dodanie repozytorium Fluent Bit
    echo '[fluent-bit]
    name=Fluent Bit
    baseurl=https://packages.fluentbit.io/amazonlinux/2
    gpgcheck=1
    gpgkey=https://packages.fluentbit.io/fluentbit.key
    enabled=1' | sudo tee /etc/yum.repos.d/fluent-bit.repo
    
    # Instalacja Fluent Bit
    sudo yum install -y fluent-bit
    
    # Pobieranie konfiguracji z Parameter Store
    aws ssm get-parameter --name "/${var.name_prefix}/${var.environment}/fluentbit/config" --region ${data.aws_region.current.name} --with-decryption --query "Parameter.Value" --output text > /tmp/fluentbit_config.json
    
    # Konwersja JSON do formatu Fluent Bit
    python3 -c '
    import json
    import sys
    
    with open("/tmp/fluentbit_config.json", "r") as f:
        config = json.load(f)
    
    output = ""
    
    # Sekcja Service
    output += "[SERVICE]\n"
    for key, value in config["service"].items():
        output += f"    {key.upper()} {value}\n"
    output += "\n"
    
    # Sekcje Input
    for input_name, input_config in config["input"].items():
        output += f"[INPUT]\n"
        for key, value in input_config.items():
            output += f"    {key.upper()} {value}\n"
        output += "\n"
    
    # Sekcje Filter
    for filter_name, filter_config in config["filter"].items():
        output += f"[FILTER]\n"
        for key, value in filter_config.items():
            output += f"    {key.upper()} {value}\n"
        output += "\n"
    
    # Sekcje Output
    for output_name, output_config in config["output"].items():
        output += f"[OUTPUT]\n"
        for key, value in output_config.items():
            output += f"    {key.upper()} {value}\n"
        output += "\n"
    
    with open("/etc/fluent-bit/fluent-bit.conf", "w") as f:
        f.write(output)
    ' || echo "Konwersja konfiguracji nie powiodła się"
    
    # Restart Fluent Bit
    sudo systemctl restart fluent-bit
    sudo systemctl enable fluent-bit
    
    # Ustawienie tagów CloudWatch
    echo "Setting up CloudWatch Agent with appropriate tags"
    cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWAGENTCONFIG'
    {
      "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "cwagent"
      },
      "metrics": {
        "append_dimensions": {
          "InstanceId": "${aws:InstanceId}"
        },
        "metrics_collected": {
          "mem": {
            "measurement": [
              "mem_used_percent"
            ]
          },
          "disk": {
            "measurement": [
              "used_percent"
            ],
            "resources": [
              "/"
            ]
          }
        }
      }
    }
    CWAGENTCONFIG
    
    # Restart agenta CloudWatch
    sudo systemctl restart amazon-cloudwatch-agent
    
    echo "Setup complete!"
  EOF
}

# Outputs
output "opensearch_endpoint" {
  description = "Endpoint OpenSearch"
  value       = var.enable_opensearch ? aws_opensearch_domain.main[0].endpoint : null
}

output "opensearch_dashboard_endpoint" {
  description = "Endpoint Dashboardu OpenSearch"
  value       = var.enable_opensearch ? aws_opensearch_domain.main[0].dashboard_endpoint : null
}

output "grafana_endpoint" {
  description = "Endpoint Grafana"
  value       = var.enable_grafana ? aws_grafana_workspace.main[0].endpoint : null
}

output "prometheus_endpoint" {
  description = "Endpoint Prometheus"
  value       = var.enable_prometheus ? aws_prometheus_workspace.main[0].prometheus_endpoint : null
}

output "prometheus_workspace_id" {
  description = "ID przestrzeni roboczej Prometheus"
  value       = var.enable_prometheus ? aws_prometheus_workspace.main[0].id : null
}

output "grafana_workspace_id" {
  description = "ID przestrzeni roboczej Grafana"
  value       = var.enable_grafana ? aws_grafana_workspace.main[0].id : null
}

output "log_group_name" {
  description = "Nazwa grupy logów CloudWatch"
  value       = aws_cloudwatch_log_group.collected_logs.name
}

output "alert_topic_arn" {
  description = "ARN tematu SNS dla alertów"
  value       = var.enable_alerting ? aws_sns_topic.alerts[0].arn : null
}

output "fluentbit_config_parameter" {
  description = "Nazwa parametru SSM z konfiguracją Fluent Bit"
  value       = var.enable_fluentbit && var.enable_opensearch ? aws_ssm_parameter.fluentbit_config[0].name : null
}

output "fluentbit_userdata_script" {
  description = "Skrypt userdata do instalacji Fluent Bit na instancjach EC2"
  value       = var.enable_fluentbit ? data.template_file.fluent_bit_userdata[0].rendered : null
}

output "fluentbit_iam_role_name" {
  description = "Nazwa roli IAM dla instancji EC2 z Fluent Bit"
  value       = var.enable_fluentbit ? aws_iam_role.fluentbit_ec2[0].name : null
}

output "fluentbit_instance_profile_name" {
  description = "Nazwa profilu instancji dla EC2 z Fluent Bit"
  value       = var.enable_fluentbit ? aws_iam_instance_profile.fluentbit_ec2[0].name : null
}