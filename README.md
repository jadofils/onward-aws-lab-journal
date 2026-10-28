# Onward Logistics: AWS Lab Journal

Weekly AWS labs for Onward Logistics, each built as infrastructure as code with AWS CloudFormation and deployed through CloudFormation GitSync. Each week lives in its own folder with its own brief, templates, scripts, documentation and README.

## Labs

| Week | Module | Lab | Folder | Status |
|:---:|--------|-----|--------|--------|
| 1 | Security & Identity Management on AWS | Secure Onboarding at Scale | [week-1-secure-onboarding/](week-1-secure-onboarding/) | Deployed |
| 2 | Network & Security on AWS | Designing a Secure Network for the Order System | [week-2-secure-network/](week-2-secure-network/) | Discovery report drafted |

## Repository Structure

```
.
├── README.md                              # This index
├── deployment.yaml                        # Week 1 GitSync deployment file (stays at the root, see below)
├── docs/                                  # Shared across weeks
│   ├── client-profile.md                  # Onward Logistics profile, company standards, requirements by week
│   └── discovery-report-template.md       # Template for each week's discovery report
├── week-1-secure-onboarding/
│   ├── README.md                          # Week 1 overview, architecture, deployment, evidence
│   ├── docs/                              # Lab brief, draw.io diagrams, PNG exports
│   ├── templates/                         # CloudFormation template
│   └── scripts/                           # Deploy-role bootstrap and evidence script
└── week-2-secure-network/
    ├── README.md                          # Week 2 overview and plan
    ├── docs/                              # Lab brief, discovery report
    ├── templates/                         # CloudFormation templates (to be added)
    └── scripts/                           # Helper and evidence scripts (to be added)
```

## Conventions

- **One folder per week.** Each folder is named `week-<n>-<topic>` and holds everything for that lab: `docs/`, `templates/`, `scripts/` and a `README.md`.
- **One GitSync stack per week.** Each week deploys its own stack from its own deployment file, so labs never change each other's resources.
- **Deployment files.**
  - Week 1's `deployment.yaml` stays at the repository root, because its live GitSync stack was set up with that path. It points to `week-1-secure-onboarding/templates/onboarding-template.yaml`.
  - From Week 2 on, each week keeps its deployment file inside its own folder (for example `week-2-secure-network/deployment.yaml`), and its GitSync stack is set up with that path.
- **Workflow.** Changes go through a branch and a pull request, and `main` is what GitSync deploys.

## Adding a new week

1. Create `week-<n>-<topic>/` with `docs/`, `templates/`, `scripts/` and a `README.md`.
2. Save the lab brief as `docs/lab-brief.md`, then write and commit `docs/discovery.md` from the [discovery report template](docs/discovery-report-template.md) before building. Follow the standards in the [Client Profile](docs/client-profile.md).
3. Add the template and a `deployment.yaml` inside the week's folder.
4. Create the GitSync stack with the deployment file path set to `week-<n>-<topic>/deployment.yaml`.
5. Add the week to the **Labs** table above.
