LAB: Automating Secure Onboarding at Scale for Onward Logistics 

Module: Security & Identity Management on AWS  |  Week (M) 1 

1. Business Scenario 

Onward Logistics is a fast growing regional delivery startup that now onboards five to ten new engineers a month. Today, every new hire's AWS access is configured by hand in the console, and the result depends heavily on which admin happened to do the work. Leadership wants this fixed before the next hiring wave: access should be built the same way every time, it should be automated rather than clicked together, and every change to who can access what needs to be traceable for audit purposes. 

In a planning call, the client lays out three specific requirements: 

“We want new hire access built the same way every time, not configured manually by whoever is on shift that day.” 

“We want a record of every change to who can access what, so we can answer who approved this and when during an audit.” 

“We have engineers who only ever need to check on running instances, for example an on call engineer confirming a deployment landed, and they should never be able to spin up new compute. Not by accident, not months from now, and not even if someone on our team later loosens their group's permissions without realizing it.” 

For background on the company, its stakeholders and its standards, read the Client Profile: Onward Logistics. 

2. What the Client Expects 

These are the objectives. How you achieve them is your design. 

Onboard three new engineers, each with the access their role needs and nothing more: a storage engineer (s3-user), a compute engineer (ec2-user-1), and an on call engineer who can only observe compute (ec2-user-2). 

Give every new engineer a secure first login, with no shared plain text credential and a forced change at first sign in. 

Guarantee that the on call engineer can never create or terminate compute, no matter what permissions are attached later. 

Make onboarding repeatable and auditable, so any change to access can be traced to a person and a time. 

Prove to the Head of Security that every objective is met. 

3. Mandatory Technical Requirements 

Provision everything with AWS CloudFormation. Nothing may be created manually in the console. 

Deploy the template using a GitSync  enabled CloudFormation stack from a version-controlled template repository. 

Generate the initial credential with AWS Secrets Manager. 

Do not use inline policies anywhere in the template. Avoid recreating iam entity specicfic policies as much as possible, rather use forward looking iam permissions procedures that caps entity permissions. 

4. Stage 1: Discovery (Before You Build) 

Write a discovery report before you build anything, following the Discovery Report Template and Guide. It has two parts: 

Research report: common solutions available for this kind of business scenario, and the risk of not having a solution. 

Business value: the advantages your chosen solution brings to the client. 

Your research should help you decide how to meet the objectives above. 

5. Stage 2: Build and Prove 

Design and build a solution that meets the objectives and the mandatory technical requirements, then gather evidence that each objective is met. You decide the design, including exactly which permissions each engineer receives. 

The client will check that: 

Each engineer can do their job on day one, and cannot do more. 

The on call engineer still cannot create or terminate compute after extra permissions are added to that engineer's group or user as a test. 

The Head of Security can see how access was defined and who changed it. 

The whole setup can be rebuilt from the repository. 

6. Deliverables 

Link to Discovery report: research report and business value. 

Lab deliverables: a link to the repository holding your CloudFormation template. 

Optional link to architecture diagram showing the identities, groups, policies and how access is controlled. 

Live review: explain and defend your reasoning. 

7. Rubric 

Discovery report (research and business value): 20% 

Solution meets the objectives and technical requirements: 40% 

Evidence that the guarantees hold: 20% 

Reasoning defended in the live review: 20% 

8. Submission 

Submission Type: Form link 

Grading: Live Review Session 