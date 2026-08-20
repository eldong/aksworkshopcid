# Application Gateway for Containers Plan

> **Status:** Planning only. No Azure resources, AKS features, Kubernetes resources, DNS records,
> or workflow changes described here have been created or applied.

## Goal

Expose `aks-static-website` through **Azure Application Gateway for Containers** using the
AKS-managed ALB Controller add-on and Kubernetes Gateway API.

Classic Application Gateway and Application Gateway Ingress Controller (AGIC) are intentionally
out of scope. This plan uses Microsoft's newer Kubernetes-focused ingress platform.

## Why this approach fits

- Application Gateway for Containers is designed specifically for Kubernetes.
- Microsoft recommends considering it for new Kubernetes ingress implementations.
- The cluster uses supported Azure CNI Overlay networking.
- The cluster is in the supported `eastus` region.
- A correctly sized and delegated subnet already exists.
- Gateway API provides a clearer modern routing model than legacy Ingress annotations.
- The platform supports HTTP/HTTPS, WAF, traffic splitting, retries, rewrites, gRPC, and TLS.

## Current environment

Read-only discovery on August 19, 2026 found:

| Item | Current value |
|------|---------------|
| AKS cluster | `aks-workshop` |
| AKS resource group | `rg-aks-workshop` |
| Region | `eastus` |
| Kubernetes version | `1.35.6` |
| Network plugin | Azure CNI Overlay |
| Pod CIDR | `10.244.0.0/16` |
| AKS node resource group | `MC_rg-aks-workshop_aks-workshop_eastus` |
| AKS virtual network | `aks-vnet-38181049` |
| ALB subnet | `aks-appgateway` (`10.238.0.0/24`) |
| ALB subnet delegation | `Microsoft.ServiceNetworking/trafficControllers` |
| Current ingress controller | NGINX |
| ALB Controller | Not currently detected |
| Existing Application Gateway for Containers | None detected |

The existing `aks-appgateway` subnet meets the documented minimum of 250 available addresses and
has the required delegation. No new subnet should be created unless revalidation finds the subnet
unavailable or incorrectly configured.

## Proposed architecture

```text
Internet
   |
   v
Application Gateway for Containers public frontend
   |
   | Azure-managed Layer 7 data plane
   v
Association through aks-appgateway subnet
   |
   v
Gateway API Gateway + HTTPRoute
   |
   v
aks-static-website ClusterIP Service
   |
   v
Two Nginx website pods
```

ALB Controller runs in AKS and translates these Kubernetes resources into Azure configuration:

- `ApplicationLoadBalancer`
- `Gateway`
- `HTTPRoute`

## Management model

Use the **managed by ALB Controller** strategy for this workshop:

- AKS manages installation and upgrades of ALB Controller.
- A Kubernetes `ApplicationLoadBalancer` resource causes ALB Controller to create the Azure
  Application Gateway for Containers resource and association.
- Kubernetes resources control the Azure resource lifecycle.
- The workshop demonstrates a Kubernetes-native workflow without requiring separate Terraform or
  Bicep.

The bring-your-own Azure resource strategy is more appropriate when a platform team needs explicit
Azure-side lifecycle control. It is unnecessary for this demonstration.

## Planned Azure and AKS changes

| Change | Purpose |
|--------|---------|
| Register required Azure providers and preview features if needed | Enable the managed add-ons |
| Enable OIDC issuer and AKS Workload Identity | Required by the ALB Controller add-on |
| Enable AKS Gateway API add-on | Install supported Gateway API resources |
| Enable Application Load Balancer add-on | Install and manage ALB Controller |
| Use existing `aks-appgateway` subnet | Connect the managed data plane to AKS |
| Add ALB identity subnet permission if required | Allow the association to join the subnet |

The add-on creates a managed identity named:

```text
applicationloadbalancer-aks-workshop
```

