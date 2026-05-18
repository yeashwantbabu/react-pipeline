#!/bin/bash
# =============================================================
#  infra/deploy.sh
#
#  ONE-TIME bootstrap. Run this locally once.
#  Reads a SINGLE parameters.json for both stacks.
#  Automatically extracts the right keys per CloudFormation template.
#
#  Usage:
#    chmod +x deploy.sh
#    ./deploy.sh --profile <aws-profile> --region <aws-region> [--env <environment>]
#
#  Examples:
#    ./deploy.sh --profile odaptos-dev --region eu-west-1
#    ./deploy.sh --profile odaptos-dev --region eu-west-1 --env dev
#    ./deploy.sh --profile odaptos-prod --region us-east-1 --env prod
# =============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success(){ echo -e "${GREEN}[OK]${NC}    $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Parse CLI arguments ───────────────────────────────────────
AWS_PROFILE=""
REGION=""
ENV_OVERRIDE=""

usage() {
  echo ""
  echo "Usage: ./deploy.sh --profile <aws-profile> --region <aws-region> [--env <environment>]"
  echo ""
  echo "  --profile   AWS CLI profile name from ~/.aws/credentials  (required)"
  echo "  --region    AWS region to deploy into e.g. eu-west-1      (required)"
  echo "  --env       Override environment: dev | staging | prod     (optional)"
  echo ""
  echo "Examples:"
  echo "  ./deploy.sh --profile odaptos-dev --region eu-west-1"
  echo "  ./deploy.sh --profile odaptos-dev --region eu-west-1 --env dev"
  echo "  ./deploy.sh --profile odaptos-prod --region us-east-1 --env prod"
  echo ""
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) AWS_PROFILE="$2"; shift 2 ;;
    --region)  REGION="$2";      shift 2 ;;
    --env)     ENV_OVERRIDE="$2"; shift 2 ;;
    --help|-h) usage ;;
    *) error "Unknown argument: $1. Run ./deploy.sh --help for usage." ;;
  esac
done

[ -z "$AWS_PROFILE" ] && error "--profile is required.  e.g. --profile odaptos-dev"
[ -z "$REGION" ]      && error "--region is required.   e.g. --region eu-west-1"

# ── Export so EVERY aws CLI call uses them automatically ──────
export AWS_PROFILE="$AWS_PROFILE"
export AWS_DEFAULT_REGION="$REGION"

PARAMS_FILE="parameters.json"
PIPELINE_TEMPLATE="cloudformation/pipeline.yml"
MAIN_TEMPLATE="cloudformation/main.yml"

# ── Pre-flight checks ────────────────────────────────────────
echo ""
echo "========================================================"
echo "   React CI/CD — Bootstrap"
echo "========================================================"
echo ""

[ ! -f "$PARAMS_FILE" ]        && error "$PARAMS_FILE not found. Fill it in first."
[ ! -f "$PIPELINE_TEMPLATE" ]  && error "$PIPELINE_TEMPLATE not found."
[ ! -f "$MAIN_TEMPLATE" ]      && error "$MAIN_TEMPLATE not found."
command -v aws     &>/dev/null || error "AWS CLI not installed. Install from https://aws.amazon.com/cli/"
command -v python3 &>/dev/null || error "python3 not found."

log "Verifying AWS credentials for profile '$AWS_PROFILE' ..."
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Profile '$AWS_PROFILE' not found or credentials are invalid.\nCheck your ~/.aws/credentials file."
ACCOUNT_ID=$(echo "$CALLER" | python3 -c "import json,sys; print(json.load(sys.stdin)['Account'])")
CALLER_ARN=$(echo "$CALLER" | python3 -c "import json,sys; print(json.load(sys.stdin)['Arn'])")
success "Authenticated  : $CALLER_ARN"
success "Account ID     : $ACCOUNT_ID"
echo ""

# ── Helper: read a single value from parameters.json ─────────
get_param() {
  python3 -c "
import json
params = json.load(open('$PARAMS_FILE'))
match = [p['ParameterValue'] for p in params if p['ParameterKey'] == '$1']
print(match[0] if match else '')
"
}

