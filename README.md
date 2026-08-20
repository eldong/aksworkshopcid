# AKS Static Website CI/CD Demo

This project demonstrates how GitHub Actions can build a containerized static website, publish
the image to an existing Azure Container Registry (ACR), and deploy it to an existing Azure
Kubernetes Service (AKS) cluster.

The sample is intentionally small and readable. It does not provision Azure infrastructure and
does not require application backend code.

## Repository structure

```text
.
|-- website/
|   |-- index.html
|   |-- about.html
|   |-- contact.html
|   `-- css/
|       `-- site.css
|-- k8s/
|   |-- deployment.yaml
|   `-- service.yaml
|-- .github/
|   `-- workflows/
|       |-- build-and-push.yml
|       `-- deploy.yml
|-- Dockerfile
|-- .dockerignore
`-- README.md
```

## Architecture overview

```text
Manual Build and Push run
    |
    v
GitHub Actions: Build and Push
    |-- Authenticate to Azure with OIDC
    |-- Build the Nginx image
    `-- Push aksworkshopedg.azurecr.io/aks-static-website:<run-number>
    |
    v
GitHub Actions: Deploy to AKS
    |-- Authenticate to Azure with OIDC
    |-- Retrieve credentials for the existing AKS cluster
    |-- Apply the Kubernetes manifests
    `-- Update the Deployment to the exact image built by CI
    |
    v
AKS Deployment (2 Nginx pods)
    |
    v
Public LoadBalancer Service on port 80
```

The Kubernetes Deployment runs two Nginx replicas. CPU and memory requests help the scheduler
place the pods, limits constrain resource consumption, and HTTP liveness/readiness probes allow
Kubernetes to monitor availability. A `LoadBalancer` Service exposes the website publicly.

## Verified workshop environment

This repository has been configured and tested with the following existing resources:

| Resource | Value |
|----------|-------|
| GitHub repository | `eldong/aksworkshopcid` |
| User-assigned managed identity | `github-aksworkshop-cicd` |
| Resource group | `rg-aks-workshop` |
| Azure Container Registry | `aksworkshopedg` |
| Azure Kubernetes Service cluster | `aks-workshop` |
| AKS authorization | Kubernetes RBAC with local cluster-user credentials |

The environment uses one user-assigned managed identity for both CI and CD to keep the workshop
simple. Separating build and deployment identities is recommended for a production environment.

## Prerequisites

- A GitHub repository whose default branch is `main`
- An existing ACR
- An existing AKS cluster
- AKS already attached to ACR so its kubelet identity can pull images
- Permission to configure a Microsoft Entra application or user-assigned managed identity for
  GitHub OIDC
- Azure CLI and Docker for optional local testing

## Configure Azure OIDC

Both workflows use OpenID Connect (OIDC). GitHub requests a short-lived token for each run, so no
long-lived Azure client secret is stored in GitHub.

This workshop uses the `github-aksworkshop-cicd` user-assigned managed identity. Its federated
identity credential trusts GitHub's token issuer and the `main` branch.

This GitHub organization uses Enterprise Managed Users (EMU), so the working subject includes the
immutable organization owner and repository IDs:

```text
repo:eldong@11573590/aksworkshopcid@1340112140:ref:refs/heads/main
```

Do not replace this with `repo:eldong/aksworkshopcid:ref:refs/heads/main` in this environment.
GitHub will present the EMU-specific subject, and Azure login will fail with `AADSTS700213` if no
federated credential matches it exactly. The credential uses:

| Claim | Value |
|-------|-------|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject | `repo:eldong@11573590/aksworkshopcid@1340112140:ref:refs/heads/main` |
| Audience | `api://AzureADTokenExchange` |

For setup guidance, see [Use the Azure Login action with OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect).

## Required GitHub secrets

Create these repository secrets under **Settings > Secrets and variables > Actions**:

| Secret | Example | Purpose |
|--------|---------|---------|
| `AZURE_CLIENT_ID` | `00000000-...` | Client ID of the Entra application or managed identity trusted by GitHub |
| `AZURE_TENANT_ID` | `00000000-...` | Microsoft Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | `00000000-...` | Subscription containing ACR and AKS |
| `ACR_NAME` | `aksworkshopedg` | ACR resource name only, without `.azurecr.io` |
| `AKS_RESOURCE_GROUP` | `rg-aks-workshop` | Resource group containing AKS |
| `AKS_CLUSTER_NAME` | `aks-workshop` | Existing AKS cluster name |

`GITHUB_TOKEN` is created automatically for each workflow run and does not need to be configured.
All six repository secrets above are configured in `eldong/aksworkshopcid`.

## Required Azure permissions

Grant only the access needed by the workflow identity:

| Scope | Role or permission | Used by |
|-------|--------------------|---------|
| `aksworkshopedg` ACR | `AcrPush` | CI pushes and pulls images |
| `aks-workshop` AKS resource | `Azure Kubernetes Service Cluster User Role` | CD retrieves cluster-user credentials |

