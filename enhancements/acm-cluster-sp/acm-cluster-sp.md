---
title: acm-cluster-sp
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
creation-date: 2026-01-29
---

# ACM Cluster Service Provider

## Summary

The ACM Cluster Service Provider (ACM Cluster SP) is a REST API that manages
Kubernetes clusters using Red Hat Advanced Cluster Management (ACM). It exposes
endpoints for creating, reading, and deleting clusters, and integrates with the
DCM Service Provider Registry. The ACM Cluster SP supports two provisioning
methods: ClusterDeployment (Hive-based traditional IPI provisioning) and
HypershiftDeployment (Hosted Control Planes for faster provisioning). It
implements the `cluster` service type schema defined by DCM.

## Motivation

### Goals

- Define the lifecycle of a Service Provider (SP) using Red Hat ACM to provision
  Kubernetes clusters.
- Define the registration flow with DCM SP API.
- Define `CREATE`, `READ`, and `DELETE` endpoints for managing clusters
  provisioned via ACM.
- Define status reporting mechanism for DCM requests.
- Support multiple provisioning methods (Hive and Hypershift) configurable via
  `providerHints`.
- Support multiple infrastructure platforms (AWS, OpenStack, Bare Metal).

### Non-Goals

- Define endpoints for day 2 operations (`scale`, `upgrade`, `hibernate`,
  `resume`) for cluster instances.
- Cluster import functionality (attaching pre-existing clusters to ACM) - may be
  considered to v2.
- Deployment strategy for the ACM Cluster SP API.
- Define `UPDATE` endpoint, as this is out of scope for the first version (v1).
- Multi-cluster workload distribution or application deployment on provisioned
  clusters.
- ACM policies, governance, or observability features.

## Proposal

### Assumptions

- The ACM Cluster Service Provider is connected to a Red Hat ACM hub cluster
  with ACM 2.9+ installed.
- The ACM hub cluster has Hive and/or Hypershift operators installed and
  configured based on desired provisioning methods.
- The ACM Cluster Service Provider has the necessary RBAC permissions to manage
  `ClusterDeployment`, `ManagedCluster`, `HostedCluster`, and related resources.
- The DCM Service Provider Registry is reachable for registration.
- The ACM Cluster Service Provider service has valid Kubernetes credentials
  (`kubeconfig` or in-cluster service account) to the ACM hub cluster.
- DCM messaging system is reachable for publishing status updates.
- Infrastructure credentials (cloud provider secrets) are pre-configured on the
  ACM hub cluster and referenced by name in requests.
- Network policies allow ACM Cluster SP to communicate with DCM.

### Integration Points

#### Red Hat ACM Integration

The ACM Cluster SP integrates with ACM through two provisioning paths:

**Hive Integration (ClusterDeployment)**

- Uses `hive.openshift.io/v1` API to create `ClusterDeployment` resources.
- Creates and manages `ClusterDeployment`, `MachinePool`, and `ClusterImageSet`
  Custom Resources.
- Leverages Hive's cluster lifecycle management for traditional IPI
  provisioning.
- Supports AWS, OpenStack, and Bare Metal platforms.

**Hypershift Integration (HostedCluster)**

- Uses `hypershift.openshift.io/v1beta1` API to create `HostedCluster`
  resources.
- Creates and manages `HostedCluster` and `NodePool` Custom Resources.
- Provides faster cluster provisioning with hosted control planes.
- Control plane runs on the ACM hub cluster; worker nodes run on target
  infrastructure.
- Supports AWS platform (OpenStack and Bare Metal support varies by Hypershift
  version).

#### DCM SP Registry

