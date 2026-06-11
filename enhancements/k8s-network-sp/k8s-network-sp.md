---
title: k8s-network-sp
authors:
  - "@tkiss"
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
Endpoints are not supported. Kubernetes Service types (ClusterIP, NodePort,
LoadBalancer) are configured via providerHints.kubernetes.type. It exposes
endpoints for creating, reading, and deleting network services, and integrates
with the DCM Service Provider Registry. The K8s Network SP implements the
`network` service type schema.

## Motivation

Currently, networking in DCM is bundled within compute resource specifications
(containers include network.ports[], VMs include network interfaces). However,
Kubernetes Services are independent resources that can:

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
- Each network request creates a `Service` resource with the type specified in
  providerHints.kubernetes.type (ClusterIP, NodePort, or LoadBalancer). If type
  is not specified, defaults to ClusterIP.
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

```golang
dcm "github.com/dcm-project/service-provider-api/pkg/registration/client"
...
request := &dcm.RegistrationRequest{
    Name: "k8s-network-sp",
    ServiceType: "network",
    DisplayName: "Kubernetes Network Service Provider",
    Endpoint:  fmt.Sprintf("%s/api/v1alpha1/networks", apiHost),
    Metadata: dcm.Metadata{
      Zone:   "us-east-1b",
      Region: "us-east-1",
    },
    Operations: []string{"CREATE", "DELETE", "READ"},
}
```

#### Registration Request Validation

**K8s Network SP-specific requirements:**

- `serviceType` field must be set to `"network"`
- `operations` field must include at minimum: `CREATE`, `READ`, `DELETE`

#### Registration Process

The environment agent handles the registration of the K8s Network SP with DCM.
The registration request includes the K8s Network SP endpoint URL in the format:
`fmt.Sprintf("%s/api/v1alpha1/networks", apiHost)`.

### Implementation Details/Notes/Constraints

- Services created by this SP are labeled with `managed-by=dcm`,
  `dcm-instance-id=<UUID>`, and `dcm-service-type=network` for tracking and
  lifecycle management.
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

The POST endpoint creates a Kubernetes Service resource. When selectors are
specified in providerHints.kubernetes.selector, the Service routes traffic to
pods matching those label selectors. The service type (ClusterIP, NodePort,
LoadBalancer) configured in providerHints.kubernetes.type determines how the
service is exposed.

During creation of the Service resource, it must be labeled with:

- `managed-by=dcm`
- `dcm-instance-id=<UUID>`
- `dcm-service-type=network`

The `dcm-instance-id` is a UUID generated by DCM. If a Service with the same
`metadata.name` already exists in the target namespace, the K8s Network SP
returns a `409 Conflict` error response without modifying the existing resource.

**Service Configuration via providerHints:**

Users can configure Kubernetes-specific options on a per-service basis using
`providerHints.kubernetes`:

| Field     | Type              | Required | Description                                                                                                                              |
| --------- | ----------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| type      | string            | No       | Service type: ClusterIP (default), NodePort, or LoadBalancer                                                                             |
| selector  | map[string]string | No       | Label selector to match target pods. If omitted, Service is created without selectors for manual endpoint management.                    |
| clusterIP | string            | No       | Specific clusterIP value. Can be a specific IP (within cluster CIDR), "None" (for headless services), or omitted for auto-assignment     |
| nodePorts | map[string]int    | No       | Map of port names to NodePort values (30000-32767). Keys must match port names in the ports[] array. Required when specifying NodePorts. |

If `type` is not specified, defaults to ClusterIP. If `selector` is not
specified, the Service is created without selectors. If `clusterIP` is not
specified, Kubernetes automatically assigns an IP from the cluster's service
CIDR range.

