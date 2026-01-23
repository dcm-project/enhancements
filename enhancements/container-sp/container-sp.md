---
title: container-sp
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

# Container Service Provider

## Summary

The Container Service Provider API is a REST API that manages containerized
workloads in a Kubernetes-based cluster. It exposes endpoints for creating,
reading and deleting containers, and integrates with the DCM Service Provider
Registry. The Container SP implements the `container` service type schema
(`v1alpha1`).

## Motivation

### Goals

- Define the lifecycle of a Service Provider (SP) running containers in
  Kubernetes-based cluster.
- Define the registration flow with DCM SP API.
- Define `CREATE`, `READ`, and `DELETE` endpoints for managing containers
  running on a cluster.
- Define status reporting mechanism for DCM requests.

### Non-Goals

- Define endpoints for day 2 operations (`start`, `stop`, `restart`, `scale`,
  ... or any update) for container instances.
- Mechanism for retrieving available computing, memory, etc., information from
  the SP infrastructure.
- Deployment strategy for the Container SP API.
- Persistent volume support (v1 uses ephemeral storage only).

## Proposal

### Assumptions

- The Container Service Provider is connected to a Kubernetes-based cluster
  (OCP, KIND, Minikube, ...).
- The Container Service Provider has the necessary RBAC permissions to manage
  `Deployment` resources across the cluster.
- The DCM Service Provider Registry is reachable for registration.
- The Container Service Provider service has valid Kubernetes credentials
  (`kubeconfig` or in-cluster service account).
- DCM messaging system is reachable for publishing status updates.
- Container SP deployment supports rolling updates with multiple replicas for high availability.
- Kubernetes cluster provides persistent storage for container volumes and operational data.
- Container SP has sufficient privileges for resource cleanup and orphaned resource management.
- Network policies allow Container SP to communicate with DCM during restart and upgrade scenarios.

### Integration Points

#### Kubernetes Integration

- Uses `k8s.io/client-go` to interact with Kubernetes API.
- Creates and manages `Deployment` resources.
- Each container request creates a `Deployment` with `replica count = 1`.
- Leverages Kubernetes `Deployment` lifecycle management.

#### DCM SP Registry

- Auto-registration on startup with DCM SP Registrar. See documentation for
  [DCM Registration Flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md)

#### DCM SP Health Check

Container SP must expose a health endpoint `http://<provider-ip>:<port>/health`
for DCM control plane to poll every 10 seconds. See documentation for
[SP Health Check](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-provider-health-check/service-provider-health-check.md).

#### DCM SP Status Reporting

- Publish status updates for container instances to the messaging system using
  CloudEvents format. Events are published to the subject:
  `dcm.providers.{providerName}.container.instances.{instanceId}.status`
- See documentation for
  [SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md).
- Use a `SharedIndexInformer` to watch and monitor `Deployment` and `Pod`
  events.

### Registration Flow

The Container SP API must successfully complete a registration process to ensure
DCM is aware of it and can use it. During startup, the service uses the DCM
registration client to send a request to the SP API registration endpoint
`POST /api/v1alpha1/providers`. See DCM
[registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md)
for more information.

Example request payload:

```golang
dcm "github.com/dcm-project/service-provider-api/pkg/registration/client"
...
request := &dcm.RegistrationRequest{
    Name: "container-sp",
    ServiceType: "container",
    DisplayName: "Container Service Provider",
    Endpoint:  fmt.Sprintf("%s/api/v1alpha1/containers", apiHost),
    Metadata: dcm.Metadata{ # These are the metadata of the K8s-based cluster on which the provider is running
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

The registration payload must conform to the validation requirements defined in the [SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

**Container SP-specific requirements:**
- `serviceType` field must be set to `"container"`
- `operations` field must include at minimum: `CREATE`, `READ`, `DELETE`
- `metadata.resources` values will be mapped to resource `limits` in Kubernetes `Deployment` manifests

#### Registration Process

The Container SP follows the standard self-registration process defined in the [SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md). The registration request includes the Container SP endpoint URL in the format: `fmt.Sprintf("%s/api/v1alpha1/containers", apiHost)`.

### API Endpoints

The CRUD endpoints are consumed by the DCM SP API to create and manage container
resources.

#### Endpoints Overview

| Method | Endpoint                               | Description                        |
| ------ | -------------------------------------- | ---------------------------------- |
| POST   | /api/v1alpha1/containers               | Create a new container             |
| GET    | /api/v1alpha1/containers               | List all containers                |
| GET    | /api/v1alpha1/containers/{containerId} | Get a container instance           |
| DELETE | /api/v1alpha1/containers/{containerId} | Delete a container instance        |
| GET    | /api/v1alpha1/health                   | Container API service health check |

##### AEP Compliance

These endpoints are defined based on AEP standards and use `aep-openapi-linter`
to check for compliance with AEP.

#### POST /api/v1alpha1/containers

**Description:** Create a new container instance.

The POST endpoint follows the contract defined in the Container schema spec
pre-defined by DCM core. See
[Container Schema](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#containers)
for the complete specification.

During creation of the resources, each `Deployment` and `Pod` must be labeled
with:

- `managed-by=dcm`
- `dcm-instance-id=<UUID>`
- `dcm-service-type=container`

The `dcm-instance-id` is a UUID generated by DCM.

Users can specify the namespace via the `providerHints.kubernetes.namespace`
field.

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
    "ports": [{ "containerPort": 8080 }]
  },
  "metadata": {
    "name": "web-app"
  },
  "providerHints": {
    "kubernetes": {
      "namespace": "production"
    }
  },
  "schemaVersion": "v1alpha1",
  "serviceType": "container"
}
```

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
  }
}
```

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
        {
          "containerPort": 8080,
          "hostPort": 30080
        }
      ],
      "metadata": {
        "namespace": "production"
      }
    },
    {
      "requestId": "c66be104-eea3-4246-975c-e6cc9b32d74d",
      "name": "api-gateway",
      "status": "FAILED",
      "ip": "10.244.0.26",
      "ports": [
        {
          "containerPort": 9090,
          "hostPort": 30090
        }
      ],
      "metadata": {
        "namespace": "production"
      }
    },
    {
      "requestId": "08aa81d1-a0d2-4d5f-a4df-b80addf07781",
      "name": "worker-service",
      "status": "PENDING",
      "ip": "",
      "ports": [],
      "metadata": {
        "namespace": "staging"
      }
    }
  ],
  "next_page_token": "eyJvZmZzZXQiOjMsImxpbWl0Ijo1MH0="
}
```

