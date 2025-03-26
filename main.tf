# Provider Configuration
provider "aws" {
  region = "us-east-1"
}

# Get current AWS region and account ID
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Presentation Tier
resource "aws_amplify_app" "frontend" {
  name = "chatbot-frontend"
  enable_auto_branch_creation = true
 
  build_spec = <<-EOT
    version: 1
    frontend:
      phases:
        preBuild:
          commands:
            - npm ci
        build:
          commands:
            - npm run build
      artifacts:
        baseDirectory: build
        files:
          - '**/*'
      cache:
        paths:
          - node_modules/**/*
  EOT
}

resource "aws_api_gateway_rest_api" "chatbot_api" {
  name        = "chatbot-api"
  description = "API for AI-Powered Customer Support Chatbot"
}

# Logic Tier
resource "aws_lambda_function" "chatbot_lambda" {
  function_name = "chatbot-lambda"
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  role          = aws_iam_role.lambda_exec_role.arn

  # Handle missing ZIP file gracefully
  filename         = fileexists("lambda_function_payload.zip") ? "lambda_function_payload.zip" : null
  source_code_hash = fileexists("lambda_function_payload.zip") ? filebase64sha256("lambda_function_payload.zip") : null

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
        Effect   = "Allow",
        Resource = "*"
      },
      {
        Action = ["lex:PostText", "lex:PostContent"],
        Effect   = "Allow",
        Resource = "*"
      },
      {
        Action = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"],
        Effect   = "Allow",
        Resource = aws_dynamodb_table.chatbot_logs.arn
      }
    ]
  })
}

# Lex Permissions - Must be created BEFORE Lex resources
resource "aws_lambda_permission" "lex_execution_permission" {
  statement_id  = "AllowExecutionFromLex"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chatbot_lambda.function_name
  principal     = "lex.amazonaws.com"
  source_arn    = "arn:aws:lex:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
}

# Lex Bot Configuration
resource "aws_lex_intent" "query_intent" {
  depends_on = [aws_lambda_permission.lex_execution_permission]

  name = "QueryIntent"
  description = "Intent for handling customer support queries"
 
  sample_utterances = [
    "I need help with my order",
    "Where is my package",
    "I have a billing issue"
  ]

  fulfillment_activity {
    type = "CodeHook"
    code_hook {
      message_version = "1.0"
      uri             = aws_lambda_function.chatbot_lambda.arn
    }
  }

  conclusion_statement {
    message {
      content      = "I'll help you resolve your issue. Is there anything else I can assist with?"
      content_type = "PlainText"
    }
    response_card = "Thanks for using our support chatbot!"
  }
}

resource "aws_lex_bot" "chatbot" {
  depends_on = [aws_lex_intent.query_intent]

  name        = "CustomerSupportChatbot"
  description = "AI-Powered Chatbot for Customer Support"
  child_directed = false

  intent {
    intent_name    = aws_lex_intent.query_intent.name
    intent_version = "$LATEST"
  }

  abort_statement {
    message {
      content_type = "PlainText"
      content      = "Sorry, I couldn't understand your request. Please try again."
    }
  }

  clarification_prompt {
    max_attempts = 2
    message {
      content_type = "PlainText"
      content      = "I didn't understand you. Can you please rephrase?"
    }
  }

  idle_session_ttl_in_seconds = 300
  voice_id = "Salli"
  process_behavior = "BUILD"
}

# Data Tier
resource "aws_dynamodb_table" "chatbot_logs" {
  name         = "ChatbotLogs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "InteractionId"

  attribute {
    name = "InteractionId"
    type = "S"
  }
}

# API Gateway Configuration
resource "aws_api_gateway_resource" "chatbot_resource" {
  rest_api_id = aws_api_gateway_rest_api.chatbot_api.id
  parent_id   = aws_api_gateway_rest_api.chatbot_api.root_resource_id
  path_part   = "chatbot"
}

resource "aws_api_gateway_method" "chatbot_method" {
  rest_api_id   = aws_api_gateway_rest_api.chatbot_api.id
  resource_id   = aws_api_gateway_resource.chatbot_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.chatbot_api.id
  resource_id             = aws_api_gateway_resource.chatbot_resource.id
  http_method             = aws_api_gateway_method.chatbot_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.chatbot_lambda.invoke_arn
}

resource "aws_lambda_permission" "api_gateway_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chatbot_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.chatbot_api.execution_arn}/*/${aws_api_gateway_method.chatbot_method.http_method}${aws_api_gateway_resource.chatbot_resource.path}"
}

resource "aws_api_gateway_deployment" "chatbot_deployment" {
  depends_on = [aws_api_gateway_integration.lambda_integration]
  rest_api_id = aws_api_gateway_rest_api.chatbot_api.id
}

resource "aws_api_gateway_stage" "chatbot_stage" {
  stage_name    = "prod"
  rest_api_id   = aws_api_gateway_rest_api.chatbot_api.id
  deployment_id = aws_api_gateway_deployment.chatbot_deployment.id
}