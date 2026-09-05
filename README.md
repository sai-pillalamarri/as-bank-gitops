# AS Bank GitOps

GitOps desired state for the AS Bank Kubernetes platform and application workloads.

This repository is the deployment source of truth for Kubernetes. Argo CD continuously reconciles the state defined here with the EKS clusters.

It demonstrates hands-on work with GitOps, Argo CD, Helm, environment promotion, Kubernetes security controls, NetworkPolicies, immutable image deployment, and separation between platform and application ownership.

## Delivery Model

The deployment path is intentionally separated from CI.

```text
Application change
      |
      v
as-bank-app
      |
      | GitHub Actions
      | build + test + scan + sign
      v
     ECR
      |
      | immutable image digest
      v
GitOps pull request
      |
      v
as-bank-gitops
      |
      v
   Argo CD
      |
      v
 Kubernetes / EKS
```

GitHub Actions builds and publishes the artifact.

It does not deploy workloads with `kubectl apply`.

Deployment happens only after the desired state changes in this repository and Argo CD reconciles that change.

## What This Repository Demonstrates

- GitOps-based Kubernetes delivery with Argo CD
- App-of-apps repository structure
- Separation between platform and application configuration
- Helm-based reusable workload configuration
- Environment-specific values without duplicating charts
- Immutable container image deployment by digest
- Automatic dev reconciliation
- Approval-controlled production promotion
- Kubernetes NetworkPolicies
- Pod Security Admission configuration
- Kyverno workload and image policies
- External Secrets configuration
- Resource requests and limits
- Liveness, readiness, and startup probes
- PodDisruptionBudgets
- HorizontalPodAutoscalers
- Topology spread constraints
- GitHub Actions validation of Kubernetes desired state

## Repository Structure

```text
.
├── .github/
│   └── workflows/
│
├── bootstrap/
│   ├── dev/
│   └── prod/
│
├── platform/
│   ├── dev/
│   └── prod/
│
└── apps/
    ├── charts/
    ├── dev/
    └── prod/
```

The three main areas have different responsibilities.

### `bootstrap/`

Contains the Argo CD application hierarchy used to bootstrap environment-level desired state.

Terraform installs Argo CD and creates the initial root Application.

After that, Argo CD follows the configuration in this repository.

### `platform/`

Contains cluster-level platform configuration.

Examples include:

- Kyverno policy configuration
- External Secrets resources
- Metrics Server
- namespace-level security configuration
- platform NetworkPolicies

Platform configuration is kept separate because it has a different blast radius and lifecycle from application workloads.

### `apps/`

Contains the Kubernetes desired state for the AS Bank application workloads.

The current application stack includes:

```text
customer-service
account-service
transaction-service
frontend
```

The workloads are rendered through reusable Helm configuration rather than maintaining a completely separate chart for every service.

## App-of-Apps Model

Argo CD uses an app-of-apps structure.

```text
Environment root
      |
      +--> Platform applications
      |
      +--> Application applications
              |
              +--> customer-service
              +--> account-service
              +--> transaction-service
              +--> frontend
```

The root Application gives Argo CD one entry point into the environment.

Child Applications then own smaller parts of the desired state.

This keeps application reconciliation separate from platform reconciliation while preserving one GitOps control plane.

## Terraform and Argo CD Ownership

Terraform and Argo CD have intentionally separate responsibilities.

```text
Terraform
   |
   +--> AWS infrastructure
   +--> EKS
   +--> Argo CD installation
   +--> environment root Application

Argo CD
   |
   +--> namespaces
   +--> platform configuration
   +--> policies
   +--> application workloads
   +--> environment values
```

The same Kubernetes object is not managed by both systems.

That avoids competing control loops where Terraform and Argo CD continuously overwrite each other's changes.

The infrastructure side of this boundary is maintained in:

