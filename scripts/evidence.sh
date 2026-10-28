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

# Stop on unset variables and failed pipes. "-e" is left out on purpose,
# so one failed check is reported and the script carries on with the rest.
# Means: catch typos and broken pipes, but keep running after a failed check.
# AWS uses: nothing; local bash setting.
set -uo pipefail

# ----------------------------- configuration ---------------------------------
# Defaults. The -s, -r and -o options can override the first three.
# Means: the stack to check.
# AWS uses: nothing yet; sent later to CloudFormation calls as --stack-name.
STACK_NAME="onward-onboarding"
# Region comes from the environment if set; otherwise the AWS CLI default is used.
# Means: take AWS_REGION, else AWS_DEFAULT_REGION, else leave empty.
# AWS uses: nothing yet; sent later as --region when not empty.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
# UTC timestamp, used to name the report folder.
# Means: the current time as text, e.g. for evidence-<time>.
# AWS uses: nothing; local clock.
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Means: output folder (empty = use the default later) and tamper test off unless -t is given.
# AWS uses: nothing.
OUT_DIR=""
TAMPER_TEST=false

# Names that must match the template. If the template renames something, update it here too.
# Means: the user, group and trail names the checks look for.
# AWS uses: nothing yet; sent later in IAM and CloudTrail calls.
S3_USER="s3-user"
EC2_USER_1="ec2-user-1"
EC2_USER_2="ec2-user-2"
OBSERVER_GROUP="onward-oncall-observers"
# The AWS managed admin policy the tamper test attaches for a few seconds.
# Means: the ARN of AdministratorAccess.
# AWS uses: nothing yet; sent only with -t when attaching and detaching.
ADMIN_POLICY_ARN="arn:aws:iam::aws:policy/AdministratorAccess"
TRAIL_NAME="onward-iam-audit-trail"

# ------------------------------- arguments -----------------------------------
# Prints the usage text from the header comment at the top of this file, then exits.
# Means: a function that shows the help text.
# AWS uses: nothing; reads this file.
usage() { sed -n '2,/^# =====.*$/p' "$0" | sed -n '2,28p' | sed 's/^# \{0,1\}//'; exit 0; }

# Reads the command-line options. A ":" after a letter means that option takes a value.
# Means: turn -s, -r, -o, -t and -h into settings.
# AWS uses: nothing; local only.
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

# Uses ./evidence-<timestamp> unless -o was given, creates it, and names the report file.
# Means: pick the output folder, create it, and set the report file path.
# AWS uses: nothing; local files.
OUT_DIR="${OUT_DIR:-./evidence-${TIMESTAMP}}"
mkdir -p "$OUT_DIR"
LOG="${OUT_DIR}/evidence-report.txt"

# Tee to console (with colour) and to the report file (colour stripped).
# From here on, everything the script prints also lands in evidence-report.txt.
# Means: send all output both to the screen and to the report file.
# AWS uses: nothing; local only.
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG")) 2>&1

# Adds --region to AWS commands only when a region was set.
# Means: an extra argument list that is empty unless a region is known.
# AWS uses: --region <region> on regional calls when set.
REGION_ARGS=()
[[ -n "$REGION" ]] && REGION_ARGS=(--region "$REGION")

# -------------------------------- helpers ------------------------------------
# Uses colours only when printing to a terminal, so the saved report stays plain text.
# Means: set colour codes if the output is a terminal, otherwise leave them empty.
# AWS uses: nothing.
if [[ -t 1 ]]; then
  GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  GREEN=""; RED=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

# Counters for the summary at the end.
# Means: start every counter at zero.
# AWS uses: nothing.
PASS=0; FAIL=0; WARN=0
SECTION_NO=0

