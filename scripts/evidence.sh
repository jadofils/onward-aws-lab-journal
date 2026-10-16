#!/usr/bin/env bash
# =============================================================================
# evidence.sh - Verification & evidence collector
# Project : Onward Logistics - Secure Onboarding at Scale
#
# Proves, with live AWS data, that each lab objective is met:
#   1. Provisioned by CloudFormation / GitSync, no inline policies
#   2. Each engineer has the access their role needs and nothing more
#   3. Secure first login (Secrets Manager + forced password change)
#   4. On-call engineer can NEVER create/terminate compute (permissions boundary)
#   5. Every access change is traceable (CloudTrail + tags)
#
# Usage:
#   ./scripts/evidence.sh [-s stack-name] [-r region] [-o output-dir] [-t] [-h]
#
#   -s  CloudFormation stack name        (default: onward-onboarding)
#   -r  AWS region of the stack          (default: AWS_REGION / CLI default)
#   -o  Output directory for the report  (default: ./evidence-<timestamp>)
#   -t  Run the TAMPER TEST: temporarily attaches AdministratorAccess to the
#       on-call group and user, proves they still cannot create/terminate
#       compute, then removes it. Modifies IAM, so it is opt-in.
#   -h  Show help
#
# Required caller permissions: cloudformation:Describe*/List*/GetTemplate,
# iam:Get*/List*/SimulatePrincipalPolicy, secretsmanager:DescribeSecret,
# cloudtrail:LookupEvents/DescribeTrails/GetTrailStatus, sts:GetCallerIdentity
# (and iam:Attach/DetachGroupPolicy, iam:Attach/DetachUserPolicy for -t).
# =============================================================================
set -uo pipefail

# ----------------------------- configuration ---------------------------------
STACK_NAME="onward-onboarding"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR=""
TAMPER_TEST=false

S3_USER="s3-user"
EC2_USER_1="ec2-user-1"
EC2_USER_2="ec2-user-2"
OBSERVER_GROUP="onward-oncall-observers"
ADMIN_POLICY_ARN="arn:aws:iam::aws:policy/AdministratorAccess"
TRAIL_NAME="onward-iam-audit-trail"

# ------------------------------- arguments -----------------------------------
usage() { sed -n '2,/^# =====.*$/p' "$0" | sed -n '2,28p' | sed 's/^# \{0,1\}//'; exit 0; }

while getopts "s:r:o:th" opt; do
  case "$opt" in
    s) STACK_NAME="$OPTARG" ;;
    r) REGION="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    t) TAMPER_TEST=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

OUT_DIR="${OUT_DIR:-./evidence-${TIMESTAMP}}"
mkdir -p "$OUT_DIR"
LOG="${OUT_DIR}/evidence-report.txt"

# Tee to console (with colour) and to the report file (colour stripped).
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG")) 2>&1

REGION_ARGS=()
[[ -n "$REGION" ]] && REGION_ARGS=(--region "$REGION")