**Note:** The response includes fully-populated resources as required by
AEP-132. Each container instance includes all available fields (id, name,
status, ip, ports, metadata) to match the detail level of the GET single
resource endpoint.

#### GET /api/v1alpha1/containers/{containerId}

**Description:** Get a specific container instance.

**Process Flow:**

1. Handler receives `GET` request with `containerId` path parameter.
2. Calls `GetContainerFromCluster(containerId)`.
3. Cluster lookup: Query Kubernetes API for `Deployment` with matching
   `dcm-instance-id` label.
4. Pod details: Query `Pod` for runtime information. Extract IP address from Pod
   status. Extract current phase (`Running`, `Pending`, etc.).
5. Response payload: Return complete container instance object.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "web-app",
  "status": "RUNNING",
  "ip": "10.244.0.25",
  "ports": [
    {
      "containerPort": 8080,
      "hostPort": 30080
    }
  ],
  "metadata": {
    "namespace": "production"
  }
}
```

> **Note**: The payload above is **only** an example. This will be updated when
> the schema contract is finalized by DCM.

#### DELETE /api/v1alpha1/containers/{containerId}

**Description:** Delete a container instance.

Remove a single container instance (`Deployment` with cascading delete for
`Pods`) and returns `204 No Content`.

#### GET /api/v1alpha1/health

**Description:** Retrieve the health status for the Container Service Provider
API.

### Status Reporting to DCM

The Container SP uses a **layered monitoring approach** with two
`SharedIndexInformer` instances to watch both `Deployment` and `Pod` resources.
This provides comprehensive visibility into both the desired state (Deployment)
and actual runtime state (Pod), enabling accurate status reporting to DCM.

#### Layered Monitoring Architecture

The Container SP monitors Kubernetes resources at two levels:

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

When either informer receives an event, the Container SP reconciles status from
both resource types using the following precedence rules:

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
section. The Container SP applies the same pattern with two informers instead of
one.

#### CloudEvents Format

Status updates are published to the messaging system using the
[CloudEvents](https://cloudevents.io/) specification (v1.0). This provides a
standardized "fire-and-forget" mechanism that decouples the Container SP from
the DCM backend.

**Message Subject Hierarchy:**

Events are published to the following subject format:

`dcm.providers.{providerName}.container.instances.{instanceId}.status`

- `providerName`: Unique name of the Container Service Provider
- `instanceId`: UUID of the container instance (from `dcm-instance-id` label)

Events are published to the following type format:

`dcm.providers.{providerName}.status.update`

- `providerName`: Unique name of the Container Service Provider

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
event.SetSource("container-sp-prod")
event.SetType("dcm.providers.container-sp.status.update")
event.SetSubject("dcm.providers.container-sp.container.instances.abc-123.status")
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
The Container SP uses the **Priority Order** defined in the reconciliation logic
above (Pod first, then Deployment, then resource not found).

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
> specification is intentionally excluded from the Container SP. This status
> only applies to Kubernetes resource types like Jobs that have a defined
> completion state. The Container SP uses Deployments which are designed for
> long-running services that continuously run and restart on failure.

**Precedence Rules**:

- **1 (Pod)**: Highest priority - report Pod status if Pod exists (`PENDING`,
  `RUNNING`, `FAILED`, or `UNKNOWN`)
- **2 (Deployment)**: Fallback - report Deployment status if Pod doesn't exist
  but Deployment does (`PENDING` or `FAILED`)
- **3 (Both)**: Resource cleanup complete - report `DELETED` when neither
  Deployment nor Pod exists

See
[Kubernetes Pod Phase](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase)
and
[Deployment Conditions](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#deployment-status)
for official definitions.

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
