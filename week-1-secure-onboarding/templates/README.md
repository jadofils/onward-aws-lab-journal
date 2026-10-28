# Week 1 Templates

The CloudFormation template that builds the whole Week 1 lab.

| File | What it creates |
|------|-----------------|
| [onboarding-template.yaml](onboarding-template.yaml) | Three IAM users, one group per role with AWS managed policies, a permissions boundary per role, a Secrets Manager first password per user, and a CloudTrail trail with an encrypted log bucket |

## How it is deployed

GitSync deploys this template to the stack `onward-onboarding` whenever `main` changes. It finds the template through [`deployment.yaml`](../../deployment.yaml) at the repository root (`template-file-path`), which also supplies the parameter values and stack tags.

The deploy runs as `onward-cfn-deploy-role`, created once by [`../scripts/create-deploy-role.sh`](../scripts/create-deploy-role.sh).

## Reading the template

Every block has comments. `# Means:` says what the line does, and `# AWS uses:` says what CloudFormation actually receives. Suggested reading order:

1. Parameters and Conditions
2. Groups (where access is granted)
3. Permissions boundaries (the ceilings, including the on-call Deny)
4. Secrets
5. Users (where group, boundary, secret and tags meet)
6. Audit: bucket, bucket policy, trail
7. Outputs

## Rules for changes

- No inline policies: no `AWS::IAM::Policy` resources and no `Policies:` property.
- Keep resource names prefixed `onward-`; [`../scripts/evidence.sh`](../scripts/evidence.sh) looks them up by name.
- A new kind of resource also needs a matching permission in `create-deploy-role.sh`.
- Validate before opening a PR: `cfn-lint templates/onboarding-template.yaml`.
