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

The ACM Cluster Service Provider (ACM Cluster SP) is a REST (Representational
State Transfer) API that manages Kubernetes clusters using Red Hat Advanced
Cluster Management (ACM). It exposes endpoints for creating, reading, and
deleting clusters, and integrates with the DCM (Data Center Management) Service
Provider Registry. The ACM Cluster SP uses HyperShift (Hosted Control Planes) to
provision clusters on KubeVirt and BareMetal platforms. It implements the
`cluster` service type schema defined by DCM.

### Scope Notes (v1)

This document defines the v1 implementation scope, which focuses on:

- **Provisioning Method**: HyperShift only (HostedCluster + NodePool CRDs
  (Custom Resource Definitions))
- **Platforms**: KubeVirt (VMs as worker nodes on OpenShift Virtualization) and
  BareMetal (via Agent provider with Assisted Installer)

This narrow scope enables faster implementation and validation. Future versions
may expand support to include:

- Hive-based provisioning (ClusterDeployment) for traditional IPI workflows
- Additional platforms: AWS, OpenStack, and other cloud providers

## Motivation

### Goals

- Define the lifecycle of a Service Provider (SP) using Red Hat ACM to provision
  Kubernetes clusters via HyperShift (Hosted Control Planes).
- Define the registration flow with DCM SP API.
- Define `CREATE`, `READ`, and `DELETE` endpoints for managing clusters
  provisioned via ACM HyperShift.
- Define status reporting mechanism for DCM requests.
- Support KubeVirt platform (worker nodes as VMs on OpenShift Virtualization).
- Support BareMetal platform (worker nodes on bare metal hosts via Agent
  provider).
- Define how the cluster credentials will be communicated to the user.

### Non-Goals

- Define endpoints for day 2 operations (`scale`, `upgrade`, `hibernate`,
  `resume`) for cluster instances.
- Cluster import functionality (attaching pre-existing clusters to ACM) - may be
  considered for future versions.
- Deployment strategy for the ACM Cluster SP API.
- Define `UPDATE` endpoint, as this is out of scope for the first version (v1).
- Multi-cluster workload distribution or application deployment on provisioned
  clusters.
- ACM policies, governance, or observability features.
- **Hive-based provisioning (ClusterDeployment)** - Traditional IPI
  (Installer-Provisioned Infrastructure) provisioning may be deferred to future
  versions. HyperShift provides faster provisioning and simpler infrastructure
  requirements for the target platforms.
- **AWS, OpenStack, and other cloud provider platforms** - v1 focuses on
  KubeVirt and BareMetal. Cloud provider support may be added in future
  versions.

## Proposal

### Assumptions

- The ACM Cluster Service Provider is connected to a Red Hat ACM hub cluster
  with ACM installed.
- The ACM hub cluster has the HyperShift operator installed and configured with
  KubeVirt and Agent providers enabled.
- The ACM Cluster Service Provider has the necessary RBAC (Role-Based Access
  Control) permissions to manage `HostedCluster`, `NodePool`, `ManagedCluster`,
  and related resources.
- The DCM Service Provider Registry is reachable for registration.
- The ACM Cluster Service Provider service has valid Kubernetes credentials
  (`kubeconfig` or in-cluster service account) to the ACM hub cluster.
- DCM messaging system is reachable for publishing status updates.
- Network policies allow ACM Cluster SP to communicate with DCM.

**KubeVirt Platform Assumptions:**

- An OpenShift cluster with OpenShift Virtualization (KubeVirt) is available as
  the infrastructure provider for worker node VMs (Virtual Machines).
- The HyperShift operator has access to the KubeVirt infrastructure cluster
  (either the hub cluster itself or a separate cluster).
- Sufficient compute, memory, and storage resources are available on the
  KubeVirt infrastructure for provisioning worker node VMs.

**BareMetal Platform Assumptions:**

- Central Infrastructure Management (CIM) is installed and configured on the ACM
  hub cluster.
- `InfraEnv` resources are pre-configured with appropriate network and discovery
  settings for bare metal hosts.
- Bare metal hosts are registered as `Agent` resources in the hub cluster and
  are available for allocation to NodePools.
- Hosts have been discovered and approved via the Assisted Installer flow.

### Integration Points

#### Red Hat ACM Integration

