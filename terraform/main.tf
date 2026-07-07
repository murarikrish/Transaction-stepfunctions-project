provider "aws" {
  region = "ap-south-1"
}

variable "bucket_name" {}
variable "image_uri" {}

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "app_sg" {
  name        = "transaction-project-sg"
  description = "Security group for EC2 and ECS"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "transaction-project-sg"
  }
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/transaction-processor"
  retention_in_days = 7
}

resource "aws_iam_role" "ec2_ssm_role" {
  name = "github-created-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_attach" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "github-created-ec2-instance-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

resource "aws_instance" "preprocess" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnets.default.ids[0]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  tags = {
    Name = "github-created-preprocessing-ec2"
  }
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
    Comment = "Transaction processing workflow with GitHub-created EC2 and ECS task"
    StartAt = "CheckEC2Instance"

    States = {
      CheckEC2Instance = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ec2:describeInstances"
        ResultPath = "$.EC2Check"
        Parameters = {
          InstanceIds = [aws_instance.preprocess.id]
        }
        Next = "IsEC2Running"
      }

      IsEC2Running = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.EC2Check.Reservations[0].Instances[0].State.Name"
            StringEquals = "running"
            Next         = "RunTransactionTask"
          },
          {
            Variable     = "$.EC2Check.Reservations[0].Instances[0].State.Name"
            StringEquals = "stopped"
            Next         = "StartEC2Instance"
          }
        ]
        Default = "EC2ValidationFailed"
      }

      StartEC2Instance = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ec2:startInstances"
        ResultPath = "$.EC2Start"
        Parameters = {
          InstanceIds = [aws_instance.preprocess.id]
        }
        Next = "WaitForEC2"
      }

      WaitForEC2 = {
        Type    = "Wait"
        Seconds = 30
        Next    = "ValidateEC2Running"
      }

      ValidateEC2Running = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ec2:describeInstances"
        ResultPath = "$.EC2Validation"
        Parameters = {
          InstanceIds = [aws_instance.preprocess.id]
        }
        Next = "IsEC2Ready"
      }

      IsEC2Ready = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.EC2Validation.Reservations[0].Instances[0].State.Name"
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
              SecurityGroups = [aws_security_group.app_sg.id]
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

output "created_ec2_instance_id" {
  value = aws_instance.preprocess.id
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