The workshop cluster has Kubernetes RBAC enabled, but it is not integrated with Microsoft Entra
and has local accounts enabled. Its cluster-user credential was verified with `kubectl auth can-i`
and can create and patch Deployments and Services. Therefore, this environment does not require an
additional `Azure Kubernetes Service RBAC Writer` assignment for the GitHub identity.

For a different cluster, inspect its authorization mode instead of copying these assignments
blindly. An Entra-integrated, Azure RBAC-enabled cluster generally also requires an appropriate
role such as `Azure Kubernetes Service RBAC Writer` at the cluster or namespace scope.

The AKS kubelet identity needs `AcrPull` on ACR. The assumption that AKS is already attached to ACR
means this permission should already exist.

## CI workflow: build and push

`.github/workflows/build-and-push.yml` runs manually through `workflow_dispatch`. The push trigger
is included as commented YAML so it can be enabled later:

1. Checks out the repository.
2. Authenticates to Azure through OIDC.
3. Signs Docker in to ACR with `az acr login`.
4. Builds the image from the root `Dockerfile`.
5. Pushes the uniquely tagged image to ACR.
6. Uploads a small artifact containing the full image reference.

The image name is:

```text
<ACR_NAME>.azurecr.io/aks-static-website:<GITHUB_RUN_NUMBER>
```

For example, CI run 42 pushes:

```text
aksworkshopedg.azurecr.io/aks-static-website:42
```

Run numbers increase for each run of the CI workflow. The deployment uses this immutable tag
instead of `latest`, making it clear which build is running and preventing tag ambiguity.

## CD workflow: deploy

`.github/workflows/deploy.yml` starts when **Build and Push** completes on `main`, or manually
through `workflow_dispatch`. Its job-level condition prevents automatic deployment unless CI
concluded successfully. A manual run requires the ACR image tag to deploy, typically the run number
from a completed **Build and Push** workflow.

The workflow:

1. Checks out the commit that triggered CI.
2. Downloads the exact image reference recorded by CI.
3. Authenticates to Azure through OIDC.
4. Runs `az aks get-credentials` for the existing cluster.
5. Runs `kubectl apply -f k8s/` to create or update the Deployment and Service.
6. Runs `kubectl set image` to replace the manifest placeholder with the exact immutable image.
7. Waits up to five minutes for the rollout to finish.
8. Prints the public Service information.

The placeholder in `k8s/deployment.yaml` is safe to leave as-is because the CD workflow replaces it
during every deployment. For manual deployment, replace `YOUR_ACR_NAME` and the image tag first.

## Run the website locally

Build and run the container:

```bash
docker build -t aks-static-website:local .
docker run --rm -p 8080:80 aks-static-website:local
```

Open <http://localhost:8080>.

## Deploy through GitHub Actions

1. Create the required GitHub secrets.
2. Configure the GitHub OIDC federated identity and Azure role assignments.
3. Confirm the AKS cluster is attached to ACR.
4. Open the repository's **Actions** tab, select **Build and Push**, and choose **Run workflow**.
5. Follow the build run until it completes successfully.
6. Follow the automatically started **Deploy to AKS** run, or run it manually and enter the CI run
   number as `image_tag`.

## Test after deployment

Wait for Azure to assign an external IP:

```bash
kubectl get service aks-static-website --watch
```

When `EXTERNAL-IP` changes from `<pending>` to an address, open:

```text
http://<EXTERNAL-IP>
```

Check workload health and the deployed image:

```bash
kubectl get deployment aks-static-website
kubectl get pods -l app=aks-static-website
kubectl get deployment aks-static-website \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

The Deployment should report two ready replicas, both pods should be `Running`, and the image
should end with the GitHub CI run number shown in the successful **Build and Push** workflow.

## Verified deployment

The complete pipeline was tested successfully on August 19, 2026:

- [Build and Push run 32315497739](https://github.com/eldong/aksworkshopcid/actions/runs/32315497739)
  authenticated with OIDC, built the Nginx image, and pushed it to ACR.
- [Deploy to AKS run 32315527791](https://github.com/eldong/aksworkshopcid/actions/runs/32315527791)
  retrieved AKS credentials, applied the manifests, updated the image, and completed the rollout.

## Troubleshooting

- **OIDC login fails:** verify the tenant, subscription, client ID, federated credential issuer,
  subject, and audience. In this EMU organization, confirm that the subject contains the immutable
  owner and repository IDs shown above.
- **ACR push is denied:** confirm the workflow identity has `AcrPush` on the registry.
- **AKS credentials fail:** confirm the cluster name/resource group and the Cluster User role.
- **`kubectl apply` is forbidden:** configure Azure RBAC for Kubernetes or Kubernetes RBAC for the
  workflow identity.
- **Pods show `ImagePullBackOff`:** confirm AKS is attached to ACR and the image reference exists.
- **External IP remains pending:** inspect `kubectl describe service aks-static-website` and verify
  the cluster can create Azure load balancers and public IPs.
- **Node.js 20 deprecation warning:** the referenced actions currently target Node.js 20, but
  GitHub-hosted runners force them to execute on Node.js 24. This warning did not prevent either
  verified workflow from succeeding.
