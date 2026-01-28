---
title: k8s-container-sp
authors:
  - "@gabriel-farache"
reviewers:
  - "@gciavarrini"
  - "@jenniferubah"
  - "@machacekondra"
  - "@ygalblum"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"
creation-date: 2026-01-21
---

# Kubernetes Container Service Provider

## Summary

The Kubernetes Container Service Provider (K8s Container SP) is a REST API that
manages containerized workloads on Kubernetes clusters. Unlike generic container
runtimes (Docker, Podman), this Service Provider specifically targets Kubernetes
as its execution platform. The current implementation focuses exclusively on
Kubernetes Deployments; other resource types such as Jobs, static Pods,
DaemonSets, or StatefulSets are not supported. It exposes endpoints for
creating, reading, and deleting containers, and integrates with the DCM Service
Provider Registry. The K8s Container SP implements the `container` service type
schema.

## Motivation

### Goals

- Define the lifecycle of a Service Provider (SP) running containers on
  Kubernetes clusters.
- Define the registration flow with DCM SP API.
- Define `CREATE`, `READ`, and `DELETE` endpoints for managing containers
  running on a Kubernetes cluster.
- Define status reporting mechanism for DCM requests.

### Non-Goals

- Define endpoints for day 2 operations (`start`, `stop`, `restart`, `scale`,
  ... or any update) for container instances.
- Mechanism for retrieving available computing, memory, etc., information from
  the SP infrastructure.
- Deployment strategy for the K8s Container SP API.
- Persistent volume support (v1 uses ephemeral storage only).
- Multi-container Pod patterns (initContainers, sidecars) - v1 supports
  single-container Deployments only.
- Support any other kind of resources other than `Deployments`

## Proposal

### Assumptions

- The Kubernetes Container Service Provider is connected to a Kubernetes cluster
  (OCP, KIND, Minikube, ...).
- The Kubernetes Container Service Provider has the necessary RBAC permissions
  to manage `Deployment` and `Service` resources in its configured namespace.
- The DCM Service Provider Registry is reachable for registration.
- The Kubernetes Container Service Provider service has valid Kubernetes
  credentials (`kubeconfig` or in-cluster service account).
- DCM messaging system is reachable for publishing status updates.
- Network policies allow K8s Container SP to communicate with DCM.

### Integration Points

#### Kubernetes Integration

- Uses `k8s.io/client-go` to interact with Kubernetes API.
- Creates and manages `Deployment` and `Service` resources.
- Each container request creates a `Deployment` with `replica count = 1` and
  optionally a `Service` based on SP configuration.
- Leverages Kubernetes `Deployment` lifecycle management.
- Services provide stable endpoints for accessing containers, abstracting Pod IP
  changes during restarts.

#### DCM SP Registry

- Auto-registration on startup with DCM SP Registrar. See documentation for
  [DCM Registration Flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md)

#### DCM SP Health Check

K8s Container SP must expose a health endpoint
`http://<provider-ip>:<port>/health` for DCM control plane to poll every 10
seconds. See documentation for
[SP Health Check](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-provider-health-check/service-provider-health-check.md).

#### DCM SP Status Reporting

- Publish status updates for container instances to the messaging system using
  CloudEvents format. Events are published to the subject:
  `dcm.providers.{providerName}.container.instances.{instanceId}.status`
- See documentation for
  [SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md).
- Use a `SharedIndexInformer` to watch and monitor `Deployment` and `Pod`
  events.

### SP Configuration

The K8s Container SP supports configuration options that control default
behavior for all containers managed by this provider instance.

#### Namespace Configuration

| Field     | Type   | Default | Description                                    |
| --------- | ------ | ------- | ---------------------------------------------- |
| namespace | string | default | Kubernetes namespace for all managed resources |

All resources created by this Service Provider (Deployments, Services) are
deployed in the configured namespace. This setting applies to all container
instances managed by the SP and cannot be overridden per-container.

#### Networking Configuration

| Field              | Type    | Default   | Description                                              |
| ------------------ | ------- | --------- | -------------------------------------------------------- |
| createService      | boolean | true      | Create a Kubernetes Service for each container           |
| defaultServiceType | string  | ClusterIP | Default Service type (ClusterIP, NodePort, LoadBalancer) |

When `createService` is enabled, the SP automatically creates a single
Kubernetes Service for each container, providing a stable endpoint for accessing
the application. The Service includes all ports defined in the container's
`network.ports[]` array - one Service is created per container, not one Service
per port. Users can override these defaults per-container via
`providerHints.kubernetes.service` (see POST endpoint documentation).

