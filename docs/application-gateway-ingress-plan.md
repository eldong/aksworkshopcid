# Application Gateway Ingress Plan

> **Status:** Planning only. No Azure resources, AKS add-ons, Kubernetes objects, DNS records, or
> workflow changes described in this document have been created or applied.

## Goal

Expose the existing `aks-static-website` workload through Azure Application Gateway and use a
Kubernetes `Ingress` resource to demonstrate Layer 7 routing.

This plan focuses on **classic Azure Application Gateway with the Application Gateway Ingress
Controller (AGIC) AKS add-on** because that is the clearest way to demonstrate Application Gateway
as a Kubernetes ingress controller.

Microsoft recommends considering the newer **Application Gateway for Containers** for new
Kubernetes ingress implementations. That alternative is described later in this document.

## Current environment

The following values were discovered through read-only Azure and Kubernetes queries on
August 19, 2026:

| Item | Current value |
|------|---------------|
| AKS cluster | `aks-workshop` |
| AKS resource group | `rg-aks-workshop` |
| Region | `eastus` |
| Kubernetes version | `1.35.6` |
| Network plugin | Azure CNI Overlay |
| Pod CIDR | `10.244.0.0/16` |
| AKS virtual network | `aks-vnet-38181049` |
| AKS virtual network address space | `10.224.0.0/12` |
| AKS node subnet | `aks-subnet` (`10.224.0.0/16`) |
| Existing gateway-named subnet | `aks-appgateway` (`10.238.0.0/24`) |
| Current ingress class | `nginx` (`k8s.io/ingress-nginx`) |
| Existing Application Gateway | None |
| AGIC add-on | Not enabled |
| GitHub deployment identity | `github-aksworkshop-cicd` |

The existing deployment identity can create Kubernetes Ingress resources. No additional Azure
role is expected for the GitHub identity because AGIC—not the GitHub workflow—configures
Application Gateway.

## Important subnet finding

The existing `aks-appgateway` subnet is delegated to:

```text
Microsoft.ServiceNetworking/trafficControllers
```

That delegation is used by **Application Gateway for Containers**. A classic Application Gateway
requires a dedicated subnet that contains only Application Gateway resources and is not delegated
to the Application Gateway for Containers traffic-controller service.

Do not remove the existing delegation merely to reuse the subnet. Removing it would discard the
cluster's existing readiness for Application Gateway for Containers and would introduce an
unnecessary destructive change.

For the classic AGIC demonstration, create a separate subnet. A proposed unused range is:

```text
Name:   snet-appgw-agic
CIDR:   10.237.0.0/24
VNet:   aks-vnet-38181049
VNet RG: MC_rg-aks-workshop_aks-workshop_eastus
```

The range must be checked again immediately before implementation in case the virtual network has
changed. A `/24` is recommended for Application Gateway v2 autoscaling and maintenance capacity.

## Proposed architecture

```text
Internet
   |
   v
Static Standard public IP
   |
   v
Azure Application Gateway Standard_v2
   |
   |  AGIC translates Kubernetes Ingress configuration
   v
AKS pod IPs through Azure CNI Overlay
   |
   v
aks-static-website Service
   |
   v
Two Nginx website pods
```

AGIC watches Kubernetes Ingress resources annotated with:

```yaml
kubernetes.io/ingress.class: azure/application-gateway
```

It then creates and maintains the corresponding Application Gateway listener, routing rule,
backend pool, HTTP settings, and health probe.

## Proposed Azure resources

| Resource | Proposed name | Notes |
|----------|---------------|-------|
| Application Gateway subnet | `snet-appgw-agic` | New `10.237.0.0/24` subnet in the AKS VNet |
| Public IP | `pip-agw-aks-workshop` | Standard SKU with static allocation |
| Application Gateway | `agw-aks-workshop` | `Standard_v2` for the basic workshop |
| AGIC managed identity | Created by AKS add-on | Typically named `ingressapplicationgateway-aks-workshop` |

