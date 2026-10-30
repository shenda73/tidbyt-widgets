#!/usr/bin/env bash
# Build and deploy the Tidbyt widget refresher to AWS Lambda.
# Widgets are the .star files in apps/, listed in apps.json.
# Safe to re-run: it creates what is missing and updates the image otherwise.
#
# First run only:
#   1. Store the Tidbyt API token in SSM:
#        aws ssm put-parameter --name /tidbyt/api-token --type SecureString --value '<token>'
#   2. Put your device ID in .env (not committed):
#        echo 'DEVICE_ID=<your-device-id>' > .env
#   3. Copy apps.example.json to apps.json (not committed) and edit it.
#
# After that, pushes to main deploy new code through GitHub Actions. Re-run this
# script only for infrastructure changes (schedules, IAM, Lambda settings).
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] && source .env

REGION="${REGION:-us-east-1}"
NAME="tidbyt-widgets"
DEVICE_ID="${DEVICE_ID:?set DEVICE_ID in .env or the environment}"
TOKEN_PARAM="/tidbyt/api-token"
OURA_PARAM="/oura/credentials"  # written by scripts/oura_login.py
TZ_NAME="America/New_York"
# Every minute from 5 AM to midnight, every 10 minutes overnight (local time, DST-aware).
DAY_CRON="cron(* 5-23 * * ? *)"
NIGHT_CRON="cron(0/10 0-4 * * ? *)"

[ -f apps.json ] || { echo "apps.json not found: copy apps.example.json to apps.json first" >&2; exit 1; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO_URI="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$NAME"
ROLE_NAME="$NAME-role"
SCHED_ROLE_NAME="$NAME-scheduler-role"
OLD_RULE_NAME="$NAME-every-10min"  # legacy UTC EventBridge rule, removed below

echo "==> ECR repository"
aws ecr describe-repositories --region "$REGION" --repository-names "$NAME" >/dev/null 2>&1 ||
  aws ecr create-repository --region "$REGION" --repository-name "$NAME" >/dev/null
# Keep only the 3 newest images.
aws ecr put-lifecycle-policy --region "$REGION" --repository-name "$NAME" --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":3},"action":{"type":"expire"}}]}' >/dev/null

echo "==> Build and push image"
aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$ACCOUNT.dkr.ecr.$REGION.amazonaws.com" >/dev/null
TAG=$(date +%Y%m%d%H%M%S)
docker build --platform linux/arm64 --provenance=false -f lambda/Dockerfile -t "$REPO_URI:$TAG" . >/dev/null 2>&1
docker push "$REPO_URI:$TAG" >/dev/null

echo "==> IAM role"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  sleep 10  # let the new role propagate before Lambda uses it
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name read-tidbyt-token --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"ssm:GetParameter\",\"Resource\":\"arn:aws:ssm:$REGION:$ACCOUNT:parameter$TOKEN_PARAM\"}]}"
# Oura refresh tokens are single use, so the Lambda writes the new one back.
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name oura-credentials --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ssm:GetParameter\",\"ssm:PutParameter\"],\"Resource\":\"arn:aws:ssm:$REGION:$ACCOUNT:parameter$OURA_PARAM\"}]}"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)

echo "==> Lambda function"
ENV="Variables={DEVICE_ID=$DEVICE_ID,TOKEN_PARAM=$TOKEN_PARAM,OURA_PARAM=$OURA_PARAM}"
if aws lambda get-function --region "$REGION" --function-name "$NAME" >/dev/null 2>&1; then
  aws lambda update-function-code --region "$REGION" --function-name "$NAME" \
    --image-uri "$REPO_URI:$TAG" >/dev/null
  aws lambda wait function-updated --region "$REGION" --function-name "$NAME"
  aws lambda update-function-configuration --region "$REGION" --function-name "$NAME" \
    --memory-size 512 --timeout 120 --environment "$ENV" >/dev/null
  aws lambda wait function-updated --region "$REGION" --function-name "$NAME"
else
  aws lambda create-function --region "$REGION" --function-name "$NAME" \
    --package-type Image --code ImageUri="$REPO_URI:$TAG" --architectures arm64 \
    --role "$ROLE_ARN" --memory-size 512 --timeout 120 --environment "$ENV" >/dev/null
  aws lambda wait function-active --region "$REGION" --function-name "$NAME"
fi
FUNC_ARN=$(aws lambda get-function --region "$REGION" --function-name "$NAME" --query Configuration.FunctionArn --output text)

echo "==> Scheduler role"
if ! aws iam get-role --role-name "$SCHED_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$SCHED_ROLE_NAME" --assume-role-policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"scheduler.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$ACCOUNT\"}}}]}" >/dev/null
  sleep 10  # let the new role propagate before the Scheduler uses it
fi
aws iam put-role-policy --role-name "$SCHED_ROLE_NAME" --policy-name invoke-lambda --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$FUNC_ARN\"}]}"
SCHED_ROLE_ARN=$(aws iam get-role --role-name "$SCHED_ROLE_NAME" --query Role.Arn --output text)

# create-schedule or update-schedule, whichever applies.
# No retries: the next scheduled run does the same job anyway.
schedule() {
  local name=$1 expr=$2 input=$3 verb=create-schedule
  aws scheduler get-schedule --region "$REGION" --name "$name" >/dev/null 2>&1 && verb=update-schedule
  aws scheduler "$verb" --region "$REGION" --name "$name" \
    --schedule-expression "$expr" --schedule-expression-timezone "$TZ_NAME" \
    --flexible-time-window Mode=OFF \
    --target "{\"Arn\":\"$FUNC_ARN\",\"RoleArn\":\"$SCHED_ROLE_ARN\",\"Input\":\"$input\",\"RetryPolicy\":{\"MaximumRetryAttempts\":0,\"MaximumEventAgeInSeconds\":3600}}" >/dev/null
}

echo "==> Schedules ($TZ_NAME)"
schedule "$NAME-day" "$DAY_CRON" '{}'
schedule "$NAME-night" "$NIGHT_CRON" '{\"night\":true}'

# Remove the old UTC-only EventBridge rule if it is still around.
if aws events describe-rule --region "$REGION" --name "$OLD_RULE_NAME" >/dev/null 2>&1; then
  aws events remove-targets --region "$REGION" --rule "$OLD_RULE_NAME" --ids 1 >/dev/null
  aws events delete-rule --region "$REGION" --name "$OLD_RULE_NAME"
  aws lambda remove-permission --region "$REGION" --function-name "$NAME" \
    --statement-id "$OLD_RULE_NAME" >/dev/null 2>&1 || true
fi

echo "Deployed $NAME ($REPO_URI:$TAG): every minute 5 AM-midnight, every 10 minutes overnight ($TZ_NAME)."
