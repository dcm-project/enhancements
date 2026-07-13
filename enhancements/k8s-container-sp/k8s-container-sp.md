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
  optionally a `Service` based on per-port `visibility` settings.
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
  CloudEvents format. Events are published to the subject: `dcm.container`
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

| Field               | Type   | Required | Description                                                       |
| ------------------- | ------ | -------- | ----------------------------------------------------------------- |
| externalServiceType | string | Yes      | Service type for `external` visibility (LoadBalancer or NodePort) |

Service creation is driven by the per-port `visibility` field defined in the
Container Port schema (see
[Service Type Definitions](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#container-port-object)).
Each port declares its visibility as `none`, `internal`, or `external`:

- When any port has `visibility` != `none`, a single Kubernetes Service is
  created including all non-none ports.
- When all non-none ports have `visibility=internal`, the Service type is
  `ClusterIP`.
- When any port has `visibility=external`, the Service type is the configured
  `externalServiceType`.
- When all ports have `visibility=none` (or no ports exist), no Service is
  created.

### Registration Flow

The K8s Container SP API must successfully complete a registration process to
ensure DCM is aware of it and can use it. During startup, the service uses the
DCM registration client to send a request to the SP API registration endpoint
`POST /api/v1alpha1/providers`. See DCM
[registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md)
for more information.

Example request payload:

```json
{
  "name": "k8s-container-sp",
  "serviceType": "container",
  "schemaVersion": "v1alpha1",
  "displayName": "Kubernetes Container Service Provider",
  "endpoint": "https://k8s-container-sp.example.com/api/v1alpha1/containers",
  "operations": ["CREATE", "DELETE", "READ"],
  "metadata": {
    "zone": "us-east-1b",
    "regionCode": "us-east-1",
    "resources": {
      "totalCpu": "200",
      "totalMemory": "2TB"
    }
  }
}
```

#### Registration Request Validation

The registration payload must conform to the validation requirements defined in
the
[SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

**K8s Container SP-specific requirements:**

- `serviceType` field must be set to `"container"`
- `schemaVersion` field must be set to `"v1alpha1"`
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
| GET    | /api/v1alpha1/containers/health        | K8s Container SP health check |

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

- `dcm.project/managed-by=dcm`
- `dcm.project/dcm-instance-id=<UUID>`
- `dcm.project/dcm-service-type=container`

The `dcm-instance-id` is a unique identifier — either a server-generated UUID or
a client-specified ID provided via the `?id=` query parameter (validated against
AEP-122 pattern `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`). Kubernetes resource
names are server-assigned using the `generateName` mechanism with
`metadata.name` as the prefix (e.g., `"web-app-"`). If a container with the same
`dcm-instance-id` already exists, the K8s Container SP returns a `409 Conflict`
error response without modifying the existing resource.

**providerHints:**

The request body supports an optional `providerHints` field (type: object,
additionalProperties: true) as defined in the
[Service Type Definitions](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#providerhints-object).
The SP accepts `providerHints` on input but does not act on hint content in the
current implementation.

> **Note**: It is not yet designed how `providerHints` can be leveraged within
> the DCM control plane to influence provider behavior. As a result, Service
> creation is currently driven by the per-port `visibility` field (see
> Networking Configuration above), which is the canonical approach. Future
> iterations may define how hints flow from catalog to provider and influence
> resource creation.

**Example Request Payload:**

```json
{
  "spec": {
    "serviceType": "container",
    "metadata": {
      "name": "web-app"
    },
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
      "ports": [
        { "containerPort": 8080, "visibility": "external" },
        { "containerPort": 9090, "visibility": "internal" }
      ]
    }
  }
}
```

The request and response use the same `Container` schema. The `spec` field
contains the container input fields as defined in the
[Container Schema](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#containers).
Server-generated read-only fields (`id`, `path`, `status`, `createTime`,
`updateTime`, `service`, `spec.metadata.namespace`) appear only in the response.

**Response:** Returns `201 Created` with the following payload. The status is
set to `PENDING` after the resource is created.

**Example Response Payload:**

```json
{
  "id": "123e4567-e89b-12d3-a456-426614174000",
  "path": "containers/123e4567-e89b-12d3-a456-426614174000",
  "status": "PENDING",
  "createTime": "2026-01-21T10:00:00Z",
  "updateTime": "2026-01-21T10:00:00Z",
  "spec": {
    "serviceType": "container",
    "metadata": {
      "name": "web-app",
      "namespace": "production"
    },
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
      "ports": [
        { "containerPort": 8080, "visibility": "external" },
        { "containerPort": 9090, "visibility": "internal" }
      ]
    }
  },
  "service": {
    "name": "web-app-k7x2m",
    "clusterIP": "10.96.45.12",
    "type": "LoadBalancer",
    "ports": [
      { "port": 8080, "targetPort": 8080, "protocol": "TCP" },
      { "port": 9090, "targetPort": 9090, "protocol": "TCP" }
    ]
  }
}
```

> **Note**: The `service` field is included only when a Service is created
> (i.e., when at least one port has `visibility` != `none`). The `service.ports`
> array reflects all non-none ports from the request's `spec.network.ports[]`,
> confirming that a single Service exposes all applicable container ports. The
> `spec.metadata.namespace` field reflects the namespace configured in the SP.
> The `service.name` is the server-assigned Kubernetes Service resource name.

**Error Handling:**

- **400 Bad Request**: Invalid request payload or missing required fields
- **409 Conflict**: Container with the same `dcm-instance-id` already exists
- **500 Internal Server Error**: Unexpected error during resource creation

#### GET /api/v1alpha1/containers

**Description:** List all container instances with pagination support.

**Query Parameters:**

- `maxPageSize` (optional): Maximum number of resources to return in a single
  page. Default: 50.
- `pageToken` (optional): Token indicating the starting point for the page.

**Process Flow:**

1. Handler receives `GET` request with optional pagination parameters.
2. Calls `ListContainersFromCluster()` with pagination context.
3. Returns fully-populated container resources per AEP-132.
4. Response includes pagination metadata (`nextPageToken`).

**Example Response Payload:**

```json
{
  "containers": [
    {
      "id": "696511df-1fcb-4f66-8ad5-aeb828f383a0",
      "path": "containers/696511df-1fcb-4f66-8ad5-aeb828f383a0",
      "status": "RUNNING",
      "createTime": "2026-01-20T08:00:00Z",
      "updateTime": "2026-01-20T08:01:30Z",
      "spec": {
        "serviceType": "container",
        "metadata": {
          "name": "web-app",
          "namespace": "production"
        },
        "image": { "reference": "quay.io/myapp:v1.2" },
        "resources": {
          "cpu": { "min": 1, "max": 2 },
          "memory": { "min": "1GB", "max": "2GB" }
        },
        "network": {
          "ip": "10.244.0.25",
          "ports": [
            { "containerPort": 8080, "visibility": "external" },
            { "containerPort": 9090, "visibility": "internal" }
          ]
        }
      },
      "service": {
        "name": "web-app-k7x2m",
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
      "id": "c66be104-eea3-4246-975c-e6cc9b32d74d",
      "path": "containers/c66be104-eea3-4246-975c-e6cc9b32d74d",
      "status": "FAILED",
      "createTime": "2026-01-20T09:00:00Z",
      "updateTime": "2026-01-20T09:02:00Z",
      "spec": {
        "serviceType": "container",
        "metadata": {
          "name": "api-gateway",
          "namespace": "production"
        },
        "image": { "reference": "docker.io/api-gw:v3.1" },
        "resources": {
          "cpu": { "min": 1, "max": 1 },
          "memory": { "min": "512MB", "max": "1GB" }
        },
        "network": {
          "ip": "10.244.0.26",
          "ports": [{ "containerPort": 3000, "visibility": "internal" }]
        }
      },
      "service": {
        "name": "api-gateway-m9p3q",
        "clusterIP": "10.96.45.13",
        "type": "ClusterIP",
        "ports": [{ "port": 3000, "targetPort": 3000, "protocol": "TCP" }]
      }
    },
    {
      "id": "08aa81d1-a0d2-4d5f-a4df-b80addf07781",
      "path": "containers/08aa81d1-a0d2-4d5f-a4df-b80addf07781",
      "status": "PENDING",
      "createTime": "2026-01-20T10:00:00Z",
      "updateTime": "2026-01-20T10:00:00Z",
      "spec": {
        "serviceType": "container",
        "metadata": {
          "name": "worker-service",
          "namespace": "production"
        },
        "image": { "reference": "quay.io/worker:v2.0" },
        "resources": {
          "cpu": { "min": 2, "max": 4 },
          "memory": { "min": "1GB", "max": "4GB" }
        },
        "network": {
          "ports": [{ "containerPort": 5000, "visibility": "none" }]
        }
      }
    }
  ],
  "nextPageToken": "a1b2c3d4e5f6"
}
```

**Note:** The response includes fully-populated resources as required by
AEP-132. Each container instance includes all fields (read-only envelope fields
plus the full `spec` with all input fields echoed back) to match the detail
level of the GET single resource endpoint. The `service` field is omitted for
containers where all ports have `visibility=none`. The `externalIP` field is
included only for LoadBalancer type Services when an external IP has been
assigned.

**Error Handling:**

- **400 Bad Request**: Invalid pagination parameters
- **500 Internal Server Error**: Unexpected error querying Kubernetes API

#### GET /api/v1alpha1/containers/{containerId}

**Description:** Get a specific container instance.

**Process Flow:**

1. Handler receives `GET` request with `containerId` path parameter.
2. Calls `GetContainerFromCluster(containerId)`.
3. Cluster lookup: Query Kubernetes API for `Deployment` with matching
   `dcm.project/dcm-instance-id` label.
4. Pod details: Query `Pod` for runtime information. Extract IP address from Pod
   status. Extract current phase (`Running`, `Pending`, etc.).
5. Service details: Query `Service` with matching `dcm.project/dcm-instance-id`
   label. Extract clusterIP, type, and externalIP (if applicable).
6. Response payload: Return complete container instance object.

**Example Response Payload:**

```json
{
  "id": "123e4567-e89b-12d3-a456-426614174000",
  "path": "containers/123e4567-e89b-12d3-a456-426614174000",
  "status": "RUNNING",
  "createTime": "2026-01-21T10:00:00Z",
  "updateTime": "2026-01-21T10:01:30Z",
  "spec": {
    "serviceType": "container",
    "metadata": {
      "name": "web-app",
      "namespace": "production"
    },
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
      "ip": "10.244.0.25",
      "ports": [
        { "containerPort": 8080, "visibility": "external" },
        { "containerPort": 9090, "visibility": "internal" }
      ]
    }
  },
  "service": {
    "name": "web-app-k7x2m",
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

> **Note**: The `service` field is omitted when no Service was created for the
> container (all ports have `visibility=none`). The `service.ports` array shows
> all ports exposed by the single Service created for this container. The
> `service.name` is the server-assigned Kubernetes Service resource name. On
> GET, the `visibility` field on `spec.network.ports` is inferred from the
> Service type: `internal` for ClusterIP, `external` for LoadBalancer/NodePort,
> `none` if no Service exists.

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

#### GET /api/v1alpha1/containers/health

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

- `dcm.project/managed-by=dcm`
- `dcm.project/dcm-service-type=container`

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
  `dcm.project/managed-by=dcm,dcm.project/dcm-service-type=container`
- Status updates are debounced to avoid flooding the messaging system during
  rapid status oscillation (e.g., running→error→running within milliseconds)
- Status updates are published to the messaging system using CloudEvents format
- The `instanceId` of the DCM resource is stored in the label
  `dcm.project/dcm-instance-id`

For detailed implementation of the `SharedIndexInformer` pattern (setup phase,
event processing flow, pros and cons), see the
[KubeVirt SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/kubevirt-sp/kubevirt-sp.md#status-reporting-to-dcm)
section. The K8s Container SP applies the same pattern with two informers
instead of one.

#### CloudEvents Format

Status updates are published to the messaging system using the
[CloudEvents](https://cloudevents.io/) specification (v1.0). This provides a
standardized "fire-and-forget" mechanism that decouples the K8s Container SP
from the DCM backend. Events are published to the messaging system on the
subject `dcm.container`.

**CloudEvent Attributes:**

| Attribute       | Value                          |
| --------------- | ------------------------------ |
| specversion     | 1.0                            |
| id              | Unique event identifier (UUID) |
| source          | `dcm/providers/{providerName}` |
| type            | `dcm.status.container`         |
| subject         | `dcm.container`                |
| datacontenttype | `application/json`             |

**Data Payload Structure:**

```json
{
  "id": "<dcm-instance-id>",
  "status": "<DCM_STATUS>",
  "message": "<human-readable description>"
}
```

The instance identity is carried in the data payload's `id` field, not in the
messaging subject or CloudEvent attributes. This allows a single wildcard
subscription (`dcm.*`) on the consumer side.

**Example Event Payload:**

```json
{
  "specversion": "1.0",
  "id": "event-123-456",
  "source": "dcm/providers/k8s-container-sp",
  "type": "dcm.status.container",
  "subject": "dcm.container",
  "datacontenttype": "application/json",
  "data": {
    "id": "abc-123",
    "status": "RUNNING",
    "message": "Container is running successfully."
  }
}
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
