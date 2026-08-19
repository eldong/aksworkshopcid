# AKS Static Website CI/CD Demo

This project demonstrates how a push to GitHub can build a containerized static website, publish
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
Push to main
    |
    v
GitHub Actions: Build and Push
    |-- Authenticate to Azure with OIDC
    |-- Build the Nginx image
    `-- Push <acr>.azurecr.io/aks-static-website:<run-number>
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

Create a Microsoft Entra application or user-assigned managed identity, add a federated identity
credential for this repository, and use a subject that permits the `main` branch:

```text
repo:<github-owner>/<repository-name>:ref:refs/heads/main
```

The deployment workflow is triggered with `workflow_run`. Depending on the identity type and
federated credential configuration used by your organization, add a credential matching the
deployment workflow's token subject as well. Azure's federated credential setup tools show the
exact subject for the selected GitHub scenario.

For setup guidance, see [Use the Azure Login action with OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect).

## Required GitHub secrets

Create these repository secrets under **Settings > Secrets and variables > Actions**:

| Secret | Example | Purpose |
|--------|---------|---------|
| `AZURE_CLIENT_ID` | `00000000-...` | Client ID of the Entra application or managed identity trusted by GitHub |
| `AZURE_TENANT_ID` | `00000000-...` | Microsoft Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | `00000000-...` | Subscription containing ACR and AKS |
| `ACR_NAME` | `myregistry` | ACR resource name only, without `.azurecr.io` |
| `AKS_RESOURCE_GROUP` | `rg-aks-demo` | Resource group containing AKS |
| `AKS_CLUSTER_NAME` | `aks-demo` | Existing AKS cluster name |

`GITHUB_TOKEN` is created automatically for each workflow run and does not need to be configured.

## Required Azure permissions

Grant only the access needed by the workflow identity:

| Scope | Role or permission | Used by |
|-------|--------------------|---------|
| Existing ACR | `AcrPush` | CI pushes images |
| Existing AKS resource | `Azure Kubernetes Service Cluster User Role` | CD retrieves user credentials |
| AKS authorization layer | Permission to apply Deployments and Services | CD deploys workload resources |

The last permission depends on the cluster's authorization mode:

- **Azure RBAC-enabled AKS:** assign an appropriate AKS Azure RBAC role, such as `Azure Kubernetes
  Service RBAC Writer`, at the cluster or target namespace scope. Creating a public Service may
  require a role that permits Service updates.
- **Kubernetes RBAC:** bind the Entra identity to a Kubernetes Role or ClusterRole that can
  `get`, `list`, `watch`, `create`, `update`, and `patch` Deployments, ReplicaSets, Pods, and
  Services in the target namespace.

The AKS kubelet identity needs `AcrPull` on ACR. The assumption that AKS is already attached to ACR
means this permission should already exist.

## CI workflow: build and push

`.github/workflows/build-and-push.yml` runs on every push to `main`:

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
myregistry.azurecr.io/aks-static-website:42
```

Run numbers increase for each run of the CI workflow. The deployment uses this immutable tag
instead of `latest`, making it clear which build is running and preventing tag ambiguity.

## CD workflow: deploy

`.github/workflows/deploy.yml` starts when **Build and Push** completes on `main`. Its job-level
condition prevents deployment unless CI concluded successfully.

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
4. Push this project to the repository's `main` branch.
5. Open the repository's **Actions** tab and follow the **Build and Push** run.
6. After CI succeeds, follow the automatically started **Deploy to AKS** run.

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

## Troubleshooting

- **OIDC login fails:** verify the tenant, subscription, client ID, federated credential issuer,
  subject, and audience.
- **ACR push is denied:** confirm the workflow identity has `AcrPush` on the registry.
- **AKS credentials fail:** confirm the cluster name/resource group and the Cluster User role.
- **`kubectl apply` is forbidden:** configure Azure RBAC for Kubernetes or Kubernetes RBAC for the
  workflow identity.
- **Pods show `ImagePullBackOff`:** confirm AKS is attached to ACR and the image reference exists.
- **External IP remains pending:** inspect `kubectl describe service aks-static-website` and verify
  the cluster can create Azure load balancers and public IPs.
