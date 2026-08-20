# Application Gateway Ingress Controller Plan

> **Status:** AGIC infrastructure created through the Azure portal; Kubernetes Ingress deployment
> remains manual. This document does not instruct the existing application workflow to replace or
> remove the current LoadBalancer Service.

## Goal

Expose `aks-static-website` through the existing classic Azure Application Gateway by using the
Application Gateway Ingress Controller (AGIC) AKS add-on and a Kubernetes `Ingress` resource.

Application Gateway for Containers, ALB Controller, and Gateway API are out of scope because the
portal enabled classic AGIC and created a classic `Standard_v2` Application Gateway.

## Current environment

Read-only discovery on August 19, 2026 found:

| Item | Current value |
|------|---------------|
| AKS cluster | `aks-workshop` |
| AKS resource group | `rg-aks-workshop` |
| AKS node resource group | `MC_rg-aks-workshop_aks-workshop_eastus` |
| Network plugin | Azure CNI Overlay |
| Application Gateway | `ingress-appgateway` |
| Application Gateway SKU | `Standard_v2`, capacity 2 |
| Application Gateway subnet | `ingress-appgateway-subnet` (`10.225.0.0/24`) |
| Subnet delegation | `Microsoft.Network/applicationGateways` |
| Public IP resource | `ingress-appgateway-appgwpip` |
| AGIC add-on | Enabled |
| AGIC managed identity | `ingressapplicationgateway-aks-workshop` |
| AGIC identity role | `Network Contributor` on the AKS node resource group |
| AGIC IngressClass | `azure-application-gateway` |
| Existing IngressClass | `nginx` |
| Existing website exposure | Kubernetes `LoadBalancer` Service |

At the last inspection, Application Gateway reported:

```text
Provisioning state: Updating
Operational state: Stopped
```

Wait for `provisioningState: Succeeded` and `operationalState: Running` before running the new
Ingress deployment workflow.

## What the portal already completed

The Azure portal:

1. Created `ingress-appgateway`.
2. Created its Standard public IP.
3. Created the dedicated `/24` Application Gateway subnet.
4. Enabled the AKS `ingress-appgw` add-on.
5. Created the AGIC managed identity.
6. Assigned network permissions to that identity.
7. Installed the AGIC controller pod.
8. Installed `IngressClass/azure-application-gateway`.

Do not enable Application Gateway for Containers or install ALB Controller in addition to this
setup. They are separate ingress products and are unnecessary for this demonstration.

## Target architecture

```text
Existing path (preserved)
Internet -> Azure Load Balancer -> LoadBalancer Service -> Nginx pods

New AGIC path
Internet -> ingress-appgateway -> AGIC-managed listener/rule/backend -> Service -> Nginx pods
```

Both paths remain available during the workshop. Keeping the existing LoadBalancer endpoint
provides a simple rollback and side-by-side comparison.

## Repository additions

### AGIC Ingress manifest

`k8s/agic/ingress.yaml` defines:

- Ingress class `azure-application-gateway`
- Root path routing to `Service/aks-static-website`
- Backend port 80
- Application Gateway health probe path `/`
- Accepted health status range `200-399`

The manifest is intentionally under `k8s/agic/`. The existing CD command:

```text
kubectl apply --filename k8s/
```

does not recurse into subdirectories, so normal application deployments do not automatically
create or modify the AGIC Ingress.

### Manual deployment workflow

`.github/workflows/deploy-agic-ingress.yml`:

1. Runs only through `workflow_dispatch`.
2. Authenticates with the existing GitHub OIDC identity.
3. Retrieves credentials for `aks-workshop`.
4. Confirms the AGIC controller deployment is ready.
5. Applies only `k8s/agic/`.
6. Waits for AGIC to publish an Ingress address.
7. Tests the website through that address.
8. Prints both Ingress and Service endpoints.

The workflow does not create, update, start, stop, or delete Application Gateway itself. Azure-side
gateway lifecycle remains controlled by the portal/AKS add-on.

## Ingress configuration

The planned manifest is:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: aks-static-website
  annotations:
    appgw.ingress.kubernetes.io/health-probe-path: /
    appgw.ingress.kubernetes.io/health-probe-status-codes: "200-399"
spec:
  ingressClassName: azure-application-gateway
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: aks-static-website
                port:
                  number: 80
```

The class selection prevents the existing NGINX ingress controller from claiming this Ingress.

## Prerequisites before running the workflow

### Application Gateway is ready

```powershell
az network application-gateway show `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --name ingress-appgateway `
  --query "{provisioningState:provisioningState,operationalState:operationalState}" `
  --output table
```

Expected:

```text
ProvisioningState    OperationalState
-------------------  ----------------
Succeeded            Running
```

### AGIC controller is ready

```powershell
kubectl get deployment ingress-appgw-deployment `
  --namespace kube-system
