###############################################################################
# AWS - IAM Role + 2 Policies / SNS y SQS
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------ Variables (sin defaults → se piden en terminal) ------------------

variable "aws_region" {
  description = "Región de AWS (ej: us-east-1, eu-west-1)"
  type        = string
}

variable "project_name" {
  description = "Nombre del proyecto (se usa como prefijo en los recursos)"
  type        = string
}

variable "environment" {
  description = "Entorno de despliegue (ej: dev, staging, prod)"
  type        = string
}

# ------------------ SNS Topic ------------------

resource "aws_sns_topic" "main" {
  name = "${var.project_name}-${var.environment}-topic"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ------------------ SQS Queue ------------------

resource "aws_sqs_queue" "main" {
  name                       = "${var.project_name}-${var.environment}-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 10

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project_name}-${var.environment}-dlq"
  message_retention_seconds = 604800

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_sqs_queue_redrive_policy" "main" {
  queue_url = aws_sqs_queue.main.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sns_topic_subscription" "sqs_subscription" {
  topic_arn = aws_sns_topic.main.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.main.arn
}

resource "aws_sqs_queue_policy" "sns_to_sqs" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.main.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.main.arn
          }
        }
      }
    ]
  })
}

# ------------------ IAM Role ------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "main" {
  name               = "${var.project_name}-${var.environment}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ---------- Policy 1: SNS Publish ----------

data "aws_iam_policy_document" "sns_policy" {
  statement {
    effect = "Allow"
    actions = [
      "sns:Publish",
      "sns:GetTopicAttributes",
      "sns:ListSubscriptionsByTopic"
    ]
    resources = [aws_sns_topic.main.arn]
  }
}

resource "aws_iam_policy" "sns_policy" {
  name        = "${var.project_name}-${var.environment}-sns-policy"
  description = "Permite publicar y consultar el topic SNS"
  policy      = data.aws_iam_policy_document.sns_policy.json
}

resource "aws_iam_role_policy_attachment" "sns_attach" {
  role       = aws_iam_role.main.name
  policy_arn = aws_iam_policy.sns_policy.arn
}

# ---------- Policy 2: SQS Consume ----------

data "aws_iam_policy_document" "sqs_policy" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl"
    ]
    resources = [
      aws_sqs_queue.main.arn,
      aws_sqs_queue.dlq.arn
    ]
  }
}

resource "aws_iam_policy" "sqs_policy" {
  name        = "${var.project_name}-${var.environment}-sqs-policy"
  description = "Permite consumir mensajes de la cola SQS"
  policy      = data.aws_iam_policy_document.sqs_policy.json
}

resource "aws_iam_role_policy_attachment" "sqs_attach" {
  role       = aws_iam_role.main.name
  policy_arn = aws_iam_policy.sqs_policy.arn
}

# ------------------ Outputs ------------------

output "iam_role_arn" {
  description = "ARN del IAM Role"
  value       = aws_iam_role.main.arn
}

output "sns_topic_arn" {
  description = "ARN del topic SNS"
  value       = aws_sns_topic.main.arn
}

output "sqs_queue_url" {
  description = "URL de la cola SQS"
  value       = aws_sqs_queue.main.url
}

output "sqs_dlq_url" {
  description = "URL de la dead-letter queue"
  value       = aws_sqs_queue.dlq.url
}