The ACM Cluster SP integrates with ACM using HyperShift (Hosted Control Planes)
for cluster provisioning. HyperShift provides faster cluster provisioning by
running the control plane as pods on the ACM hub cluster while worker nodes run
on the target infrastructure.

**HyperShift Core Integration**

- Uses `hypershift.openshift.io/v1beta1` API to create `HostedCluster` and
  `NodePool` resources.
- Control plane components run as pods on the ACM hub cluster, reducing
  infrastructure requirements.
- Worker nodes are provisioned on the target infrastructure (KubeVirt VMs or
  bare metal hosts).
- Provides faster provisioning compared to traditional IPI methods.

**KubeVirt Provider Integration**

The KubeVirt provider creates worker nodes as virtual machines on an existing
OpenShift Virtualization (KubeVirt) infrastructure:

- Uses `platform.type: KubeVirt` in the HostedCluster specification.
- Creates VMs as worker nodes on the KubeVirt infrastructure cluster.
- The infrastructure cluster can be the ACM hub cluster itself or a separate
  OpenShift cluster with OpenShift Virtualization installed.
- NodePool defines the VM specifications (CPU, memory, storage) for worker
  nodes.
- Leverages KubeVirt's VM lifecycle management for node operations.

**Agent Provider Integration (BareMetal)**

The Agent provider provisions worker nodes on bare metal hosts using the
Assisted Installer flow:

- Uses `platform.type: Agent` in the HostedCluster specification.
- Integrates with Central Infrastructure Management (CIM) on the ACM hub
  cluster.
- References pre-configured `InfraEnv` resources for host discovery and network
  configuration.
- Bare metal hosts must be registered as `Agent` resources and approved before
  allocation.
- NodePool references the `InfraEnv` and specifies agent selection criteria.
- Hosts are assigned to NodePools based on labels and availability.

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
- Use `SharedIndexInformer` to watch `HostedCluster`
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

#### Default Platform Configuration

| Field           | Type   | Default  | Description                     |
| --------------- | ------ | -------- | ------------------------------- |
| defaultPlatform | string | kubevirt | Default infrastructure platform |

**Valid values for v1:**

- `defaultPlatform`:
  - `kubevirt` - Worker nodes as VMs on OpenShift Virtualization
  - `baremetal` - Worker nodes on bare metal hosts via Agent provider

`defaultPlatform` is used when `providerHints.acm.platform` is not specified in
the request.

> **Note**: v1 uses HyperShift exclusively for cluster provisioning. There is no
> `defaultProvisioningType` configuration as the provisioning method is fixed.

#### Platform-Specific Configuration

**KubeVirt Platform:**

| Field                  | Type   | Default | Description                                |
| ---------------------- | ------ | ------- | ------------------------------------------ |
| kubevirtInfraCluster   | string | ""      | Kubeconfig for KubeVirt infrastructure     |
| kubevirtInfraNamespace | string | ""      | Namespace for worker VMs on infrastructure |

If `kubevirtInfraCluster` is empty, the ACM hub cluster is used as the KubeVirt
infrastructure cluster.

**BareMetal Platform:**

