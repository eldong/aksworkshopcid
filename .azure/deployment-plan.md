# Azure Deployment Plan

> **Status:** Ready for Validation

Generated: 2026-08-19

---

## 1. Project Overview

**Goal:** Create a complete, student-friendly GitHub project demonstrating CI/CD of a containerized static website to an existing Azure Kubernetes Service cluster through Azure Container Registry.

**Path:** New Project

**Scope boundary:** Generate application code, container configuration, Kubernetes manifests, GitHub Actions workflows, and documentation. Do not provision or deploy Azure resources.

---

## 2. Requirements

| Attribute | Value |
|-----------|-------|
| Classification | Development / educational demo |
| Scale | Small; two application replicas |
| Budget | Cost-optimized; uses existing ACR and AKS resources |
| Subscription | Runtime workflow input through `AZURE_SUBSCRIPTION_ID`; no subscription access is required while generating the project |
| Location | Determined by the existing resources; no region-specific resource will be created |

---

## 3. Components Detected

The workspace was empty before this plan was created.

| Component | Type | Technology | Path |
|-----------|------|------------|------|
| Static website | Frontend | HTML, CSS, Bootstrap | `website/` |
| Web container | Container | Nginx Alpine | `Dockerfile` |
| Kubernetes workload | Deployment and public service | Kubernetes YAML | `k8s/` |
| CI pipeline | Container build and publish | GitHub Actions, Docker, Azure OIDC | `.github/workflows/build-and-push.yml` |
| CD pipeline | AKS deployment | GitHub Actions, Azure OIDC, kubectl | `.github/workflows/deploy.yml` |

---

## 4. Recipe Selection

**Selected:** AZCLI / custom GitHub Actions pipeline

**Rationale:**

- The target is an existing AKS cluster and ACR.
- The requested deployment mechanism is GitHub Actions rather than `azd`.
- Azure CLI is required only for OIDC login and obtaining AKS credentials.
- Terraform, Bicep, and new Azure infrastructure are explicitly out of scope.

---

## 5. Architecture

**Stack:** Containers

```text
Developer push to main
        |
        v
GitHub Actions CI --OIDC--> Azure
        |
        +--> Build Nginx image
        +--> Push <acr>.azurecr.io/aks-static-website:<run_number>
        |
        v
Successful CI triggers CD --OIDC--> Azure
        |
        +--> Get existing AKS credentials
        +--> Apply manifests and set immutable image tag
        v
AKS Deployment (2 pods) --> LoadBalancer Service --> Public website
```

### Service Mapping

| Component | Azure Service | SKU |
|-----------|---------------|-----|
| Container registry | Existing Azure Container Registry | Existing |
| Container orchestration | Existing Azure Kubernetes Service | Existing |
| Public endpoint | AKS `LoadBalancer` Service | Existing cluster integration |

### Supporting Services

No additional Azure services are created. AKS observability, logging, networking, and identity remain properties of the existing cluster.

---

## 6. Provisioning Limit Checklist

No Azure resources are provisioned by this project. The CI workflow pushes one image tag to the existing ACR, and the CD workflow creates or updates namespaced Kubernetes objects on the existing AKS cluster.

| Resource Type | Number to Deploy | Total After Deployment | Limit/Quota | Notes |
|---------------|------------------|------------------------|-------------|-------|
| Azure ARM resources | 0 | Unchanged | Not applicable | Existing ACR and AKS are prerequisites |
| Kubernetes Deployment | 1 | 1 workload | Cluster-dependent | Two small Nginx replicas |
| Kubernetes LoadBalancer Service | 1 | 1 service | Cluster/subscription-dependent | Uses the existing AKS load balancer integration |

**Status:** No Azure resource provisioning; subscription quota validation is outside project-generation scope.

---

## 7. Execution Checklist

### Phase 1: Planning

- [x] Analyze workspace
- [x] Gather requirements
- [x] Record Azure context as runtime configuration for existing resources
- [x] Prepare resource inventory
- [x] Determine quota validation is not applicable because no Azure resources are provisioned
- [x] Scan codebase
- [x] Select recipe
- [x] Plan architecture
- [x] User approved this plan

### Phase 2: Execution

