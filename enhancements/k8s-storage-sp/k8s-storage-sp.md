---
title: k8s-storage-sp
authors:
  - "@igavra"
reviewers:
  - "@gciavarrini"
  - "@jenniferubah"
  - "@machacekondra"
  - "@ygalblum"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"
creation-date: 2026-05-28
---

# Kubernetes Storage Service Provider

## Summary

The Kubernetes Storage Service Provider (K8s Storage SP) creates and manages
persistent storage volumes on Kubernetes clusters on behalf of DCM.

This is a DCM control-plane adapter, not a storage backend. The SP translates
DCM storage requests into Kubernetes `PersistentVolumeClaim` (PVC) resources and
reports lifecycle status back to DCM. It does not implement the underlying
block/file provisioning—that remains the responsibility of the cluster's
StorageClass and CSI driver.

The v1 implementation focuses exclusively on PVC lifecycle management (CREATE,
READ, UPDATE, DELETE). UPDATE supports capacity expansion when the StorageClass
allows it. StorageClass provisioning, volume snapshots, and cross-cluster
migration are out of scope. The K8s Storage SP implements the `storage` service
type schema. Each SP instance connects to exactly one Kubernetes cluster API.
Multiple SP instances may target the same cluster when separate namespaces or
registrations are required.

## Motivation

Applications and composite deployments need independently provisioned persistent
storage that can be requested through DCM catalog items and attached to
workloads (for example, a database PVC for a three-tier application). This
enhancement defines the Kubernetes Storage Service Provider that implements the
portable `storage` service type on Kubernetes clusters.

### Goals

- Define the lifecycle of a Service Provider (SP) managing persistent volumes on
  Kubernetes clusters.
