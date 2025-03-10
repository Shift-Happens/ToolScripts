# main.tf - Moduł do odtwarzania po awarii w wielu regionach AWS

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 4.0"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

# Zmienne wejściowe
variable "app_name" {
  description = "Nazwa aplikacji, dla której tworzona jest infrastruktura DR"
  type        = string
}

variable "primary_region" {
  description = "Główny region AWS"
  type        = string
}

variable "secondary_region" {
  description = "Zapasowy region AWS"
  type        = string
}

variable "primary_vpc_cidr" {
  description = "Blok CIDR dla VPC w głównym regionie"
  type        = string
  default     = "10.0.0.0/16"
}

variable "secondary_vpc_cidr" {
  description = "Blok CIDR dla VPC w zapasowym regionie"
  type        = string
  default     = "10.1.0.0/16"
}

variable "primary_azs" {
  description = "Lista stref dostępności w głównym regionie"
  type        = list(string)
}

variable "secondary_azs" {
  description = "Lista stref dostępności w zapasowym regionie"
  type        = list(string)
}

variable "primary_subnets" {
  description = "Lista bloków CIDR dla podsieci w głównym regionie"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "secondary_subnets" {
  description = "Lista bloków CIDR dla podsieci w zapasowym regionie"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
}

variable "db_instance_class" {
  description = "Klasa instancji bazy danych"
  type        = string
  default     = "db.t3.medium"
}

variable "db_name" {
  description = "Nazwa bazy danych"
  type        = string
}

variable "db_username" {
  description = "Nazwa użytkownika bazy danych"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Hasło użytkownika bazy danych"
  type        = string
  sensitive   = true
}

variable "enable_route53_failover" {
  description = "Czy włączyć automatyczne przełączanie DNS za pomocą Route 53"
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "Domena DNS dla aplikacji"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tagi do przypisania wszystkim zasobom"
  type        = map(string)
  default     = {}
}

# VPC w głównym regionie
resource "aws_vpc" "primary" {
  provider = aws.primary
  
  cidr_block           = var.primary_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = merge(
    {
      "Name" = "${var.app_name}-primary-vpc"
    },
    var.tags
  )
}

# VPC w zapasowym regionie
resource "aws_vpc" "secondary" {
  provider = aws.secondary
  
  cidr_block           = var.secondary_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = merge(
    {
      "Name" = "${var.app_name}-secondary-vpc"
    },
    var.tags
  )
}

# Podsieci w głównym regionie
resource "aws_subnet" "primary" {
  provider = aws.primary
  count    = length(var.primary_subnets)
  
  vpc_id            = aws_vpc.primary.id
  cidr_block        = var.primary_subnets[count.index]
  availability_zone = var.primary_azs[count.index % length(var.primary_azs)]
  
  tags = merge(
    {
      "Name" = "${var.app_name}-primary-subnet-${count.index + 1}"
    },
    var.tags
  )
}

# Podsieci w zapasowym regionie
resource "aws_subnet" "secondary" {
  provider = aws.secondary
  count    = length(var.secondary_subnets)
  
  vpc_id            = aws_vpc.secondary.id
  cidr_block        = var.secondary_subnets[count.index]
  availability_zone = var.secondary_azs[count.index % length(var.secondary_azs)]
  
  tags = merge(
    {
      "Name" = "${var.app_name}-secondary-subnet-${count.index + 1}"
    },
    var.tags
  )
}

# Grupa bezpieczeństwa dla RDS w głównym regionie
resource "aws_security_group" "primary_db" {
  provider = aws.primary
  
  name        = "${var.app_name}-primary-db-sg"
  description = "Security group for primary database"
  vpc_id      = aws_vpc.primary.id
  
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.primary_subnets
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = merge(
    {
      "Name" = "${var.app_name}-primary-db-sg"
    },
    var.tags
  )
}

# Grupa bezpieczeństwa dla RDS w zapasowym regionie
resource "aws_security_group" "secondary_db" {
  provider = aws.secondary
  
  name        = "${var.app_name}-secondary-db-sg"
  description = "Security group for secondary database"
  vpc_id      = aws_vpc.secondary.id
  
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.secondary_subnets
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = merge(
    {
      "Name" = "${var.app_name}-secondary-db-sg"
    },
    var.tags
  )
}

# Grupa podsieci RDS w głównym regionie
resource "aws_db_subnet_group" "primary" {
  provider = aws.primary
  
  name       = "${var.app_name}-primary-db-subnet-group"
  subnet_ids = aws_subnet.primary[*].id
  
  tags = merge(
    {
      "Name" = "${var.app_name}-primary-db-subnet-group"
    },
    var.tags
  )
}

# Grupa podsieci RDS w zapasowym regionie
resource "aws_db_subnet_group" "secondary" {
  provider = aws.secondary
  
  name       = "${var.app_name}-secondary-db-subnet-group"
  subnet_ids = aws_subnet.secondary[*].id
  
  tags = merge(
    {
      "Name" = "${var.app_name}-secondary-db-subnet-group"
    },
    var.tags
  )
}

# Parametry klucza KMS dla szyfrowania bazy danych
resource "aws_kms_key" "primary_db" {
  provider = aws.primary
  
  description             = "KMS key for primary database encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  
  tags = merge(
    {
      "Name" = "${var.app_name}-primary-db-kms-key"
    },
    var.tags
  )
}

resource "aws_kms_key" "secondary_db" {
  provider = aws.secondary
  
  description             = "KMS key for secondary database encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  
  tags = merge(
    {
      "Name" = "${var.app_name}-secondary-db-kms-key"
    },
    var.tags
  )
}

# Główna instancja RDS MySQL
resource "aws_db_instance" "primary" {
  provider = aws.primary
  
  identifier                = "${var.app_name}-primary-db"
  engine                    = "mysql"
  engine_version            = "8.0"
  instance_class            = var.db_instance_class
  allocated_storage         = 20
  max_allocated_storage     = 100
  db_name                   = var.db_name
  username                  = var.db_username
  password                  = var.db_password
  db_subnet_group_name      = aws_db_subnet_group.primary.name
  vpc_security_group_ids    = [aws_security_group.primary_db.id]
  backup_retention_period   = 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "mon:04:00-mon:05:00"
  multi_az                  = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.app_name}-primary-final-snapshot"
  storage_encrypted         = true
  kms_key_id                = aws_kms_key.primary_db.arn
  
  tags = merge(
    {
      "Name" = "${var.app_name}-primary-db"
    },
    var.tags
  )
}

