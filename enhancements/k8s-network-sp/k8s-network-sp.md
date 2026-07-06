---
title: k8s-network-sp
authors:
  - "@pwaresia"
reviewers:
  - "@gciavarrini"
  - "@jenniferubah"
  - "@machacekondra"
  - "@ygalblum"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"

creation-date: 2026-06-03
---

# Kubernetes Network Service Provider

## Summary

The Kubernetes Network Service Provider (K8s Network SP) is a DCM control-plane
adapter that translates network provisioning requests into Kubernetes Service
resources to provide network access to workloads running on Kubernetes clusters.
Unlike managing networking as part of compute resources (containers, VMs), this
Service Provider specifically focuses on Kubernetes Services as first-class
network resources.

The current implementation focuses exclusively on Kubernetes Service objects;
other network resource types such as Ingress, NetworkPolicy, or standalone
Endpoints are not supported. It exposes endpoints for creating, reading, and
deleting network services with configurable Kubernetes Service types (ClusterIP,
NodePort, LoadBalancer), and integrates with the DCM Service Provider Registry.
The K8s Network SP implements the `network` service type schema.

## Motivation

Currently, networking in DCM is bundled within compute resource specifications.
For example, containers include network.ports[] with visibility fields to
control Service creation (internal, external, or none). However, Kubernetes
Services are independent resources that can:

- Provide stable endpoints for workloads managed outside DCM
- Load balance across multiple pods/containers
- Expose services externally via NodePort or LoadBalancer types
- Be managed independently of the underlying compute resources

By treating Kubernetes Services as first-class DCM resources, users gain the
flexibility to manage network access separately from compute lifecycle,
supporting use cases like exposing existing workloads, multi-service routing,
and centralized network policy management.

### Goals

- Define the lifecycle of a Service Provider (SP) managing Kubernetes Service
  resources.
- Define the registration flow with DCM SP API for the `network` service type.
- Define `CREATE`, `READ`, and `DELETE` endpoints for managing Kubernetes
  Services.
- Define status reporting mechanism for Kubernetes Service resources.
- Support Kubernetes Service resource management with configurable k8s-service
  types.
- Enable backend selection for routing traffic to workloads.

### Non-Goals

- Define endpoints for day 2 operations (update service type, modify selectors,
  change ports) for service instances.
- Support for Ingress resources (L7 routing, path-based routing, TLS
  termination).
- Support for NetworkPolicy resources (pod-level firewall rules).
- Support for Endpoints or EndpointSlice resources managed independently.
- Service mesh integration (Istio, Linkerd, Consul).
- DNS configuration or custom DNS records.
- Certificate management for TLS-enabled services.
- Persistent IP address reservation across service deletion/recreation.
- Multi-cluster service federation (services spanning multiple clusters).
- Deployment strategy for the K8s Network SP API.

### User Stories

#### Story 1: Expose an existing application

As a platform engineer, I want to expose my containerized application running in
Kubernetes (deployed outside DCM) by creating a LoadBalancer service through
DCM, so that external users can access it via a stable public IP address without
manually creating Kubernetes Service YAML files.

#### Story 2: Create internal service endpoints

As a developer, I want to create a ClusterIP service for my microservices to
communicate with each other within the cluster, managed through DCM's unified
API rather than directly interacting with Kubernetes, enabling consistent
service management across different infrastructure types.

## Proposal

### Assumptions

- The Kubernetes Network Service Provider is connected to a Kubernetes cluster
  (OCP, KIND, Minikube, etc).
- The Kubernetes Network Service Provider has the necessary RBAC permissions to
  manage `Service` resources in its configured namespace.
- The DCM Service Provider Registry is reachable for registration.
- The Kubernetes Network Service Provider service has valid Kubernetes
  credentials (`kubeconfig` or in-cluster service account).
- DCM messaging system is reachable for publishing status updates.
- Network policies allow K8s Network SP to communicate with DCM.
- For LoadBalancer services: The cluster must have a LoadBalancer controller
  configured (cloud provider integration, MetalLB, etc.). Without this,
  LoadBalancer services will be created but remain in PENDING state
  indefinitely.