# -------------------------------- helpers ------------------------------------
if [[ -t 1 ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=""; RED=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

PASS=0; FAIL=0; WARN=0
SECTION_NO=0

section() { SECTION_NO=$((SECTION_NO + 1)); printf '\n%s== %d. %s ==%s\n' "$BOLD$BLUE" "$SECTION_NO" "$1" "$RESET"; }
pass()    { PASS=$((PASS + 1)); printf '  %s[PASS]%s %s\n' "$GREEN" "$RESET" "$1"; }
fail()    { FAIL=$((FAIL + 1)); printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$1"; }
warn()    { WARN=$((WARN + 1)); printf '  %s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1"; }
info()    { printf '  %s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }

aws_cmd() { aws "$@" "${REGION_ARGS[@]}" 2>/dev/null; }
aws_iam() { aws iam "$@" 2>/dev/null; }   # IAM is global

# simulate <user> <action> -> prints evaluation decision
simulate() {
  aws_iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/$1" \
    --action-names "$2" \
    --resource-arns "*" \
    --query 'EvaluationResults[0].EvalDecision' --output text
}

# expect <user> <allowed|denied> <action...>
expect() {
  local user="$1" want="$2"; shift 2
  local action decision
  for action in "$@"; do
    decision="$(simulate "$user" "$action")"
    decision="${decision:-error}"
    if [[ "$want" == "allowed" && "$decision" == "allowed" ]]; then
      pass "$user CAN   $action  (decision: $decision)"
    elif [[ "$want" == "denied" && "$decision" != "allowed" && "$decision" != "error" ]]; then
      pass "$user CANNOT $action  (decision: $decision)"
    else
      fail "$user expected $want for $action but got: $decision"
    fi
  done
}

cleanup_tamper() {
  if [[ "${TAMPER_ACTIVE:-false}" == "true" ]]; then
    printf '\n%s[CLEANUP]%s Removing temporary AdministratorAccess attachments...\n' "$YELLOW" "$RESET"
    aws iam detach-group-policy --group-name "$OBSERVER_GROUP" --policy-arn "$ADMIN_POLICY_ARN" >/dev/null 2>&1
    aws iam detach-user-policy  --user-name "$EC2_USER_2"      --policy-arn "$ADMIN_POLICY_ARN" >/dev/null 2>&1
    TAMPER_ACTIVE=false
    printf '  Done.\n'
  fi
}
trap cleanup_tamper EXIT INT TERM

# ------------------------------- pre-flight ----------------------------------
command -v aws >/dev/null 2>&1 || { echo "aws CLI is required but not installed."; exit 2; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
[[ -z "$ACCOUNT_ID" ]] && { echo "Unable to call AWS. Check your credentials."; exit 2; }

printf '%s================================================================%s\n' "$BOLD" "$RESET"
printf '%s  ONWARD LOGISTICS - ACCESS CONTROL EVIDENCE REPORT%s\n' "$BOLD" "$RESET"
printf '%s================================================================%s\n' "$BOLD" "$RESET"
printf '  Generated (UTC) : %s\n' "$TIMESTAMP"
printf '  Account         : %s\n' "$ACCOUNT_ID"
printf '  Run by          : %s\n' "$CALLER_ARN"
printf '  Stack           : %s\n' "$STACK_NAME"
printf '  Region          : %s\n' "${REGION:-<CLI default>}"
printf '  Tamper test     : %s\n' "$TAMPER_TEST"
printf '  Report          : %s\n' "$LOG"

# =============================================================================
section "Provisioning: CloudFormation stack and GitSync"
# =============================================================================
STACK_STATUS="$(aws_cmd cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].StackStatus' --output text)"

if [[ "$STACK_STATUS" =~ ^(CREATE_COMPLETE|UPDATE_COMPLETE)$ ]]; then
  pass "Stack '$STACK_NAME' exists and is healthy ($STACK_STATUS)"
else
  fail "Stack '$STACK_NAME' not healthy or not found (status: ${STACK_STATUS:-not found})"
fi

aws_cmd cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].{Id:StackId,Created:CreationTime,Updated:LastUpdatedTime,Tags:Tags}' \
  --output json > "${OUT_DIR}/stack-details.json"
aws_cmd cloudformation list-stack-resources --stack-name "$STACK_NAME" \
  --query 'StackResourceSummaries[].{Type:ResourceType,LogicalId:LogicalResourceId,Physical:PhysicalResourceId,Status:ResourceStatus}' \
  --output table > "${OUT_DIR}/stack-resources.txt"
info "Stack resource inventory saved to stack-resources.txt"

# GitSync configuration (CodeConnections; falls back to the older CLI namespace)
SYNC_JSON=""
for svc in codeconnections codestar-connections; do
  SYNC_JSON="$(aws "$svc" get-sync-configuration --sync-type CFN_STACK_SYNC \
    --resource-name "$STACK_NAME" "${REGION_ARGS[@]}" --output json 2>/dev/null)" && [[ -n "$SYNC_JSON" ]] && break
done
if [[ -n "$SYNC_JSON" ]]; then
  echo "$SYNC_JSON" > "${OUT_DIR}/gitsync-configuration.json"
  REPO="$(echo "$SYNC_JSON" | sed -n 's/.*"RepositoryName": *"\([^"]*\)".*/\1/p' | head -1)"
  BRANCH="$(echo "$SYNC_JSON" | sed -n 's/.*"Branch": *"\([^"]*\)".*/\1/p' | head -1)"
  CONFIG_FILE="$(echo "$SYNC_JSON" | sed -n 's/.*"ConfigFile": *"\([^"]*\)".*/\1/p' | head -1)"
  pass "GitSync enabled: repo=${REPO:-?} branch=${BRANCH:-?} deployment-file=${CONFIG_FILE:-?}"
else
  warn "Could not read GitSync configuration (missing permission or stack not GitSync-enabled)"
fi

# Drift detection: the live resources must still match the repository template.
DRIFT_ID="$(aws_cmd cloudformation detect-stack-drift --stack-name "$STACK_NAME" \
  --query StackDriftDetectionId --output text)"
if [[ -n "$DRIFT_ID" ]]; then
  for _ in $(seq 1 30); do
    DRIFT_STATE="$(aws_cmd cloudformation describe-stack-drift-detection-status \
      --stack-drift-detection-id "$DRIFT_ID" --query DetectionStatus --output text)"
    [[ "$DRIFT_STATE" != "DETECTION_IN_PROGRESS" ]] && break
    sleep 3
  done
  DRIFT_RESULT="$(aws_cmd cloudformation describe-stack-drift-detection-status \
    --stack-drift-detection-id "$DRIFT_ID" --query StackDriftStatus --output text)"
  if [[ "$DRIFT_RESULT" == "IN_SYNC" ]]; then
    pass "No configuration drift: live IAM matches the repository template"
  else
    fail "Drift status: ${DRIFT_RESULT:-unknown} (access was changed outside the template)"
    aws_cmd cloudformation describe-stack-resource-drifts --stack-name "$STACK_NAME" \
      --stack-resource-drift-status-filters MODIFIED DELETED \
      --output json > "${OUT_DIR}/drift-details.json"
  fi
else
  warn "Could not start drift detection"
fi

# =============================================================================
section "Policy hygiene: no inline policies anywhere"
# =============================================================================
INLINE_RES="$(aws_cmd cloudformation list-stack-resources --stack-name "$STACK_NAME" \
  --query "length(StackResourceSummaries[?ResourceType=='AWS::IAM::Policy'])" --output text)"
[[ "${INLINE_RES:-x}" == "0" ]] \
  && pass "Stack contains zero AWS::IAM::Policy (inline policy) resources" \
  || fail "Stack contains inline policy resources: ${INLINE_RES:-unknown}"

TEMPLATE_BODY="$(aws_cmd cloudformation get-template --stack-name "$STACK_NAME" \
  --template-stage Original --query TemplateBody --output text)"
echo "$TEMPLATE_BODY" > "${OUT_DIR}/deployed-template.yaml"
if grep -Eq '^[[:space:]]*Policies:' "${OUT_DIR}/deployed-template.yaml"; then
  fail "Deployed template contains an inline 'Policies:' property"
else
  pass "Deployed template has no inline 'Policies:' property"
fi

for u in "$S3_USER" "$EC2_USER_1" "$EC2_USER_2"; do
  n="$(aws_iam list-user-policies --user-name "$u" --query 'length(PolicyNames)' --output text)"
  [[ "${n:-x}" == "0" ]] && pass "User $u has 0 inline policies" || fail "User $u has inline policies: ${n:-unknown}"
done
for g in onward-s3-engineers onward-compute-engineers "$OBSERVER_GROUP"; do
  n="$(aws_iam list-group-policies --group-name "$g" --query 'length(PolicyNames)' --output text)"
  [[ "${n:-x}" == "0" ]] && pass "Group $g has 0 inline policies" || fail "Group $g has inline policies: ${n:-unknown}"
done

# =============================================================================
section "Identity design: groups, boundaries and tags"
# =============================================================================
declare -A EXPECT_GROUP=( ["$S3_USER"]="onward-s3-engineers" ["$EC2_USER_1"]="onward-compute-engineers" ["$EC2_USER_2"]="$OBSERVER_GROUP" )
declare -A EXPECT_BOUNDARY=( ["$S3_USER"]="onward-boundary-s3-engineer" ["$EC2_USER_1"]="onward-boundary-compute-engineer" ["$EC2_USER_2"]="onward-boundary-compute-observer" )

for u in "$S3_USER" "$EC2_USER_1" "$EC2_USER_2"; do
  groups="$(aws_iam list-groups-for-user --user-name "$u" --query 'Groups[].GroupName' --output text)"
  [[ "$groups" == "${EXPECT_GROUP[$u]}" ]] \
    && pass "$u is a member of ${EXPECT_GROUP[$u]} only" \
    || fail "$u group membership is '${groups:-none}', expected '${EXPECT_GROUP[$u]}'"

  boundary="$(aws_iam get-user --user-name "$u" --query 'User.PermissionsBoundary.PermissionsBoundaryArn' --output text)"
  [[ "$boundary" == *"/${EXPECT_BOUNDARY[$u]}" ]] \
    && pass "$u has permissions boundary ${EXPECT_BOUNDARY[$u]}" \
    || fail "$u boundary is '${boundary:-none}', expected ${EXPECT_BOUNDARY[$u]}"

  approver="$(aws_iam list-user-tags --user-name "$u" --query "Tags[?Key=='ApprovedBy'].Value | [0]" --output text)"
  [[ -n "$approver" && "$approver" != "None" ]] \
    && pass "$u carries audit tag ApprovedBy=$approver" \
    || fail "$u is missing the ApprovedBy audit tag"

  direct="$(aws_iam list-attached-user-policies --user-name "$u" --query 'length(AttachedPolicies)' --output text)"
  [[ "${direct:-x}" == "0" ]] \
    && pass "$u has no directly attached policies (access flows only via its group)" \
    || warn "$u has $direct directly attached policies (expected 0)"
done

for g in onward-s3-engineers onward-compute-engineers "$OBSERVER_GROUP"; do
  pols="$(aws_iam list-attached-group-policies --group-name "$g" --query 'AttachedPolicies[].PolicyName' --output text | tr '\t' ',')"
  info "Group $g -> managed policies: $pols"
done
aws_iam get-policy-version \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/onward-boundary-compute-observer" \
  --version-id v1 --query 'PolicyVersion.Document' --output json > "${OUT_DIR}/observer-boundary-document.json"
info "On-call boundary document saved to observer-boundary-document.json"

# =============================================================================
section "Secure first login: Secrets Manager and forced password change"
# =============================================================================
for u in "$S3_USER" "$EC2_USER_1" "$EC2_USER_2"; do
  sid="onward/onboarding/$u"
  sname="$(aws_cmd secretsmanager describe-secret --secret-id "$sid" --query Name --output text)"
  [[ "$sname" == "$sid" ]] \
    && pass "Secret $sid exists in Secrets Manager (value not printed)" \
    || fail "Secret $sid not found"

  reset="$(aws_iam get-login-profile --user-name "$u" --query 'LoginProfile.PasswordResetRequired' --output text)"
  last="$(aws_iam get-user --user-name "$u" --query 'User.PasswordLastUsed' --output text)"
  if [[ "$reset" == "True" || "$reset" == "true" ]]; then
    pass "$u must change password at first sign-in (PasswordResetRequired=true)"
  elif [[ -n "$last" && "$last" != "None" ]]; then
    pass "$u has already signed in and changed the initial password (last used: $last)"
  else
    fail "$u does not require a password reset and has no sign-in history"
  fi
done
if grep -Eq 'resolve:secretsmanager' "${OUT_DIR}/deployed-template.yaml"; then
  pass "Template reads passwords via Secrets Manager dynamic references (no plain text)"
else
  fail "Template does not use Secrets Manager dynamic references"
fi

# =============================================================================
section "Day-one access: each engineer can do the job and nothing more"
# =============================================================================
info "Storage engineer ($S3_USER)"
expect "$S3_USER" allowed  s3:ListAllMyBuckets s3:CreateBucket s3:PutObject s3:GetObject
expect "$S3_USER" denied   ec2:RunInstances ec2:TerminateInstances iam:CreateUser

info "Compute engineer ($EC2_USER_1)"
expect "$EC2_USER_1" allowed ec2:DescribeInstances ec2:RunInstances ec2:StartInstances ec2:StopInstances ec2:TerminateInstances
expect "$EC2_USER_1" denied  s3:PutObject s3:CreateBucket iam:CreateUser

info "On-call engineer ($EC2_USER_2)"
expect "$EC2_USER_2" allowed ec2:DescribeInstances ec2:DescribeInstanceStatus ec2:GetConsoleOutput
expect "$EC2_USER_2" denied  ec2:RunInstances ec2:TerminateInstances ec2:StartInstances ec2:StopInstances s3:PutObject iam:CreateUser

info "All users can change their own password"
for u in "$S3_USER" "$EC2_USER_1" "$EC2_USER_2"; do expect "$u" allowed iam:ChangePassword; done

# =============================================================================
section "Guarantee: on-call engineer can never create or terminate compute"
# =============================================================================
if $TAMPER_TEST; then
  info "TAMPER TEST: attaching AdministratorAccess to group $OBSERVER_GROUP and user $EC2_USER_2"
  TAMPER_ACTIVE=true
  aws iam attach-group-policy --group-name "$OBSERVER_GROUP" --policy-arn "$ADMIN_POLICY_ARN" >/dev/null 2>&1 \
    && pass "Attached AdministratorAccess to group $OBSERVER_GROUP (simulated careless change)" \
    || fail "Could not attach AdministratorAccess to the group (check permissions)"
  aws iam attach-user-policy --user-name "$EC2_USER_2" --policy-arn "$ADMIN_POLICY_ARN" >/dev/null 2>&1 \
    && pass "Attached AdministratorAccess directly to $EC2_USER_2 (simulated careless change)" \
    || fail "Could not attach AdministratorAccess to the user (check permissions)"
  info "Waiting for IAM propagation..."
  sleep 10

  info "Re-testing $EC2_USER_2 WITH full admin attached:"
  expect "$EC2_USER_2" denied ec2:RunInstances ec2:TerminateInstances ec2:CreateFleet ec2:RequestSpotInstances
  expect "$EC2_USER_2" denied iam:CreateUser s3:DeleteBucket
  expect "$EC2_USER_2" allowed ec2:DescribeInstances

  cleanup_tamper
  info "Waiting for IAM propagation..."
  sleep 5
  expect "$EC2_USER_2" denied ec2:RunInstances ec2:TerminateInstances
  info "Permissions restored to the template-defined state."
else
  warn "Tamper test skipped. Re-run with -t to prove the guarantee after adding extra permissions."
  expect "$EC2_USER_2" denied ec2:RunInstances ec2:TerminateInstances ec2:CreateFleet ec2:RequestSpotInstances
fi

# =============================================================================
section "Auditability: who changed access, and when"
# =============================================================================
TRAIL_JSON="$(aws_cmd cloudtrail describe-trails --trail-name-list "$TRAIL_NAME" --query 'trailList[0].Name' --output text)"
if [[ "$TRAIL_JSON" == "$TRAIL_NAME" ]]; then
  LOGGING="$(aws_cmd cloudtrail get-trail-status --name "$TRAIL_NAME" --query IsLogging --output text)"
  [[ "$LOGGING" == "True" ]] && pass "CloudTrail '$TRAIL_NAME' is actively logging" || fail "CloudTrail '$TRAIL_NAME' is not logging"
else
  warn "Trail '$TRAIL_NAME' not found (EnableAuditTrail=false?). Falling back to CloudTrail event history."
fi

# IAM is a global service: its events are recorded in us-east-1.
AUDIT_FILE="${OUT_DIR}/cloudtrail-iam-events.txt"
: > "$AUDIT_FILE"
for ev in CreateUser CreateLoginProfile AddUserToGroup AttachGroupPolicy DetachGroupPolicy AttachUserPolicy DetachUserPolicy PutUserPermissionsBoundary CreatePolicy; do
  rows="$(aws cloudtrail lookup-events --region us-east-1 \
    --lookup-attributes AttributeKey=EventName,AttributeValue="$ev" --max-results 10 \
    --query 'Events[].[EventTime,EventName,Username]' --output text 2>/dev/null)"
  [[ -n "$rows" ]] && echo "$rows" >> "$AUDIT_FILE"
done
sort -r "$AUDIT_FILE" -o "$AUDIT_FILE"
if [[ -s "$AUDIT_FILE" ]]; then
  pass "CloudTrail returned $(wc -l < "$AUDIT_FILE" | tr -d ' ') IAM change events (time | event | actor)"
  head -n 15 "$AUDIT_FILE" | while IFS=$'\t' read -r t e a; do printf '         %s  %-26s %s\n' "$t" "$e" "$a"; done
else
  fail "No IAM change events found in CloudTrail event history"
fi

LAST_TAMPER="$(aws cloudtrail lookup-events --region us-east-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AttachGroupPolicy --max-results 1 \
  --query 'Events[0].Username' --output text 2>/dev/null)"
[[ -n "$LAST_TAMPER" && "$LAST_TAMPER" != "None" ]] && info "Most recent AttachGroupPolicy was performed by: $LAST_TAMPER"

info "Template change history lives in Git:  git log --follow -- templates/onboarding-template.yaml"

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS + FAIL))
printf '\n%s================================================================%s\n' "$BOLD" "$RESET"
printf '%s  SUMMARY%s\n' "$BOLD" "$RESET"
printf '%s================================================================%s\n' "$BOLD" "$RESET"
printf '  Checks passed : %s%d%s / %d\n' "$GREEN" "$PASS" "$RESET" "$TOTAL"
printf '  Checks failed : %s%d%s\n' "$([[ $FAIL -gt 0 ]] && echo "$RED" || echo "$GREEN")" "$FAIL" "$RESET"
printf '  Warnings      : %s%d%s\n' "$YELLOW" "$WARN" "$RESET"
printf '  Evidence files: %s\n' "$OUT_DIR"
if [[ $FAIL -eq 0 ]]; then
  printf '\n  %sRESULT: ALL OBJECTIVES VERIFIED%s\n\n' "$GREEN$BOLD" "$RESET"
  exit 0
else
  printf '\n  %sRESULT: %d CHECK(S) FAILED - REVIEW ABOVE%s\n\n' "$RED$BOLD" "$FAIL" "$RESET"
  exit 1
fi