```

The ready replica count should match the desired count.

### Website is healthy

```powershell
kubectl get deployment aks-static-website
kubectl get service aks-static-website
kubectl get pods --selector app=aks-static-website
```

The Deployment should have two ready replicas and the existing LoadBalancer endpoint should still
serve the website.

## Deployment procedure

1. Open the repository's **Actions** page.
2. Select **Deploy AGIC Ingress**.
3. Choose **Run workflow** on `main`.
4. Follow the job through controller readiness, manifest application, address assignment, and HTTP
   verification.
5. Open the address printed by the workflow.
6. Confirm Home, About, and Contact pages work.
7. Confirm the existing Service public IP still works.

## How AGIC manages Application Gateway

AGIC watches Kubernetes Ingress resources assigned to `azure-application-gateway`. It translates
them into Application Gateway configuration, including:

- Listener
- Request-routing rule
- Backend address pool
- Backend HTTP settings
- Health probe

AGIC assumes ownership of the linked Application Gateway by default. Do not manually edit its
listeners, backend pools, routing rules, HTTP settings, or probes in the portal. Manual
configuration can be overwritten during reconciliation.

Use Kubernetes Ingress resources and AGIC annotations as the configuration source of truth.

## Validation

### Kubernetes

```powershell
kubectl get ingress aks-static-website --output wide
kubectl describe ingress aks-static-website
kubectl get endpointslice --selector kubernetes.io/service-name=aks-static-website
```

Confirm:

- The Ingress class is `azure-application-gateway`.
- An address is present.
- The backend resolves to `aks-static-website:80`.
- No warning events report permission or configuration failures.

### Application Gateway

```powershell
az network application-gateway show-backend-health `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --name ingress-appgateway `
  --output table
```

Confirm backend health is `Healthy`. If it is not, inspect the health probe response and network
reachability before modifying the Ingress.

### Functional

```powershell
$address = kubectl get ingress aks-static-website `
  --output jsonpath="{.status.loadBalancer.ingress[0].ip}"

curl.exe --fail "http://$address/"
curl.exe --fail "http://$address/about.html"
curl.exe --fail "http://$address/contact.html"
```

## Existing workflow and endpoint

The following remain unchanged:

- `.github/workflows/build-and-push.yml`
- `.github/workflows/deploy.yml`
- `k8s/service.yaml`
- Service type `LoadBalancer`
- Existing public Service endpoint

Application image releases continue through the existing CI/CD process. The separate AGIC workflow
controls only the optional Ingress resource.

## DNS, TLS, and WAF follow-up

The first iteration uses HTTP and the Application Gateway public IP.

A later workshop stage can:

1. Assign a DNS name to the static gateway public IP.
2. Add an HTTPS listener through Ingress TLS configuration or a gateway certificate.
3. Store certificates securely, preferably with an approved Key Vault integration.
4. Add `appgw.ingress.kubernetes.io/ssl-redirect: "true"`.
5. Upgrade or use `WAF_v2` if demonstrating Web Application Firewall.
6. Enable Application Gateway diagnostic logs.

These are intentionally excluded from the first ingress deployment.

## Troubleshooting

### Ingress address remains empty

- Confirm Application Gateway is `Running`.
- Confirm `ingress-appgw-deployment` is ready.
- Inspect `kubectl describe ingress aks-static-website`.
- Inspect AGIC controller logs.
- Confirm `spec.ingressClassName` uses the installed `azure-application-gateway` class.

### Backend health is unhealthy

- Confirm both Nginx pods are ready.
- Confirm Service port 80 resolves to container port 80.
- Confirm `/` returns a status in `200-399`.
- Confirm Application Gateway can reach the Azure CNI Overlay pod backends.
- Check network security groups and routes before changing application probes.

### NGINX processes the Ingress

Confirm:

```yaml
spec:
  ingressClassName: azure-application-gateway
```

Do not also set the legacy `kubernetes.io/ingress.class` annotation. This cluster validates that
the annotation value must exactly match `ingressClassName`, while AGIC's historical annotation
value uses a different controller-style name.

### AGIC overwrites portal changes

This is expected. AGIC owns the gateway configuration. Move desired routing behavior into the
Kubernetes Ingress and supported AGIC annotations.

## Rollback

Because the existing LoadBalancer Service remains:

1. Continue using the original Service public IP.
2. Delete only the optional Ingress:

   ```powershell
   kubectl delete `
     --filename k8s/agic/ingress.yaml
   ```

3. Confirm the LoadBalancer endpoint still works.

Do not disable the AGIC add-on or delete Application Gateway as part of routine application
rollback. Those are destructive infrastructure operations and require a separate approved cleanup
plan.

## References

- [Application Gateway Ingress Controller overview](https://learn.microsoft.com/azure/application-gateway/ingress-controller-overview)
- [Enable AGIC for an existing AKS cluster](https://learn.microsoft.com/azure/application-gateway/tutorial-ingress-controller-add-on-existing)
- [AGIC annotations](https://learn.microsoft.com/azure/application-gateway/ingress-controller-annotations)