| Field               | Type   | Default | Description                           |
| ------------------- | ------ | ------- | ------------------------------------- |
| defaultInfraEnvName | string | ""      | Default InfraEnv for agent discovery  |
| agentNamespace      | string | ""      | Namespace where Agents are registered |

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
    DisplayName: "ACM Cluster Service Provider (HyperShift)",
    Endpoint:  fmt.Sprintf("%s/api/v1alpha1/clusters", apiHost),
    Metadata: dcm.Metadata{
      Capabilities: dcm.ProviderCapabilities{
          SupportedPlatforms:         []string{"kubevirt", "baremetal"},
          SupportedProvisioningTypes: []string{"hypershift"},
          SupportedVersions:          []string{"4.16", "4.17", "4.18"},
      },
    },
    Operations: []string{"CREATE", "DELETE", "READ"},
}
```

#### Capability Advertisement

The `metadata.Capabilities` field advertises what this SP instance supports.
Users and DCM can query registered providers to discover supported platforms,
provisioning types, and Kubernetes versions before making requests.

| Field                      | Type     | Description                                           |
| -------------------------- | -------- | ----------------------------------------------------- |
| supportedPlatforms         | []string | Platforms this SP can provision (kubevirt, baremetal) |
| supportedProvisioningTypes | []string | Provisioning methods available (hypershift for v1)    |
| supportedVersions          | []string | OpenShift versions available via ClusterImageSets     |

The SP populates these values based on:

- **supportedPlatforms**: Platforms for which infrastructure is configured on
  the ACM hub cluster (KubeVirt infrastructure and/or Agent/InfraEnv resources).
- **supportedProvisioningTypes**: For v1, this is always `["hypershift"]` as
  Hive-based provisioning is not supported in this version.
- **supportedVersions**: Available `ClusterImageSet` resources on the ACM hub
  cluster. The SP queries these at startup and may refresh periodically.

If a user requests an unsupported platform or provisioning type, the SP returns
`422 Unprocessable Entity`.

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

These endpoints are defined based on AEP (API Enhancement Proposals) standards
and use `aep-openapi-linter` to check for compliance with AEP.

#### POST /api/v1alpha1/clusters

**Description:** Create a new Kubernetes cluster.

The POST endpoint follows the contract defined in the Cluster schema spec
pre-defined by DCM core. See
[Cluster Schema](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#kubernetes-cluster)
for the complete specification.

During creation of the resources, each `HostedCluster` must be labeled with:

- `managed-by=dcm`
- `dcm-instance-id=<UUID>`
- `dcm-service-type=cluster`

The `dcm-instance-id` is a UUID (Universally Unique Identifier) generated by
DCM. If a cluster with the same `metadata.name` already exists, the ACM Cluster
SP returns a `409 Conflict` error response without modifying the existing
resource.

**Provisioning Method Selection via providerHints:**

Users specify the provisioning method and platform configuration using
`providerHints.acm`:

| Field       | Type   | Description                                        |
| ----------- | ------ | -------------------------------------------------- |
| platform    | string | Infrastructure platform: `kubevirt` or `baremetal` |
| baseDomain  | string | Base DNS (Domain Name System) domain for cluster   |
| infraEnv    | string | (BareMetal only) Name of the InfraEnv resource     |
| agentLabels | object | (BareMetal only) Labels for agent selection        |

> **Note**: v1 uses HyperShift exclusively. There is no `provisioningType` field
> as the provisioning method is fixed.

**Version Field Handling:**

The `version` field in the request specifies the desired Kubernetes/OpenShift
version. The following rules apply:

- **Format**: Accepts either minor version (`1.29`) or full semantic version
  (`1.29.4`). If only minor version is specified, the SP selects the latest
  available patch version from the ACM hub's `ClusterImageSet` resources.
- **Validation**: The SP validates that the requested version exists as a
  `ClusterImageSet` on the ACM hub cluster. If not available, returns
  `422 Unprocessable Entity` with a message indicating the version is not
  supported.
- **Discovery**: Available versions are advertised in the SP's registration
  metadata (`Capabilities.SupportedVersions`). Users can query the DCM registry
  to discover supported versions before making requests.

**Node Specification to Instance Type Mapping:**

The request payload uses abstract resource specifications (`cpu`, `memory`,
`storage`) rather than cloud-specific instance types. The ACM Cluster SP
translates these abstract specifications to platform-specific instance types.

**Example Request Payload (HyperShift on KubeVirt):**

```json
{
  "version": "4.15",
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
      "platform": "kubevirt",
      "baseDomain": "example.com"
    }
  },
  "schemaVersion": "v1alpha1",
  "serviceType": "cluster"
}
```

**Example Request Payload (HyperShift on BareMetal):**

```json
{
  "version": "4.15",
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
      "platform": "baremetal",
      "baseDomain": "example.com",
      "infraEnv": "production-infraenv",
      "agentLabels": {
        "location": "datacenter-1",
        "role": "worker"
      }
    }
  },
  "schemaVersion": "v1alpha1",
  "serviceType": "cluster"
}
```

> **Note**: For HyperShift deployments (both KubeVirt and BareMetal):
>
> - The `controlPlane.count` field is **ignored**. HyperShift manages control
>   plane high availability internally as pods on the ACM hub cluster, not as
>   discrete VMs.
> - The `controlPlane.cpu` and `controlPlane.memory` fields define resource
>   requests for the hosted control plane pods running on the hub cluster.
> - The `controlPlane.storage` field is ignored for HyperShift (etcd storage is
>   managed by the HyperShift operator).
> - The `worker` configuration defines the `NodePool` for worker nodes.

**Platform-Specific Notes:**

- **KubeVirt**: Worker nodes are created as VMs on the OpenShift Virtualization
  infrastructure. The `worker.cpu`, `worker.memory`, and `worker.storage` values
  are used to configure the VM specifications.
- **BareMetal**: The `infraEnv` field references the InfraEnv resource for agent
  discovery. The `agentLabels` field is used to select specific agents from the
  pool of available bare metal hosts. The `worker.cpu`, `worker.memory`, and
  `worker.storage` values are used as minimum requirements for agent selection.

**Response:** Returns `201 Created` with the following payload. The status is
set to `PENDING` after the resource is created.

**Example Response Payload:**

```json
{
  "requestId": "123e4567-e89b-12d3-a456-426614174000",
  "name": "dev-cluster-01",
  "status": "PENDING",
  "provisioningType": "hypershift",
  "platform": "kubevirt",
  "version": "4.15",
  "apiEndpoint": "",
  "consoleUrl": "",
  "nodes": {
    "controlPlane": {
      "ready": 0,
      "total": 3
    },
    "worker": {
      "ready": 0,
      "total": 3
    }
  },
  "kubeconfig": "",
  "metadata": {
    "namespace": "dev-cluster-01",
    "createdAt": "2026-01-29T10:30:00Z"
  }
}
```

> **Note**: The payload above is **only** an example. This will be updated when
> the schema contract is finalized by DCM. Fields like `apiEndpoint`,
> `consoleUrl`, and `kubeconfig` are empty at creation time and will be
> populated once the cluster reaches `READY` status. The `kubeconfig` field will
> contain a base64-encoded kubeconfig file that provides admin access to the
> provisioned cluster.

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
3. Queries `HostedCluster` resources labeled with `managed-by=dcm`.
4. Returns fully-populated cluster resources per AEP-132.
5. Response includes pagination metadata (`next_page_token`).

**Example Response Payload:**

```json
{
  "results": [
    {
      /* cluster instance - same schema as POST response */
    },
    {
      /* cluster instance - same schema as POST response */
    }
  ],
  "next_page_token": "a1b2c3d4e5f6"
}
```

> **Note**: Per AEP-132, LIST returns fully-populated resources. Fields like
> `apiEndpoint`, `consoleUrl`, and `kubeconfig` may be empty for clusters that
> are still provisioning or have failed.

**Error Handling:**

- **400 Bad Request**: Invalid pagination parameters
- **500 Internal Server Error**: Unexpected error querying ACM hub

#### GET /api/v1alpha1/clusters/{clusterId}

**Description:** Get a specific cluster instance.

> **Note**: The response schema is identical to the POST response schema defined
> above.

**Process Flow:**

1. Handler receives `GET` request with `clusterId` path parameter.
2. Calls `GetClusterFromHub(clusterId)`.
3. Cluster lookup: Query ACM hub for `HostedCluster` with matching
   `dcm-instance-id` label.
4. Extract cluster details: API endpoint, console URL, version, node counts.
5. Check `HostedCluster.Status` conditions.
6. Response payload: Return complete cluster instance object.

**Kubeconfig Field Behavior:**

The `kubeconfig` field is populated based on the cluster status:

- **READY**: Contains the base64-encoded kubeconfig file retrieved from the ACM
  hub cluster secret. Users can decode this to access the cluster.
- **PROVISIONING/PENDING**: Empty string. Credentials are not yet available as
  the cluster is still being created.
- **FAILED**: Empty string. Cluster provisioning failed; no valid credentials
  exist.

**Security Considerations:**

The `kubeconfig` field contains sensitive credentials that grant admin access to
the provisioned cluster. Implementations should:

- Protect the API with proper authentication and authorization mechanisms.
- Use TLS (Transport Layer Security) for all API communications to prevent
  credential interception.
- Consider implementing short-lived tokens or certificate rotation for
  production deployments.
- Log access to kubeconfig data for audit purposes.

For v1, those are not mandatory but as soon as DCM will support AuthN/Z
(Authentication/Authorization) and RBAC, those considerations needs to be taken
care of.

**Error Handling:**

- **404 Not Found**: Cluster with the specified `clusterId` does not exist
- **500 Internal Server Error**: Unexpected error querying ACM hub

#### DELETE /api/v1alpha1/clusters/{clusterId}

**Description:** Delete a cluster instance.

Remove a cluster instance (`HostedCluster` with cascading delete for all child
resources including `NodePools` and `ManagedCluster`), and returns
`204 No Content`.

**Process Flow:**

1. Handler receives `DELETE` request with `clusterId` path parameter.
2. Lookup `HostedCluster` resource by `dcm-instance-id` label.
3. Delete the resource with cascading deletion.
4. Return `204 No Content` on success.

**Error Handling:**

- **404 Not Found**: Cluster with the specified `clusterId` does not exist
- **500 Internal Server Error**: Unexpected error during resource deletion

#### GET /api/v1alpha1/health

**Description:** Retrieve the health status for the ACM Cluster Service Provider
API.

The health check verifies:

- Connectivity to ACM hub cluster
- HyperShift operator availability
- KubeVirt infrastructure accessibility (if KubeVirt platform is enabled)
- Agent/CIM resources availability (if BareMetal platform is enabled)

### Status Reporting to DCM

The ACM Cluster SP uses a `SharedIndexInformer` to watch cluster resources and
report status changes to DCM. The informer watches `HostedCluster` resources
created by this SP instance.

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
    Status:  "READY",
    Message: "Cluster is ready and all nodes are available.",
})
```

