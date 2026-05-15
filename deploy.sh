#!/bin/bash
# =============================================================
#  infra/deploy.sh
#
#  ONE-TIME bootstrap script.
#  Run this ONCE from your local machine to create the Infra Pipeline.
#  After that, every git push to the infra repo triggers the pipeline
#  which in turn deploys main.yml (VPC + EC2 + React pipeline).
#
#  Usage:
#    chmod +x deploy.sh
#    ./deploy.sh
# =============================================================
set -e

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success(){ echo -e "${GREEN}[OK]${NC}    $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Config ───────────────────────────────────────────────────
PIPELINE_TEMPLATE="cloudformation/pipeline.yml"
PIPELINE_PARAMS="parameters.pipeline.json"
INFRA_PARAMS="parameters.json"

# ── Pre-flight checks ────────────────────────────────────────
echo ""
echo "========================================================"
echo "   React CI/CD — Infra Pipeline Bootstrap"
echo "========================================================"
echo ""

[ ! -f "$PIPELINE_TEMPLATE" ] && error "$PIPELINE_TEMPLATE not found."
[ ! -f "$PIPELINE_PARAMS" ]   && error "$PIPELINE_PARAMS not found."
[ ! -f "$INFRA_PARAMS" ]      && error "$INFRA_PARAMS not found."
command -v aws &>/dev/null    || error "AWS CLI not installed."
command -v python3 &>/dev/null || error "python3 not installed (needed to parse JSON)."

aws sts get-caller-identity &>/dev/null \
  || error "AWS credentials not configured. Run: aws configure"

# ── Helper: read a value from a parameters JSON file ─────────
get_param() {
  local file=$1 key=$2
  python3 -c "
import json, sys
params = json.load(open('$file'))
match = [p['ParameterValue'] for p in params if p['ParameterKey'] == '$key']
print(match[0] if match else '')
"
}

# ── Read values (no hardcoding) ───────────────────────────────
PROJECT=$(get_param "$PIPELINE_PARAMS" "Project")
ENVIRONMENT=$(get_param "$PIPELINE_PARAMS" "Environment")
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
PIPELINE_STACK_NAME="${PROJECT}-infra-pipeline-${ENVIRONMENT}"
INFRA_STACK_NAME="${PROJECT}-infra-${ENVIRONMENT}"

log "Project          : $PROJECT"
log "Environment      : $ENVIRONMENT"
log "Region           : $REGION"
log "Pipeline stack   : $PIPELINE_STACK_NAME"
log "Infra stack      : $INFRA_STACK_NAME"
echo ""

# ── Validate templates ────────────────────────────────────────
log "Validating pipeline.yml..."
aws cloudformation validate-template \
  --template-body file://$PIPELINE_TEMPLATE \
  --region $REGION > /dev/null
success "pipeline.yml is valid."

log "Validating main.yml..."
aws cloudformation validate-template \
  --template-body file://cloudformation/main.yml \
  --region $REGION > /dev/null
success "main.yml is valid."
echo ""

# ── Deploy the Infra Pipeline stack ──────────────────────────
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name $PIPELINE_STACK_NAME \
  --region $REGION \
  --query "Stacks[0].StackStatus" \
  --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" = "DOES_NOT_EXIST" ]; then
  log "Creating Infra Pipeline stack: $PIPELINE_STACK_NAME ..."
  aws cloudformation create-stack \
    --stack-name $PIPELINE_STACK_NAME \
    --template-body file://$PIPELINE_TEMPLATE \
    --parameters file://$PIPELINE_PARAMS \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $REGION

  log "Waiting for pipeline stack creation (~2 min)..."
  aws cloudformation wait stack-create-complete \
    --stack-name $PIPELINE_STACK_NAME \
    --region $REGION
  success "Infra Pipeline stack created."

else
  warn "Pipeline stack already exists (status: $STACK_STATUS)."
  read -p "Update it? (y/n): " CONFIRM
  if [ "$CONFIRM" = "y" ]; then
    UPDATE=$(aws cloudformation update-stack \
      --stack-name $PIPELINE_STACK_NAME \
      --template-body file://$PIPELINE_TEMPLATE \
      --parameters file://$PIPELINE_PARAMS \
      --capabilities CAPABILITY_NAMED_IAM \
      --region $REGION 2>&1 || echo "NO_CHANGE")

    if echo "$UPDATE" | grep -q "No updates are to be performed"; then
      warn "No changes to pipeline stack."
    else
      aws cloudformation wait stack-update-complete \
        --stack-name $PIPELINE_STACK_NAME \
        --region $REGION
      success "Infra Pipeline stack updated."
    fi
  fi
fi

# ── Trigger the infra pipeline manually (first run) ──────────
echo ""
PIPELINE_NAME=$(aws cloudformation describe-stacks \
  --stack-name $PIPELINE_STACK_NAME \
  --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='InfraPipelineName'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [ -n "$PIPELINE_NAME" ] && [ "$PIPELINE_NAME" != "None" ]; then
  log "Triggering first run of infra pipeline: $PIPELINE_NAME ..."
  EXEC_ID=$(aws codepipeline start-pipeline-execution \
    --name $PIPELINE_NAME \
    --region $REGION \
    --query "pipelineExecutionId" \
    --output text)
  success "Pipeline triggered. Execution ID: $EXEC_ID"

  echo ""
  log "Monitoring infra pipeline (polls every 20s, max 15 min)..."
  MAX=45; ATTEMPT=0
  while [ $ATTEMPT -lt $MAX ]; do
    STATUS=$(aws codepipeline get-pipeline-execution \
      --pipeline-name $PIPELINE_NAME \
      --pipeline-execution-id $EXEC_ID \
      --region $REGION \
      --query "pipelineExecution.status" \
      --output text 2>/dev/null || echo "InProgress")

    echo "  Attempt $((ATTEMPT+1))/$MAX — Status: $STATUS"

    if [ "$STATUS" = "Succeeded" ]; then
      echo ""
      success "Infra pipeline SUCCEEDED!"
      break
    elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Stopped" ]; then
      echo ""
      error "Infra pipeline $STATUS. Check AWS Console for details."
    fi
    sleep 20
    ATTEMPT=$((ATTEMPT+1))
  done
fi

# ── Download EC2 private key ──────────────────────────────────
echo ""
KEY_PAIR_NAME="${PROJECT}-${ENVIRONMENT}-keypair"
KEY_PAIR_ID=$(aws ec2 describe-key-pairs \
  --filters "Name=key-name,Values=${KEY_PAIR_NAME}" \
  --region $REGION \
  --query "KeyPairs[0].KeyPairId" \
  --output text 2>/dev/null || echo "")

PEM_FILE="${KEY_PAIR_NAME}.pem"
if [ -n "$KEY_PAIR_ID" ] && [ "$KEY_PAIR_ID" != "None" ] && [ ! -f "$PEM_FILE" ]; then
  log "Downloading private key from SSM..."
  aws ssm get-parameter \
    --name "/ec2/keypair/${KEY_PAIR_ID}" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region $REGION > "$PEM_FILE"
  chmod 400 "$PEM_FILE"
  success "Private key saved to: $PEM_FILE"
  warn "Do NOT commit this file to Git (it is in .gitignore)."
fi

# ── Print final outputs ───────────────────────────────────────
echo ""
EC2_IP=$(aws cloudformation describe-stacks \
  --stack-name $INFRA_STACK_NAME \
  --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='EC2PublicIP'].OutputValue" \
  --output text 2>/dev/null || echo "pending")

echo "========================================================"
echo "   Bootstrap Complete!"
echo "========================================================"
echo ""
success "Infra stack     : $INFRA_STACK_NAME"
success "App URL         : http://${EC2_IP}"
success "SSH             : ssh -i ${PEM_FILE} ec2-user@${EC2_IP}"
echo ""
log "From here on — just push to your repos:"
log "  infra repo push  → triggers Infra Pipeline → re-deploys AWS resources"
log "  react repo push  → triggers React Pipeline → builds & deploys app"
echo ""
