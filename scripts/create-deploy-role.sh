#!/usr/bin/env bash
# =============================================================================
# create-deploy-role.sh - CloudFormation service role for the onboarding stack
# Project : Onward Logistics - Secure Onboarding at Scale
#
# Creates (or updates) one role used for both GitSync fields:
#   - Git sync IAM role   (trusted by cloudformation.sync.codeconnections)
#   - Stack service role  (trusted by cloudformation, creates the resources)
# Deploy permissions are scoped to what templates/onboarding-template.yaml
# creates. All permissions live in customer managed policies (no inline
# policies). Safe to run more than once.
#
# Run it in AWS CloudShell (credentials and the AWS CLI are already set up):
#   bash create-deploy-role.sh
#
# Then select the role in: Create stack > Configure stack options > Permissions
# =============================================================================
set -euo pipefail

ROLE_NAME="onward-cfn-deploy-role"
POLICY_NAME="onward-cfn-deploy-policy"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
GITSYNC_POLICY_NAME="onward-cfn-gitsync-policy"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Account : ${ACCOUNT_ID}"
echo "Role    : ${ROLE_NAME}"
echo "Policy  : ${POLICY_NAME}"

# ------------------------- trust: CloudFormation only ------------------------
cat > "${WORK_DIR}/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "cloudformation.amazonaws.com",
          "cloudformation.sync.codeconnections.amazonaws.com"
        ]
      },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" } }
    }
  ]
}
EOF

# ------------- permissions: only what onboarding-template.yaml needs ---------
cat > "${WORK_DIR}/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IamUsersGroupsBoundaries",
      "Effect": "Allow",
      "Action": [
        "iam:CreateUser", "iam:DeleteUser", "iam:GetUser",
        "iam:TagUser", "iam:UntagUser", "iam:ListUserTags",
        "iam:AddUserToGroup", "iam:RemoveUserFromGroup", "iam:ListGroupsForUser",
        "iam:PutUserPermissionsBoundary", "iam:DeleteUserPermissionsBoundary",
        "iam:CreateLoginProfile", "iam:UpdateLoginProfile", "iam:DeleteLoginProfile", "iam:GetLoginProfile",
        "iam:CreateGroup", "iam:DeleteGroup", "iam:GetGroup",
        "iam:AttachGroupPolicy", "iam:DetachGroupPolicy", "iam:ListAttachedGroupPolicies",
        "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
        "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:ListPolicyVersions",
        "iam:TagPolicy", "iam:UntagPolicy", "iam:ListPolicyTags"
      ],
      "Resource": [
        "arn:aws:iam::${ACCOUNT_ID}:user/s3-user",
        "arn:aws:iam::${ACCOUNT_ID}:user/ec2-user-*",
        "arn:aws:iam::${ACCOUNT_ID}:group/onward-*",
        "arn:aws:iam::${ACCOUNT_ID}:policy/onward-boundary-*"
      ]
    },
    {
      "Sid": "OnboardingSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue", "secretsmanager:UpdateSecret",
        "secretsmanager:TagResource", "secretsmanager:UntagResource"
      ],
      "Resource": "arn:aws:secretsmanager:*:${ACCOUNT_ID}:secret:onward/onboarding/*"
    },
    {
      "Sid": "GeneratePasswords",
      "Effect": "Allow",
      "Action": "secretsmanager:GetRandomPassword",
      "Resource": "*"
    },
    {
      "Sid": "AuditLogBucket",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketAcl",
        "s3:PutBucketPolicy", "s3:GetBucketPolicy", "s3:DeleteBucketPolicy",
        "s3:PutEncryptionConfiguration", "s3:GetEncryptionConfiguration",
        "s3:PutBucketPublicAccessBlock", "s3:GetBucketPublicAccessBlock",
        "s3:PutBucketVersioning", "s3:GetBucketVersioning",
        "s3:PutBucketTagging", "s3:GetBucketTagging"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AuditTrail",
      "Effect": "Allow",
      "Action": [
        "cloudtrail:CreateTrail", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
        "cloudtrail:StartLogging", "cloudtrail:StopLogging",
        "cloudtrail:DescribeTrails", "cloudtrail:GetTrail", "cloudtrail:GetTrailStatus",
        "cloudtrail:PutEventSelectors", "cloudtrail:GetEventSelectors",
        "cloudtrail:AddTags", "cloudtrail:RemoveTags", "cloudtrail:ListTags"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# ------- Git sync: read the repo, run change sets, watch for new commits -----
cat > "${WORK_DIR}/gitsync-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SyncToCloudFormation",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateChangeSet", "cloudformation:DeleteChangeSet",
        "cloudformation:DescribeChangeSet", "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStacks", "cloudformation:ExecuteChangeSet",
        "cloudformation:GetTemplate", "cloudformation:ListChangeSets",
        "cloudformation:ListStacks", "cloudformation:ValidateTemplate"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PolicyForManagedRules",
      "Effect": "Allow",
      "Action": ["events:PutRule", "events:PutTargets"],
      "Resource": "*",
      "Condition": { "StringEquals": { "events:ManagedBy": "cloudformation.sync.codeconnections.amazonaws.com" } }
    },
    {
      "Sid": "PolicyForDescribingRule",
      "Effect": "Allow",
      "Action": "events:DescribeRule",
      "Resource": "*"
    },
    {
      "Sid": "PassThisRoleToCloudFormation",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}",
      "Condition": { "StringEquals": { "iam:PassedToService": "cloudformation.amazonaws.com" } }
    }
  ]
}
EOF

# upsert_policy <name> <document> -> creates the managed policy or publishes a new default version
upsert_policy() {
  local arn="arn:aws:iam::${ACCOUNT_ID}:policy/$1"
  if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    echo "Policy $1 exists - publishing a new default version"
    # IAM keeps at most 5 versions: remove the oldest non-default one if full.
    local versions oldest
    versions="$(aws iam list-policy-versions --policy-arn "$arn" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
    if [[ "$(wc -w <<< "$versions")" -ge 4 ]]; then
      oldest="$(tr '\t' '\n' <<< "$versions" | sort -V | head -1)"
      aws iam delete-policy-version --policy-arn "$arn" --version-id "$oldest"
    fi
    aws iam create-policy-version --policy-arn "$arn" \
      --policy-document "file://$2" --set-as-default >/dev/null
  else
    echo "Creating policy $1"
    aws iam create-policy --policy-name "$1" \
      --description "Onward onboarding stack deployment ($1)" \
      --policy-document "file://$2" \
      --tags Key=Project,Value=onward-logistics-onboarding \
      >/dev/null
  fi
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn"
}

# ---------------------------------- role -------------------------------------
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Role exists - updating trust policy"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://${WORK_DIR}/trust.json"
else
  echo "Creating role"
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "CloudFormation service role for the onward-onboarding stack" \
    --assume-role-policy-document "file://${WORK_DIR}/trust.json" \
    --tags Key=Project,Value=onward-logistics-onboarding Key=ManagedBy,Value=create-deploy-role.sh \
    >/dev/null
fi

# -------------------------------- policies -----------------------------------
upsert_policy "$POLICY_NAME" "${WORK_DIR}/policy.json"
upsert_policy "$GITSYNC_POLICY_NAME" "${WORK_DIR}/gitsync-policy.json"

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
echo
echo "Done. Role ARN: ${ROLE_ARN}"
echo "Select '${ROLE_NAME}' as the Git sync IAM role and as the stack's IAM role."