Use `WAF_v2` instead of `Standard_v2` if demonstrating managed WAF policies is part of the
workshop. WAF adds security capabilities and additional cost/complexity, so `Standard_v2` is the
recommended first iteration.

## Why the gateway must use the AKS virtual network

The cluster uses Azure CNI Overlay. Current Microsoft guidance requires Application Gateway and an
Azure CNI Overlay AKS cluster to be in the same virtual network for the AGIC scenario.

This means the new subnet must be added to the AKS virtual network in the AKS-managed node resource
group. That change should be made carefully: do not alter or delete existing AKS-managed subnets,
route tables, public IPs, or load balancer resources.

## Implementation phases

The following commands are examples for a future implementation. They are intentionally not run
as part of this plan.

### Phase 1: Revalidate the environment

Before making changes:

1. Confirm the active Azure subscription and tenant.
2. Confirm that `10.237.0.0/24` is still unused.
3. Confirm that no Application Gateway has been created since this plan was written.
4. Confirm the current AKS network mode is still Azure CNI Overlay.
5. Export or otherwise record the current AKS add-on configuration.
6. Record the current public website endpoint for rollback testing.

Example read-only commands:

```powershell
az account show --output table

az aks show `
  --resource-group rg-aks-workshop `
  --name aks-workshop `
  --query "{networkProfile:networkProfile,addonProfiles:addonProfiles}" `
  --output json

az network vnet subnet list `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --vnet-name aks-vnet-38181049 `
  --output table
```

### Phase 2: Create a dedicated AGIC subnet

Create a nondelegated `/24` subnet for classic Application Gateway:

```powershell
az network vnet subnet create `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --vnet-name aks-vnet-38181049 `
  --name snet-appgw-agic `
  --address-prefixes 10.237.0.0/24
```

Do not reuse:

- `aks-subnet`
- `aks-appgateway`
- `aks-virtualkubelet`

### Phase 3: Create a dedicated public IP

Create a Standard, static public IP for the Application Gateway:

```powershell
az network public-ip create `
  --resource-group rg-aks-workshop `
  --name pip-agw-aks-workshop `
  --location eastus `
  --sku Standard `
  --allocation-method Static
```

Do not reuse the existing AKS load balancer or Kubernetes Service public IPs.

### Phase 4: Create Application Gateway v2

Resolve the subnet ID and create a `Standard_v2` gateway:

```powershell
$appGatewaySubnetId = az network vnet subnet show `
  --resource-group MC_rg-aks-workshop_aks-workshop_eastus `
  --vnet-name aks-vnet-38181049 `
  --name snet-appgw-agic `
  --query id `
  --output tsv

az network application-gateway create `
  --resource-group rg-aks-workshop `
  --name agw-aks-workshop `
  --location eastus `
  --sku Standard_v2 `
  --capacity 1 `
  --public-ip-address pip-agw-aks-workshop `
  --subnet $appGatewaySubnetId `
  --priority 100
```

Before implementation, review current Application Gateway pricing. Unlike the existing Kubernetes
LoadBalancer Service, Application Gateway incurs gateway capacity and data-processing charges.

### Phase 5: Enable the AGIC add-on

Resolve the Application Gateway resource ID and associate it with AKS:

```powershell
$appGatewayId = az network application-gateway show `
  --resource-group rg-aks-workshop `
  --name agw-aks-workshop `
  --query id `
  --output tsv

az aks enable-addons `
  --resource-group rg-aks-workshop `
  --name aks-workshop `
  --addons ingress-appgw `
  --appgw-id $appGatewayId