[`as-bank-infra`](https://github.com/sai-pillalamarri/as-bank-infra)

## Environment Behaviour

Dev and prod intentionally use different reconciliation behaviour.

### Dev

Dev child Applications use automatic synchronization.

```text
Git merge
   |
   v
Argo detects new revision
   |
   v
automatic sync
   |
   v
new desired state running
```

This provides fast feedback without requiring a manual deployment command.

### Prod

Production Applications do not automatically sync application changes.

Promotion requires an explicit reviewed Git change and controlled reconciliation.

This keeps the artifact promotion decision visible in Git rather than hiding it inside a deployment pipeline.

## Immutable Image Deployment

Application images are deployed by digest.

Example:

```yaml
image:
  repository: <ecr-repository>
  digest: sha256:...
```

A digest identifies the exact image content.

The same digest can therefore move through environments without rebuilding the image.

The delivery model is:

```text
build once
    |
    v
sha256 digest
    |
    +--> dev
    |
    +--> qa
    |
    +--> prod
```

This is different from using a mutable tag such as:

```text
latest
```

where the same tag can later point to different image content.

## Application Release to GitOps

The application release workflow publishes signed images to ECR and updates this repository through a pull request.

```text
Merge application code
        |
        v
GitHub Actions
        |
        +--> build image
        +--> scan image
        +--> generate SBOM
        +--> sign image
        +--> push to ECR
        |
        v
resolve image digest
        |
        v
GitOps pull request
        |
        v
manifest validation
        |
        v
merge
        |
        v
Argo CD reconciliation
```

Humans do not manually copy image digests into the cluster.

The Git commit records which artifact should be running.

## Workload Standards

The application workloads include Kubernetes operational controls such as:

- resource requests and limits
- startup probes
- readiness probes
- liveness probes
- non-root execution
- read-only root filesystems
- dropped Linux capabilities
- PodDisruptionBudgets
- HorizontalPodAutoscalers
- topology spread constraints
- dedicated ServiceAccounts
- default-deny NetworkPolicies

These controls are part of the desired state rather than changes made manually after deployment.

## Kubernetes Security

The GitOps configuration participates in several security layers.

### Kyverno

Kyverno policies enforce workload requirements at admission time.

Controls include:

- signed AS Bank images
- no `latest` image tags
- non-root containers
- read-only root filesystem
- resource requests and limits
- required labels
- no privileged containers
- no host namespaces
- no `hostPath`

An unsigned image was deliberately tested and rejected by the cluster admission path.

### Pod Security Admission

Application namespaces enforce Kubernetes restricted Pod Security standards.

A root container was deliberately tested and rejected.

### NetworkPolicies

Application namespaces use default-deny networking.

Explicit policies then allow only the communication paths the workloads need.

Verification included:

- DNS egress remained available
- arbitrary HTTPS egress was blocked
- unwanted cross-namespace ingress was blocked

These controls were tested as behaviour, not only committed as YAML.

## Secrets

Application secrets are not stored in this repository.

The delivery path is:

```text
AWS Secrets Manager
        |
        v
External Secrets Operator
        |
        v
Kubernetes Secret
        |
        v
Application workload
```

This repository contains the desired External Secrets configuration, but not the secret values themselves.

AWS access for the controller uses EKS Pod Identity rather than static AWS credentials.

## Helm

Application deployment uses shared Helm patterns rather than duplicating similar Kubernetes manifests for every service.

Environment differences are expressed through values.

The goal is:

```text
shared deployment pattern
        +
service values
        +
environment values
```

rather than:

```text
dev chart
prod chart
qa chart
```

with mostly duplicated YAML.

## Validation

Changes to this repository are validated through GitHub Actions before merge.

The validation workflow checks the desired state without deploying it.

That keeps the responsibilities clear:

```text
GitHub Actions
     |
     +--> validate

Argo CD
     |
     +--> deploy / reconcile
```

A successful CI job does not mean the pipeline has permission to change the cluster.

## GitOps Proof

The GitOps flow has been tested end to end.

A merged repository change advanced the Argo CD application to the new Git revision and rolled the workload without:

```text
kubectl apply
```

and without manually pressing Sync in Argo CD.

That proves the deployment path is:

```text
Git change
   |
   v
Argo reconciliation
   |
   v
running workload
```

rather than Git being used only as documentation for manual deployments.

## Related Repositories

### Infrastructure

[`as-bank-infra`](https://github.com/sai-pillalamarri/as-bank-infra)

Terraform, AWS networking, EKS, IAM, Karpenter, RDS, Cognito, environment lifecycle, and platform bootstrap.

### Application

[`as-bank-app`](https://github.com/sai-pillalamarri/as-bank-app)

Java/Spring Boot services and React frontend, including CI, security testing, image scanning, SBOM generation, signing, and release automation.

## Hands-On Areas

This repository provides practical work across:

```text
Argo CD
GitOps
Kubernetes
Helm
Kustomize
GitHub Actions
Kyverno
External Secrets
NetworkPolicy
Pod Security
HPA
PDB
immutable image promotion
environment configuration
deployment troubleshooting
```

The focus is not only on writing manifests.

The implementation includes building the reconciliation model, proving automatic deployment from Git, enforcing admission and network controls, integrating secrets with AWS identity, and troubleshooting the platform when those controls affect workloads.

## Project Note

AS Bank is a learning project using synthetic data.

It does not contain real customer, payment, or regulated banking data and is not presented as production banking experience.