#### Status Mapping (HostedCluster)

The following table maps HyperShift `HostedCluster` conditions to DCM statuses:

| DCM Status   | HostedCluster Condition           | Description                         |
| ------------ | --------------------------------- | ----------------------------------- |
| PENDING      | Progressing=Unknown               | Cluster creation initiated          |
| PROVISIONING | Progressing=True, Available=False | Control plane being provisioned     |
| READY        | Available=True, Progressing=False | Cluster is fully operational        |
| FAILED       | Degraded=True                     | Cluster is in degraded/failed state |
| DELETED      | N/A                               | HostedCluster not found             |

See
[Hypershift HostedCluster API](https://github.com/openshift/hypershift/blob/main/api/hypershift/v1beta1/hostedcluster_types.go)
for official definitions.

#### Status Reconciliation Logic

When the informer receives an event for a `HostedCluster` resource, the ACM
Cluster SP applies the status mapping and publishes updates:

1. Extract `HostedCluster` status conditions.
2. Map conditions to DCM status using the table above.
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
provisioning. Cluster import will be added in future versions to support
brownfield scenarios where users have pre-existing clusters.

### Alternative 4: Hive-Based Provisioning (ClusterDeployment)

#### Description

Use Hive's ClusterDeployment CRD for traditional IPI (Installer-Provisioned
Infrastructure) cluster provisioning instead of HyperShift.