### Registration Flow

The K8s Container SP API must successfully complete a registration process to
ensure DCM is aware of it and can use it. During startup, the service uses the
DCM registration client to send a request to the SP API registration endpoint
`POST /api/v1alpha1/providers`. See DCM
[registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md)
for more information.

Example request payload:

```golang
dcm "github.com/dcm-project/service-provider-api/pkg/registration/client"
...
request := &dcm.RegistrationRequest{
    Name: "k8s-container-sp",
    ServiceType: "container",
    ServiceTypeVersion: "1.0.0",
    DisplayName: "Kubernetes Container Service Provider",
    Endpoint:  fmt.Sprintf("%s/api/v1alpha1/containers", apiHost),
    Metadata: dcm.Metadata{ # These are the metadata of the Kubernetes cluster on which the provider is running
      Zone:   "us-east-1b",
      Region: "us-east-1",
      Resources: dcm.ProviderResources{
          TotalCpu: "200",
          TotalMemory: "2TB"
      }
    },
    Operations: []string{"CREATE", "DELETE", "READ"},
}
```

#### Registration Request Validation

The registration payload must conform to the validation requirements defined in
the
[SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

**K8s Container SP-specific requirements:**

- `serviceType` field must be set to `"container"`
- `operations` field must include at minimum: `CREATE`, `READ`, `DELETE`
- `metadata.resources` fields may or may not define the cluster capacity **at
  the time of registration**

#### Registration Process

The K8s Container SP follows the standard self-registration process defined in
the
[SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).
The registration request includes the K8s Container SP endpoint URL in the
format: `fmt.Sprintf("%s/api/v1alpha1/containers", apiHost)`.

### API Endpoints

The CRUD endpoints are consumed by the DCM SP API to create and manage container
resources.

#### Endpoints Overview

| Method | Endpoint                               | Description                   |
| ------ | -------------------------------------- | ----------------------------- |
| POST   | /api/v1alpha1/containers               | Create a new container        |
| GET    | /api/v1alpha1/containers               | List all containers           |
| GET    | /api/v1alpha1/containers/{containerId} | Get a container instance      |
| DELETE | /api/v1alpha1/containers/{containerId} | Delete a container instance   |
| GET    | /api/v1alpha1/health                   | K8s Container SP health check |

##### AEP Compliance

These endpoints are defined based on AEP standards and use `aep-openapi-linter`
to check for compliance with AEP.

#### POST /api/v1alpha1/containers

**Description:** Create a new container instance.

The POST endpoint follows the contract defined in the Container schema spec
pre-defined by DCM core. See
[Container Schema](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#containers)
for the complete specification.

During creation of the resources, each `Deployment`, `Pod`, and `Service` must
be labeled with:

- `managed-by=dcm`
- `dcm-instance-id=<UUID>`
- `dcm-service-type=container`

The `dcm-instance-id` is a UUID generated by DCM. If a Deployment with the same
`metadata.name` already exists in the configured namespace, the K8s Container SP
returns a `409 Conflict` error response without modifying the existing resource.

**Service Configuration via providerHints:**

Users can override the SP default networking configuration on a per-container
basis using `providerHints.kubernetes.service`:

| Field   | Type    | Description                                                       |
| ------- | ------- | ----------------------------------------------------------------- |
| enabled | boolean | Override SP default (true to create, false to skip)               |
| type    | string  | Override default Service type (ClusterIP, NodePort, LoadBalancer) |

If `providerHints.kubernetes.service` is not specified, the SP uses its
configured defaults. If `enabled` is explicitly set to `false`, no Service is
created for that container.

**Example Request Payload:**

```json
{
  "image": { "reference": "quay.io/myapp:v1.2" },
  "resources": {
    "cpu": { "min": 1, "max": 2 },
    "memory": { "min": "1GB", "max": "2GB" }
  },
  "process": {
    "command": ["/app/start"],
    "args": ["--config", "/etc/config.yaml"],
    "env": [
      { "name": "ENV", "value": "production" },
      { "name": "LOG_LEVEL", "value": "info" }
    ]
  },
  "network": {
    "ports": [{ "containerPort": 8080 }, { "containerPort": 9090 }]
  },
  "metadata": {
    "name": "web-app"
  },
  "providerHints": {
    "kubernetes": {
      "service": {
        "enabled": true,
        "type": "LoadBalancer"
      }
    }
  },
  "schemaVersion": "v1alpha1",
  "serviceType": "container"
}
```

> **Note**: The `providerHints.kubernetes.service` section is optional. If
> omitted, the SP uses its configured defaults.

**Response:** Returns `201 Created` with the following payload. The status is
set to `PENDING` after the resource is created.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "web-app",
  "status": "PENDING",
  "metadata": {
    "namespace": "production"
  },
  "service": {
    "clusterIP": "10.96.45.12",
    "type": "LoadBalancer",
    "ports": [
      { "port": 8080, "targetPort": 8080, "protocol": "TCP" },
      { "port": 9090, "targetPort": 9090, "protocol": "TCP" }
    ]
  }
}
```

> **Note**: The `service` field is included only when a Service is created. If
> Service creation is disabled, this field is omitted from the response. The
> `service.ports` array reflects all ports from the request's `network.ports[]`,
> confirming that a single Service exposes all container ports. The
> `metadata.namespace` field reflects the namespace configured in the SP
> configuration file where the resources were created.

**Error Handling:**

- **400 Bad Request**: Invalid request payload or missing required fields
- **409 Conflict**: Deployment with the same `metadata.name` already exists in
  the configured namespace
- **500 Internal Server Error**: Unexpected error during resource creation

#### GET /api/v1alpha1/containers

**Description:** List all container instances with pagination support.

**Query Parameters:**

- `max_page_size` (optional): Maximum number of resources to return in a single
  page. Default: 50.
- `page_token` (optional): Token indicating the starting point for the page.

**Process Flow:**

1. Handler receives `GET` request with optional pagination parameters.
2. Calls `ListContainersFromCluster()` with pagination context.
3. Returns fully-populated container resources per AEP-132.
4. Response includes pagination metadata (`next_page_token`).

**Example Response Payload:**

```json
{
  "results": [
    {
      "requestId": "696511df-1fcb-4f66-8ad5-aeb828f383a0",
      "name": "web-app",
      "status": "RUNNING",
      "ip": "10.244.0.25",
      "ports": [
        { "containerPort": 8080, "hostPort": 30080 },
        { "containerPort": 9090, "hostPort": 30090 }
      ],
      "metadata": {
        "namespace": "production"
      },
      "service": {
        "clusterIP": "10.96.45.12",
        "type": "LoadBalancer",
        "externalIP": "34.123.45.67",
        "ports": [
          { "port": 8080, "targetPort": 8080, "protocol": "TCP" },
          { "port": 9090, "targetPort": 9090, "protocol": "TCP" }
        ]
      }
    },
    {
      "requestId": "c66be104-eea3-4246-975c-e6cc9b32d74d",
      "name": "api-gateway",
      "status": "FAILED",
      "ip": "10.244.0.26",
      "ports": [{ "containerPort": 3000, "hostPort": 30300 }],
      "metadata": {
        "namespace": "production"
      },
      "service": {
        "clusterIP": "10.96.45.13",
        "type": "ClusterIP",
        "ports": [{ "port": 3000, "targetPort": 3000, "protocol": "TCP" }]
      }
    },
    {
      "requestId": "08aa81d1-a0d2-4d5f-a4df-b80addf07781",
      "name": "worker-service",
      "status": "PENDING",
      "ip": "",
      "ports": [],
      "metadata": {
        "namespace": "production"
      }
    }
  ],
  "next_page_token": "a1b2c3d4e5f6"
}
```

**Note:** The response includes fully-populated resources as required by
AEP-132. Each container instance includes all available fields (id, name,
status, ip, ports, metadata, service) to match the detail level of the GET
single resource endpoint. The `service` field is omitted for containers where
Service creation was disabled. The `externalIP` field is included only for
LoadBalancer type Services when an external IP has been assigned.

**Error Handling:**

- **400 Bad Request**: Invalid pagination parameters
- **500 Internal Server Error**: Unexpected error querying Kubernetes API

#### GET /api/v1alpha1/containers/{containerId}

**Description:** Get a specific container instance.

**Process Flow:**

1. Handler receives `GET` request with `containerId` path parameter.
2. Calls `GetContainerFromCluster(containerId)`.
3. Cluster lookup: Query Kubernetes API for `Deployment` with matching
   `dcm-instance-id` label.
4. Pod details: Query `Pod` for runtime information. Extract IP address from Pod
   status. Extract current phase (`Running`, `Pending`, etc.).
5. Service details: Query `Service` with matching `dcm-instance-id` label.
   Extract clusterIP, type, and externalIP (if applicable).
6. Response payload: Return complete container instance object.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "web-app",
  "status": "RUNNING",
  "ip": "10.244.0.25",
  "ports": [
    { "containerPort": 8080, "hostPort": 30080 },
    { "containerPort": 9090, "hostPort": 30090 }
  ],
  "metadata": {
    "namespace": "production"
  },
  "service": {
    "clusterIP": "10.96.45.12",
    "type": "LoadBalancer",
    "externalIP": "34.123.45.67",
    "ports": [
      { "port": 8080, "targetPort": 8080, "protocol": "TCP" },
      { "port": 9090, "targetPort": 9090, "protocol": "TCP" }
    ]
  }
}
```

> **Note**: The payload above is **only** an example. This will be updated when
> the schema contract is finalized by DCM. The `service` field is omitted when
> no Service was created for the container. The `service.ports` array shows all
> ports exposed by the single Service created for this container.

**Error Handling:**

- **404 Not Found**: Container with the specified `containerId` does not exist
- **500 Internal Server Error**: Unexpected error querying Kubernetes API

#### DELETE /api/v1alpha1/containers/{containerId}

**Description:** Delete a container instance.

Remove a single container instance (`Deployment` with cascading delete for
`Pods`) and associated `Service` (if one was created), and returns
`204 No Content`.

**Error Handling:**

- **404 Not Found**: Container with the specified `containerId` does not exist
- **500 Internal Server Error**: Unexpected error during resource deletion

#### GET /api/v1alpha1/health

**Description:** Retrieve the health status for the Kubernetes Container Service
Provider API.

### Status Reporting to DCM

The K8s Container SP uses a **layered monitoring approach** with two
`SharedIndexInformer` instances to watch both `Deployment` and `Pod` resources.
This provides comprehensive visibility into both the desired state (Deployment)
and actual runtime state (Pod), enabling accurate status reporting to DCM.

#### Layered Monitoring Architecture

The K8s Container SP monitors Kubernetes resources at two levels:

1. **Deployment Level**: Tracks creation, rollout status, and replica failures
2. **Pod Level**: Tracks actual runtime state, IP addresses, and container
   statuses

Both informers watch resources labeled with:

- `managed-by=dcm`
- `dcm-service-type=container`

**Rationale for Layered Monitoring**:

- **Deployment-only monitoring** misses runtime details like Pod IP and
  container-level failures
- **Pod-only monitoring** misses Deployment-level failures (e.g., ReplicaSet
  can't create Pods due to quota limits)
- **Layered approach** provides complete visibility into the full lifecycle from
  creation to runtime

#### Status Reconciliation Logic

When either informer receives an event, the K8s Container SP reconciles status
from both resource types using the following precedence rules:

1. **Pod status** (highest priority if Pod exists):
   - Pod.Status.Phase → DCM status mapping
   - Pod.Status.PodIP → Instance IP address
   - Pod.Status.ContainerStatuses → Detailed failure reasons
2. **Deployment status** (if Pod doesn't exist yet):
   - Deployment.Status.Conditions.Available = False → `PENDING`
   - Deployment.Status.Conditions.ReplicaFailure = True → `FAILED`
   - Deployment.Status.Replicas = 0 → `FAILED` (ReplicaSet couldn't create Pod)
3. **Resource not found** (neither exists):
   - Report `DELETED` to DCM
4. **Node lost** (Pod exists but node is unreachable):
   - Pod.Status.Phase = `Unknown` → `UNKNOWN`

**Implementation Notes**:

- Both informers use the same label selector:
  `managed-by=dcm,dcm-service-type=container`
- Status updates are debounced to avoid flooding the messaging system during
  rapid status oscillation (e.g., running→error→running within milliseconds)
- Status updates are published to the messaging system using CloudEvents format
- The `instanceId` of the DCM resource is stored in the label `dcm-instance-id`

For detailed implementation of the `SharedIndexInformer` pattern (setup phase,
event processing flow, pros and cons), see the
[KubeVirt SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/kubevirt-sp/kubevirt-sp.md#status-reporting-to-dcm)
section. The K8s Container SP applies the same pattern with two informers
instead of one.

#### CloudEvents Format

Status updates are published to the messaging system using the
[CloudEvents](https://cloudevents.io/) specification (v1.0). This provides a
standardized "fire-and-forget" mechanism that decouples the K8s Container SP
from the DCM backend.

**Message Subject Hierarchy:**

Events are published to the following subject format:

`dcm.providers.{providerName}.container.instances.{instanceId}.status`

- `providerName`: Unique name of the Kubernetes Container Service Provider
- `instanceId`: UUID of the container instance (from `dcm-instance-id` label)

Events are published to the following type format:

`dcm.providers.{providerName}.status.update`

- `providerName`: Unique name of the Kubernetes Container Service Provider

**Payload Structure:**

```golang
type ContainerStatus struct {
    Status  string `json:"status"`
    Message string `json:"message"`
}
```

**Example Event:**

```golang
cloudevents "github.com/cloudevents/sdk-go/v2"

event := cloudevents.NewEvent()
event.SetID("event-123-456")
event.SetSource("k8s-container-sp-prod")
event.SetType("dcm.providers.k8s-container-sp.status.update")
event.SetSubject("dcm.providers.k8s-container-sp.container.instances.abc-123.status")
event.SetData(cloudevents.ApplicationJSON, ContainerStatus{
    Status:  "RUNNING",
    Message: "Container is running successfully.",
})
```

See
[SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md)
for the complete CloudEvents contract and messaging system details.

#### Status Mapping from Kubernetes to DCM

The following table maps Kubernetes resource statuses to DCM generic statuses.
The K8s Container SP uses the **Priority Order** defined in the reconciliation
logic above (Pod first, then Deployment, then resource not found).

| DCM Status | Primary Source | Kubernetes Condition                             | Precedence |
| ---------- | -------------- | ------------------------------------------------ | ---------- |
| PENDING    | Pod            | Pod.Phase = `Pending` (scheduling, image pull)   | 1          |
| PENDING    | Deployment     | Deployment.Available = False AND no Pod exists   | 2          |
| RUNNING    | Pod            | Pod.Phase = `Running`                            | 1          |
| FAILED     | Pod            | Pod.Phase = `Failed`                             | 1          |
| FAILED     | Deployment     | Deployment.ReplicaFailure = True OR Replicas = 0 | 2          |
| UNKNOWN    | Pod            | Pod.Phase = `Unknown` (node lost)                | 1          |
| DELETED    | Both           | Neither Deployment nor Pod found in cluster      | 3          |

> **Note**: The `SUCCEEDED` status defined in the
> [SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md)
> specification is intentionally excluded from the K8s Container SP. This status
> only applies to Kubernetes resource types like Jobs that have a defined
> completion state. The K8s Container SP uses Deployments which are designed for
> long-running services that continuously run and restart on failure.

**Precedence Rules**:

- **1 (Pod)**: Highest priority - report Pod status if Pod exists (`PENDING`,
  `RUNNING`, `FAILED`, or `UNKNOWN`)
- **2 (Deployment)**: Fallback - report Deployment status if Pod doesn't exist
  but Deployment does (`PENDING` or `FAILED`)
- **3 (Both)**: Resource cleanup complete - report `DELETED` when neither
  Deployment nor Pod exists

For official definitions, see

- [Kubernetes Pod Phase](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase)
- [Deployment Conditions](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#deployment-status)

## Alternatives

### Alternative 1: Use Bare Pods Instead of Deployments

#### Description

Create Pod resources directly instead of Deployments, establishing a 1:1 mapping
between DCM container instance and Kubernetes Pod. This would simplify the
status monitoring architecture by eliminating the need to watch multiple
resource types.

#### Pros

- Simpler monitoring architecture (only watch Pods, no layered informers)
- Perfect 1:1 semantic alignment with "container instance" concept
- No intermediate ReplicaSet layer to debug
- Straightforward lifecycle management
- Reduced complexity in reconciliation logic

#### Cons

- No automatic restart on container failure (containers stay in Failed state)
- No automatic recreation on node failure or Pod eviction
- Poor operational resilience compared to standard Kubernetes patterns
- Manual intervention required for common failure scenarios
- Difficult to add day-2 operations (rolling updates, scaling) in future
  versions
- Users expect cloud services to be self-healing by default

#### Status

Rejected

#### Rationale

DCM container instances should behave like resilient cloud services, not
ephemeral batch jobs. Automatic restart on failure and automatic recreation on
node failure are expected behaviors for production workloads running in managed
container platforms.

While the bare Pod approach would simplify the status monitoring implementation,
it sacrifices operational resilience that users expect from a production
service. The additional monitoring complexity (watching both Deployments and
Pods with layered informers) is justified by:

1. **Production readiness**: Automatic recovery from common failure scenarios
   (container crash, node failure, resource pressure)
2. **Future extensibility**: Deployments provide a foundation for day-2
   operations like rolling updates and controlled scaling

The layered monitoring approach provides complete visibility into both desired
state (Deployment) and actual state (Pod), enabling accurate status reporting
while maintaining production-grade resilience.