- Define the registration flow with DCM SP API.
- Define `CREATE`, `READ`, `UPDATE`, and `DELETE` endpoints for managing PVC
  instances on a Kubernetes cluster. `UPDATE` supports capacity expansion when
  the underlying StorageClass and CSI driver allow it (see
  [PATCH /api/v1alpha1/volumes/{volume_id}](#patch-apiv1alpha1volumesvolume_id)).
- Define status reporting to DCM via CloudEvents on the messaging system.
- Manage `PersistentVolumeClaim` resources through a single Kubernetes cluster
  API per SP instance. Multiple SP instances may target the same cluster when
  isolation requires separate namespaces or registrations.

### Non-Goals

- Implementing CSI drivers, Ceph, NetApp, or any storage backend data plane.
- Provisioning or managing `StorageClass` resources (clusters must provide
  pre-configured StorageClasses).
- Configuring volume encryption or KMS/Vault integration. Encryption is
  configured at cluster creation time via the cluster service type. The storage
  SP selects from available StorageClasses, which may be encrypted or
  unencrypted based on cluster configuration.
- Volume snapshots, clones, or backup/restore workflows.
- Cross-cluster volume migration or multi-attach (ReadWriteMany) beyond what the
  selected StorageClass supports.
- Separate network service provisioning (storage data-path networking is handled
  by the cluster CSI/kubelet stack).
- Deployment strategy for the K8s Storage SP API (covered by platform deployment
  documentation).
- `ReadWriteOncePod` (RWOP) support — requires Kubernetes 1.22+ and driver
  support. If needed, it may be requested via `provider_hints.kubernetes` in v2.

## Proposal

### Assumptions

#### Kubernetes Cluster Prerequisites

- A target Kubernetes cluster already exists (OCP, KIND, Minikube, etc.) and is
  reachable via kubeconfig or in-cluster service account.
- The cluster has at least one `StorageClass` configured with a working
  provisioner (typically a CSI driver, e.g., Ceph RBD, AWS EBS CSI), or static
  PVs pre-bound via StorageClass. When the SP submits a PVC, the cluster
  provisions or binds the volume automatically.
- **For encrypted volumes**, StorageClasses with KMS/Vault integration must be
  pre-configured during cluster provisioning (see cluster service type). The
  storage SP does not configure encryption parameters; it selects from available
  StorageClasses (e.g., `ceph-rbd-encrypted`, `gp3-kms`). Encryption
  configuration (KMS provider, key IDs) is embedded in the StorageClass
  parameters and handled at cluster creation time, not per-volume.

  Example encrypted StorageClass (configured by cluster SP):

  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: ceph-rbd-encrypted
  provisioner: rbd.csi.ceph.com
  parameters:
    encrypted: "true"
    encryptionKMSID: "vault-kms"
    # or for AWS:
    # encrypted: "true"
    # kmsKeyId: "arn:aws:kms:us-east-1:123456789:key/abc-123"
  ```

- The K8s Storage SP has RBAC permissions to manage `PersistentVolumeClaim`
  resources in its configured namespace and read `StorageClass` resources
  cluster-wide.

#### DCM Platform Prerequisites

- The DCM Service Provider Registry is reachable for registration.
- DCM messaging system (NATS) is reachable for publishing status updates.

#### Deployment Model

- Each SP instance runs as a separate process and registers with DCM under a
  unique name.
- Each SP instance connects to exactly one Kubernetes cluster API and is scoped
  to one configured namespace.
- Multiple SP instances may target the same cluster for multi-tenancy or storage
  tier differentiation.
- Authentication uses a kubeconfig file (external deployment) or an in-cluster
  ServiceAccount when deployed as a Kubernetes Deployment in the target cluster.
- The SP may register directly with DCM or via an environment agent. See
  [Environment Agent](../environment-agent/environment-agent.md).
- When multiple storage SPs register against the same cluster, DCM Placement
  selects the provider by policy.

### Integration Points

#### Kubernetes Integration

- Uses `k8s.io/client-go` to interact with the Kubernetes API.
- Creates and watches `PersistentVolumeClaim` resources. Each storage request
  becomes one PVC with `capacity` from the request and optional `storage_class`,
  `volume_mode`, and `access_mode` from `provider_hints.kubernetes`.
- Does not create Pods, Deployments, or workload attachments — consumers attach
  PVCs through their own service types or day-2 operations.

#### DCM SP Registry

- Auto-registration on startup with DCM SP Registrar. See
  [DCM Registration Flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

#### DCM SP Health Check

K8s Storage SP must expose a health endpoint at
`GET /api/v1alpha1/volumes/health` (resource-relative: DCM polls
`{registered_endpoint}/health` where the registered endpoint is
`{base}/api/v1alpha1/volumes`). See
[SP Health Check](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-provider-health-check/service-provider-health-check.md).

#### DCM SP Status Reporting

- Publishes status updates for storage instances to NATS subject `dcm.storage`
  using CloudEvents format.
- Uses a `SharedIndexInformer` to watch `PersistentVolumeClaim` events.

### SP Configuration

The K8s Storage SP supports configuration options that control default behavior
for all volumes managed by this provider instance.

#### Namespace Configuration

| Field     | Type   | Default | Description                               |
| --------- | ------ | ------- | ----------------------------------------- |
| namespace | string | default | Kubernetes namespace for all managed PVCs |

All PVCs created by this Service Provider are deployed in the configured
namespace. This setting applies to all storage instances and cannot be
overridden per-volume in v1.

#### Storage Defaults

| Field                 | Type   | Default       | Description                                     |
| --------------------- | ------ | ------------- | ----------------------------------------------- |
| default_storage_class | string | (cluster)     | StorageClass used when not specified in request |
| default_access_mode   | string | ReadWriteOnce | PVC access mode when not specified in request   |

Per-volume `storage_class`, `volume_mode`, and `access_mode` may be set under
`provider_hints.kubernetes` (see POST endpoint documentation). When
`access_mode` is omitted, the SP applies `default_access_mode`.

### Registration Flow

The K8s Storage SP API must successfully complete a registration process to
ensure DCM is aware of it. During startup, the service uses the DCM registration
client to send a request to the SP API registration endpoint
`POST /api/v1alpha1/providers`. See DCM
[registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md)
for more information.

Example registration payload (via `service-provider-manager` client):

```golang
import (
    dcmv1alpha1 "github.com/dcm-project/service-provider-manager/api/v1alpha1/provider"
)

payload := dcmv1alpha1.Provider{
    Name:          "k8s-storage-sp",
    ServiceType:   "storage",
    DisplayName:   ptr("Kubernetes Storage Service Provider"),
    Endpoint:      fmt.Sprintf("%s/api/v1alpha1/volumes", apiHost),
    SchemaVersion: "v1alpha1",
    Operations:    &[]string{"CREATE", "READ", "UPDATE", "DELETE"},
    Metadata: &dcmv1alpha1.ProviderMetadata{
        RegionCode: ptr("us-east-1"),
        Zone:       ptr("us-east-1b"),
    },
}
```

#### Registration Request Validation

The registration payload must conform to the validation requirements defined in
the
[SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

**K8s Storage SP-specific requirements:**

- `service_type` field must be set to `"storage"`
- `operations` field must include: `CREATE`, `READ`, `UPDATE`, `DELETE`
- `metadata.resources.total_storage` may reflect cluster capacity at
  registration time (optional)

#### Registration Process

The K8s Storage SP follows the standard self-registration process. The
registration request includes the endpoint URL in the format:
`fmt.Sprintf("%s/api/v1alpha1/volumes", apiHost)`.

### API Endpoints

The CRUD endpoints are consumed by the DCM SP API to create and manage storage
resources.

#### Endpoints Overview

| Method | Endpoint                          | Description                     |
| ------ | --------------------------------- | ------------------------------- |
| POST   | /api/v1alpha1/volumes             | Create a new volume (PVC)       |
| GET    | /api/v1alpha1/volumes             | List all volumes                |
| GET    | /api/v1alpha1/volumes/{volume_id} | Get a volume instance           |
| PATCH  | /api/v1alpha1/volumes/{volume_id} | Update volume (expand capacity) |
| DELETE | /api/v1alpha1/volumes/{volume_id} | Delete a volume instance        |
| GET    | /api/v1alpha1/volumes/health      | K8s Storage SP health check     |

##### AEP Compliance

These endpoints are defined based on AEP standards and use `aep-openapi-linter`
to check for compliance with AEP.

#### POST /api/v1alpha1/volumes

**Description:** Create a new storage volume instance.

The POST endpoint follows the portable `storage` service type contract (see
[Service Type Definitions - Storage](../service-type-definitions/service-type-definitions.md#storage)).
Required fields: `service_type`, `capacity`, `metadata.name`. Optional:
`provider_hints.kubernetes` (`storage_class`, `volume_mode`, `access_mode`).

During creation, each PVC must be labeled with:

- `dcm.project/managed-by=dcm`
- `dcm.project/dcm-instance-id=<UUID>`
- `dcm.project/dcm-service-type=storage`

The `dcm-instance-id` is a UUID generated by DCM. If a PVC with the same
`metadata.name` already exists in the configured namespace, the K8s Storage SP
returns a `409 Conflict` error response without modifying the existing resource.

**PVC settings via provider_hints:**

| Field         | Type   | Description                                                                 |
| ------------- | ------ | --------------------------------------------------------------------------- |
| storage_class | string | StorageClass name (overrides SP default)                                    |
| volume_mode   | string | `Filesystem` (default) or `Block`                                           |
| access_mode   | string | PVC access mode: `ReadWriteOnce` (default), `ReadOnlyMany`, `ReadWriteMany` |

`access_mode` maps directly to Kubernetes PVC `spec.accessModes`.

**Example request payload:**

```json
{
  "service_type": "storage",
  "capacity": "100Gi",
  "metadata": {
    "name": "app-data"
  },
  "provider_hints": {
    "kubernetes": {
      "storage_class": "gp3-csi",
      "volume_mode": "Filesystem",
      "access_mode": "ReadWriteOnce"
    }
  }
}
```

**Response:** Returns `201 Created` with status `PROVISIONING` while the PVC is
pending binding.

**Example response payload:**

```json
{
  "id": "123e4567-e89b-12d3-a456-426614174000",
  "path": "volumes/123e4567-e89b-12d3-a456-426614174000",
  "spec": {
    "service_type": "storage",
    "capacity": "100Gi",
    "metadata": {
      "name": "app-data",
      "namespace": "production",
      "storage_class": "gp3-csi"
    },
    "provider_hints": {
      "kubernetes": {
        "storage_class": "gp3-csi",
        "access_mode": "ReadWriteOnce"
      }
    }
  },
  "status": "PROVISIONING"
}
```

**Error Handling:**

- **400 Bad Request**: Invalid request payload or missing required fields
- **409 Conflict**: PVC with the same `metadata.name` already exists
- **422 Unprocessable Entity**: Requested StorageClass does not exist
- **500 Internal Server Error**: Unexpected error during resource creation

#### GET /api/v1alpha1/volumes

**Description:** List all storage volume instances with pagination support.

**Query Parameters:**

- `max_page_size` (optional): Maximum number of resources per page. Default: 50.
- `page_token` (optional): Token for the next page.

**Example Response Payload:**

```json
{
  "volumes": [
    {
      "id": "123e4567-e89b-12d3-a456-426614174000",
      "path": "volumes/123e4567-e89b-12d3-a456-426614174000",
      "spec": {
        "service_type": "storage",
        "capacity": "100Gi",
        "metadata": {
          "name": "app-data",
          "namespace": "production",
          "storage_class": "gp3-csi",
          "volume_name": "pvc-abc123"
        },
        "provider_hints": {
          "kubernetes": {
            "storage_class": "gp3-csi",
            "access_mode": "ReadWriteOnce"
          }
        }
      },
      "status": "RUNNING"
    }
  ],
  "next_page_token": ""
}
```

#### GET /api/v1alpha1/volumes/{volume_id}

**Description:** Get a specific storage volume instance by DCM instance ID
(`dcm-instance-id` label).

**Example Response Payload:**

```json
{
  "id": "123e4567-e89b-12d3-a456-426614174000",
  "path": "volumes/123e4567-e89b-12d3-a456-426614174000",
  "spec": {
    "service_type": "storage",
    "capacity": "100Gi",
    "metadata": {
      "name": "app-data",
      "namespace": "production",
      "storage_class": "gp3-csi",
      "volume_name": "pvc-abc123"
    },
    "provider_hints": {
      "kubernetes": {
        "storage_class": "gp3-csi",
        "access_mode": "ReadWriteOnce"
      }
    }
  },
  "status": "RUNNING"
}
```

**Error Handling:**

- **404 Not Found**: Volume with the specified `volume_id` does not exist
- **500 Internal Server Error**: Unexpected error querying Kubernetes API

#### PATCH /api/v1alpha1/volumes/{volume_id}

**Description:** Update a storage volume. v1 supports **capacity expansion**
only.

The SP validates the request before patching the PVC:

1. Retrieves the PVC and its StorageClass
2. Checks `allowVolumeExpansion: true` on the StorageClass
3. Rejects requests where the new capacity is less than or equal to the current
   request (shrinking is not supported)
4. Patches `spec.resources.requests.storage` on the PVC

**Pre-patch validation (v1):** The SP checks policy preconditions (StorageClass
expansion, new size greater than current). It does **not** pre-flight backend
free space, cloud account quotas, or Ceph pool capacity — those are not exposed
through a portable Kubernetes API. Expansion may still fail asynchronously after
a successful PATCH for backend limits.

When a `ResourceQuota` on `requests.storage` exists in the configured namespace,
the SP pre-checks on PATCH and returns **409** if exceeded; if no such quota
exists, skip the check.

**Example Request Payload:**

```json
{
  "capacity": "200Gi"
}
```

**Response:** Returns `200 OK` with updated resource representation if expansion
is initiated. Kubernetes handles the actual expansion asynchronously; status
updates are published via CloudEvents as the expansion progresses.

**Error Handling:**

- **404 Not Found**: Volume with the specified `volume_id` does not exist
- **422 Unprocessable Entity**: StorageClass does not allow volume expansion
  (`allowVolumeExpansion: false` or not set)
- **400 Bad Request**: New capacity is smaller than or equal to current capacity
  (shrinking not supported)
- **409 Conflict**: A `ResourceQuota` limiting `requests.storage` in the
  configured namespace exceeded
- **500 Internal Server Error**: Unexpected error during update

#### Volume expansion behavior

After PATCH, Kubernetes and the CSI driver expand the volume asynchronously. The
SP does not call CSI directly. Typical sequence:

1. **Controller expand** — CSI grows the backend volume (`Resizing` condition)
2. **Node / filesystem expand** — kubelet or CSI resizes the filesystem on the
   node (`FileSystemResizePending` until complete; a Pod restart may be required
   for the new size to be visible inside the container)

Whether expansion completes **online** (while the Pod is running) depends on the
CSI driver, `volume_mode` (`Filesystem` vs `Block`), and mount state — not only
`allowVolumeExpansion` on the StorageClass.

| What the SP can validate before PATCH | What the SP cannot validate before PATCH    |
| ------------------------------------- | ------------------------------------------- |
| StorageClass exists                   | Free space in Ceph pool / NFS export        |
| `allowVolumeExpansion: true`          | Cloud provider volume/account limits        |
| New size > current request            | CSI driver expand capability (beyond SC)    |
| `ResourceQuota` on `requests.storage` | Whether filesystem resize needs Pod restart |

If expansion fails after PATCH (driver unsupported, quota exceeded at backend,
volume at platform max size), Kubernetes sets conditions and events on the PVC.
The SP maps these to DCM status (see status mapping below); callers must monitor
status — a `200 OK` on PATCH means expansion was **initiated**, not guaranteed
complete.

See
[Volume Expansion](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims)
in Kubernetes documentation for driver-specific behavior.

#### DELETE /api/v1alpha1/volumes/{volume_id}

**Description:** Delete a storage volume instance (PVC). The SP issues a
Kubernetes DELETE on the PVC and returns `204 No Content` when the API accepts
the request. If the PVC is still mounted, Kubernetes keeps it in **Terminating**
until no Pod references it (finalizers); the SP reports **DELETING** via
CloudEvents until removal completes.

**Error Handling:**

- **404 Not Found**: Volume with the specified `volume_id` does not exist
- **500 Internal Server Error**: Unexpected error during deletion

#### GET /api/v1alpha1/volumes/health

**Description:** Retrieve the health status for the K8s Storage SP API.

### Status Reporting to DCM

The K8s Storage SP uses a `SharedIndexInformer` to watch `PersistentVolumeClaim`
resources labeled with `dcm.project/managed-by=dcm` and
`dcm.project/dcm-service-type=storage`. When a relevant PVC event occurs, the SP
maps Kubernetes state to DCM generic status and publishes a CloudEvent to the
messaging system.

Status updates are published using the [CloudEvents](https://cloudevents.io/)
specification (v1.0). Events are published to NATS subject `dcm.storage`
(`dcm.{service_type}` pattern). See
[Service Provider Status Reporting](../state-management/service-provider-status-reporting.md)
for the platform-wide CloudEvents contract and status mapping guidelines.

#### CloudEvents Format

**NATS subject:** `dcm.storage`

**CloudEvent attributes:**

| Attribute         | Value                           |
| ----------------- | ------------------------------- |
| `source`          | `dcm/providers/{provider_name}` |
| `type`            | `dcm.status.storage`            |
| `subject`         | `dcm.storage`                   |
| `datacontenttype` | `application/json`              |

Instance identity is carried in the data payload `id` field (from the
`dcm-instance-id` label), not in the NATS subject.

**Payload structure:**

```golang
type StorageStatus struct {
    Id      string `json:"id"`
    Status  string `json:"status"`
    Message string `json:"message"`
}
```

**Example event:**

```golang
cloudevents "github.com/cloudevents/sdk-go/v2"

event := cloudevents.NewEvent()
event.SetID("event-123-456")
event.SetSource("dcm/providers/k8s-storage-sp")
event.SetType("dcm.status.storage")
event.SetSubject("dcm.storage")
event.SetData(cloudevents.ApplicationJSON, StorageStatus{
    Id:      "abc-123",
    Status:  "RUNNING",
    Message: "PVC is bound to volume pvc-abc123.",
})
```

#### Status Mapping from Kubernetes to DCM

| DCM Status   | Kubernetes Condition                                     |
| ------------ | -------------------------------------------------------- |
| PROVISIONING | PVC Phase = `Pending` (waiting for binding/provisioning) |
| PROVISIONING | PVC Phase = `Bound` and `Resizing` or                    |
|              | `FileSystemResizePending` condition is `True` (expansion |
|              | in progress)                                             |
| RUNNING      | PVC Phase = `Bound` and no active resize conditions      |
| FAILED       | PVC Phase = `Lost` or unrecoverable binding/expansion    |
|              | failure (see PVC events and conditions)                  |
| DELETING     | PVC has `deletionTimestamp` set                          |
| DELETED      | PVC not found in cluster                                 |

For official definitions, see
[Kubernetes PVC Phase](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#phase).

**Implementation Notes:**

- The `instance_id` is read from the `dcm.project/dcm-instance-id` label on the
  PVC.
- When bound, the status message may include `volume_name` from
  `spec.metadata.volume_name` (mapped from `pvc.spec.volumeName`).

### Upgrade / Downgrade Strategy

- SP upgrades are rolling deployments; informers reconnect automatically.
- Downgrade: avoid schema changes without catalog compatibility review.
- Existing PVCs retain DCM labels; re-registration is idempotent per SP name.

## Alternatives

### Alternative 1: Per-Instance Namespace Override

#### Description

Allow catalog or placement manager to specify a target namespace per volume
instance, instead of deploying all PVCs to a single configured namespace.

#### Pros

- Enables multi-tenant namespace isolation without deploying multiple SP
  instances
- Supports composite applications where different components (and their storage)
  are deployed to different namespaces
- Aligns with FLPATH-4115 tenant isolation requirements
- More flexible for dynamic namespace provisioning workflows

#### Cons

- Increases SP complexity (namespace validation, existence checks, dynamic RBAC)
- Requires SP to have cluster-wide PVC create permissions or dynamic RoleBinding
  management
- Namespace lifecycle management becomes ambiguous (who creates/deletes
  namespaces?)
- Harder to reason about SP RBAC scope (single namespace vs cluster-wide)

#### Status

Deferred to v2

#### Rationale

v1 prioritizes simplicity with a single-namespace deployment model. The SP has
clearly scoped RBAC permissions (manage PVCs in one namespace, read
StorageClasses cluster-wide) and straightforward operational boundaries. For
multi-tenant scenarios, operators can deploy multiple SP instances (one per
tenant namespace) and register each separately with DCM. Per-instance namespace
override is a known requirement for future versions when multi-tenant isolation
patterns mature (FLPATH-4115).

## Infrastructure Needed

- New repository: `k8s-storage-service-provider` (Go), modeled on
  `k8s-container-service-provider`.
- OpenAPI spec: `api/v1alpha1/openapi.yaml` in `k8s-storage-service-provider`.