```

The add-on creates a managed identity for AGIC. After enabling it:

1. Verify the `ingress-appgw` add-on reports `enabled: true`.
2. Verify the AGIC pod is running.
3. Verify the add-on identity can update `agw-aks-workshop`.
4. Verify it can read/join the Application Gateway subnet.
5. If the automatically created role assignments are insufficient, grant the add-on identity the
   minimum documented access. Do not grant the GitHub identity `Contributor` merely to solve an
   AGIC identity issue.

AGIC assumes full ownership of its linked Application Gateway by default. Do not manually add
listeners, backend pools, or routing rules to this workshop gateway because AGIC can overwrite
configuration that is not represented by Kubernetes Ingress resources.

### Phase 6: Add a Kubernetes Ingress manifest

Create `k8s/ingress.yaml` with content similar to:

```yaml
# Route public Application Gateway traffic to the website Service.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: aks-static-website
  annotations:
    # AGIC watches only Ingress resources assigned to this controller.
    kubernetes.io/ingress.class: azure/application-gateway
    # Use the existing website root as the Application Gateway health probe.
    appgw.ingress.kubernetes.io/health-probe-path: /
    appgw.ingress.kubernetes.io/health-probe-status-codes: "200-399"
spec:
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

The existing NGINX ingress controller should not process this resource because it is explicitly
assigned to AGIC.

### Phase 7: Use a staged Service transition

Keep the current `LoadBalancer` Service temporarily while validating Application Gateway. A
`LoadBalancer` Service also has a cluster-internal service endpoint, so the Ingress can target it
during the transition.

This provides two paths during testing:

```text
Current path: Internet -> Azure Load Balancer -> Service -> pods
New path:     Internet -> Application Gateway -> AGIC-managed backend -> pods
```

After Application Gateway is proven healthy:

1. Change `k8s/service.yaml` from `type: LoadBalancer` to `type: ClusterIP`.
2. Deploy the change.
3. Confirm the old Kubernetes Service public IP is released.
4. Update the README architecture and testing instructions.

Do not remove the existing LoadBalancer path before the Application Gateway endpoint has been
tested.

### Phase 8: CI/CD integration

No workflow logic change should be required. The current CD workflow applies every manifest in
`k8s/`, so adding `k8s/ingress.yaml` causes the Ingress to be deployed automatically.

Before relying on CD:

1. Confirm the workflow's cluster-user credential can create and patch Ingress resources.
2. Validate the new manifest with `kubectl apply --dry-run=client`.
3. Confirm the successful CI workflow still triggers CD.
4. Confirm AGIC, rather than NGINX, reconciles the new Ingress.

The current cluster-user credential was already verified as able to create Ingress resources.

### Phase 9: DNS and TLS

For an initial HTTP demonstration, use the Application Gateway public IP directly.

For a realistic HTTPS demonstration:

1. Choose a DNS hostname.
2. Create an `A` record pointing to the Application Gateway static public IP.
3. Obtain a TLS certificate for that hostname.
4. Decide whether the certificate is represented by a Kubernetes TLS secret or managed through
   Application Gateway/Key Vault.
5. Add the Ingress host and TLS configuration.
6. Enable HTTP-to-HTTPS redirect with:

   ```yaml
   appgw.ingress.kubernetes.io/ssl-redirect: "true"
   ```

7. Validate certificate renewal before calling the setup production-ready.

DNS and TLS are optional for the first workshop iteration but should be included before using the
endpoint for anything beyond a demonstration.

## Validation checklist

### Azure

- [ ] Application Gateway provisioning state is `Succeeded`.
- [ ] Application Gateway uses `Standard_v2` or `WAF_v2`.
- [ ] The public IP is Standard SKU and static.
- [ ] The gateway is attached only to `snet-appgw-agic`.
- [ ] The AGIC add-on is enabled.
- [ ] The AGIC managed identity has only the required scopes.
- [ ] Application Gateway backend health reports the website endpoints as healthy.

### Kubernetes

- [ ] AGIC pod is `Running` and ready.
- [ ] An Application Gateway ingress class is present after add-on installation.
- [ ] `kubectl get ingress aks-static-website` reports an address.
- [ ] The Ingress backend references Service port 80.
- [ ] Both website pods remain ready.
- [ ] The NGINX controller does not claim the AGIC Ingress.

### Functional