# Instancja zapasowa RDS MySQL (readreplica)
resource "aws_db_instance" "secondary" {
  provider = aws.secondary
  
  identifier                = "${var.app_name}-secondary-db"
  replicate_source_db       = aws_db_instance.primary.arn
  instance_class            = var.db_instance_class
  vpc_security_group_ids    = [aws_security_group.secondary_db.id]
  db_subnet_group_name      = aws_db_subnet_group.secondary.name
  backup_retention_period   = 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "mon:04:00-mon:05:00"
  multi_az                  = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.app_name}-secondary-final-snapshot"
  storage_encrypted         = true
  kms_key_id                = aws_kms_key.secondary_db.arn
  
  tags = merge(
    {
      "Name" = "${var.app_name}-secondary-db"
    },
    var.tags
  )
}

# Bucket S3 dla logów i kopii zapasowych w głównym regionie
resource "aws_s3_bucket" "primary_backup" {
  provider = aws.primary
  
  bucket = "${var.app_name}-primary-backup-${var.primary_region}"
  
  tags = merge(
    {
      "Name" = "${var.app_name}-primary-backup"
    },
    var.tags
  )
}

# Bucket S3 dla logów i kopii zapasowych w zapasowym regionie
resource "aws_s3_bucket" "secondary_backup" {
  provider = aws.secondary
  
  bucket = "${var.app_name}-secondary-backup-${var.secondary_region}"
  
  tags = merge(
    {
      "Name" = "${var.app_name}-secondary-backup"
    },
    var.tags
  )
}