### Integration Points

#### Kubernetes Integration

- Uses `k8s.io/client-go` to interact with Kubernetes API.
- Creates and manages `Service` resources.
- Each network request creates a `Service` resource with the Kubernetes Service
  type inferred from the generic `loadBalancerType` field and the presence of
  `nodePorts` in providerHints.kubernetes. See
  [Service Type Inference](#service-type-inference) for the complete mapping
  table.
- Services use label selectors to route traffic to matching pods.
- Leverages Kubernetes Service lifecycle management for endpoint updates.

#### DCM SP Registry

- Auto-registration on startup via environment agent. The environment agent
  handles registration with DCM SP Registrar on behalf of the Service Provider.
  See documentation for
  [Environment Agent](https://github.com/dcm-project/enhancements/blob/main/enhancements/environment-agent/environment-agent.md)

#### DCM SP Health Check

K8s Network SP must expose a health endpoint
`http://<provider-ip>:<port>/health` for DCM control plane to poll every 10
seconds. See documentation for
[SP Health Check](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-provider-health-check/service-provider-health-check.md).

#### DCM SP Status Reporting

- Publish status updates for network services to the messaging system using
  CloudEvents format. Events are published to the subject:
  `dcm.providers.{providerName}.network.instances.{instanceId}.status`
- See documentation for
  [SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md).
- Use a `SharedIndexInformer` to watch and monitor `Service` events.

### SP Configuration

The K8s Network SP supports configuration options that control default behavior
for all network services managed by this provider instance.

#### Namespace Configuration

| Field     | Type   | Default | Description                                    |
| --------- | ------ | ------- | ---------------------------------------------- |
| namespace | string | default | Kubernetes namespace for all managed resources |

All Service resources created by this Service Provider are deployed in the
configured namespace. This setting applies to all network instances managed by
the SP and cannot be overridden per-service.

### Registration Flow

The K8s Network SP API must successfully complete a registration process to
ensure DCM is aware of it and can use it. During startup, the environment agent
handles the registration of the K8s Network SP with DCM. See
[Environment Agent](https://github.com/dcm-project/enhancements/blob/main/enhancements/environment-agent/environment-agent.md)
for more information.

Example request payload:

```json
{
  "name": "k8s-network-sp",
  "service_type": "network",
  "schema_version": "v1alpha1",
  "display_name": "Kubernetes Network Service Provider",
  "endpoint": "https://k8s-network-sp.example.com/api/v1alpha1/networks",
  "operations": ["CREATE", "DELETE", "READ"],
  "metadata": {
    "zone": "us-east-1b",
    "region_code": "us-east-1"
  }
}
```

#### Registration Request Validation

**K8s Network SP-specific requirements:**

- `service_type` field must be set to `"network"`
- `schema_version` field must be set to `"v1alpha1"`
- `operations` field must include at minimum: `CREATE`, `READ`, `DELETE`

#### Registration Process

The environment agent handles the registration of the K8s Network SP with DCM.
The registration request includes the K8s Network SP endpoint URL in the format:
`fmt.Sprintf("%s/api/v1alpha1/networks", apiHost)`.

### Implementation Details/Notes/Constraints

- Services created by this SP are labeled with `dcm.project/managed-by=dcm`,
  `dcm.project/dcm-instance-id=<UUID>`, and
  `dcm.project/dcm-service-type=network` for tracking and lifecycle management.
- The `providerHints.kubernetes.selector` field is optional. Services can be
  created without selectors for manual endpoint management (via EndpointSlices)
  or for services that proxy to external resources.
- For Services with selectors: The SP does not validate whether pods matching
  the selectors exist. Kubernetes will handle endpoint updates as matching pods
  are created or removed.
- LoadBalancer services depend on the cluster having a LoadBalancer controller
  (cloud provider integration, MetalLB, etc.). If unavailable, the service will
  be created but may remain in `Pending` state.
- Port conflicts are not validated by the SP. Kubernetes will reject Service
  creation if NodePort conflicts occur.
- Service names must be DNS-compatible (RFC 1035): lowercase alphanumeric,
  hyphens, max 63 characters.
- When using providerHints.kubernetes.selector, Services can only select pods
  within the same namespace (the namespace configured for this SP instance).
  Target workloads must exist in the same namespace.

### Service Type Inference

The K8s Network SP infers the Kubernetes Service type from the
`loadBalancerType` field and the presence of `nodePorts` in providerHints:

| loadBalancerType | nodePorts present? | K8s Service Type | Behavior                                      |
| :--------------- | :----------------- | :--------------- | :-------------------------------------------- |
| omitted          | No                 | ClusterIP        | Basic internal service                        |
| omitted          | Yes                | NodePort         | Exposed on all node IPs with specified ports  |
| network          | No                 | LoadBalancer     | LoadBalancer, nodePorts auto-allocated by K8s |
| network          | Yes                | LoadBalancer     | LoadBalancer, uses specified nodePorts        |
| application      | No                 | Ingress          | Not supported in v1 (return error)            |
| application      | Yes                | Error            | Invalid: nodePorts not applicable for Ingress |

### Risks and Mitigations

| Risk                                                                | Mitigation                                                                                                                                                                                                                                     |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Service created but no matching pods exist (endpoints remain empty) | This is normal Kubernetes behavior. Services with providerHints.kubernetes.selector automatically update endpoints when matching pods become ready.                                                                                            |
| LoadBalancer service stuck in Pending (no LB controller)            | Status reporting shows PENDING state; document cluster prerequisites (LoadBalancer controller required)                                                                                                                                        |
| NodePort conflicts with existing services                           | Kubernetes API will reject with 409; SP returns error to user                                                                                                                                                                                  |
| Orphaned services if pod labels change                              | Services use static selectors defined in providerHints.kubernetes.selector; users must manage pod labels to match                                                                                                                              |
| Security: exposing services without authentication/authorization    | Document that Service type choice affects exposure scope: ClusterIP (cluster-internal), NodePort (accessible from nodes), LoadBalancer (publicly accessible). Users must ensure application-layer authentication before choosing LoadBalancer. |
| RBAC permission issues in configured namespace                      | Document RBAC requirements; SP needs Service create/read/delete permissions in configured namespace                                                                                                                                            |

## Design Details

### API Endpoints

The CRUD endpoints are consumed by the DCM SP API to create and manage network
service resources.

#### Endpoints Overview

| Method | Endpoint                            | Description                   |
| ------ | ----------------------------------- | ----------------------------- |
| POST   | /api/v1alpha1/networks              | Create a new network instance |
| GET    | /api/v1alpha1/networks              | List all network instances    |
| GET    | /api/v1alpha1/networks/{instanceId} | Get a network instance        |
| DELETE | /api/v1alpha1/networks/{instanceId} | Delete a network instance     |
| GET    | /api/v1alpha1/health                | K8s Network SP health check   |

##### AEP Compliance

These endpoints are defined based on AEP standards and use `aep-openapi-linter`
to check for compliance with AEP.

#### POST /api/v1alpha1/networks

**Description:** Create a new network instance.

The POST endpoint follows the contract defined in the Network schema spec
pre-defined by DCM core. See
[Network Schema](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#network)
for the complete specification.

The POST endpoint creates a Kubernetes Service resource. The generic
`loadBalancerType` field expresses load balancing intent. The K8s Network SP
infers the Kubernetes Service type (ClusterIP, NodePort, LoadBalancer) from
`loadBalancerType` and the presence of `nodePorts` in providerHints. When
selectors are specified in providerHints.kubernetes.selector, the Service routes
traffic to pods matching those label selectors.

During creation of the Service resource, it must be labeled with:

- `dcm.project/managed-by=dcm`
- `dcm.project/dcm-instance-id=<UUID>`
- `dcm.project/dcm-service-type=network`

The `dcm.project/dcm-instance-id` is a UUID generated by DCM. If a Service with
the same `metadata.name` already exists in the target namespace, the K8s Network
SP returns a `409 Conflict` error response without modifying the existing
resource.

**Service Configuration:**

The network service uses the generic `loadBalancerType` field to express load
balancing intent:

**Generic Field:**

| Field            | Type   | Required | Description                                              |
| :--------------- | :----- | :------- | :------------------------------------------------------- |
| loadBalancerType | string | No       | Load balancer tier: `network` (L4) or `application` (L7) |

**Kubernetes-Specific Configuration (providerHints.kubernetes):**

| Field     | Type              | Required | Description                                                                                                                                                                                        |
| :-------- | :---------------- | :------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| selector  | map[string]string | No       | Label selector to match target pods. If omitted, Service is created without selectors for manual endpoint management.                                                                              |
| clusterIP | string            | No       | Specific clusterIP value. Can be a specific IP (within cluster CIDR), "None" (for headless services), or omitted for auto-assignment                                                               |
| nodePorts | map[string]int    | No       | Map of port names to NodePort values (30000-32767). When present with no loadBalancerType, creates NodePort Service. With loadBalancerType: network, specifies nodePorts for LoadBalancer backend. |

**Mapping: Generic Field + nodePorts → Kubernetes Service Type**

| loadBalancerType | nodePorts present? | K8s Service Type | Notes                                  |
| :--------------- | :----------------- | :--------------- | :------------------------------------- |
| omitted          | No                 | ClusterIP        | Basic internal service                 |
| omitted          | Yes                | NodePort         | Exposed on all node IPs (dev/test)     |
| network          | No                 | LoadBalancer     | LoadBalancer, auto-allocated nodePorts |
| network          | Yes                | LoadBalancer     | LoadBalancer, specified nodePorts      |
| application      | No                 | Ingress          | Not supported in v1 (Non-Goal)         |
| application      | Yes                | Error            | nodePorts not applicable for Ingress   |

**Example Request Payload (LoadBalancer):**

```json
{
  "ports": [
    {
      "name": "http",
      "protocol": "TCP",
      "port": 80,
      "targetPort": 8080
    },
    {
      "name": "https",
      "protocol": "TCP",
      "port": 443,
      "targetPort": 8443
    }
  ],
  "metadata": {
    "name": "web-frontend-service"
  },
  "loadBalancerType": "network",
  "providerHints": {
    "kubernetes": {
      "selector": {
        "app": "web-frontend",
        "tier": "frontend"
      }
    }
  },
  "serviceType": "network"
}
```

**Example: LoadBalancer with specified NodePorts**

```json
{
  "ports": [
    {
      "name": "http",
      "protocol": "TCP",
      "port": 80,
      "targetPort": 8080
    }
  ],
  "metadata": {
    "name": "lb-fixed-nodeport"
  },
  "loadBalancerType": "network",
  "providerHints": {
    "kubernetes": {
      "selector": {
        "app": "backend"
      },
      "nodePorts": { "http": 30808 }
    }
  },
  "serviceType": "network"
}
```

**Example: ClusterIP Service**

```json
{
  "ports": [{ "protocol": "TCP", "port": 3000, "targetPort": 3000 }],
  "metadata": { "name": "internal-api" },
  "providerHints": {
    "kubernetes": {
      "selector": { "app": "api" }
    }
  },
  "serviceType": "network"
}
```

**Example: NodePort Service**

```json
{
  "ports": [{ "name": "http", "port": 80, "targetPort": 8080 }],
  "metadata": { "name": "dev-service" },
  "providerHints": {
    "kubernetes": {
      "selector": { "app": "dev" },
      "nodePorts": { "http": 30080 }
    }
  },
  "serviceType": "network"
}
```

> **Note**: The `loadBalancerType` field expresses load balancing intent. The
> K8s Network SP infers the Kubernetes Service type from `loadBalancerType` and
> the presence of `nodePorts`:
>
> - No `loadBalancerType` + no `nodePorts` → ClusterIP
> - No `loadBalancerType` + `nodePorts` present → NodePort
> - `loadBalancerType: network` → LoadBalancer (nodePorts auto-allocated or
>   specified)
>
> Platform-specific configuration:
>
> - `selector` is optional. If omitted, the Service is created without selectors
>   for manual endpoint management (via EndpointSlices) or for services that
>   proxy to external resources.
> - `clusterIP` can be a specific IP from the cluster's service CIDR, `"None"`
>   for headless services, or omitted for auto-assignment.
> - `nodePorts` (in request) is a map under `providerHints.kubernetes`. In
>   responses, each port object has a `nodePort` field (singular) showing the
>   allocated value. The `nodePorts` keys must match port `name` fields in the
>   ports[] array.

**Response:** Returns `201 Created` with the following payload. The status is
set to `PENDING` after the resource is created.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "web-frontend-service",
  "status": "PENDING",
  "ports": [
    {
      "name": "http",
      "protocol": "TCP",
      "port": 80,
      "targetPort": 8080
    },
    {
      "name": "https",
      "protocol": "TCP",
      "port": 443,
      "targetPort": 8443
    }
  ],
  "loadBalancerType": "network",
  "metadata": {
    "type": "LoadBalancer",
    "clusterIP": "10.96.45.12",
    "selector": {
      "app": "web-frontend",
      "tier": "frontend"
    }
  }
}
```

> **Note**: The response includes the `loadBalancerType` field from the request.
> The `metadata` field contains Kubernetes-specific details:
>
> - `type`: The actual K8s Service type created (ClusterIP, NodePort,
>   LoadBalancer) - response-only, inferred from `loadBalancerType` and
>   `nodePorts` presence
> - `clusterIP`: Auto-assigned or user-specified cluster IP
> - `selector`: Label selectors for pod routing
> - `externalIPs`: Array of external IPs or hostnames for LoadBalancer services
>   (from `.status.loadBalancer.ingress[]`). Populated asynchronously.
> - `nodePort`: Per-port field showing the allocated NodePort value
>   (auto-assigned or from request `providerHints.kubernetes.nodePorts`)

**Error Handling:**

- **400 Bad Request**: Invalid request payload, missing required fields, or
  invalid port numbers
- **409 Conflict**: Service with the same `metadata.name` already exists in the
  target namespace
- **500 Internal Server Error**: Unexpected error during resource creation

#### GET /api/v1alpha1/networks

**Description:** List all network instances with pagination support.

**Query Parameters:**

- `max_page_size` (optional): Maximum number of resources to return in a single
  page. Default: 50.
- `page_token` (optional): Token indicating the starting point for the page.

**Process Flow:**

1. Handler receives `GET` request with optional pagination parameters.
2. Calls `ListServicesFromCluster()` with pagination context.
3. Returns fully-populated service resources per AEP-132.
4. Response includes pagination metadata (`next_page_token`).

**Example Response Payload:**

```json
{
  "results": [
    {
      "requestId": "123e4567-e89b-12d3-a456-426614174000",
      "name": "web-frontend-service",
      "status": "READY",
      "loadBalancerType": "network",
      "ports": [
        {
          "name": "http",
          "protocol": "TCP",
          "port": 80,
          "targetPort": 8080,
          "nodePort": 31234
        }
      ],
      "metadata": {
        "type": "LoadBalancer",
        "clusterIP": "10.96.45.12",
        "externalIPs": ["34.123.45.67"],
        "selector": {
          "app": "web-frontend"
        }
      }
    },
    {
      "requestId": "456e7890-e89b-12d3-a456-426614174001",
      "name": "api-gateway",
      "status": "READY",
      "ports": [
        {
          "name": "api",
          "protocol": "TCP",
          "port": 3000,
          "targetPort": 3000
        }
      ],
      "metadata": {
        "type": "ClusterIP",
        "clusterIP": "10.96.45.13",
        "selector": {
          "app": "api-gateway"
        }
      }
    },
    {
      "requestId": "789e1234-e89b-12d3-a456-426614174002",
      "name": "dev-service",
      "status": "READY",
      "ports": [
        {
          "name": "http",
          "protocol": "TCP",
          "port": 8080,
          "targetPort": 8080,
          "nodePort": 30080
        }
      ],
      "metadata": {
        "type": "NodePort",
        "clusterIP": "10.96.45.14",
        "selector": {
          "app": "dev"
        }
      }
    }
  ],
  "next_page_token": "a1b2c3d4e5f6"
}
```

> **Note:** Each response includes the `loadBalancerType` field (if specified in
> the request). The `metadata.type` field shows the actual Kubernetes Service
> type created. Platform-specific details (clusterIP, externalIPs, selector,
> nodePort) are in the `metadata` object.

**Error Handling:**

- **400 Bad Request**: Invalid pagination parameters
- **500 Internal Server Error**: Unexpected error querying Kubernetes API

#### GET /api/v1alpha1/networks/{instanceId}

**Description:** Get a specific network instance.

**Process Flow:**

1. Handler receives `GET` request with `instanceId` path parameter.
2. Calls `GetServiceFromCluster(instanceId)`.
3. Cluster lookup: Query Kubernetes API for `Service` with matching
   `dcm.project/dcm-instance-id` label.
4. Response payload: Return complete service instance object.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "web-frontend-service",
  "status": "READY",
  "loadBalancerType": "network",
  "ports": [
    {
      "name": "http",
      "protocol": "TCP",
      "port": 80,
      "targetPort": 8080,
      "nodePort": 31234
    },
    {
      "name": "https",
      "protocol": "TCP",
      "port": 443,
      "targetPort": 8443,
      "nodePort": 31235
    }
  ],
  "metadata": {
    "type": "LoadBalancer",
    "clusterIP": "10.96.45.12",
    "externalIPs": ["34.123.45.67"],
    "selector": {
      "app": "web-frontend",
      "tier": "frontend"
    }
  }
}
```

**Error Handling:**

- **404 Not Found**: Service with the specified `instanceId` does not exist
- **500 Internal Server Error**: Unexpected error querying Kubernetes API

#### DELETE /api/v1alpha1/networks/{instanceId}

**Description:** Delete a network instance.

Remove a single Kubernetes Service resource and returns `204 No Content`.

**Error Handling:**

- **404 Not Found**: Service with the specified `instanceId` does not exist
- **500 Internal Server Error**: Unexpected error during resource deletion

#### GET /api/v1alpha1/health

**Description:** Retrieve the health status for the Kubernetes Service Network
Provider API.

### Status Reporting to DCM

The K8s Network SP uses a `SharedIndexInformer` to watch Kubernetes `Service`
resources and report status changes to DCM via the messaging system.

#### Status Reconciliation Logic

When the informer receives a Service event, the K8s Network SP determines the
status based on the Service resource state.

**Note:** Unlike Pods and Deployments, Kubernetes Services do not expose health
status conditions (Ready, Available, Degraded) in their `.status` field.
Services are declarative networking abstractions - they define routing rules for
traffic to pods matching a selector. The Service object itself only tracks
`.status.loadBalancer.ingress` for LoadBalancer types.

**Status Determination Flow:**

1. **Check if Service resource exists:**
   - Service not found → `DELETED`

2. **For LoadBalancer Services:**
   - Check `.status.loadBalancer.ingress` for external IP assignment:
     - No external IP assigned → `PENDING`
     - External IP assigned → `READY`

3. **For ClusterIP and NodePort Services:**
   - Service exists → `READY`

**Implementation Notes:**

- Status updates are debounced to avoid flooding the messaging system during
  rapid status changes (e.g., LoadBalancer IP assignment may trigger multiple
  events)
- The informer uses label selector:
  `dcm.project/managed-by=dcm,dcm.project/dcm-service-type=network`
- The `instanceId` is retrieved from the `dcm.project/dcm-instance-id` label on
  the Service

#### CloudEvents Format

Status updates are published to the messaging system using the
[CloudEvents](https://cloudevents.io/) specification (v1.0). This provides a
standardized "fire-and-forget" mechanism that decouples the K8s Network SP from
the DCM backend.

**Message Subject Hierarchy:**

Events are published to the following subject format:

`dcm.providers.{providerName}.network.instances.{instanceId}.status`

- `providerName`: Unique name of the Kubernetes Network Service Provider
- `instanceId`: UUID of the network service (from `dcm.project/dcm-instance-id`
  label)

Events are published to the following type format:

`dcm.providers.{providerName}.status.update`

- `providerName`: Unique name of the Kubernetes Network Service Provider

**Payload Structure:**

```golang
type NetworkServiceStatus struct {
    Id      string `json:"id"`
    Status  string `json:"status"`
    Message string `json:"message"`
}
```

**Example Event:**

```golang
cloudevents "github.com/cloudevents/sdk-go/v2"

event := cloudevents.NewEvent()
event.SetID("event-123-456")
event.SetSource("k8s-network-sp-prod")
event.SetType("dcm.providers.k8s-network-sp.status.update")
event.SetSubject("dcm.providers.k8s-network-sp.network.instances.abc-123.status")
event.SetData(cloudevents.ApplicationJSON, NetworkServiceStatus{
    Id:      "abc-123",
    Status:  "READY",
    Message: "Service ready",
})
```

See
[SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md)
for the complete CloudEvents contract and messaging system details.

#### Status Mapping from Kubernetes to DCM

The following table maps Kubernetes Service resource fields to DCM generic
statuses. The K8s Network SP uses field-based inspection to determine status.

| DCM Status | Kubernetes Condition                                                                            |
| ---------- | ----------------------------------------------------------------------------------------------- |
| PENDING    | Service exists AND `.spec.type` = LoadBalancer AND `.status.loadBalancer.ingress[]` is empty    |
| READY      | Service exists AND `.spec.type` = LoadBalancer AND `.status.loadBalancer.ingress[]` has entries |
| READY      | Service exists AND `.spec.type` = NodePort                                                      |
| READY      | Service exists AND `.spec.type` = ClusterIP                                                     |
| DELETED    | Service resource not found in cluster                                                           |

**Field Notes**:

- `.status.loadBalancer.ingress[]` is an array that can contain multiple entries
- Each entry can have either `.ip` (e.g., GKE, MetalLB) or `.hostname` (e.g.,
  AWS ELB)
- LoadBalancer is `READY` when at least one entry exists with an assigned IP or
  hostname
- ClusterIP services with `.spec.clusterIP = "None"` are headless services and
  are immediately `READY`

**Rationale:**

Services are declarative networking abstractions - they define routing rules and
are considered functional once created, regardless of current endpoint
availability. ClusterIP and NodePort services are immediately `READY` upon
creation. LoadBalancer services transition from `PENDING` to `READY` once an
external IP or hostname is assigned by the LoadBalancer controller. Empty
endpoints are normal and do not affect service status during:

- Initial creation (pods not yet started)
- Rolling updates (pods restarting)
- Scaling to zero
- Temporary pod failures
- Headless services (`.spec.clusterIP = "None"`)

### Test Plan

**Unit Tests:**

- API endpoint handlers (POST, GET, DELETE)
- Service creation logic with label application
- Selector and port configuration validation
- Error handling and HTTP status code verification
- CloudEvents payload formatting

**Integration Tests:**

- Deploy K8s Network SP to KIND/Minikube cluster
- Create Services of each type (ClusterIP, NodePort, LoadBalancer)
- Verify Service resources created in Kubernetes with correct labels
- Verify Service selector correctly configured (traffic will route when matching
  pods exist)
- Delete Service and verify cleanup

**Status Reporting Tests:**

- Verify SharedIndexInformer watches Services with correct label selectors
- Test status transitions: PENDING → READY for LoadBalancer (when external IP
  assigned)
- Test READY status for ClusterIP and NodePort services (immediately after
  creation)
- Test DELETED status when Service removed from cluster
- Verify CloudEvents published to correct NATS subject
- Validate CloudEvents payload structure and content

**End-to-End Tests:**

- Full workflow through DCM Placement Manager
- Service creation request → K8s Network SP → Service in cluster
- Status updates propagated back to DCM via messaging system