Microsoft documents that the add-on normally assigns this identity `Network Contributor`,
`AppGW for Containers Configuration Manager`, and `Reader` in the AKS node resource group. These
assignments must be verified after enablement rather than duplicated blindly.

The existing GitHub identity, `github-aksworkshop-cicd`, should not receive Azure network or
Application Gateway roles. It only needs enough Kubernetes authorization to apply the planned
Gateway API manifests.

## Implementation phases

The following commands are examples for a future implementation. They have not been run.

### Phase 1: Revalidate prerequisites

Confirm:

1. The active subscription and tenant are correct.
2. `eastus` still supports Application Gateway for Containers.
3. AKS remains on a supported Kubernetes version.
4. The cluster still uses Azure CNI or Azure CNI Overlay.
5. `aks-appgateway` remains `/24`, empty, and delegated only to
   `Microsoft.ServiceNetworking/trafficControllers`.
6. No existing Application Gateway for Containers deployment owns the subnet.
7. Required Azure resource providers and features are registered.

Example checks:

```powershell
az account show --output table

az aks show `
  --resource-group rg-aks-workshop `
  --name aks-workshop `
  --query "{location:location,kubernetesVersion:kubernetesVersion,networkProfile:networkProfile,oidcIssuerProfile:oidcIssuerProfile,securityProfile:securityProfile,ingressProfile:ingressProfile}" `
  --output json

az network vnet subnet show `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --vnet-name aks-vnet-38181049 `
  --name aks-appgateway `
  --output json
```

### Phase 2: Register required capabilities

Current Microsoft add-on guidance calls for these providers, CLI extensions, and preview features:

```powershell
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.NetworkFunction
az provider register --namespace Microsoft.ServiceNetworking

az extension add --name alb
az extension add --name aks-preview

az feature register `
  --namespace Microsoft.ContainerService `
  --name ManagedGatewayAPIPreview

az feature register `
  --namespace Microsoft.ContainerService `
  --name ApplicationLoadBalancerPreview
```

Feature registration can take time. Wait until each feature reports `Registered` before enabling
the add-ons. Re-register the `Microsoft.ContainerService` provider if Azure requires it after
feature registration.

Because preview requirements can change, recheck the current Microsoft documentation immediately
before implementation.

### Phase 3: Enable OIDC and Workload Identity

ALB Controller requires AKS Workload Identity:

```powershell
az aks update `
  --resource-group rg-aks-workshop `
  --name aks-workshop `
  --enable-oidc-issuer `
  --enable-workload-identity
```

This changes cluster configuration but does not require recreating the cluster.

Validate:

```powershell
az aks show `
  --resource-group rg-aks-workshop `
  --name aks-workshop `
  --query "{oidc:oidcIssuerProfile.enabled,workloadIdentity:securityProfile.workloadIdentity.enabled}" `
  --output json
```

### Phase 4: Enable Gateway API and ALB Controller

Enable both managed add-ons together:

```powershell
az aks update `
  --resource-group rg-aks-workshop `
  --name aks-workshop `
  --enable-gateway-api `
  --enable-application-load-balancer
```

Application Gateway for Containers requires the AKS Gateway API add-on to avoid conflicts with
other Gateway API installations.

Validate:

```powershell
kubectl get pods --namespace kube-system
kubectl get gatewayclass azure-alb-external --output yaml
```

Expected results:

- Two `alb-controller` pods are ready.
- `GatewayClass/azure-alb-external` exists.
- Its controller is `alb.networking.azure.io/alb-controller`.
- The GatewayClass reports an accepted/valid condition.

### Phase 5: Verify the ALB managed identity and roles

Find the add-on identity:

```powershell
az identity show `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --name applicationloadbalancer-aks-workshop `
  --output json