- Auto-registration on startup with DCM SP Registrar. See documentation for
  [DCM Registration Flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

#### DCM SP Health Check

ACM Cluster SP must expose a health endpoint
`http://<provider-ip>:<port>/health` for DCM control plane to poll every 10
seconds. See documentation for
[SP Health Check](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-provider-health-check/service-provider-health-check.md).

#### DCM SP Status Reporting

- Publish status updates for cluster instances to the messaging system using
  CloudEvents format. Events are published to the subject:
  `dcm.providers.{providerName}.cluster.instances.{instanceId}.status`
- See documentation for
  [SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md).
- Use `SharedIndexInformer` to watch `ClusterDeployment` and `HostedCluster`
  resources.

### SP Configuration

The ACM Cluster SP supports configuration options that control default behavior
for all clusters managed by this provider instance.

#### Hub Cluster Configuration

| Field         | Type   | Default | Description                                   |
| ------------- | ------ | ------- | --------------------------------------------- |
| hubKubeconfig | string | ""      | Path to kubeconfig for ACM hub cluster access |
| namespace     | string | default | Default namespace for cluster resources       |

When the ACM Cluster SP is deployed on the ACM hub cluster, `hubKubeconfig` can
be left empty. The SP will use its own service account (assigned during SP
deployment), which must have the necessary RBAC permissions to manage ACM
resources (see Assumptions section).

#### Default Provisioning Configuration

| Field                   | Type   | Default | Description                     |
| ----------------------- | ------ | ------- | ------------------------------- |
| defaultProvisioningType | string | hive    | Default provisioning method     |
| defaultPlatform         | string | aws     | Default infrastructure platform |

**Valid values for v1:**

- `defaultProvisioningType`:
  - `hive` - ClusterDeployment-based provisioning (traditional IPI)
  - `hypershift` - HostedCluster-based provisioning (Hosted Control Planes)
- `defaultPlatform`:
  - `aws` - Amazon Web Services
  - `openstack` - OpenStack
  - `baremetal` - Bare Metal

These defaults are used when `providerHints.acm` is not specified in the
request.

### Registration Flow

The ACM Cluster SP API must successfully complete a registration process to
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
    Name: "acm-cluster-sp",
    ServiceType: "cluster",
    ServiceTypeVersion: "1.0.0",
    DisplayName: "ACM Cluster Service Provider",
    Endpoint:  fmt.Sprintf("%s/api/v1alpha1/clusters", apiHost),
    Metadata: dcm.Metadata{
      Zone:   "us-east-1b",
      Region: "us-east-1",
      Resources: dcm.ProviderResources{
          TotalCpu: "1000",
          TotalMemory: "4TB"
      }
    },
    Operations: []string{"CREATE", "DELETE", "READ"},
}
```

#### Registration Request Validation

The registration payload must conform to the validation requirements defined in
the
[SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

**ACM Cluster SP-specific requirements:**

- `serviceType` field must be set to `"cluster"`
- `operations` field must include at minimum: `CREATE`, `READ`, `DELETE`
- `metadata.resources` fields may represent the aggregate capacity of the
  infrastructure platforms managed by the ACM hub

#### Registration Process

The ACM Cluster SP follows the standard self-registration process defined in the
[SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).
The registration request includes the ACM Cluster SP endpoint URL in the format:
`fmt.Sprintf("%s/api/v1alpha1/clusters", apiHost)`.

### API Endpoints

The CRUD endpoints are consumed by the DCM SP API to create and manage cluster
resources.

#### Endpoints Overview

| Method | Endpoint                           | Description               |
| ------ | ---------------------------------- | ------------------------- |
| POST   | /api/v1alpha1/clusters             | Create a new cluster      |
| GET    | /api/v1alpha1/clusters             | List all clusters         |
| GET    | /api/v1alpha1/clusters/{clusterId} | Get a cluster instance    |
| DELETE | /api/v1alpha1/clusters/{clusterId} | Delete a cluster instance |
| GET    | /api/v1alpha1/health               | ACM Cluster SP health     |

##### AEP Compliance

These endpoints are defined based on AEP standards and use `aep-openapi-linter`
to check for compliance with AEP.

#### POST /api/v1alpha1/clusters

**Description:** Create a new Kubernetes cluster.

The POST endpoint follows the contract defined in the Cluster schema spec
pre-defined by DCM core. See
[Cluster Schema](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#kubernetes-cluster)
for the complete specification.

During creation of the resources, each `ClusterDeployment` or `HostedCluster`
must be labeled with:

- `managed-by=dcm`
- `dcm-instance-id=<UUID>`
- `dcm-service-type=cluster`

The `dcm-instance-id` is a UUID generated by DCM. If a cluster with the same
`metadata.name` already exists, the ACM Cluster SP returns a `409 Conflict`
error response without modifying the existing resource.

**Provisioning Method Selection via providerHints:**

Users specify the provisioning method and platform configuration using
`providerHints.acm`:

| Field            | Type   | Description                                              |
| ---------------- | ------ | -------------------------------------------------------- |
| provisioningType | string | Provisioning method: `hive` or `hypershift`              |
| platform         | string | Infrastructure platform: `aws`, `openstack`, `baremetal` |
| credentialsRef   | string | Name of the credentials secret on ACM hub                |
| baseDomain       | string | Base DNS domain for the cluster                          |

> **Note**: The cloud region is inferred from the SP's registration metadata
> (`metadata.region`). Clusters are provisioned in the region specified during
> SP registration.

**Example Request Payload (Hive on AWS):**

```json
{
  "version": "1.29",
  "nodes": {
    "controlPlane": {
      "count": 3,
      "cpu": 4,
      "memory": "16GB",
      "storage": "120GB"
    },
    "worker": {
      "count": 3,
      "cpu": 8,
      "memory": "32GB",
      "storage": "250GB"
    }
  },
  "metadata": {
    "name": "prod-cluster-01"
  },
  "providerHints": {
    "acm": {
      "provisioningType": "hive",
      "platform": "aws",
      "credentialsRef": "aws-credentials",
      "baseDomain": "example.com"
    }
  },
  "schemaVersion": "v1alpha1",
  "serviceType": "cluster"
}
```

**Example Request Payload (Hypershift on AWS):**

```json
{
  "version": "1.29",
  "nodes": {
    "controlPlane": {
      "count": 3,
      "cpu": 4,
      "memory": "16GB",
      "storage": "120GB"
    },
    "worker": {
      "count": 3,
      "cpu": 8,
      "memory": "32GB",
      "storage": "250GB"
    }
  },
  "metadata": {
    "name": "dev-cluster-01"
  },
  "providerHints": {
    "acm": {
      "provisioningType": "hypershift",
      "platform": "aws",
      "credentialsRef": "aws-credentials",
      "baseDomain": "example.com"
    }
  },
  "schemaVersion": "v1alpha1",
  "serviceType": "cluster"
}
```

> **Note**: For Hypershift, the `controlPlane` configuration defines the hosted
> control plane resources running on the ACM hub cluster. The `worker`
> configuration defines the NodePool for worker nodes on the target
> infrastructure.

**Response:** Returns `201 Created` with the following payload. The status is
set to `PENDING` after the resource is created.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "prod-cluster-01",
  "status": "PENDING",
  "provisioningType": "hive",
  "platform": "aws",
  "metadata": {
    "namespace": "prod-cluster-01"
  }
}
```

