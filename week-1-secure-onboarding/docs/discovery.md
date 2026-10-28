# Discovery Report: Secure Onboarding at Scale for Onward Logistics

| | |
|---|---|
| Lab | Automating Secure Onboarding at Scale for Onward Logistics (Week 1) |
| Name | Jado Fils SEZIKEYE |
| Date | 28 October 2026 |
| Client | Onward Logistics (see the [Client Profile](../../docs/client-profile.md)) |

> This report was completed after the Week 1 build, using what was learned during it. The same content is in [Discovery Report.docx](Discovery%20Report.docx).

## 1. What you found

### The client's need

Onward Logistics needs every new engineer to get exactly the access their job requires, set up the same way every time, with a record of who approved each change and a firm guarantee that on-call staff can never start or remove servers.

### Solutions that exist

| Solution | How it works | Trade-off for this client |
|----------|--------------|---------------------------|
| Manual setup in the AWS console (today) | An admin clicks together users and permissions in the console for each new hire. | **Strength:** nothing new to learn. **Weakness:** the result depends on which admin did it, access creeps upward, and there is no record of who approved what. |
| IAM users and groups written as CloudFormation code | Access is written once as code and deployed the same way for every hire. | **Strength:** repeatable and reviewable. **Weakness:** a later change to a group can still widen access, with no ceiling to stop it. |
| CloudFormation through GitSync, with groups and permissions boundaries (chosen) | Groups grant each role its access, a boundary on each user sets a maximum that can never be exceeded, and every change is a reviewed Git commit. | **Strength:** meets all three client requirements in a single account. **Weakness:** one extra policy to maintain per role; IAM Identity Center is the better long-term home once AWS Organizations is in place. |

### What happens with no solution

Manual onboarding repeats the same risks with every hire, five to ten times a month. Admins under time pressure grant broad access to unblock someone, two engineers in the same role end up able to do different things, and nobody can answer an auditor who asks who approved an engineer's access and when. An on-call engineer who can launch or terminate servers can also create unplanned cost or take down a running service by mistake.

Over-permissive cloud access has a documented price. In the 2019 Capital One breach, personal data of about 100 million people was exposed from systems hosted on AWS. In August 2020 the US Office of the Comptroller of the Currency fined the bank $80 million, citing weak risk assessment before it moved operations to the cloud. For Onward, where trust is the product, a similar incident would cost merchants, customers and penalties in every market it serves.

### Sources

- AWS, [Permissions boundaries for IAM entities](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)
- Cleary Gottlieb, [OCC Imposes $80 Million Penalty in Connection With Bank Data Breach](https://www.clearygottlieb.com/news-and-insights/publication-listing/occ-imposes-80-million-penalty-in-connection-with-bank-data-breach)
- SD Times, [Capital One fined $80 million for 2019 data breach](https://sdtimes.com/data/capital-one-fined-80-million-for-2019-data-breach)
- Mondaq, [OCC imposes $80 million penalty in connection with bank data breach](https://www.mondaq.com/unitedstates/financial-services/977444/occ-imposes-80-million-penalty-in-connection-with-bank-data-breach)

## 2. The business value of your solution

### Your chosen approach

I chose to define all access as code in one AWS CloudFormation template, deployed automatically by CloudFormation GitSync from a Git repository. Each engineer gets access only through the group for their role, and every user carries a permissions boundary: a ceiling that no later change can lift.

This suits Onward better than the other options because it answers all three client requirements at once:

- **Same every time:** every hire is built from the same template, and the whole setup can be rebuilt from the repository.
- **Traceable:** every change is a reviewed commit, every user carries an ApprovedBy tag, and CloudTrail records every access change.
- **Guaranteed limit:** the on-call engineer's boundary contains an explicit Deny on creating or terminating compute, which still wins if someone later attaches AdministratorAccess.

It needs only one AWS account, so it fits Onward's starting point today, and it maps directly onto IAM Identity Center later.

### Services you will use

| Service | The job it does | Why this service, used this way |
|---------|-----------------|---------------------------------|
| AWS CloudFormation with GitSync (through AWS CodeConnections) | Builds every user, group, policy, secret and trail from one template in Git; each merge to main deploys automatically | The same result every time, every change reviewed, and the whole setup rebuildable from the repository |
| AWS IAM groups with AWS managed policies | Give each role its access: S3 full access, EC2 full access, or EC2 read-only | No inline or per-user policies to maintain; AWS keeps the managed policies up to date |
| IAM permissions boundaries (customer managed policies) | Set the most each user can ever do; the on-call boundary denies creating or terminating compute | The guarantee holds even after a careless change, which a group policy alone cannot promise |
| AWS Secrets Manager | Generates a unique 24-character first password for each engineer, read by the template without ever appearing in it | No shared or plain-text password, and the engineer must choose a new one at first sign-in |
| AWS CloudTrail with Amazon S3 | Records every IAM call (who, what, when) in an encrypted, versioned, private bucket that is kept even if the stack is deleted | Answers who changed access and when, for any audit |
| IAM deployment role (`onward-cfn-deploy-role`) | Lets GitSync and CloudFormation create only the resources in the template | Least privilege for the automation itself |

### Who benefits, and how you will know

| Stakeholder | Benefit | How you would know |
|-------------|---------|--------------------|
| Leadership | Onboarding keeps pace with five to ten hires a month without depending on which admin is on shift | A new engineer is added through one reviewed pull request and has access minutes after it is merged |
| Head of Security | Least privilege is enforced by a ceiling, not by trust | Tamper test: with AdministratorAccess attached, `ec2-user-2` is still denied `ec2:RunInstances` |
| Auditors | Every access question has an answer | Each change shows a Git commit, a pull-request approval, an ApprovedBy tag and a CloudTrail event |
| New engineers | The right access on day one, and a private first password | Each engineer signs in, is asked to set a new password, and the policy simulator allows their job's actions |
| Platform team | No manual console work, and any outside change is spotted | CloudFormation drift detection reports `IN_SYNC` |

### Limits and risks of your design

- **Timing:** this report was completed after the Week 1 build, using what was learned during it.
- AmazonS3FullAccess and AmazonEC2FullAccess are broad within their service; a later phase can narrow them to specific buckets or tagged instances.
- Engineers use IAM users with passwords and MFA is not yet required; IAM Identity Center with single sign-on and MFA is the recommended next step once AWS Organizations is in place.
- The deployment role is created once by a bootstrap script kept in the repository, because GitSync needs it before the stack exists.
- The approver is recorded as a parameter; requiring pull-request approval by the Head of Security in GitHub would enforce it.
- Not yet covered from the Client Profile: temporary, limited access for people outside the company, and budget alerts so spend is visible from day one.
