#!/bin/bash

# Exit on error
set -e

# Install required dependencies
echo "Installing required dependencies..."
if ! command -v pip &> /dev/null; then
    sudo apt update
    sudo apt install -y python3-pip
fi

if ! command -v zip &> /dev/null; then
    sudo apt install -y zip
fi

# Configuration variables
LAMBDA_FUNCTION_NAME="loki-log-processor"
SOURCE_BUCKET="jsonchunksource"
DESTINATION_BUCKET="jsonchunkdestination"
LAMBDA_ROLE_NAME="loki-processor-role"
LAMBDA_POLICY_NAME="loki-processor-policy"
REGION="us-east-1"  # Change this to your desired region

# Create temporary directory for Lambda package
echo "Creating temporary directory for Lambda package..."
TEMP_DIR=$(mktemp -d)
cd $TEMP_DIR

# Create Python Lambda function
cat > lambda_function.py << 'EOL'
import json
import boto3
import logging
import gzip
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client('s3')

def decode_loki_tsdb(content):
    """
    Decode various Loki TSDB formats to JSON.
    Handles:
    - Compressed chunks (gzip, snappy)
    - Index files
    - Series files
    - Different encodings (protobuf, json)
    """
    try:
        # Try different decompression methods
        try:
            decompressed = gzip.decompress(content)
        except:
            try:
                import snappy
                decompressed = snappy.decompress(content)
            except:
                decompressed = content

        # Check for protobuf format
        try:
            from google.protobuf.json_format import MessageToDict
            import cortexpb.cortexpb_pb2 as cortexpb
            chunk = cortexpb.Chunk()
            chunk.ParseFromString(decompressed)
            return MessageToDict(chunk)
        except:
            pass

        # Check for index file format
        try:
            if b'index' in decompressed[:20]:
                index_data = {}
                lines = decompressed.split(b'\n')
                for line in lines:
                    if line:
                        parts = line.split(b'\t')
                        if len(parts) >= 2:
                            index_data[parts[0].decode()] = parts[1].decode()
                return index_data
        except:
            pass

        # Check for series file format
        try:
            if b'series' in decompressed[:20]:
                series_data = []
                lines = decompressed.split(b'\n')
                for line in lines:
                    if line:
                        series_data.append(line.decode())
                return {"series": series_data}
        except:
            pass

        # Try JSON format
        try:
            return json.loads(decompressed)
        except:
            pass

        # Try basic string format
        try:
            return {"content": decompressed.decode()}
        except:
            pass

        # If all attempts fail, return binary as base64
        import base64
        return {
            "content": base64.b64encode(content).decode(),
            "encoding": "base64",
            "format": "binary"
        }

    except Exception as e:
        logger.error(f"Error decoding TSDB: {str(e)}")
        raise

def lambda_handler(event, context):
    try:
        # Get the S3 bucket and key from the event
        bucket = event['Records'][0]['s3']['bucket']['name']
        key = event['Records'][0]['s3']['object']['key']
       
        # URL decode the key
        from urllib.parse import unquote_plus
        key = unquote_plus(key)
        logger.info(f"Processing file {key} from bucket {bucket}")
       
        # Get the object from S3
        response = s3_client.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read()
       
        # Decode TSDB to JSON
        json_data = decode_loki_tsdb(content)
       
        # Upload JSON to destination bucket
        destination_key = key.replace('.tsdb', '.json').replace('.gz', '').replace('.zip', '')
        logger.info(f"Uploading to destination bucket with key: {destination_key}")
       
        s3_client.put_object(
            Bucket='jsonchunkdestination',
            Key=destination_key,
            Body=json.dumps(json_data),
            ContentType='application/json'
        )
       
        logger.info(f"Successfully uploaded to {destination_key}")
       
        logger.info(f"Successfully processed {key} to {destination_key}")
        return {
            'statusCode': 200,
            'body': json.dumps(f'Successfully processed {key}')
        }
       
    except Exception as e:
        logger.error(f"Error processing file: {str(e)}")
        raise
EOL

# Create requirements.txt
cat > requirements.txt << 'EOL'
boto3
python-snappy
protobuf
EOL

# Install dependencies
pip install --target . -r requirements.txt

# Create ZIP file for Lambda
zip -r ../lambda_function.zip .
cd ..

# Create S3 buckets if they don't exist
echo "Creating S3 buckets if they don't exist..."
aws s3api create-bucket --bucket "$SOURCE_BUCKET" --region "$REGION" || true
aws s3api create-bucket --bucket "$DESTINATION_BUCKET" --region "$REGION" || true

# Wait for buckets to be created
sleep 5

# Create IAM policy document
cat > policy.json << 'EOL'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::jsonchunksource",
                "arn:aws:s3:::jsonchunksource/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::jsonchunkdestination",
                "arn:aws:s3:::jsonchunkdestination/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:*:*:*"
        }
    ]
}
EOL

# Create trust policy document
cat > trust-policy.json << 'EOL'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOL

# Create or update IAM role and policy
echo "Setting up IAM role and policy..."
if aws iam get-role --role-name "$LAMBDA_ROLE_NAME" 2>/dev/null; then
    echo "Role exists, updating policy..."
else
    aws iam create-role \
        --role-name "$LAMBDA_ROLE_NAME" \
        --assume-role-policy-document file://trust-policy.json
fi

aws iam put-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name "$LAMBDA_POLICY_NAME" \
    --policy-document file://policy.json

# Wait for role to be created (IAM changes can take a few seconds to propagate)
echo "Waiting for IAM role to be ready..."
sleep 10

# Get the role ARN
ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)

# Create or update Lambda function
echo "Setting up Lambda function..."
if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" 2>/dev/null; then
    echo "Function exists, updating..."
    aws lambda update-function-code \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --zip-file fileb://lambda_function.zip \
        --region "$REGION"
else
    aws lambda create-function \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --runtime python3.9 \
        --handler lambda_function.lambda_handler \
        --role "$ROLE_ARN" \
        --zip-file fileb://lambda_function.zip \
        --timeout 300 \
        --memory-size 256 \
        --region "$REGION"
fi

# Add S3 trigger
echo "Adding S3 trigger..."
LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" --query 'Configuration.FunctionArn' --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

aws lambda add-permission \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --statement-id "AllowS3Invoke" \
    --action "lambda:InvokeFunction" \
    --principal s3.amazonaws.com \
    --source-arn "arn:aws:s3:::$SOURCE_BUCKET" \
    --region "$REGION" 2>/dev/null || true

# Create S3 bucket notification with proper ARN
cat > notification.json << EOL
{
    "LambdaFunctionConfigurations": [
        {
            "LambdaFunctionArn": "$LAMBDA_ARN",
            "Events": ["s3:ObjectCreated:*"]
        }
    ]
}
EOL

aws s3api put-bucket-notification-configuration \
    --bucket "$SOURCE_BUCKET" \
    --notification-configuration file://notification.json

# Clean up temporary files
rm -rf "$TEMP_DIR" lambda_function.zip policy.json trust-policy.json notification.json

echo "Setup complete! Lambda function $LAMBDA_FUNCTION_NAME is now watching bucket $SOURCE_BUCKET for .tsdb files"
echo "Logs will be available in CloudWatch under /aws/lambda/$LAMBDA_FUNCTION_NAME"