- [x] Generate three-page Bootstrap website
- [x] Generate Nginx `Dockerfile` and `.dockerignore`
- [x] Generate commented Kubernetes Deployment and LoadBalancer Service manifests
- [x] Generate commented OIDC-based CI and CD workflows
- [x] Generate comprehensive README
- [x] Validate required files, HTML navigation links, YAML syntax, Docker build configuration, and workflow data flow
- [x] Update plan status to `Ready for Validation`

### Phase 3: Validation

- [x] Invoke `azure-validate`
- [x] Azure CLI installation: not required for offline project generation
- [x] Authentication: deferred to GitHub Actions OIDC at runtime
- [x] Bicep compilation: not applicable; no Bicep is generated
- [x] ARM template validation: not applicable; no ARM resources are provisioned
- [x] What-if preview: not applicable; no ARM deployment is performed
- [ ] Docker build: blocked locally because the Docker Desktop Linux engine is not running; CI performs this build
- [x] Azure policy validation: not applicable; no Azure resources are provisioned
- [x] Static role verification: required least-privilege runtime roles are documented in `README.md`
- [x] Kubernetes client-side dry run
- [x] Record validation proof
- [ ] Update plan status to `Validated`

### Phase 4: Deployment

Not requested. Deployment will occur later through GitHub Actions after repository configuration.

---

## 8. Validation Proof

| Check | Command Run | Result | Timestamp |
|-------|-------------|--------|-----------|
| Required project files | PowerShell `Test-Path` checks | Pass: 11 required files present | 2026-08-19 |
| Website navigation | PowerShell link checks across all HTML pages | Pass: all three pages and shared stylesheet linked | 2026-08-19 |
| YAML syntax | Python `yaml.safe_load_all` for Kubernetes and workflow YAML | Pass: 4 files parsed | 2026-08-19 |
| Container build | `docker build --quiet --tag aks-static-website:validation .` | Environment blocked: Docker Desktop Linux engine is not running | 2026-08-19 |
| Project requirements | PowerShell contract assertions | Pass: 16 CI, CD, Kubernetes, and Dockerfile checks | 2026-08-19 |
| Kubernetes manifests | `kubectl apply --dry-run=client --validate=false --filename k8s\` | Pass: Deployment and Service accepted | 2026-08-19 |

**Validated by:** `azure-validate`; formal completion is pending a Docker build in an environment with a running engine

---

## 9. Files to Generate

| File | Purpose | Status |
|------|---------|--------|
| `.azure/deployment-plan.md` | Preparation and validation source of truth | Complete |
| `website/index.html` | Home page | Complete |
| `website/about.html` | About page | Complete |
| `website/contact.html` | Contact page | Complete |
| `website/css/site.css` | Shared site styling | Complete |
| `k8s/deployment.yaml` | Two-replica Nginx workload with resources and probes | Complete |
| `k8s/service.yaml` | Public LoadBalancer service | Complete |
| `.github/workflows/build-and-push.yml` | OIDC CI image build and ACR push | Complete |
| `.github/workflows/deploy.yml` | OIDC CD deployment to AKS | Complete |
| `Dockerfile` | Nginx container image | Complete |
| `.dockerignore` | Docker build exclusions | Complete |
| `README.md` | Setup, architecture, permissions, workflows, and testing guide | Complete |

---

## 10. Planned Implementation Decisions

- Use `nginx:1.27-alpine` and copy the static website to `/usr/share/nginx/html`.
- Use a placeholder image in the base manifest: `YOUR_ACR_NAME.azurecr.io/aks-static-website:latest`.
- Tag each CI image with `${{ github.run_number }}`.
- Pass the exact immutable image reference from CI to CD as a workflow artifact, avoiding ambiguity between workflow run numbers.
- Trigger CD with `workflow_run` only when the CI workflow completes successfully on `main`.
- Use GitHub repository secrets for Azure tenant, subscription, client, ACR, AKS resource group, and AKS cluster identifiers.
- Grant the OIDC identity `AcrPush` on ACR and sufficient AKS access to retrieve credentials and apply namespaced workload resources.
- Use `kubectl apply` followed by `kubectl set image` and `kubectl rollout status`.
- Add explanatory comments to every YAML file while keeping all files directly usable after replacing configuration values.

---

## 11. Next Step

Push the project to a GitHub repository after configuring the documented secrets, OIDC trust, and Azure permissions. The GitHub-hosted CI runner will perform the container build.