# Print helpers: a numbered section heading, and PASS / FAIL / WARN / INFO lines.
# pass, fail and warn also add one to their counter.
# Means: small functions that format and count each result line.
# AWS uses: nothing; they only print.
section() { SECTION_NO=$((SECTION_NO + 1)); printf '\n%s== %d. %s ==%s\n' "$BOLD$BLUE" "$SECTION_NO" "$1" "$RESET"; }
pass()    { PASS=$((PASS + 1)); printf '  %s[PASS]%s %s\n' "$GREEN" "$RESET" "$1"; }
fail()    { FAIL=$((FAIL + 1)); printf '  %s[FAIL]%s %s\n' "$RED" "$RESET" "$1"; }
warn()    { WARN=$((WARN + 1)); printf '  %s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1"; }
info()    { printf '  %s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }

# Wrappers that run AWS commands quietly. aws_cmd adds the region; IAM needs no region.
# Means: shortcuts that run "aws ..." and hide error messages.
# AWS uses: whatever command is passed in; aws_cmd adds --region, aws_iam targets global IAM.
aws_cmd() { aws "$@" "${REGION_ARGS[@]}" 2>/dev/null; }
aws_iam() { aws iam "$@" 2>/dev/null; }   # IAM is global

# simulate <user> <action> -> prints evaluation decision
# Asks the IAM policy simulator whether the user may run the action, without running it.
# The simulator includes group policies, user policies and the permissions boundary.
# Means: test one action for one user and print allowed, implicitDeny or explicitDeny.
# AWS uses: IAM SimulatePrincipalPolicy (read-only; nothing is actually run).
simulate() {
  aws_iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::${ACCOUNT_ID}:user/$1" \
    --action-names "$2" \
    --resource-arns "*" \
    --query 'EvaluationResults[0].EvalDecision' --output text
}

# expect <user> <allowed|denied> <action...>
# Simulates each action and records PASS when the result matches what we expect.
# "denied" covers both implicitDeny and explicitDeny; an empty answer counts as an error.
# Means: compare each simulated decision with the expected one and print PASS or FAIL.
# AWS uses: one SimulatePrincipalPolicy call per action (through simulate).
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

# Removes the temporary AdministratorAccess from the on-call group and user.
# It does nothing unless the tamper test actually attached it.
# Means: undo the tamper test so ec2-user-2 is back to normal.
# AWS uses: IAM DetachGroupPolicy and DetachUserPolicy (only when the tamper test ran).
cleanup_tamper() {
  if [[ "${TAMPER_ACTIVE:-false}" == "true" ]]; then
    printf '\n%s[CLEANUP]%s Removing temporary AdministratorAccess attachments...\n' "$YELLOW" "$RESET"
    aws iam detach-group-policy --group-name "$OBSERVER_GROUP" --policy-arn "$ADMIN_POLICY_ARN" >/dev/null 2>&1
    aws iam detach-user-policy  --user-name "$EC2_USER_2"      --policy-arn "$ADMIN_POLICY_ARN" >/dev/null 2>&1
    TAMPER_ACTIVE=false
    printf '  Done.\n'
  fi
}
# Runs the cleanup whenever the script ends, even after an error or Ctrl+C, so admin is never left attached.
# Means: register cleanup_tamper to run on exit, interrupt or termination.
# AWS uses: nothing by itself; cleanup_tamper calls IAM only if needed.
trap cleanup_tamper EXIT INT TERM

# ------------------------------- pre-flight ----------------------------------
# Stops early if the AWS CLI is missing.
# Means: check that the "aws" command exists on this machine.
# AWS uses: nothing; local check.
command -v aws >/dev/null 2>&1 || { echo "aws CLI is required but not installed."; exit 2; }

# Reads who is running the script and in which account. Fails if credentials are not working.
# Means: get the account ID and the caller's ARN; stop if AWS can't be reached.
# AWS uses: STS GetCallerIdentity (read-only), twice.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
[[ -z "$ACCOUNT_ID" ]] && { echo "Unable to call AWS. Check your credentials."; exit 2; }

# Report header: when, which account, who ran it, which stack and region.
# Means: print the report's title block.
# AWS uses: nothing; prints values gathered above.
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
# Checks that the stack exists and finished successfully.
# Means: read the stack's status and PASS only on CREATE_COMPLETE or UPDATE_COMPLETE.
# AWS uses: CloudFormation DescribeStacks (read-only).
STACK_STATUS="$(aws_cmd cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].StackStatus' --output text)"

if [[ "$STACK_STATUS" =~ ^(CREATE_COMPLETE|UPDATE_COMPLETE)$ ]]; then
  pass "Stack '$STACK_NAME' exists and is healthy ($STACK_STATUS)"
else
  fail "Stack '$STACK_NAME' not healthy or not found (status: ${STACK_STATUS:-not found})"
fi

# Saves the stack details and a table of every resource it created, as evidence files.
# Means: write stack-details.json and stack-resources.txt into the report folder.
# AWS uses: CloudFormation DescribeStacks and ListStackResources (read-only).
aws_cmd cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].{Id:StackId,Created:CreationTime,Updated:LastUpdatedTime,Tags:Tags}' \
  --output json > "${OUT_DIR}/stack-details.json"
aws_cmd cloudformation list-stack-resources --stack-name "$STACK_NAME" \
  --query 'StackResourceSummaries[].{Type:ResourceType,LogicalId:LogicalResourceId,Physical:PhysicalResourceId,Status:ResourceStatus}' \
  --output table > "${OUT_DIR}/stack-resources.txt"
info "Stack resource inventory saved to stack-resources.txt"

# GitSync configuration (CodeConnections; falls back to the older CLI namespace)
# Proves the stack is deployed from Git, and records the repo, branch and deployment file.
# Means: try the new service name first, then the old one, and stop at the first answer.
# AWS uses: CodeConnections GetSyncConfiguration (read-only), or the older CodeStar Connections call.
SYNC_JSON=""
for svc in codeconnections codestar-connections; do
  SYNC_JSON="$(aws "$svc" get-sync-configuration --sync-type CFN_STACK_SYNC \
    --resource-name "$STACK_NAME" "${REGION_ARGS[@]}" --output json 2>/dev/null)" && [[ -n "$SYNC_JSON" ]] && break
done
if [[ -n "$SYNC_JSON" ]]; then
  echo "$SYNC_JSON" > "${OUT_DIR}/gitsync-configuration.json"
  # Pulls three fields out of the JSON with sed, so jq is not required.
  # Means: read the repo name, branch and deployment file from the saved JSON.
  # AWS uses: nothing; local text processing.
  REPO="$(echo "$SYNC_JSON" | sed -n 's/.*"RepositoryName": *"\([^"]*\)".*/\1/p' | head -1)"
  BRANCH="$(echo "$SYNC_JSON" | sed -n 's/.*"Branch": *"\([^"]*\)".*/\1/p' | head -1)"
  CONFIG_FILE="$(echo "$SYNC_JSON" | sed -n 's/.*"ConfigFile": *"\([^"]*\)".*/\1/p' | head -1)"
  pass "GitSync enabled: repo=${REPO:-?} branch=${BRANCH:-?} deployment-file=${CONFIG_FILE:-?}"
else
  warn "Could not read GitSync configuration (missing permission or stack not GitSync-enabled)"
fi

# Drift detection: the live resources must still match the repository template.
# Starts a drift check, then polls every 3 seconds (up to 30 times) until it finishes.
# Means: ask CloudFormation to compare live resources with the template, then wait for the answer.
# AWS uses: CloudFormation DetectStackDrift, then DescribeStackDriftDetectionStatus repeatedly.
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
  # IN_SYNC means nobody changed these resources in the console. Otherwise, save what drifted.
  # Means: PASS on IN_SYNC; otherwise FAIL and save the drifted resources.
  # AWS uses: CloudFormation DescribeStackResourceDrifts (read-only, only when drift is found).
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
# 1) The stack must contain no AWS::IAM::Policy resources (that type creates inline policies).
# Means: count resources of type AWS::IAM::Policy in the stack; it must be 0.
# AWS uses: CloudFormation ListStackResources (read-only).
INLINE_RES="$(aws_cmd cloudformation list-stack-resources --stack-name "$STACK_NAME" \
  --query "length(StackResourceSummaries[?ResourceType=='AWS::IAM::Policy'])" --output text)"
[[ "${INLINE_RES:-x}" == "0" ]] \
  && pass "Stack contains zero AWS::IAM::Policy (inline policy) resources" \
  || fail "Stack contains inline policy resources: ${INLINE_RES:-unknown}"

# 2) Downloads the template AWS actually deployed and checks it has no "Policies:" property.
# Means: save the deployed template, then search it for an inline Policies property.
# AWS uses: CloudFormation GetTemplate (read-only); the search itself is local.
TEMPLATE_BODY="$(aws_cmd cloudformation get-template --stack-name "$STACK_NAME" \
  --template-stage Original --query TemplateBody --output text)"
echo "$TEMPLATE_BODY" > "${OUT_DIR}/deployed-template.yaml"
if grep -Eq '^[[:space:]]*Policies:' "${OUT_DIR}/deployed-template.yaml"; then
  fail "Deployed template contains an inline 'Policies:' property"
else
  pass "Deployed template has no inline 'Policies:' property"
fi

# 3) Asks IAM directly: each user and each group must have zero inline policies.
# Means: count inline policies on every user and group; each count must be 0.
# AWS uses: IAM ListUserPolicies and ListGroupPolicies (read-only).
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
# Lookup tables: the group and the boundary each user is expected to have.
# Means: two maps from user name to expected group and expected boundary.
# AWS uses: nothing; local data.
declare -A EXPECT_GROUP=( ["$S3_USER"]="onward-s3-engineers" ["$EC2_USER_1"]="onward-compute-engineers" ["$EC2_USER_2"]="$OBSERVER_GROUP" )
declare -A EXPECT_BOUNDARY=( ["$S3_USER"]="onward-boundary-s3-engineer" ["$EC2_USER_1"]="onward-boundary-compute-engineer" ["$EC2_USER_2"]="onward-boundary-compute-observer" )

# For each user, checks four things: correct group, correct boundary,
# an ApprovedBy tag, and no policies attached directly to the user.
# Means: compare each user's real settings with the expected ones.
# AWS uses: IAM ListGroupsForUser, GetUser, ListUserTags and ListAttachedUserPolicies (all read-only).
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

# Lists the managed policies on each group, and saves the on-call boundary JSON as evidence.
# Means: print each group's policies and save the observer boundary document to a file.
# AWS uses: IAM ListAttachedGroupPolicies and GetPolicyVersion (read-only).
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
  # The secret must exist. describe-secret reads only metadata, never the password.
  # Means: confirm onward/onboarding/<user> exists.
  # AWS uses: Secrets Manager DescribeSecret (read-only, no secret value).
  sid="onward/onboarding/$u"
  sname="$(aws_cmd secretsmanager describe-secret --secret-id "$sid" --query Name --output text)"
  [[ "$sname" == "$sid" ]] \
    && pass "Secret $sid exists in Secrets Manager (value not printed)" \
    || fail "Secret $sid not found"

  # PASS if a reset is still required, or if the user already signed in and changed it.
  # Means: read the reset flag and the last sign-in time to judge first-login security.
  # AWS uses: IAM GetLoginProfile and GetUser (read-only).
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
# The deployed template must read passwords through dynamic references, not plain text.
# Means: search the saved deployed template for "resolve:secretsmanager".
# AWS uses: nothing; local search of the file downloaded earlier.
if grep -Eq 'resolve:secretsmanager' "${OUT_DIR}/deployed-template.yaml"; then
  pass "Template reads passwords via Secrets Manager dynamic references (no plain text)"
else
  fail "Template does not use Secrets Manager dynamic references"
fi

# =============================================================================
section "Day-one access: each engineer can do the job and nothing more"
# =============================================================================
# For each engineer: actions their job needs must be allowed, and actions outside it denied.
# Means: run expect() with job actions (allowed) and out-of-role actions (denied).
# AWS uses: IAM SimulatePrincipalPolicy once per action (read-only).
info "Storage engineer ($S3_USER)"
expect "$S3_USER" allowed  s3:ListAllMyBuckets s3:CreateBucket s3:PutObject s3:GetObject
expect "$S3_USER" denied   ec2:RunInstances ec2:TerminateInstances iam:CreateUser

info "Compute engineer ($EC2_USER_1)"
expect "$EC2_USER_1" allowed ec2:DescribeInstances ec2:RunInstances ec2:StartInstances ec2:StopInstances ec2:TerminateInstances
expect "$EC2_USER_1" denied  s3:PutObject s3:CreateBucket iam:CreateUser

info "On-call engineer ($EC2_USER_2)"
expect "$EC2_USER_2" allowed ec2:DescribeInstances ec2:DescribeInstanceStatus ec2:GetConsoleOutput
expect "$EC2_USER_2" denied  ec2:RunInstances ec2:TerminateInstances ec2:StartInstances ec2:StopInstances s3:PutObject iam:CreateUser

# Every user must be able to change their own password (needed for the forced reset).
# Means: check iam:ChangePassword is allowed for all three users.
# AWS uses: IAM SimulatePrincipalPolicy (read-only).
info "All users can change their own password"
for u in "$S3_USER" "$EC2_USER_1" "$EC2_USER_2"; do expect "$u" allowed iam:ChangePassword; done

# =============================================================================
section "Guarantee: on-call engineer can never create or terminate compute"
# =============================================================================
if $TAMPER_TEST; then
  # Simulates a careless change: attaches full admin to the on-call group AND user.
  # Means: really attach AdministratorAccess for a short test (only with -t).
  # AWS uses: IAM AttachGroupPolicy and AttachUserPolicy (these CHANGE IAM).
  info "TAMPER TEST: attaching AdministratorAccess to group $OBSERVER_GROUP and user $EC2_USER_2"
  TAMPER_ACTIVE=true
  aws iam attach-group-policy --group-name "$OBSERVER_GROUP" --policy-arn "$ADMIN_POLICY_ARN" >/dev/null 2>&1 \
    && pass "Attached AdministratorAccess to group $OBSERVER_GROUP (simulated careless change)" \
    || fail "Could not attach AdministratorAccess to the group (check permissions)"
  aws iam attach-user-policy --user-name "$EC2_USER_2" --policy-arn "$ADMIN_POLICY_ARN" >/dev/null 2>&1 \
    && pass "Attached AdministratorAccess directly to $EC2_USER_2 (simulated careless change)" \
    || fail "Could not attach AdministratorAccess to the user (check permissions)"
  # IAM changes take a few seconds to apply everywhere.
  # Means: wait 10 seconds before testing.
  # AWS uses: nothing.
  info "Waiting for IAM propagation..."
  sleep 10

  # Even with admin attached, the boundary must still deny creating compute and anything
  # outside its ceiling, while read-only access keeps working.
  # Means: re-test ec2-user-2 while it has full admin attached.
  # AWS uses: IAM SimulatePrincipalPolicy (read-only).
  info "Re-testing $EC2_USER_2 WITH full admin attached:"
  expect "$EC2_USER_2" denied ec2:RunInstances ec2:TerminateInstances ec2:CreateFleet ec2:RequestSpotInstances
  expect "$EC2_USER_2" denied iam:CreateUser s3:DeleteBucket
  expect "$EC2_USER_2" allowed ec2:DescribeInstances

  # Removes the admin policy again and confirms the user is back to the template's state.
  # Means: detach admin, wait 5 seconds, and test once more.
  # AWS uses: IAM DetachGroupPolicy and DetachUserPolicy, then SimulatePrincipalPolicy.
  cleanup_tamper
  info "Waiting for IAM propagation..."
  sleep 5
  expect "$EC2_USER_2" denied ec2:RunInstances ec2:TerminateInstances
  info "Permissions restored to the template-defined state."
else
  # Without -t, only checks the normal state and reminds you to run the tamper test.
  # Means: test the normal state only and print a reminder.
  # AWS uses: IAM SimulatePrincipalPolicy (read-only).
  warn "Tamper test skipped. Re-run with -t to prove the guarantee after adding extra permissions."
  expect "$EC2_USER_2" denied ec2:RunInstances ec2:TerminateInstances ec2:CreateFleet ec2:RequestSpotInstances
fi

# =============================================================================
section "Auditability: who changed access, and when"
# =============================================================================
# Checks that our trail exists and is recording right now.
# Means: find the trail by name, then check it is logging.
# AWS uses: CloudTrail DescribeTrails and GetTrailStatus (read-only).
TRAIL_JSON="$(aws_cmd cloudtrail describe-trails --trail-name-list "$TRAIL_NAME" --query 'trailList[0].Name' --output text)"
if [[ "$TRAIL_JSON" == "$TRAIL_NAME" ]]; then
  LOGGING="$(aws_cmd cloudtrail get-trail-status --name "$TRAIL_NAME" --query IsLogging --output text)"
  [[ "$LOGGING" == "True" ]] && pass "CloudTrail '$TRAIL_NAME' is actively logging" || fail "CloudTrail '$TRAIL_NAME' is not logging"
else
  warn "Trail '$TRAIL_NAME' not found (EnableAuditTrail=false?). Falling back to CloudTrail event history."
fi

# IAM is a global service: its events are recorded in us-east-1.
# Looks up the last 10 events of each IAM change type and saves time, event and actor.
# Means: collect recent IAM change events into cloudtrail-iam-events.txt.
# AWS uses: CloudTrail LookupEvents in us-east-1, once per event name (read-only).
AUDIT_FILE="${OUT_DIR}/cloudtrail-iam-events.txt"
: > "$AUDIT_FILE"
for ev in CreateUser CreateLoginProfile AddUserToGroup AttachGroupPolicy DetachGroupPolicy AttachUserPolicy DetachUserPolicy PutUserPermissionsBoundary CreatePolicy; do
  rows="$(aws cloudtrail lookup-events --region us-east-1 \
    --lookup-attributes AttributeKey=EventName,AttributeValue="$ev" --max-results 10 \
    --query 'Events[].[EventTime,EventName,Username]' --output text 2>/dev/null)"
  [[ -n "$rows" ]] && echo "$rows" >> "$AUDIT_FILE"
done
# Sorts newest first and prints the 15 most recent events in the report.
# Means: sort the saved events and print the top 15.
# AWS uses: nothing; local file.
sort -r "$AUDIT_FILE" -o "$AUDIT_FILE"
if [[ -s "$AUDIT_FILE" ]]; then
  pass "CloudTrail returned $(wc -l < "$AUDIT_FILE" | tr -d ' ') IAM change events (time | event | actor)"
  head -n 15 "$AUDIT_FILE" | while IFS=$'\t' read -r t e a; do printf '         %s  %-26s %s\n' "$t" "$e" "$a"; done
else
  fail "No IAM change events found in CloudTrail event history"
fi

# Shows who most recently attached a policy to a group (after -t, that is the tamper test).
# Means: print the user name on the newest AttachGroupPolicy event.
# AWS uses: CloudTrail LookupEvents in us-east-1 (read-only).
LAST_TAMPER="$(aws cloudtrail lookup-events --region us-east-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AttachGroupPolicy --max-results 1 \
  --query 'Events[0].Username' --output text 2>/dev/null)"
[[ -n "$LAST_TAMPER" && "$LAST_TAMPER" != "None" ]] && info "Most recent AttachGroupPolicy was performed by: $LAST_TAMPER"

# Reminds the reader that the code history (who changed the template) is in Git.
# Means: print the git command that shows the template's change history.
# AWS uses: nothing.
info "Template change history lives in Git:  git log --follow -- templates/onboarding-template.yaml"

# =============================================================================
# Summary
# =============================================================================
# Prints the totals. Exit code 0 means every check passed; 1 means at least one failed.
# Means: print passed, failed and warning counts and the final result.
# AWS uses: nothing; prints the counters.
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