**Error Handling:**

- **400 Bad Request**: Invalid request payload or missing required fields
- **409 Conflict**: Cluster with the same `metadata.name` already exists
- **422 Unprocessable Entity**: Unsupported platform or provisioning type
  combination
- **500 Internal Server Error**: Unexpected error during resource creation

#### GET /api/v1alpha1/clusters

**Description:** List all cluster instances with pagination support.

**Query Parameters:**

- `max_page_size` (optional): Maximum number of resources to return in a single
  page. Default: 50.
- `page_token` (optional): Token indicating the starting point for the page.

**Process Flow:**

1. Handler receives `GET` request with optional pagination parameters.
2. Calls `ListClustersFromHub()` with pagination context.
3. Queries both `ClusterDeployment` and `HostedCluster` resources labeled with
   `managed-by=dcm`.
4. Returns fully-populated cluster resources per AEP-132.
5. Response includes pagination metadata (`next_page_token`).

**Example Response Payload:**

```json
{
  "results": [
    {
      "requestId": "696511df-1fcb-4f66-8ad5-aeb828f383a0",
      "name": "prod-cluster-01",
      "status": "RUNNING",
      "provisioningType": "hive",
      "platform": "aws",
      "version": "1.29.4",
      "apiEndpoint": "https://api.prod-cluster-01.example.com:6443",
      "consoleUrl": "https://console-openshift-console.apps.prod-cluster-01.example.com",
      "nodes": {
        "controlPlane": { "ready": 3, "total": 3 },
        "worker": { "ready": 3, "total": 3 }
      },
      "kubeconfig": {
        "secretName": "prod-cluster-01-admin-kubeconfig",
        "secretNamespace": "prod-cluster-01"
      },
      "metadata": {
        "namespace": "prod-cluster-01",
        "createdAt": "2026-01-29T10:30:00Z"
      }
    },
    {
      "requestId": "c66be104-eea3-4246-975c-e6cc9b32d74d",
      "name": "dev-cluster-01",
      "status": "PROVISIONING",
      "provisioningType": "hypershift",
      "platform": "aws",
      "version": "1.29",
      "apiEndpoint": "",
      "consoleUrl": "",
      "nodes": {
        "controlPlane": { "ready": 0, "total": 3 },
        "worker": { "ready": 0, "total": 3 }
      },
      "kubeconfig": {
        "secretName": "",
        "secretNamespace": "clusters"
      },
      "metadata": {
        "namespace": "clusters",
        "createdAt": "2026-01-29T11:45:00Z"
      }
    },
    {
      "requestId": "08aa81d1-a0d2-4d5f-a4df-b80addf07781",
      "name": "staging-cluster",
      "status": "FAILED",
      "provisioningType": "hive",
      "platform": "openstack",
      "version": "1.28",
      "apiEndpoint": "",
      "consoleUrl": "",
      "nodes": {
        "controlPlane": { "ready": 0, "total": 3 },
        "worker": { "ready": 0, "total": 3 }
      },
      "kubeconfig": {
        "secretName": "",
        "secretNamespace": "staging-cluster"
      },
      "metadata": {
        "namespace": "staging-cluster",
        "createdAt": "2026-01-28T09:15:00Z"
      }
    }
  ],
  "next_page_token": "a1b2c3d4e5f6"
}
```