- [ ] `curl http://<application-gateway-public-ip>/` returns HTTP 200.
- [ ] Home, About, and Contact pages load through Application Gateway.
- [ ] Application Gateway access logs show the requests.
- [ ] A pod rollout completes without losing the ingress endpoint.
- [ ] The old LoadBalancer endpoint remains available until cutover is approved.

## Observability

For a complete demonstration, configure Application Gateway diagnostic settings to send access,
performance, and firewall logs to the existing or an approved Log Analytics workspace.

Useful troubleshooting checks include:

```powershell
kubectl get pods --all-namespaces | Select-String ingress
kubectl get ingress aks-static-website --output wide
kubectl describe ingress aks-static-website

az network application-gateway show-backend-health `
  --resource-group rg-aks-workshop `
  --name agw-aks-workshop
```

Common failure causes:

- The Ingress class annotation is missing or incorrect.
- The AGIC managed identity cannot update Application Gateway.
- The Application Gateway subnet is delegated or contains unsupported resources.
- Network security group rules block required Application Gateway traffic.
- The health probe path or expected status codes do not match the application.
- Application Gateway cannot reach pod IPs because the network layout differs from the plan.
- AGIC has overwritten manual gateway configuration because it owns the gateway.

## Rollback plan

The staged approach preserves the existing LoadBalancer endpoint until cutover.

If Application Gateway ingress does not work:

1. Keep or restore `service.yaml` as `type: LoadBalancer`.
2. Delete only the `aks-static-website` Ingress resource.
3. Confirm the existing LoadBalancer endpoint still serves the site.
4. Disable the `ingress-appgw` add-on only after removing its Ingress resources.
5. Remove the dedicated Application Gateway, public IP, and `snet-appgw-agic` subnet only after
   confirming they are not shared.
6. Do not delete or alter the existing `aks-appgateway` delegated subnet.

Each deletion should be reviewed and confirmed separately because it is destructive.

## Alternative: Application Gateway for Containers

Application Gateway for Containers is Microsoft's newer Kubernetes-focused Layer 7 ingress
offering. It supports both Kubernetes Ingress and Gateway API resources and uses ALB Controller
instead of AGIC.

It is a strong option for this cluster because:

- The existing `aks-appgateway` subnet is already delegated to
  `Microsoft.ServiceNetworking/trafficControllers`.
- `eastus` supports Application Gateway for Containers.
- It supports Azure CNI Overlay.
- Microsoft recommends considering it for new Kubernetes ingress implementations.
- It offers Gateway API, traffic splitting, retries, header and URL rewrites, gRPC, TLS, and WAF.

It is not identical to classic Application Gateway. If the workshop goal is specifically to teach
the long-established Application Gateway plus AGIC model, follow the classic plan above. If the
goal is to teach the current recommended Azure ingress platform, create a separate implementation
plan for Application Gateway for Containers and reuse the already delegated subnet.

## Decision required before implementation

Choose one path:

| Option | Best when | Subnet |
|--------|-----------|--------|
| Classic Application Gateway + AGIC | The workshop specifically teaches Application Gateway and Kubernetes Ingress | Create `snet-appgw-agic` (`10.237.0.0/24`) |
| Application Gateway for Containers | The workshop should use Microsoft's newer Kubernetes ingress platform | Revalidate and use existing delegated `aks-appgateway` subnet |

Do not implement both for this single website unless the explicit goal is a side-by-side comparison;
doing so adds cost and makes traffic ownership less clear.

## References

- [Application Gateway Ingress Controller overview](https://learn.microsoft.com/azure/application-gateway/ingress-controller-overview)
- [Enable AGIC add-on for an existing AKS cluster](https://learn.microsoft.com/azure/application-gateway/tutorial-ingress-controller-add-on-existing)
- [Application Gateway infrastructure configuration](https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure)
- [AGIC annotations](https://learn.microsoft.com/azure/application-gateway/ingress-controller-annotations)
- [Application Gateway for Containers overview](https://learn.microsoft.com/azure/application-gateway/for-containers/overview)