```

Verify its effective assignments include the required configuration-manager and networking access.
If the add-on did not grant subnet join permission at the necessary scope, assign `Network
Contributor` to the identity on the existing subnet only:

```powershell
$principalId = az identity show `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --name applicationloadbalancer-aks-workshop `
  --query principalId `
  --output tsv

$subnetId = az network vnet subnet show `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --vnet-name aks-vnet-38181049 `
  --name aks-appgateway `
  --query id `
  --output tsv

az role assignment create `
  --assignee-object-id $principalId `
  --assignee-principal-type ServicePrincipal `
  --role "Network Contributor" `
  --scope $subnetId
```

Do not create this assignment unless validation shows it is needed.

### Phase 6: Add ApplicationLoadBalancer

Add `k8s/alb-infrastructure.yaml`:

```yaml
# ALB Controller creates and manages Application Gateway for Containers from this resource.
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: aks-workshop-alb
  namespace: default
spec:
  associations:
    # Replace this placeholder with the verified full subnet resource ID.
    - /subscriptions/<subscription-id>/resourceGroups/MC_rg-aks-workshop_aks-workshop_eastus/providers/Microsoft.Network/virtualNetworks/aks-vnet-38181049/subnets/aks-appgateway
```

The full subnet ID is not a secret, but hardcoding the subscription ID makes the manifest specific
to one Azure environment. For this workshop repository, that is acceptable if clearly documented.
An alternative is to template the value during CD.

Provisioning can take several minutes. Watch status:

```powershell
kubectl get applicationloadbalancer aks-workshop-alb `
  --namespace default `
  --output yaml `
  --watch
```

Continue only after the resource reports accepted and ready/programmed conditions.

### Phase 7: Add Gateway

Add `k8s/gateway.yaml`:

```yaml
# Gateway defines the public HTTP listener managed by Application Gateway for Containers.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: aks-static-website
  namespace: default
  annotations:
    alb.networking.azure.io/alb-namespace: default
    alb.networking.azure.io/alb-name: aks-workshop-alb
spec:
  gatewayClassName: azure-alb-external
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

The annotation names must be rechecked against the installed ALB Controller version before
implementation because the add-on is evolving.

### Phase 8: Add HTTPRoute

Add `k8s/http-route.yaml`:

```yaml
# Route all HTTP paths from the public Gateway to the website Service.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: aks-static-website
  namespace: default
spec:
  parentRefs:
    - name: aks-static-website
      sectionName: http
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: aks-static-website
          port: 80
```

The existing NGINX ingress controller does not process Gateway API resources associated with
`azure-alb-external`, so both controllers can coexist during migration.

### Phase 9: Stage the Service transition

Keep the existing `LoadBalancer` Service while validating the new path:

```text
Existing: Internet -> Azure Load Balancer -> Service -> pods
New:      Internet -> Application Gateway for Containers -> HTTPRoute -> Service -> pods
```

After the new endpoint works:

1. Change `k8s/service.yaml` from `LoadBalancer` to `ClusterIP`.
2. Deploy the change.
3. Confirm the old Service public IP is released.
4. Update the main README architecture and testing instructions.

Do not remove the existing endpoint before the Application Gateway for Containers frontend is
healthy and tested.

### Phase 10: CI/CD integration

The current CD workflow runs:

```text
kubectl apply --filename k8s/
```

Therefore, it will automatically apply the three new manifests once they are committed. However,
the first provisioning should be staged:

1. Enable and validate the managed add-ons separately.
2. Apply `alb-infrastructure.yaml` and wait for the Azure resource to become ready.
3. Apply `gateway.yaml` and `http-route.yaml`.
4. Test the new endpoint.
5. Only then include the manifests in routine CD.

This prevents a normal application deployment from hiding infrastructure provisioning failures.

The GitHub deployment credential must be checked for permission to create:

- `ApplicationLoadBalancer`
- `Gateway`
- `HTTPRoute`

If the current cluster-user credential lacks any of these permissions, update Kubernetes
authorization narrowly rather than granting Azure subscription-level roles.

## DNS, TLS, and WAF

For the first demonstration, use the generated public frontend hostname directly over HTTP.

