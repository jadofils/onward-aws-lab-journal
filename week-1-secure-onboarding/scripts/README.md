# Week 1 Scripts

Bash scripts that run in **AWS CloudShell**, which already has the AWS CLI and your credentials.

| Script | When to run it | What it does | Changes AWS? |
|--------|----------------|--------------|:---:|
| [create-deploy-role.sh](create-deploy-role.sh) | Once per account, **before** creating the GitSync stack | Creates or updates `onward-cfn-deploy-role` with two customer managed policies: `onward-cfn-gitsync-policy` (Git sync) and `onward-cfn-deploy-policy` (only what the template creates) | Yes, IAM |
| [evidence.sh](evidence.sh) | **After** the stack is `CREATE_COMPLETE`, and before the review | Checks every lab objective against the live account and writes a pass/fail report to `evidence-<timestamp>/` | No, unless `-t` is used |

## Order

```
create-deploy-role.sh  ->  GitSync deploys the template  ->  evidence.sh
```

## Usage

Upload the script in CloudShell (**Actions > Upload file**), then:

```bash
bash create-deploy-role.sh            # safe to run again; updates instead of failing

bash evidence.sh                      # read-only checks
bash evidence.sh -t                   # adds the tamper test (lab account only)
bash evidence.sh -h                   # all options: -s stack, -r region, -o output folder
```

## Notes

- The tamper test (`-t`) attaches AdministratorAccess to the on-call group and user for about 15 seconds to prove the boundary still blocks creating compute, then removes it. A trap removes it even if the script is interrupted.
- `evidence-*/` folders are in `.gitignore`. Redact account details before sharing a report.
- Every block has `# Means:` and `# AWS uses:` comments; the second one names the exact AWS API call, or says the line is local only.
- If you rename anything in the template, update the names at the top of `evidence.sh`.