**Example Request Payload:**

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
  "providerHints": {
    "kubernetes": {
      "type": "LoadBalancer",
      "selector": {
        "app": "web-frontend",
        "tier": "frontend"
      },
      "clusterIP": "10.96.45.12"
    }
  },
  "serviceType": "network"
}
```

> **Note**: All fields in `providerHints.kubernetes` are optional. If `selector`
> is omitted, the Service is created without selectors for manually managed
> endpoints (via EndpointSlices) or for services that proxy to external
> resources. If `type` is omitted, defaults to ClusterIP. If `clusterIP` is
> omitted, Kubernetes automatically assigns an IP. Set
> `providerHints.kubernetes.clusterIP: "None"` to create a headless service.
> When using `providerHints.kubernetes.nodePorts`, all ports must have unique
> `name` fields. The keys in `nodePorts` must match these port names.

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
  "metadata": {
    "type": "LoadBalancer",
    "selector": {
      "app": "web-frontend",
      "tier": "frontend"
    },
    "clusterIP": "10.96.45.12"
  }
}
```

> **Note**: The `metadata` field in the response contains platform-specific
> details (type, selector, clusterIP). The `clusterIP` is assigned by
> Kubernetes. For LoadBalancer services, `externalIP` will be populated
> asynchronously and reported via status updates. The `nodePort` values are
> allocated by Kubernetes if not explicitly specified in the request.

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
        "namespace": "default",
        "type": "LoadBalancer",
        "clusterIP": "10.96.45.12",
        "externalIP": "34.123.45.67"
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
        "namespace": "default",
        "type": "ClusterIP",
        "clusterIP": "10.96.45.13"
      }
    },
    {
      "requestId": "789e1234-e89b-12d3-a456-426614174002",
      "name": "cache-service",
      "status": "READY",
      "ports": [
        {
          "protocol": "TCP",
          "port": 6379,
          "targetPort": 6379
        }
      ],
      "metadata": {
        "namespace": "default",
        "type": "ClusterIP",
        "clusterIP": "10.96.45.14"
      }
    }
  ],
  "next_page_token": "a1b2c3d4e5f6"
}
```

> **Note:** The response includes fully-populated resources as required by
> AEP-132. Each service instance includes all available fields (requestId, name,
> status, ports, metadata) to match the detail level of the GET single resource
> endpoint. The `metadata` field contains platform-specific details (namespace,
> type, clusterIP, externalIP, selector). The `externalIP` field is included
> only for LoadBalancer type Services when an external IP has been assigned.

**Error Handling:**

- **400 Bad Request**: Invalid pagination parameters
- **500 Internal Server Error**: Unexpected error querying Kubernetes API

#### GET /api/v1alpha1/networks/{instanceId}

**Description:** Get a specific network instance.

**Process Flow:**

1. Handler receives `GET` request with `instanceId` path parameter.
2. Calls `GetServiceFromCluster(instanceId)`.
3. Cluster lookup: Query Kubernetes API for `Service` with matching
   `dcm-instance-id` label.
4. Response payload: Return complete service instance object.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "web-frontend-service",
  "status": "READY",
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
    "namespace": "default",
    "type": "LoadBalancer",
    "clusterIP": "10.96.45.12",
    "externalIP": "34.123.45.67",
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
- The informer uses label selector: `managed-by=dcm,dcm-service-type=network`
- The `instanceId` is retrieved from the `dcm-instance-id` label on the Service

#### CloudEvents Format

Status updates are published to the messaging system using the
[CloudEvents](https://cloudevents.io/) specification (v1.0). This provides a
standardized "fire-and-forget" mechanism that decouples the K8s Network SP from
the DCM backend.

**Message Subject Hierarchy:**

Events are published to the following subject format:

`dcm.providers.{providerName}.network.instances.{instanceId}.status`

- `providerName`: Unique name of the Kubernetes Network Service Provider
- `instanceId`: UUID of the network service (from `dcm-instance-id` label)

Events are published to the following type format:

`dcm.providers.{providerName}.status.update`

- `providerName`: Unique name of the Kubernetes Network Service Provider

**Payload Structure:**

```golang
type NetworkServiceStatus struct {
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
- Verify CloudEvents published to correct NATS subjects
- Validate CloudEvents payload structure and content

**End-to-End Tests:**

- Full workflow through DCM Placement Manager
- Service creation request → K8s Network SP → Service in cluster
- Status updates propagated back to DCM via messaging system