> **Note**: Per AEP-132, LIST returns fully-populated resources with the same
> structure as GET. Fields like `apiEndpoint`, `consoleUrl`, and
> `kubeconfig.secretName` may be empty for clusters that are still provisioning
> or have failed.

**Error Handling:**

- **400 Bad Request**: Invalid pagination parameters
- **500 Internal Server Error**: Unexpected error querying ACM hub

#### GET /api/v1alpha1/clusters/{clusterId}

**Description:** Get a specific cluster instance.

**Process Flow:**

1. Handler receives `GET` request with `clusterId` path parameter.
2. Calls `GetClusterFromHub(clusterId)`.
3. Cluster lookup: Query ACM hub for `ClusterDeployment` or `HostedCluster` with
   matching `dcm-instance-id` label.
4. Extract cluster details: API endpoint, console URL, version, node counts.
5. For Hive clusters: Check `ClusterDeployment.Status` conditions.
6. For Hypershift clusters: Check `HostedCluster.Status` conditions.
7. Response payload: Return complete cluster instance object.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "prod-cluster-01",
  "status": "RUNNING",
  "provisioningType": "hive",
  "platform": "aws",
  "version": "1.29.4",
  "apiEndpoint": "https://api.prod-cluster-01.example.com:6443",
  "consoleUrl": "https://console-openshift-console.apps.prod-cluster-01.example.com",
  "nodes": {
    "controlPlane": {
      "ready": 3,
      "total": 3
    },
    "worker": {
      "ready": 3,
      "total": 3
    }
  },
  "kubeconfig": {
    "secretName": "prod-cluster-01-admin-kubeconfig",
    "secretNamespace": "prod-cluster-01"
  },
  "metadata": {
    "namespace": "prod-cluster-01",
    "createdAt": "2026-01-29T10:30:00Z"
  }
}
```

> **Note**: The payload above is **only** an example. This will be updated when
> the schema contract is finalized by DCM. The `kubeconfig` field provides a
> reference to the secret containing admin credentials for the provisioned
> cluster.

**Error Handling:**

- **404 Not Found**: Cluster with the specified `clusterId` does not exist
- **500 Internal Server Error**: Unexpected error querying ACM hub

#### DELETE /api/v1alpha1/clusters/{clusterId}

**Description:** Delete a cluster instance.

Remove a cluster instance (`ClusterDeployment` or `HostedCluster` with cascading
delete for all child resources including `MachinePools`, `NodePools`, and
`ManagedCluster`), and returns `204 No Content`.

**Process Flow:**

1. Handler receives `DELETE` request with `clusterId` path parameter.
2. Lookup cluster resource by `dcm-instance-id` label.
3. Determine resource type (ClusterDeployment or HostedCluster).
4. Delete the resource with cascading deletion.
5. Return `204 No Content` on success.

**Error Handling:**

- **404 Not Found**: Cluster with the specified `clusterId` does not exist
- **500 Internal Server Error**: Unexpected error during resource deletion

#### GET /api/v1alpha1/health

**Description:** Retrieve the health status for the ACM Cluster Service Provider
API.

The health check verifies:

- Connectivity to ACM hub cluster
- Hive operator availability (if Hive provisioning is enabled)
- Hypershift operator availability (if Hypershift provisioning is enabled)

### Status Reporting to DCM

The ACM Cluster SP uses a `SharedIndexInformer` to watch cluster resources and
report status changes to DCM. The informer watches both `ClusterDeployment` and
`HostedCluster` resources based on the provisioning methods enabled in the SP
configuration.

#### Informer Setup

Resources are watched with the label selector:

- `managed-by=dcm`
- `dcm-service-type=cluster`

The `instanceId` of the DCM resource is stored in the label `dcm-instance-id`.

For detailed implementation of the `SharedIndexInformer` pattern (setup phase,
event processing flow, pros and cons), see the
[KubeVirt SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/kubevirt-sp/kubevirt-sp.md#status-reporting-to-dcm)
section.

#### CloudEvents Format

Status updates are published to the messaging system using the
[CloudEvents](https://cloudevents.io/) specification (v1.0).

**Message Subject Hierarchy:**

Events are published to the following subject format:

`dcm.providers.{providerName}.cluster.instances.{instanceId}.status`

- `providerName`: Unique name of the ACM Cluster Service Provider
- `instanceId`: UUID of the cluster instance (from `dcm-instance-id` label)

Events are published with the following type format:

`dcm.providers.{providerName}.status.update`

**Payload Structure:**

```golang
type ClusterStatus struct {
    Status  string `json:"status"`
    Message string `json:"message"`
}
```

**Example Event:**

```golang
cloudevents "github.com/cloudevents/sdk-go/v2"

