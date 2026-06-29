---
title: osac-sp
authors:
  - "@jordigilh"
reviewers:
  - "@gciavarrini"
  - "@jenniferubah"
  - "@machacekondra"
  - "@ygalblum"
approvers:
  - "@machacekondra"
  - "@ygalblum"
  - "@jenniferubah"
creation-date: 2026-06-29
---

# OSAC Service Provider

## Open Questions

None at this time.

## Summary

The OSAC Service Provider (OSAC SP) is a REST API that manages OpenShift
clusters through the Open Sovereign AI Cloud (OSAC) platform. It exposes
endpoints for creating, reading, and deleting clusters, and integrates with the
DCM Service Provider Registry. The OSAC SP acts as an adapter between DCM and
the OSAC fulfillment service, translating DCM cluster requests into OSAC
fulfillment API calls.

### Scope Notes (v1)

This document defines the v1 implementation scope, which focuses on:

- **Service Type**: `cluster` only (OpenShift clusters via Hosted Control
  Planes)
- **Integration Path**: OSAC fulfillment service public gRPC API
  (`osac.public.v1.ClusterOrders`)

**VM-as-a-Service (deferred):** OSAC's `ComputeInstance` CRD and operator
controller are feature-complete (multi-NIC networking, security groups, console
proxy, provisioning webhooks). The public API proto includes ComputeInstance
**message type** definitions (see
[fulfillment-api PRs](https://github.com/osac-project/fulfillment-api/pulls?q=is%3Apr+compute+instance)
for state and condition enums added through Feb 2026). However, the fulfillment
service does not yet register a ComputeInstance **gRPC service** with CRUD RPC
methods. The
[fulfillment-service README](https://github.com/osac-project/fulfillment-service)
`grpcurl list` output shows only four public services:
`osac.public.v1.ClusterOrders`, `osac.public.v1.Clusters`,
`osac.public.v1.ClusterTemplates`, and `osac.public.v1.Events` — no
`osac.public.v1.ComputeInstances`. Once OSAC registers a public ComputeInstance
service with lifecycle RPCs, a subsequent version of this enhancement will add
`serviceType: "vm"` registration using the same adapter pattern. This avoids
bypassing OSAC's intended architecture by creating CRDs directly on the hub
cluster.

## Motivation

OSAC provides a self-service platform for provisioning OpenShift clusters, VMs,
and bare metal hosts at scale, currently deployed at the Mass Open Cloud (MOC).
Integrating OSAC as a DCM Service Provider enables DCM to leverage OSAC's mature
provisioning infrastructure — including Hosted Control Planes, template-based
automation via Ansible Automation Platform (AAP), and multi-hub support —
without duplicating OSAC's existing orchestration logic.

### Goals

- Define the lifecycle of an SP using OSAC to provision OpenShift clusters.
- Define the registration flow with DCM SP API.
- Define `CREATE`, `READ`, and `DELETE` endpoints for managing clusters
  provisioned via OSAC.
- Define status reporting mechanism for DCM requests.
- Define how cluster credentials are communicated to the user.

### Non-Goals

- Define endpoints for day 2 operations (`scale`, `upgrade`, `hibernate`) for
  cluster instances.
- **VM-as-a-Service provisioning** — OSAC's ComputeInstance operator is
  feature-complete, but the fulfillment service public gRPC API does not yet
  expose VM operations. VM support will be added once OSAC surfaces
  `ComputeInstance` lifecycle through `osac.public.v1.*`. See
  [Scope Notes](#scope-notes-v1).
- Bare Metal-as-a-Service as a standalone service type — bare metal hosts are
  the underlying infrastructure for OSAC clusters, not a separate user-facing
  service.
- Deployment strategy for the OSAC SP API.
- Define `UPDATE` endpoint, as this is out of scope for v1.
- Multi-hub placement logic — OSAC handles hub selection internally.
- OSAC internal components (operator, AAP playbooks, networking controllers).

## Proposal

### Assumptions

- The OSAC platform is deployed and operational, including the fulfillment
  service, OSAC operator, and AAP backend.
- The OSAC fulfillment service is reachable from the OSAC SP via gRPC or REST.
- The OSAC SP is registered as an OAuth 2.0 client in OSAC's Keycloak instance
  and has valid credentials (client ID and secret) to authenticate via OIDC
  client credentials flow.
- The DCM Service Provider Registry is reachable for registration.
- DCM messaging system is reachable for publishing status updates.
- At least one infrastructure hub is registered with the OSAC fulfillment
  service and has capacity to provision clusters.
- Network policies allow OSAC SP to communicate with both DCM and the OSAC
  fulfillment service.

### Authentication

OSAC uses Keycloak as its identity provider with standard OIDC support. The OSAC
SP authenticates against the OSAC fulfillment service using the OAuth 2.0 client
credentials flow:

1. The OSAC SP is registered as a client in OSAC's Keycloak instance.
2. On startup (and periodically), the SP obtains a JWT from Keycloak using its
   client credentials.
3. The JWT is passed as a bearer token on all gRPC calls to the OSAC fulfillment
   service.

For multi-tenant fleet management — where DCM needs to operate across multiple
OSAC organizations — Keycloak's token exchange capability (RFC 8693) allows the
OSAC SP to obtain tenant-scoped tokens without requiring separate credentials
per organization. No OSAC-specific auth integration is required; standard OIDC
and token exchange libraries work out of the box.

### Multi-Hub Topology

OSAC supports multiple infrastructure hubs managed by a single fulfillment
service. DCM's topology awareness operates at the Service Provider level —
during registration, the OSAC SP advertises region and zone metadata that DCM's
Policy Manager uses for SP selection. Hub selection within OSAC is an internal
placement decision handled by the fulfillment service, opaque to DCM. The
`providerHints.osac.hubName` field allows users to override hub selection when
needed, but is optional — if omitted, OSAC selects the appropriate hub.

### Catalog Independence

DCM and OSAC maintain independent service catalogs. The OSAC SP does not expose
OSAC's cluster catalog items to DCM, nor does DCM push its catalog definitions
into OSAC. Instead, the OSAC SP maps DCM requests to OSAC templates via the
`providerHints.osac.templateId` field. Administrators configure DCM catalog
items that reference the appropriate OSAC template, keeping each system's
catalog management self-contained.

### Integration Points

#### OSAC Fulfillment Service Integration

The OSAC SP communicates with the OSAC fulfillment service using its gRPC API.
The fulfillment service manages the lifecycle of cluster orders by coordinating
with the OSAC operator on the hub cluster.

- Uses the OSAC fulfillment service gRPC API to create, query, and delete
  cluster orders.
- The fulfillment service translates requests into `ClusterOrder` custom
  resources on the hub cluster.
- The OSAC operator reconciles `ClusterOrder` CRDs by triggering AAP
  provisioning templates.
- Clusters are provisioned using Hosted Control Planes via ACM on the hub
  cluster.

```mermaid
sequenceDiagram
    participant DCM as DCM Control Plane
    participant SP as OSAC SP
    participant FS as OSAC Fulfillment Service
    participant OP as OSAC Operator
    participant AAP as Ansible Automation Platform

    DCM->>SP: POST /api/v1alpha1/clusters
    SP->>FS: osac.public.v1.ClusterOrders/Create (gRPC)
    FS->>FS: Create ClusterOrder CR
    OP->>OP: Reconcile ClusterOrder
    OP->>AAP: Launch provisioning template
    AAP->>AAP: Provision HCP cluster
    OP->>FS: Update ClusterOrder status
    SP->>FS: osac.public.v1.ClusterOrders/Get (poll)
    SP->>DCM: Publish status event (CloudEvents)
```

#### DCM SP Registry

- Auto-registration on startup with DCM SP Registrar. See documentation for
  [DCM Registration Flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

#### DCM SP Health Check

OSAC SP must expose a health endpoint `http://<provider-ip>:<port>/health` for
DCM control plane to poll every 10 seconds. See documentation for
[SP Health Check](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-provider-health-check/service-provider-health-check.md).

#### DCM SP Status Reporting

- Publish status updates for cluster instances to the messaging system using
  CloudEvents format. Events are published to the subject:
  `dcm.providers.{providerName}.cluster.instances.{instanceId}.status`
- See documentation for
  [SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md).
- Use a polling loop against the OSAC fulfillment service to detect status
  changes on ClusterOrder resources.

### User Stories

#### Story 1: Provision an OpenShift Cluster

As a DCM user, I want to request an OpenShift cluster through DCM so that I
receive a fully provisioned cluster with credentials, without needing to
interact with OSAC directly.

#### Story 2: Query Cluster Status

As a DCM user, I want to check the status of my cluster provisioning request so
that I know when my cluster is ready and can retrieve the access credentials.

#### Story 3: Delete a Cluster

As a DCM user, I want to delete a cluster I no longer need so that
infrastructure resources are released.

### SP Configuration

The OSAC SP supports configuration options that control how it connects to the
OSAC fulfillment service.

#### Fulfillment Service Configuration

| Field              | Type   | Default | Description                                   |
| ------------------ | ------ | ------- | --------------------------------------------- |
| fulfillmentAddress | string | ""      | OSAC fulfillment service gRPC address         |
| oidcIssuerUrl      | string | ""      | Keycloak OIDC issuer URL                      |
| oidcClientId       | string | ""      | OAuth 2.0 client ID registered in Keycloak    |
| oidcClientSecret   | string | ""      | OAuth 2.0 client secret (or path to file)     |
| defaultHubName     | string | ""      | Default hub for cluster provisioning          |
| tlsEnabled         | bool   | true    | Enable TLS for fulfillment service connection |
| tlsCertFile        | string | ""      | Path to TLS CA certificate file               |

### Registration Flow

The OSAC SP API must successfully complete a registration process to ensure DCM
is aware of it and can use it. During startup, the service uses the DCM
registration client to send a request to the SP API registration endpoint
`POST /api/v1alpha1/providers`. See DCM
[registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md)
for more information.

Example request payload:

```json
{
  "name": "osac-sp",
  "serviceType": "cluster",
  "displayName": "OSAC Service Provider",
  "endpoint": "https://osac-sp.example.com/api/v1alpha1/clusters",
  "metadata": {
    "capabilities": {
      "supportedPlatforms": ["baremetal"],
      "supportedProvisioningTypes": ["hypershift"],
      "kubernetesSupportedVersions": ["1.29", "1.30", "1.31"]
    }
  },
  "operations": ["CREATE", "DELETE", "READ"]
}
```

#### Capability Advertisement

| Field                       | Type     | Description                                        |
| --------------------------- | -------- | -------------------------------------------------- |
| supportedPlatforms          | []string | Platforms this SP can provision (baremetal)        |
| supportedProvisioningTypes  | []string | Provisioning methods available (hypershift for v1) |
| kubernetesSupportedVersions | []string | Kubernetes versions supported by this SP           |

The SP populates these values based on the capabilities reported by the OSAC
fulfillment service. The OSAC platform provisions clusters on bare metal
infrastructure using Hosted Control Planes.

#### Registration Process

The OSAC SP follows the standard self-registration process defined in the
[SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md):

- API server starts and initializes HTTP listener.
- After the server is ready, registration runs in a background goroutine.
- Registration request is sent to the DCM Service Provider Registry.
- On success, the service is registered and available for DCM to use.
- Registration failures are retried with exponential backoff and logged but do
  not block server startup.

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
| GET    | /api/v1alpha1/health               | OSAC SP health check      |

##### AEP Compliance

These endpoints are defined based on AEP standards and use `aep-openapi-linter`
to check for compliance with AEP.

#### POST /api/v1alpha1/clusters

**Description:** Create a new OpenShift cluster.

The POST endpoint follows the contract defined in the Cluster schema spec
pre-defined by DCM core. See
[Cluster Schema](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#kubernetes-cluster)
for the complete specification.

The OSAC SP translates the DCM cluster request into an OSAC fulfillment service
`osac.public.v1.ClusterOrders/Create` gRPC call, mapping DCM fields to OSAC's
cluster order request specification.

**Field Mapping (DCM to OSAC Fulfillment API):**

| DCM Field                | OSAC Fulfillment API Field  | Notes                                  |
| ------------------------ | --------------------------- | -------------------------------------- |
| version                  | template_parameters         | Mapped to OpenShift release image      |
| nodes.controlPlane.count | node_sets[cp].size          | HCP manages internally; passed as hint |
| nodes.worker.count       | node_sets[worker].size      | Number of worker nodes                 |
| nodes.worker.cpu         | template_parameters.cpu     | CPU per worker node                    |
| nodes.worker.memory      | template_parameters.memory  | Memory per worker node                 |
| nodes.worker.storage     | template_parameters.storage | Storage per worker node                |
| metadata.name            | name                        | Cluster name                           |
| providerHints.osac       | template_parameters         | OSAC-specific parameters (see below)   |

**Provider Hints (osac):**

| Field        | Type   | Description                                          |
| ------------ | ------ | ---------------------------------------------------- |
| hubName      | string | Target hub for provisioning (overrides default)      |
| templateId   | string | OSAC catalog template to use for provisioning        |
| baseDomain   | string | Base DNS domain for the cluster                      |
| pullSecret   | string | Pull secret reference for cluster image pulls        |
| sshKey       | string | SSH public key for node access                       |
| releaseImage | string | Specific OpenShift release image (overrides version) |

**Example Request Payload:**

```json
{
  "version": "4.16",
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
    "name": "sovereign-ai-cluster-01"
  },
  "providerHints": {
    "osac": {
      "baseDomain": "moc.example.com",
      "templateId": "default-hcp"
    }
  },
  "serviceType": "cluster"
}
```

**Response:** Returns `201 Created` with the following payload. The status is
set to `PENDING` after the resource is created.

```json
{
  "requestId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "name": "sovereign-ai-cluster-01",
  "status": "PENDING",
  "platform": "baremetal",
  "version": "4.16",
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
    "namespace": "sovereign-ai-cluster-01",
    "createdAt": "2026-06-29T14:30:00Z"
  }
}
```

**Error Handling:**

- **400 Bad Request**: Invalid request payload or missing required fields
- **409 Conflict**: Cluster with the same `metadata.name` already exists
- **422 Unprocessable Entity**: Unsupported configuration or version
- **500 Internal Server Error**: Unexpected error during resource creation
- **502 Bad Gateway**: OSAC fulfillment service is unreachable

#### GET /api/v1alpha1/clusters

**Description:** List all cluster instances with pagination support.

**Query Parameters:**

- `max_page_size` (optional): Maximum number of resources to return in a single
  page. Default: 50.
- `page_token` (optional): Token indicating the starting point for the page.

**Process Flow:**

1. Handler receives `GET` request with optional pagination parameters.
2. Calls OSAC fulfillment service `osac.public.v1.ClusterOrders/List` gRPC
   method.
3. Filters results to those created by this SP instance.
4. Returns fully-populated cluster resources per AEP-132.
5. Response includes pagination metadata (`next_page_token`).

**Error Handling:**

- **400 Bad Request**: Invalid pagination parameters
- **500 Internal Server Error**: Unexpected error querying OSAC
- **502 Bad Gateway**: OSAC fulfillment service is unreachable

#### GET /api/v1alpha1/clusters/{clusterId}

**Description:** Get a specific cluster instance.

**Process Flow:**

1. Handler receives `GET` request with `clusterId` path parameter.
2. Calls OSAC fulfillment service `osac.public.v1.ClusterOrders/Get` gRPC method
   using the stored OSAC order ID mapped to `clusterId`.
3. Translates OSAC cluster order status and details to DCM response format.
4. When cluster reaches `READY` status, retrieves credentials via
   `osac.public.v1.Clusters/GetKubeconfig`.
5. Returns complete cluster instance object.

**Kubeconfig Field Behavior:**

- **READY**: Contains the base64-encoded kubeconfig retrieved via
  `osac.public.v1.Clusters/GetKubeconfig`. Users can decode this to access the
  cluster.
- **PROVISIONING/PENDING**: Empty string. Credentials are not yet available.
- **FAILED**: Empty string. Cluster provisioning failed.

**Error Handling:**

- **404 Not Found**: Cluster with the specified `clusterId` does not exist
- **500 Internal Server Error**: Unexpected error querying OSAC
- **502 Bad Gateway**: OSAC fulfillment service is unreachable

#### DELETE /api/v1alpha1/clusters/{clusterId}

**Description:** Delete a cluster instance.

Sends an `osac.public.v1.ClusterOrders/Delete` gRPC call to the OSAC fulfillment
service, which triggers the OSAC operator to decommission the cluster via AAP.
Returns `204 No Content`.

**Process Flow:**

1. Handler receives `DELETE` request with `clusterId` path parameter.
2. Looks up the OSAC order ID mapped to `clusterId`.
3. Calls OSAC fulfillment service `osac.public.v1.ClusterOrders/Delete` gRPC
   method.
4. Returns `204 No Content` on success.

**Error Handling:**

- **404 Not Found**: Cluster with the specified `clusterId` does not exist
- **500 Internal Server Error**: Unexpected error during deletion
- **502 Bad Gateway**: OSAC fulfillment service is unreachable

#### GET /api/v1alpha1/health

**Description:** Retrieve the health status for the OSAC Service Provider API.

The health check verifies:

- Connectivity to the OSAC fulfillment service (gRPC health check)
- Valid OIDC token (can obtain or refresh JWT from Keycloak)
- At least one hub is registered and available

### Implementation Details/Notes/Constraints

#### ID Mapping

The OSAC SP maintains a mapping between DCM instance IDs (`clusterId`) and OSAC
order IDs. This mapping is stored locally and used to translate between DCM and
OSAC identifiers on all operations.

#### Status Polling

Unlike SPs that watch Kubernetes CRDs directly, the OSAC SP polls the OSAC
fulfillment service (`osac.public.v1.ClusterOrders/List`) at a configurable
interval (default: 30 seconds) to detect status changes on cluster orders. When
a status change is detected, the SP publishes a CloudEvents status update to
DCM. The OSAC fulfillment service also exposes an `osac.public.v1.Events`
service which may enable event-driven status updates in a future iteration.

#### Version Translation

The OSAC SP translates between DCM's Kubernetes version format (e.g., `1.29`)
and OSAC's OpenShift version format (e.g., `4.16`). The SP maintains an internal
compatibility matrix for this translation. If a user specifies `version` using
the OpenShift format directly (e.g., `4.16`), the SP accepts it without
translation.

### Risks and Mitigations

| Risk                                                                    | Mitigation                                                                                                             |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| OSAC fulfillment service is unavailable, causing all operations to fail | Health check detects connectivity loss; exponential backoff on retries; DCM can route to alternative cluster providers |
| Status polling introduces latency in reporting cluster readiness        | Configurable poll interval; future enhancement to use `osac.public.v1.Events` service for event-driven status updates  |
| ID mapping data loss (local storage) causes orphaned clusters           | Persist mapping in a durable store; reconciliation loop matches OSAC orders by metadata labels                         |
| OSAC platform version upgrades change the gRPC API contract             | Pin to a specific OSAC API version; version negotiation on startup                                                     |
| Network partition between OSAC SP and fulfillment service               | Circuit breaker pattern; return 502 to DCM so it can retry or failover                                                 |

## Design Details

### Status Reporting to DCM

The OSAC SP uses a polling loop to monitor cluster order status changes in the
OSAC fulfillment service and publishes updates to DCM via CloudEvents.

#### Polling Loop

- Runs in a background goroutine at a configurable interval (default: 30s).
- Calls `osac.public.v1.ClusterOrders/List` for all cluster orders created by
  this SP instance.
- Compares current status against last-known status from the local cache.
- Publishes a CloudEvents status update for each order that has changed.

#### CloudEvents Format

Status updates are published using the [CloudEvents](https://cloudevents.io/)
specification (v1.0).

**Message Subject:**

`dcm.providers.{providerName}.cluster.instances.{instanceId}.status`

**Event Type:**

`dcm.providers.{providerName}.status.update`

**Payload:**

```json
{
  "status": "READY",
  "message": "Cluster is ready and all nodes are available."
}
```

#### Status Mapping (OSAC to DCM)

The OSAC fulfillment service returns status values on cluster order responses.
The OSAC SP maps these to DCM status values:

| DCM Status   | OSAC Fulfillment Status | Description                                       |
| ------------ | ----------------------- | ------------------------------------------------- |
| PENDING      | (newly created)         | Order accepted, not yet started                   |
| PROVISIONING | PROGRESSING             | Cluster is being provisioned                      |
| READY        | READY                   | Cluster is fully operational                      |
| FAILED       | FAILED                  | Provisioning failed                               |
| UNAVAILABLE  | DEGRADED                | Cluster is provisioned but experiencing issues    |
| DELETED      | (order not found)       | ClusterOrder has been removed from fulfillment DB |

### Upgrade / Downgrade Strategy

The OSAC SP is a stateless adapter service. Upgrades are performed by deploying
a new version of the SP image. The ID mapping store must be preserved across
upgrades. Downgrades are safe as long as the OSAC fulfillment service gRPC API
remains backward-compatible.

## Implementation History

- 2026-06-29: Initial enhancement proposal created.

## Drawbacks

The primary drawback is the additional indirection layer. Unlike the ACM Cluster
SP which creates HyperShift CRDs directly on the hub cluster, the OSAC SP goes
through the OSAC fulfillment service, adding a network hop and dependency. This
introduces:

- Higher latency on provisioning requests (additional gRPC call).
- An additional failure point (fulfillment service availability).
- Status reporting via polling rather than direct CRD watches, which adds
  latency to status updates.

This tradeoff is acceptable because it preserves OSAC's existing orchestration
logic (multi-hub placement, template-based automation, catalog management)
without reimplementing it in the SP, and aligns with OSAC's intended integration
model where external consumers go through the fulfillment API.

## Alternatives

### Alternative 1: Direct CRD Creation on OSAC Hub Cluster

#### Description

The OSAC SP creates `ClusterOrder` CRDs directly on the OSAC hub cluster,
bypassing the fulfillment service entirely. This is similar to how the ACM
Cluster SP creates `HostedCluster` CRDs directly.

#### Pros

- Lower latency (no gRPC hop to fulfillment service)
- Direct CRD watch for real-time status updates (SharedIndexInformer)
- Fewer moving parts in the data path
- Simpler error handling (fewer network boundaries)

#### Cons

- Bypasses OSAC's fulfillment logic (catalog items, multi-hub placement, access
  control)
- Requires OSAC SP to have cluster-admin credentials on the hub cluster
- Tightly couples DCM to OSAC's internal CRD schema, which may change
- Cannot leverage OSAC's built-in rate limiting and request validation
- Breaks OSAC's intended architecture where external consumers use the API

#### Status

Rejected

#### Rationale

The fulfillment service exists precisely to provide a governed, stable API
surface for external consumers. Bypassing it would require the OSAC SP to
reimplement OSAC's orchestration logic and would create a maintenance burden as
OSAC's internal CRD schema evolves. The additional latency of the gRPC hop is
negligible compared to cluster provisioning time (minutes to hours).

### Alternative 2: OSAC REST Gateway Instead of gRPC

#### Description

Use the OSAC fulfillment service's REST gateway instead of the gRPC API for
communication between the OSAC SP and OSAC.

#### Pros

- Simpler implementation (HTTP/JSON vs. Protocol Buffers)
- Easier to debug with standard HTTP tooling (curl, browser)
- No protobuf dependency in the OSAC SP codebase

#### Cons

- REST gateway may not expose all gRPC features (streaming, bidirectional)
- Additional translation layer (REST gateway is itself a gRPC client)
- Slightly higher overhead (JSON serialization vs. protobuf)
- REST gateway may lag behind gRPC API in feature parity

#### Status

Deferred

#### Rationale

gRPC provides better performance, type safety via generated clients, and access
to the full OSAC API surface including streaming for future real-time status
updates. If the REST gateway achieves full feature parity and the team prefers
HTTP-based integration, this can be revisited. The implementation could support
both backends via a configurable transport layer.

### Alternative 3: Include VM Support in v1 via Direct CRD Creation

#### Description

Add `serviceType: "vm"` support in v1 by having the OSAC SP create
`ComputeInstance` CRDs directly on the OSAC hub cluster, bypassing the
fulfillment service for VM operations while using the fulfillment gRPC API for
clusters.

#### Pros

- Delivers both service types in v1
- OSAC's ComputeInstance operator is already feature-complete
- Users get VM provisioning without waiting for OSAC's fulfillment API

#### Cons

- Creates two different integration paths within a single SP (gRPC for clusters,
  direct CRD for VMs), increasing complexity
- Bypasses OSAC's intended architecture for external consumers
- Tightly couples the OSAC SP to the ComputeInstance CRD schema, which is still
  evolving (e.g., OSAC-769 multi-NIC migration completed June 2026)
- Requires cluster-admin credentials on the hub for VM operations
- When OSAC does expose VMs through the fulfillment API, the SP would need to
  migrate from direct CRD to gRPC — a breaking change in integration pattern
- No access to OSAC's catalog templates, rate limiting, or access control for
  VMs

#### Status

Rejected

#### Rationale

The short-term benefit of delivering VM support in v1 does not justify the
technical debt of maintaining two divergent integration paths. The
ComputeInstance CRD is still undergoing schema changes (recent field removals,
immutability additions), and coupling to it directly would create a maintenance
burden. Waiting for OSAC to expose VMs through their public fulfillment API
ensures a consistent adapter pattern across both service types and avoids a
costly migration later.

## Infrastructure Needed

- Access to an OSAC deployment (fulfillment service, operator, hub cluster with
  AAP) for integration testing.
- gRPC client stubs generated from OSAC's protobuf definitions.
- CI/CD pipeline for building and testing the OSAC SP image.
- Container registry for publishing the OSAC SP image.