# Konfiguracja replikacji między bucketami S3
resource "aws_s3_bucket_replication_configuration" "backup_replication" {
  provider = aws.primary
  
  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.primary_backup.id
  
  rule {
    id     = "backup-replication-rule"
    status = "Enabled"
    
    destination {
      bucket        = aws_s3_bucket.secondary_backup.arn
      storage_class = "STANDARD"
    }
  }
}

# Rola IAM dla replikacji S3
resource "aws_iam_role" "replication" {
  provider = aws.primary
  
  name = "${var.app_name}-s3-replication-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
      }
    ]
  })
}

# Polityka IAM dla roli replikacji S3
resource "aws_iam_policy" "replication" {
  provider = aws.primary
  
  name = "${var.app_name}-s3-replication-policy"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.primary_backup.arn
        ]
      },
      {
        Action = [
          "s3:GetObjectVersion",
          "s3:GetObjectVersionAcl"
        ]
        Effect = "Allow"
        Resource = [
          "${aws_s3_bucket.primary_backup.arn}/*"
        ]
      },
      {
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete"
        ]
        Effect = "Allow"
        Resource = [
          "${aws_s3_bucket.secondary_backup.arn}/*"
        ]
      }
    ]
  })
}

# Połączenie polityki replikacji z rolą
resource "aws_iam_role_policy_attachment" "replication" {
  provider = aws.primary
  
  role       = aws_iam_role.replication.name
  policy_arn = aws_iam_policy.replication.arn
}

# Zasoby Route 53 dla automatycznego przełączania failover (opcjonalnie)
resource "aws_route53_health_check" "primary" {
  count = var.enable_route53_failover && var.domain_name != "" ? 1 : 0
  
  fqdn              = "primary.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  
  tags = merge(
    {
      "Name" = "${var.app_name}-primary-health-check"
    },
    var.tags
  )
}

resource "aws_route53_health_check" "secondary" {
  count = var.enable_route53_failover && var.domain_name != "" ? 1 : 0
  
  fqdn              = "secondary.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  
  tags = merge(
    {
      "Name" = "${var.app_name}-secondary-health-check"
    },
    var.tags
  )
}

# Strefa hostowana Route 53 (zakładając, że już istnieje)
data "aws_route53_zone" "main" {
  count = var.enable_route53_failover && var.domain_name != "" ? 1 : 0
  
  name         = var.domain_name
  private_zone = false
}

# Rekordy DNS dla failover
resource "aws_route53_record" "primary" {
  count = var.enable_route53_failover && var.domain_name != "" ? 1 : 0
  
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"
  
  failover_routing_policy {
    type = "PRIMARY"
  }
  
  set_identifier  = "${var.app_name}-primary"
  health_check_id = aws_route53_health_check.primary[0].id
  alias {
    name                   = "primary.${var.domain_name}"
    zone_id                = data.aws_route53_zone.main[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "secondary" {
  count = var.enable_route53_failover && var.domain_name != "" ? 1 : 0
  
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"
  
  failover_routing_policy {
    type = "SECONDARY"
  }
  
  set_identifier  = "${var.app_name}-secondary"
  health_check_id = aws_route53_health_check.secondary[0].id
  alias {
    name                   = "secondary.${var.domain_name}"
    zone_id                = data.aws_route53_zone.main[0].zone_id
    evaluate_target_health = true
  }
}

# Outputs
output "primary_vpc_id" {
  description = "ID VPC w głównym regionie"
  value       = aws_vpc.primary.id
}

output "secondary_vpc_id" {
  description = "ID VPC w zapasowym regionie"
  value       = aws_vpc.secondary.id
}

output "primary_db_endpoint" {
  description = "Endpoint bazy danych w głównym regionie"
  value       = aws_db_instance.primary.endpoint
}

output "secondary_db_endpoint" {
  description = "Endpoint bazy danych w zapasowym regionie"
  value       = aws_db_instance.secondary.endpoint
}

output "primary_backup_bucket" {
  description = "Nazwa bucketa S3 w głównym regionie"
  value       = aws_s3_bucket.primary_backup.bucket
}

output "secondary_backup_bucket" {
  description = "Nazwa bucketa S3 w zapasowym regionie"
  value       = aws_s3_bucket.secondary_backup.bucket
}
