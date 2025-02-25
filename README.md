# Loki Log Processor

An AWS Lambda-based solution for automatically converting Loki TSDB log files to JSON format.

## Overview

This project deploys an automated serverless pipeline that processes Loki Time Series Database (TSDB) files. When TSDB files are uploaded to a source S3 bucket, a Lambda function automatically converts them to JSON format and stores the results in a destination S3 bucket.

The solution handles various Loki TSDB formats, including:
- Compressed chunks (gzip, snappy)
- Index files
- Series files
- Different encodings (protobuf, JSON)

## Architecture

The deployment script sets up the following AWS resources:

- **Source S3 Bucket**: `jsonchunksource` - Where you upload TSDB files
- **Destination S3 Bucket**: `jsonchunkdestination` - Where processed JSON files are stored
- **Lambda Function**: `loki-log-processor` - Processes the files
- **IAM Role & Policy**: `loki-processor-role` - Grants necessary permissions to Lambda

![Architecture Diagram](https://github.com/ChaosKyle/loki2splunklambda/blob/main/loki2json.png)

## Prerequisites

- AWS CLI installed and configured with appropriate permissions
- Python 3 and pip (will be installed by the script if missing)
- Bash shell environment
- Internet connection to download dependencies

## Installation

1. Save the setup script as `deploy-loki-processor.sh`
2. Make the script executable:
   ```bash
   chmod +x deploy-loki-processor.sh
   ```
3. Run the script:
   ```bash
   ./deploy-loki-processor.sh
   ```

The script will:
- Install required system dependencies if needed
- Create Python Lambda function code
- Package Lambda dependencies
- Create/update S3 buckets
- Set up IAM roles and policies
- Create/update the Lambda function
- Configure S3 event notification to trigger Lambda

## Configuration

You can modify the following variables at the top of the script:

```bash
LAMBDA_FUNCTION_NAME="loki-log-processor"  # Name of the Lambda function
SOURCE_BUCKET="jsonchunksource"            # Source bucket name
DESTINATION_BUCKET="jsonchunkdestination"  # Destination bucket name
LAMBDA_ROLE_NAME="loki-processor-role"     # IAM role name
LAMBDA_POLICY_NAME="loki-processor-policy" # IAM policy name
REGION="us-east-1"                         # AWS region
```

## Usage

1. **Upload TSDB Files**: Upload your Loki TSDB files to the `jsonchunksource` S3 bucket
2. **Automatic Processing**: Lambda will automatically convert the files to JSON
3. **Access Results**: Processed JSON files will be available in the `jsonchunkdestination` bucket

The Lambda function will:
- Detect the file format (.tsdb, .gz, .zip)
- Attempt various decompression methods
- Try different parsers (protobuf, index file, series file, JSON)
- Fall back to base64 encoding if the format can't be determined
- Save the resulting JSON to the destination bucket with appropriate naming

## Monitoring

CloudWatch logs for the Lambda function are available under:
```
/aws/lambda/loki-log-processor
```

## Troubleshooting

If you encounter issues:

1. Check the CloudWatch logs for specific error messages
2. Ensure your AWS CLI has appropriate permissions
3. Verify that the S3 buckets exist and are accessible
4. Check that the Lambda function has the correct IAM policy

## Advanced Configuration

### Lambda Function Parameters

The Lambda function is configured with:
- Runtime: Python 3.9
- Timeout: 300 seconds (5 minutes)
- Memory: 256 MB

You can modify these settings using AWS CLI or the AWS Console if needed.

### Dependencies

The Lambda function uses the following Python libraries:
- boto3: AWS SDK for Python
- python-snappy: For Snappy compression/decompression
- protobuf: For handling Protocol Buffers

## License
MIT

Production Best Practices
When deploying this solution in a production environment, consider implementing these additional best practices:
Infrastructure as Code (IaC)

Store the Lambda code and deployment scripts in a Git repository
Use AWS CloudFormation, Terraform, or AWS SAM to define your infrastructure
Implement CI/CD pipelines for automated testing and deployment

Security Enhancements

Enable S3 bucket encryption (SSE-S3 or KMS)
Configure VPC for Lambda with private subnets if needed
Implement least privilege access (refine IAM permissions)
Enable AWS CloudTrail for auditing
Set up S3 bucket policies to restrict access
Use Secrets Manager for any sensitive configuration
Implement versioning on S3 buckets

Scalability & Reliability

Configure Lambda concurrency limits appropriate for your load
Set up S3 event batching for high-volume scenarios
Implement dead-letter queues for failed Lambda executions
Create CloudWatch alarms for error thresholds
Implement cross-region replication for disaster recovery

Cost Optimization

Configure Lambda memory allocation based on actual needs
Implement S3 lifecycle policies for archiving or expiring old data
Monitor CloudWatch metrics to optimize performance vs. cost
Consider S3 Intelligent-Tiering for infrequently accessed files