event := cloudevents.NewEvent()
event.SetID("event-123-456")
event.SetSource("acm-cluster-sp-prod")
event.SetType("dcm.providers.acm-cluster-sp.status.update")
event.SetSubject("dcm.providers.acm-cluster-sp.cluster.instances.abc-123.status")
event.SetData(cloudevents.ApplicationJSON, ClusterStatus{
    Status:  "RUNNING",
    Message: "Cluster is running and all nodes are ready.",
})
```

#### Status Mapping - Hive (ClusterDeployment)

The following table maps Hive `ClusterDeployment` conditions to DCM statuses:

| DCM Status   | ClusterDeployment Condition                | Description                  |
| ------------ | ------------------------------------------ | ---------------------------- |
| PENDING      | No conditions set                          | Cluster creation initiated   |
| PROVISIONING | Provisioning=True                          | Cluster is being provisioned |
| RUNNING      | Provisioned=True, Ready=True               | Cluster is fully operational |
| FAILED       | ProvisionFailed=True OR InstallFailed=True | Cluster provisioning failed  |
| DELETED      | N/A                                        | ClusterDeployment not found  |

See
[Hive ClusterDeployment Conditions](https://github.com/openshift/hive/blob/master/apis/hive/v1/clusterdeployment_types.go)
for official definitions.

#### Status Mapping - Hypershift (HostedCluster)

The following table maps Hypershift `HostedCluster` conditions to DCM statuses:

| DCM Status   | HostedCluster Condition           | Description                         |
| ------------ | --------------------------------- | ----------------------------------- |
| PENDING      | Progressing=Unknown               | Cluster creation initiated          |
| PROVISIONING | Progressing=True, Available=False | Control plane being provisioned     |
| RUNNING      | Available=True, Progressing=False | Cluster is fully operational        |
| FAILED       | Degraded=True                     | Cluster is in degraded/failed state |
| DELETED      | N/A                               | HostedCluster not found             |

See
[Hypershift HostedCluster API](https://github.com/openshift/hypershift/blob/main/api/hypershift/v1beta1/hostedcluster_types.go)
for official definitions.

#### Status Reconciliation Logic

When the informer receives an event, the ACM Cluster SP determines the
provisioning type from the resource and applies the appropriate status mapping:

1. Check resource type (`ClusterDeployment` or `HostedCluster`).
2. Apply the corresponding status mapping table.
3. Publish status update to DCM via CloudEvents.

## Alternatives

### Alternative 1: Direct Cluster Provisioning Without ACM

#### Description

Provision clusters directly using platform-specific installers (OpenShift
Installer, eksctl, gcloud) without the ACM abstraction layer. Each platform
would have its own provisioning logic within the SP.

#### Pros

- No dependency on ACM installation
- Direct control over provisioning process
- Potentially simpler for single-platform deployments

#### Cons

- Loses multi-cluster management capabilities
- No unified view of all clusters
- Each platform requires separate implementation
- No built-in cluster lifecycle management
- Misses ACM features like policies, observability, and governance

#### Status

Rejected

#### Rationale

ACM provides a unified abstraction layer for multi-cluster management that
aligns with DCM's goals of managing distributed infrastructure. The benefits of
centralized cluster management, consistent lifecycle operations, and
extensibility to additional platforms outweigh the ACM dependency.

### Alternative 2: Terraform-Based Provisioning

#### Description

Use Terraform with platform-specific providers (AWS, OpenStack, vSphere) to
provision clusters, storing state in a backend and managing lifecycle through
Terraform operations.

#### Pros

- Well-established infrastructure-as-code approach
- Extensive platform support
- Declarative configuration

#### Cons

- Requires Terraform state management
- More complex error handling and recovery
- Not Kubernetes-native
- Additional operational complexity
- Doesn't integrate with OpenShift/ACM ecosystem

#### Status

Rejected

#### Rationale

ACM provides a Kubernetes-native approach that integrates better with the DCM
architecture and OpenShift ecosystem. The Kubernetes CRD-based model offers
better observability, reconciliation, and integration with existing tooling.

### Alternative 3: Cluster Import Only (No Provisioning)

#### Description

Only support importing existing clusters into ACM for management, without
provisioning new clusters. Users would provision clusters through other means
and then attach them to DCM via ACM's import mechanism.

#### Pros

- Simpler implementation
- Works with any existing cluster
- No cloud provider credentials needed

#### Cons

- Doesn't provide full lifecycle management
- Users need separate tooling for cluster provisioning
- Inconsistent experience compared to other DCM Service Providers

#### Status

Deferred

#### Rationale

Cluster import is a valuable capability that complements provisioning. However,
for v1, the focus is on providing full lifecycle management through
provisioning. Cluster import will be added in v2 to support brownfield scenarios
where users have pre-existing clusters.