# ── Helper: extract only the keys a given template declares ──
# Parses the Parameters: block from the CloudFormation YAML and
# filters parameters.json to only include keys that template knows about.
extract_params_for_template() {
  local template=$1
  python3 - "$template" "$PARAMS_FILE" << 'PYEOF'
import sys, json

template_file = sys.argv[1]
params_file   = sys.argv[2]

with open(template_file) as f:
    content = f.read()

in_params = False
declared_keys = []
skip_words = {'Type','Default','Description','AllowedValues','AllowedPattern','MinLength','MaxLength'}

for line in content.splitlines():
    if line.strip() == 'Parameters:':
        in_params = True
        continue
    if in_params:
        # Top-level parameter key: exactly 2 spaces indent, ends with ':'
        if line.startswith('  ') and not line.startswith('   ') and line.strip().endswith(':'):
            key = line.strip().rstrip(':')
            if key not in skip_words:
                declared_keys.append(key)
        elif line and not line.startswith(' '):
            break  # exited the Parameters block

all_params = json.load(open(params_file))
filtered = [p for p in all_params if p['ParameterKey'] in declared_keys]
print(json.dumps(filtered, indent=2))
PYEOF
}

# ── Read values from parameters.json ─────────────────────────
PROJECT=$(get_param "Project")
ENVIRONMENT=$(get_param "Environment")

# --env flag overrides the Environment in parameters.json
if [ -n "$ENV_OVERRIDE" ]; then
  warn "--env flag provided. Overriding Environment '$ENVIRONMENT' → '$ENV_OVERRIDE'"
  ENVIRONMENT="$ENV_OVERRIDE"
fi

[ -z "$PROJECT" ]     && error "'Project' not found in $PARAMS_FILE"
[ -z "$ENVIRONMENT" ] && error "'Environment' not found in $PARAMS_FILE"

PIPELINE_STACK="${PROJECT}-infra-pipeline-${ENVIRONMENT}"
INFRA_STACK="${PROJECT}-infra-${ENVIRONMENT}"

echo ""
log "Profile        : $AWS_PROFILE"
log "Region         : $REGION"
log "Account        : $ACCOUNT_ID"
log "Project        : $PROJECT"
log "Environment    : $ENVIRONMENT"
log "Pipeline stack : $PIPELINE_STACK"
log "Infra stack    : $INFRA_STACK"
log "Parameters     : $PARAMS_FILE"
echo ""

# ── Validate both templates ───────────────────────────────────
log "Validating $PIPELINE_TEMPLATE ..."
aws cloudformation validate-template \
  --template-body file://$PIPELINE_TEMPLATE > /dev/null
success "$PIPELINE_TEMPLATE is valid."

log "Validating $MAIN_TEMPLATE ..."
aws cloudformation validate-template \
  --template-body file://$MAIN_TEMPLATE > /dev/null
success "$MAIN_TEMPLATE is valid."
echo ""

# ── Step 1: Deploy pipeline.yml ───────────────────────────────
log "Extracting parameters for $PIPELINE_TEMPLATE ..."
PIPELINE_PARAMS=$(extract_params_for_template "$PIPELINE_TEMPLATE")
PIPELINE_PARAMS_FILE=$(mktemp /tmp/pipeline-params-XXXX.json)
echo "$PIPELINE_PARAMS" > "$PIPELINE_PARAMS_FILE"

log "Parameters for pipeline stack:"
echo "$PIPELINE_PARAMS" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    print(f'  {p[\"ParameterKey\"]:30s} = {p[\"ParameterValue\"]}')
"
echo ""

STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name $PIPELINE_STACK \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
  log "Creating pipeline stack: $PIPELINE_STACK ..."
  aws cloudformation create-stack \
    --stack-name $PIPELINE_STACK \
    --template-body file://$PIPELINE_TEMPLATE \
    --parameters file://$PIPELINE_PARAMS_FILE \
    --capabilities CAPABILITY_NAMED_IAM
  log "Waiting for pipeline stack creation (~2 min)..."
  aws cloudformation wait stack-create-complete --stack-name $PIPELINE_STACK
  success "Pipeline stack created."

elif [ "$STACK_STATUS" = "ROLLBACK_COMPLETE" ]; then
  warn "Stack is in ROLLBACK_COMPLETE. Deleting and recreating..."
  aws cloudformation delete-stack --stack-name $PIPELINE_STACK
  aws cloudformation wait stack-delete-complete --stack-name $PIPELINE_STACK
  aws cloudformation create-stack \
    --stack-name $PIPELINE_STACK \
    --template-body file://$PIPELINE_TEMPLATE \
    --parameters file://$PIPELINE_PARAMS_FILE \
    --capabilities CAPABILITY_NAMED_IAM
  aws cloudformation wait stack-create-complete --stack-name $PIPELINE_STACK
  success "Pipeline stack recreated."

