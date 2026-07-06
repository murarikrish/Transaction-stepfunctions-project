provider "aws" {
  region = "ap-south-1"
}

variable "bucket_name" {}
variable "image_uri" {}
variable "ec2_instance_id" {
  default = "i-0409e65e467933834"
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/transaction-processor"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "main" {
  name = "transaction-cluster"
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "ecs-task-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_s3_policy" {
  name = "ecs-s3-read-write-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ]
      Resource = [
        "arn:aws:s3:::${var.bucket_name}",
        "arn:aws:s3:::${var.bucket_name}/*"
      ]
    }]
  })
}

resource "aws_ecs_task_definition" "task" {
  family                   = "transaction-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "transaction-container"
      image     = var.image_uri
      essential = true

      environment = [
        { name = "BUCKET", value = var.bucket_name },
        { name = "INPUT_KEY", value = "input/transaction.csv" },
        { name = "OUTPUT_KEY", value = "output/result.json" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_logs.name
          awslogs-region        = "ap-south-1"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "ecs_sg" {
  name        = "ecs-transaction-sg"
  description = "Security group for ECS transaction task"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "stepfunctions_role" {
  name = "stepfunctions-ecs-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "states.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "stepfunctions_policy" {
  name = "stepfunctions-ecs-ec2-policy"
  role = aws_iam_role.stepfunctions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StartInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:DescribeTasks",
          "ecs:StopTask"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_task_execution_role.arn,
          aws_iam_role.ecs_task_role.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:PutRule",
          "events:DescribeRule"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "transaction_workflow" {
  name     = "transaction-processing-workflow"
  role_arn = aws_iam_role.stepfunctions_role.arn

  definition = jsonencode({
    Comment = "Transaction processing workflow with EC2 validation and ECS task"
    StartAt = "CheckEC2Instance"

    States = {
      CheckEC2Instance = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ec2:describeInstances"
        Parameters = {
          InstanceIds = [var.ec2_instance_id]
        }
        Next = "IsEC2Running"
      }

      IsEC2Running = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.Reservations[0].Instances[0].State.Name"
            StringEquals = "running"
            Next         = "RunTransactionTask"
          },
          {
            Variable     = "$.Reservations[0].Instances[0].State.Name"
            StringEquals = "stopped"
            Next         = "StartEC2Instance"
          }
        ]
        Default = "EC2ValidationFailed"
      }

      StartEC2Instance = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ec2:startInstances"
        Parameters = {
          InstanceIds = [var.ec2_instance_id]
        }
        Next = "WaitForEC2"
      }

      WaitForEC2 = {
        Type    = "Wait"
        Seconds = 30
        Next    = "ValidateEC2Running"
      }

      ValidateEC2Running = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ec2:describeInstances"
        Parameters = {
          InstanceIds = [var.ec2_instance_id]
        }
        Next = "IsEC2Ready"
      }

      IsEC2Ready = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.Reservations[0].Instances[0].State.Name"
            StringEquals = "running"
            Next         = "RunTransactionTask"
          }
        ]
        Default = "EC2ValidationFailed"
      }

      RunTransactionTask = {
        Type     = "Task"
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          Cluster        = aws_ecs_cluster.main.arn
          TaskDefinition = aws_ecs_task_definition.task.arn
          LaunchType     = "FARGATE"

          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = data.aws_subnets.default.ids
              SecurityGroups = [aws_security_group.ecs_sg.id]
              AssignPublicIp = "ENABLED"
            }
          }
        }
        End = true
      }

      EC2ValidationFailed = {
        Type  = "Fail"
        Error = "EC2ValidationFailed"
        Cause = "EC2 instance is not running and could not be started"
      }
    }
  })
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.task.arn
}

output "step_function_arn" {
  value = aws_sfn_state_machine.transaction_workflow.arn
}
