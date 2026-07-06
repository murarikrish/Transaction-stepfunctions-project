import csv
import json
import os
from io import StringIO
import boto3
 
s3 = boto3.client("s3")
 
bucket = os.environ["BUCKET"]
input_key = os.environ["INPUT_KEY"]
output_key = os.environ["OUTPUT_KEY"]
 
obj = s3.get_object(Bucket=bucket, Key=input_key)
content = obj["Body"].read().decode("utf-8")
 
reader = csv.DictReader(StringIO(content))
 
total_transactions = 0
total_amount = 0
debit_count = 0
credit_count = 0
 
for row in reader:
    total_transactions += 1
    total_amount += float(row["amount"])
 
    if row["type"].lower() == "debit":
        debit_count += 1
    elif row["type"].lower() == "credit":
        credit_count += 1
 
result = {
    "status": "SUCCESS",
    "total_transactions": total_transactions,
    "total_amount": total_amount,
    "debit_count": debit_count,
    "credit_count": credit_count,
    "output_file": f"s3://{bucket}/{output_key}"
}
 
s3.put_object(
    Bucket=bucket,
    Key=output_key,
    Body=json.dumps(result, indent=2),
    ContentType="application/json"
)
 
print(json.dumps(result, indent=2))