else
  warn "Pipeline stack already exists (status: $STACK_STATUS)."
  read -p "  Update it? (y/n): " CONFIRM
  if [ "$CONFIRM" = "y" ]; then
    UPDATE=$(aws cloudformation update-stack \
      --stack-name $PIPELINE_STACK \
      --template-body file://$PIPELINE_TEMPLATE \
      --parameters file://$PIPELINE_PARAMS_FILE \
      --capabilities CAPABILITY_NAMED_IAM 2>&1 || echo "NO_CHANGE")
    if echo "$UPDATE" | grep -q "No updates are to be performed"; then
      warn "No changes to pipeline stack."
    else
      aws cloudformation wait stack-update-complete --stack-name $PIPELINE_STACK
      success "Pipeline stack updated."
    fi
  fi
fi
rm -f "$PIPELINE_PARAMS_FILE"

# ── Step 2: Trigger infra pipeline → it deploys main.yml ─────
echo ""
PIPELINE_NAME=$(aws cloudformation describe-stacks \
  --stack-name $PIPELINE_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='InfraPipelineName'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [ -n "$PIPELINE_NAME" ] && [ "$PIPELINE_NAME" != "None" ]; then
  log "Triggering infra pipeline: $PIPELINE_NAME ..."
  EXEC_ID=$(aws codepipeline start-pipeline-execution \
    --name $PIPELINE_NAME \
    --query "pipelineExecutionId" --output text)
  success "Pipeline triggered. Execution ID: $EXEC_ID"

  echo ""
  log "Monitoring pipeline — polls every 20s, times out after 15 min..."
  MAX=45; ATTEMPT=0
  while [ $ATTEMPT -lt $MAX ]; do
    STATUS=$(aws codepipeline get-pipeline-execution \
      --pipeline-name $PIPELINE_NAME \
      --pipeline-execution-id $EXEC_ID \
      --query "pipelineExecution.status" --output text 2>/dev/null || echo "InProgress")
    echo "  [$((ATTEMPT+1))/$MAX] Status: $STATUS"
    if [ "$STATUS" = "Succeeded" ]; then
      echo ""; success "Infra pipeline SUCCEEDED — all AWS resources are live!"; break
    elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Stopped" ]; then
      echo ""
      error "Infra pipeline $STATUS. Check the pipeline in AWS Console:
  https://${REGION}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${PIPELINE_NAME}/view"
    fi
    sleep 20; ATTEMPT=$((ATTEMPT+1))
  done
fi

# ── Step 3: Download EC2 private key from SSM ─────────────────
echo ""
KEY_PAIR_NAME="${PROJECT}-${ENVIRONMENT}-keypair"
KEY_PAIR_ID=$(aws ec2 describe-key-pairs \
  --filters "Name=key-name,Values=${KEY_PAIR_NAME}" \
  --query "KeyPairs[0].KeyPairId" --output text 2>/dev/null || echo "")

PEM_FILE="${KEY_PAIR_NAME}.pem"
if [ -n "$KEY_PAIR_ID" ] && [ "$KEY_PAIR_ID" != "None" ] && [ ! -f "$PEM_FILE" ]; then
  log "Downloading private key from SSM Parameter Store..."
  aws ssm get-parameter \
    --name "/ec2/keypair/${KEY_PAIR_ID}" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text > "$PEM_FILE"
  chmod 400 "$PEM_FILE"
  success "Private key saved to: $PEM_FILE"
  warn "Do NOT commit this .pem file — it is already in .gitignore."
elif [ -f "$PEM_FILE" ]; then
  warn "PEM file already exists locally: $PEM_FILE — skipping download."
fi

# ── Final summary ─────────────────────────────────────────────
echo ""
EC2_IP=$(aws cloudformation describe-stacks \
  --stack-name $INFRA_STACK \
  --query "Stacks[0].Outputs[?OutputKey=='EC2PublicIP'].OutputValue" \
  --output text 2>/dev/null || echo "pending")

echo "========================================================"
echo "   Bootstrap Complete!"
echo "========================================================"
echo ""
success "Profile      : $AWS_PROFILE"
success "Region       : $REGION"
success "Environment  : $ENVIRONMENT"
success "Infra stack  : $INFRA_STACK"
success "App URL      : http://${EC2_IP}"
success "SSH          : ssh -i ${PEM_FILE} ec2-user@${EC2_IP}"
echo ""
log "From here — just push code to trigger pipelines:"
log "  Push to infra repo  → re-deploys AWS infrastructure"
log "  Push to react repo  → builds and deploys the React app"
echo ""