For a production-style follow-up:

1. Choose a DNS hostname.
2. Point DNS to the Application Gateway for Containers frontend.
3. Store or reference an appropriate TLS certificate.
4. Add an HTTPS listener on port 443.
5. Attach TLS configuration to the Gateway.
6. Redirect HTTP to HTTPS.
7. Add and test an Application Gateway for Containers WAF security policy.
8. Validate certificate renewal and WAF logs.

TLS and WAF should be separate workshop stages so the initial routing concepts remain clear.

## Validation checklist

### Azure and add-ons

- [ ] Required providers and features report `Registered`.
- [ ] OIDC issuer and AKS Workload Identity are enabled.
- [ ] Gateway API and Application Load Balancer add-ons are enabled.
- [ ] Two ALB Controller pods are ready.
- [ ] `GatewayClass/azure-alb-external` is valid.
- [ ] Add-on managed identity and role assignments exist at minimal scopes.
- [ ] Existing `aks-appgateway` subnet remains delegated correctly.

### Kubernetes and Azure resource lifecycle

- [ ] `ApplicationLoadBalancer/aks-workshop-alb` is accepted and ready.
- [ ] The Application Gateway for Containers resource and association exist in Azure.
- [ ] `Gateway/aks-static-website` is accepted and programmed.
- [ ] `HTTPRoute/aks-static-website` is accepted by its parent.
- [ ] Backend references resolve to the website Service.
- [ ] Both Nginx pods remain ready.

### Functional

- [ ] The generated frontend hostname resolves.
- [ ] Home, About, and Contact pages return HTTP 200.
- [ ] A pod rollout completes without losing the frontend.
- [ ] The existing LoadBalancer endpoint remains available until cutover.
- [ ] After cutover, the Service works as `ClusterIP`.

Useful commands:

```powershell
kubectl get applicationloadbalancer --all-namespaces
kubectl get gatewayclass
kubectl get gateway --all-namespaces
kubectl get httproute --all-namespaces
kubectl describe gateway aks-static-website
kubectl describe httproute aks-static-website
```

## Observability

Configure Application Gateway for Containers diagnostic settings to an approved Log Analytics
workspace. Capture access and WAF logs if those categories are available for the chosen setup.

Also monitor:

- ALB Controller pod logs and restarts
- Gateway and HTTPRoute status conditions
- ApplicationLoadBalancer provisioning conditions
- Backend health
- AKS pod readiness and rollout status

## Rollback

The staged approach keeps the current public Service available.

If the new route fails:

1. Keep or restore `service.yaml` as `type: LoadBalancer`.
2. Remove `HTTPRoute/aks-static-website`.
3. Remove `Gateway/aks-static-website`.
4. Confirm the original public endpoint still serves the application.
5. Remove `ApplicationLoadBalancer/aks-workshop-alb` only after confirming it is not shared.
6. Disable the ALB and Gateway API add-ons only after all dependent resources are removed.
7. Disable Workload Identity/OIDC only if no other workloads use them and the impact has been
   reviewed.
8. Preserve the `aks-appgateway` subnet unless a separate approved cleanup explicitly removes it.

Every deletion and add-on disablement is destructive and must be reviewed separately before
execution.

## Cost considerations

Application Gateway for Containers introduces Azure charges beyond the current Kubernetes
LoadBalancer Service. Review current pricing for:

- Application Gateway for Containers resource usage
- Capacity/data processing
- WAF, if enabled
- Diagnostic log ingestion and retention
- Public data transfer

Delete unused workshop resources after the demonstration only through an approved cleanup plan.

## References

- [Application Gateway for Containers overview](https://learn.microsoft.com/azure/application-gateway/for-containers/overview)
- [Deploy ALB Controller with the AKS add-on](https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon)
- [Create Application Gateway for Containers managed by ALB Controller](https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-create-application-gateway-for-containers-managed-by-alb-controller)