#### Pros

- Mature and well-tested provisioning method
- Full control plane runs on dedicated infrastructure
- Better isolation between clusters
- Supports a wider range of customizations

#### Cons

- Slower provisioning times compared to HyperShift
- Higher infrastructure requirements (control plane needs dedicated nodes)
- More complex BareMetal setup (requires IPMI (Intelligent Platform Management
  Interface)/BMC (Baseboard Management Controller), DHCP (Dynamic Host
  Configuration Protocol), PXE (Preboot Execution Environment) configuration)
- KubeVirt is not a standard supported platform for Hive

#### Status

Deferred

#### Rationale

For v1, HyperShift provides a better fit for the target platforms (KubeVirt and
BareMetal). HyperShift has native KubeVirt support and the Agent provider
simplifies BareMetal provisioning compared to Hive's IPI approach. Hive-based
provisioning may be added in future versions for use cases requiring dedicated
control plane infrastructure.

### Alternative 5: Full Platform Support (AWS, OpenStack, KubeVirt, BareMetal)

#### Description

Support all platforms from v1 instead of focusing only on KubeVirt and
BareMetal. This would include AWS, OpenStack, vSphere, and other cloud
providers.

#### Pros

- More flexibility for diverse infrastructure environments
- Single implementation covers all use cases
- Broader user adoption from day one

#### Cons

- Significantly larger implementation scope
- More testing combinations and edge cases
- Requires cloud provider credentials and integration
- Delays delivery of initial functionality
- Different platforms have varying levels of HyperShift support maturity

#### Status

Deferred

#### Rationale

v1 focuses on KubeVirt and BareMetal to enable faster validation and delivery.
These platforms align with on-premises and edge deployment scenarios that are
priority use cases. AWS and OpenStack support will be added in subsequent
versions as the implementation matures.
