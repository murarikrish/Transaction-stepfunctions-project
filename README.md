# Transaction Processing with AWS Step Functions, EC2 and ECS
 
This project processes a transaction CSV file using AWS Step Functions and ECS.
 
## Workflow
 
1. Check EC2 instance status
2. If EC2 is stopped, start EC2
3. Wait for EC2 to become ready
4. Validate EC2 running state
5. Run ECS Fargate task
6. ECS reads transaction.csv from S3
7. ECS writes result.json to S3
 
## Input File
 
S3 input:
 
s3://<bucket-name>/input/transaction.csv
 
## Step Function Input
 
{
  "bucket": "<bucket-name>",
  "input_key": "input/transaction.csv",
  "output_key": "output/result.json"
}
 
## Output
 
S3 output:
 
s3://<bucket-name>/output/result.json
 
Example output:
 
{
  "status": "SUCCESS",
  "total_transactions": 3,
  "total_amount": 6000.0,
  "debit_count": 2,
  "credit_count": 1
}
 
## AWS Services Used
 
- EC2
- S3
- ECR
- ECS Fargate
- Step Functions
- IAM
- CloudWatch Logs
- Terraform
