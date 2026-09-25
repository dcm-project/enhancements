---
title: cost-sp
authors:
  - "@pgarciaq"
reviewers:
  - "@gciavarrini"
  - "@machacekondra"
  - "@ygalblum"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"
  - "@gabriel-farache"
  - "@jenniferubah"
approvers:
  - TBD
creation-date: 2026-04-17
see-also:
  - "/enhancements/kubevirt-sp/kubevirt-sp.md"
  - "/enhancements/acm-cluster-sp/acm-cluster-sp.md"
  - "/enhancements/k8s-container-sp/k8s-container-sp.md"
  - "/enhancements/sp-registration-flow/sp-registration-flow.md"
  - "/enhancements/service-provider-health-check/service-provider-health-check.md"
  - "/enhancements/service-type-definitions/service-type-definitions.md"
  - "/enhancements/control-plane-monolith/control-plane-monolith.md"
---

# Cost Management Service Provider

## Open Questions

1. **Tag-based rates in the spec?** Koku supports rates keyed by label
   key:value pairs (40+ cost dimensions). Should the `CostSpec` schema include
   tag rates in v1, or defer to v2? *Recommendation: defer — tiered rates cover
   90% of use cases; tag rates add significant schema complexity.*

2. **In-place tier upgrades.** *(Deferred.)* Can an instance be upgraded from
   Tier 1 to Tier 3 without delete+recreate? Koku cost models are mutable
   (PUT), so the SP could support it. However, DCM does not yet support
   instance updates, so this is deferred until that capability is available.
   The proposal was influenced by UDLM's vision of mutable resource
   specifications; v1 uses delete+recreate.

3. **Multi-tenancy mapping.** DCM does not have tenancy yet (v1). Koku uses
   schema-per-tenant. Which Koku tenant does the bridge create sources in?
   *For v1, a single pre-configured Koku tenant is assumed.*

## Summary

The Cost Management Service Provider integrates
[Red Hat Lightspeed Cost Management](https://github.com/project-koku/koku)
(Project Koku) with DCM's provisioning lifecycle. It introduces a new `cost`
service type and a Go microservice (`koku-cost-provider`) that translates DCM
lifecycle events into Koku API operations — creating sources, cost models, and
metering configurations automatically when DCM provisions infrastructure.

Unlike existing SPs that provision compute resources (VMs, containers,
clusters), the cost SP provisions **cost visibility**: metering, overhead
distribution, and financial tracking for resources managed by other SPs. It
uses DCM's standard SP contract — the same `POST` / `DELETE` / CloudEvent
lifecycle as any other provider.

Implementation: [pgarciaq/cost-dcm-provider](https://github.com/pgarciaq/cost-dcm-provider)

## Motivation

When DCM provisions an OpenShift cluster, someone must separately configure
cost tracking in Koku: create a source, install the metrics operator, set up a
cost model with rates and distribution settings. Today this is entirely manual
and disconnected from DCM's lifecycle.

This creates several problems:

- **No automatic cost visibility.** Clusters can run for days before cost
  tracking is configured.
- **No lifecycle synchronization.** Deleting a cluster in DCM does not clean up
  its Koku source or cost model.
- **No governance.** Rate policies, markup limits, and budget enforcement cannot
  be applied through DCM's policy engine.
- **No audit trail.** Cost configuration changes are invisible to DCM.

Making cost tracking a first-class DCM resource — with its own service type,
catalog items, and policies — solves all of these.

### Goals

- Introduce a `cost` service type that extends DCM's service type enum.
- Provide a Go service provider (`koku-cost-provider`) that creates Koku
  sources and cost models via Koku's REST API.
- Support three tiers of cost visibility: basic metering, metering +
  distribution, and full cost (metering + distribution + price list).
- Define catalog items for each tier, configured by the platform operator.
- Enable automated cost instance creation via a bridge that watches NATS
  cluster events and creates cost instances through DCM's catalog pipeline.
- Expose metering and cost data through read-only query endpoints on the SP.
- Publish standard CloudEvent status updates to NATS.
- Implement the three-state health model (`healthy`/`unhealthy`/`unavailable`).

### Non-Goals

- Replacing or reimplementing Koku's metering pipeline, rate engine,
  distribution logic, or reporting.
- Cloud cost management in v1 (AWS CUR, Azure, GCP). The v1 scope focuses on
  OpenShift cluster and VM metering. Koku already handles cloud costs and the
  SP architecture is designed to support additional resource types (VMs,
  OpenStack workloads, cloud costs) in future versions.
- Tag-based rates in v1 (deferred to v2).
- DCM UI integration for cost dashboards (future capability).

**Note on scope:** The `cost` service type is intentionally generic — not
OpenShift-specific. The
[koku-metrics-operator](https://github.com/project-koku/koku-metrics-operator)
already captures OpenShift Virtualization VM metrics (CPU, memory, disk,
uptime, labels — see
[queries.go](https://github.com/project-koku/koku-metrics-operator/blob/main/internal/collector/queries.go#L36))
in addition to pod, node, PVC, namespace, and GPU metrics. RHOSO (Red Hat
OpenStack Services on OpenShift) metering support is being added before end of
year ([COST-5067](https://redhat.atlassian.net/browse/COST-5067)). Future
versions of this SP will expose those additional cost dimensions through DCM.

## Proposal

### Overview

The cost SP bridges the gap between DCM (which knows *what* was provisioned and
*when*) and Koku (which knows *how to calculate costs* but not *what DCM
provisioned*). It does this by:

1. Registering as a DCM service provider for the `cost` service type.
2. Receiving create/delete requests from the control plane.
3. Translating those into Koku API calls (create/delete sources and cost
   models).
4. Monitoring readiness via a background reconciler.
5. Publishing status events to NATS.
6. Serving metering and cost query endpoints (read-only).

A companion **bridge component** (which can be the same binary) watches NATS
for cluster READY events and automatically creates cost instances through
DCM's catalog pipeline — so every cluster gets cost tracking without manual
intervention.

### User Stories

#### Story 1 — Automatic cost tracking for every cluster

A platform operator configures cost catalog items and a bridge label→tier
mapping once. After that, every cluster provisioned through DCM automatically
gets metering and cost tracking at the appropriate tier. The operator does not
need to touch Koku manually for each cluster.

#### Story 2 — Three tiers of visibility

A platform operator offers three levels of cost visibility through the catalog:

- **Basic Metering** (Tier 1): CPU, memory, and storage utilization. No cost
  model needed. Suitable for dev/test clusters.
- **Metering + Distribution** (Tier 2): Tier 1 plus overhead categorization
  (control plane, platform, worker, storage, GPU, network) distributed across
  projects. No dollar amounts.
- **Full Cost** (Tier 3): Tier 2 plus a price list with rates. Every metric
  becomes a billable quantity: `cost = metering × rate`.

#### Story 3 — Tenant queries cost data

A tenant queries their cluster's CPU utilization and cost breakdown through the
cost SP's read-only API. They see only their own clusters — Koku's RBAC
enforces multi-tenant isolation.

#### Story 4 — Policy-governed rates

A platform operator creates Rego policies that enforce minimum markup on
production clusters and cap rates within allowed ranges. These policies apply
to both automatic (bridge-initiated) and manual cost instances.

#### Story 5 — Cluster deletion cascade

When a cluster is deleted, the bridge detects the NATS deletion event and
triggers cleanup of the corresponding cost instance through DCM's standard
lifecycle. Historical cost data is preserved (Koku source is paused, not
deleted).

### Implementation Details/Notes/Constraints

#### New Service Type: `cost`

This SP introduces a new `cost` service type. Metering and cost tracking is
not a VM, container, or cluster — it is a cross-cutting capability that
applies to those resources. A separate service type cleanly separates concerns
and enables catalog governance and policy evaluation.

The `cost` service type definition (schema and enum addition) will be
submitted as a separate PR to the
[service-type-definitions](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md)
enhancement, consistent with how `vm`, `container`, `database`, and `cluster`
are defined there. This document references that definition.

#### Spec Schema

```yaml
CostSpec:
  type: object
  required:
    - target
  properties:
    target:
      type: object
      required:
        - resource_id
      properties:
        resource_id:
          type: string
          description: DCM instance ID of the cluster to track costs for.
        resource_type:
          type: string
          default: cluster
    cost_model:
      type: object
      properties:
        rates:
          type: array
          items:
            type: object
            required: [metric, value]
            properties:
              metric:
                type: string
                enum:
                  - cpu_core_usage_per_hour
                  - cpu_core_request_per_hour
                  - memory_gb_usage_per_hour
                  - memory_gb_request_per_hour
                  - storage_gb_usage_per_month
                  - storage_gb_request_per_month
                  - node_cost_per_month
                  - cluster_cost_per_month
                  - pvc_cost_per_month
              cost_type:
                type: string
                enum: [Infrastructure, Supplementary]
                default: Infrastructure
              value:
                type: number
                minimum: 0
        markup:
          type: object
          properties:
            value:
              type: number
              default: 0
            unit:
              type: string
              enum: [percent]
              default: percent
        distribution:
          type: string
          enum: [cpu, memory]
          default: cpu
    currency:
      type: string
      default: USD
```

The three tiers map to what is present in the spec:

| Tier | `cost_model` | `cost_model.rates` | What Koku does |
|------|-------------|-------------------|----------------|
| 1 — Basic Metering | absent | — | Source only. Usage data flows. |
| 2 — Distribution | present | absent | Source + cost model with distribution. Overhead is categorized. |
| 3 — Full Cost | present | present | Source + cost model + rates. `cost = metering × rate`. |

#### Registration

```json
{
  "name": "koku-cost-provider",
  "display_name": "Red Hat Lightspeed Cost Management",
  "service_type": "cost",
  "endpoint": "http://koku-cost-provider:8080/api/v1alpha1/instances",
  "schema_version": "v1alpha1",
  "operations": ["create", "delete"]
}
```

#### Create Workflow

1. Validate that the target cluster exists and is READY (query control plane).
2. Resolve the OpenShift `cluster_id` from the target cluster's
   `ClusterVersion` CR (via kubeconfig from ACM hub).
3. Create a Koku Source (`POST /api/cost-management/v1/sources/`).
4. If `cost_model` is present in the spec, create a Koku Cost Model
   (`POST /api/cost-management/v1/cost-models/`). Skip for Tier 1.
5. Store the ID mapping (see table below).
6. Return `{id, status: "PROVISIONING"}`.
7. Background reconciler polls `GET /sources/{uuid}/stats/` until first
   metering data appears, then publishes a READY CloudEvent.

**ID Mapping:**

The SP maintains a four-way mapping in SQLite that links DCM and Koku objects
for lifecycle management:

| Field | Description | Example |
|-------|------------|---------|
| `dcm_instance_id` | DCM catalog item instance ID | `inst-abc123` |
| `cluster_id` | OpenShift cluster UUID (from `ClusterVersion` CR) | `d4f8e2a1-...` |
| `koku_source_uuid` | Koku source created for this cluster | `src-789xyz` |
| `koku_cost_model_uuid` | Koku cost model (Tier 2/3 only; null for Tier 1) | `cm-456def` |

This mapping enables the SP to:
- On **DELETE**: look up the Koku source to pause and cost model to remove.
- On **status queries**: filter Koku reports by the target cluster's `cluster_id`.
- On **reconciliation**: check whether metering data is flowing for the source.

#### Delete Workflow

1. Look up mapping for the instance.
2. Delete the Koku cost model (if one was assigned).
3. Pause the Koku source (`PATCH /sources/{uuid}/ {"paused": true}`) to
   preserve historical data.
4. Clean up mapping.
5. Publish DELETED CloudEvent.
6. Return 204.

#### Status Lifecycle

```
PROVISIONING → READY → ERROR → DELETED
```

- **PROVISIONING**: Koku source created; waiting for first metering data.
- **READY**: Metering data is actively flowing.
- **ERROR**: Operator not uploading, Koku API unreachable, or other failure.
- **DELETED**: Source paused, cost model removed.

##### Status Mapping from Koku to DCM

The following table maps Koku-side conditions to DCM status values:

| DCM Status | Koku Condition | Description |
|------------|---------------|-------------|
| PROVISIONING | Source created, no metering data yet | Koku source exists but `GET /sources/{uuid}/stats/` returns empty data. Operator may still be bootstrapping (~10-15 min). |
| READY | Metering data actively flowing | `GET /sources/{uuid}/stats/` returns recent data points. Source is active and not paused. |
| ERROR | Operator not uploading | Source exists but metering data has gone stale (no new data beyond the configured staleness threshold). |
| ERROR | Koku API unreachable | SP cannot reach the Koku API to verify source status. |
| ERROR | Source creation failed | Koku rejected the `POST /sources/` request (e.g., duplicate `cluster_id`, invalid authentication). |
| DELETED | Source paused, cost model removed | `PATCH /sources/{uuid}/ {"paused": true}` succeeded. Historical data is preserved in Koku. |

#### API Endpoints

The following table summarizes the full API surface:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check (three-state model) |
| `/metrics` | GET | Prometheus metrics |
| `/api/v1alpha1/instances` | POST | Create a cost instance (Koku source + optional cost model) |
| `/api/v1alpha1/instances/{id}` | GET | Get cost instance status and details |
| `/api/v1alpha1/instances/{id}` | DELETE | Delete cost instance (pause Koku source, remove cost model) |
| `/api/v1alpha1/instances` | GET | List cost instances |
| `/usage/{id}/compute` | GET | Query CPU utilization (proxied from Koku) |
| `/usage/{id}/memory` | GET | Query memory utilization (proxied from Koku) |
| `/usage/{id}/storage` | GET | Query storage utilization (proxied from Koku) |
| `/cost-reports/{id}` | GET | Query cost summary (requires cost model) |
| `/cost-reports/{id}/breakdown` | GET | Query cost breakdown by project (requires cost model) |
| `/cost-reports/{id}/forecast` | GET | Query cost forecast (requires cost model) |

#### Health Endpoint

The SP implements the three-state health model per the
[SP Health Check](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-provider-health-check/service-provider-health-check.md)
enhancement:

```json
{"status": "healthy", "version": "0.1.0", "uptime": 3600}
```

The SP returns `healthy` when the Koku API is reachable, or `unhealthy` when
Koku is down. The third state, `unavailable`, is inferred by the control plane
when the SP itself is unreachable (non-200 / timeout after `FailureThreshold`).

#### Read-Only Query API

In addition to the CRUD lifecycle, the SP serves metering and cost query
endpoints. These are designed for multiple consumers:

- **DCM UI** — platform engineers can see cost data alongside provisioned
  resources in a single dashboard.
- **Tenant self-service** — operators or project owners can query their
  cluster's metering and cost data through DCM's API gateway without needing
  direct Koku access.
- **External tooling** — CI/CD pipelines for cost gates, external dashboards,
  or cost-aware placement policies.

**Metering** (always available):

| Endpoint | Koku API Call |
|----------|--------------|
| `GET /usage/{id}/compute` | `GET /reports/openshift/compute/?filter[cluster]={cluster_id}` |
| `GET /usage/{id}/memory` | `GET /reports/openshift/memory/?filter[cluster]={cluster_id}` |
| `GET /usage/{id}/storage` | `GET /reports/openshift/volumes/?filter[cluster]={cluster_id}` |

**Cost** (available when a cost model is assigned):

| Endpoint | Koku API Call |
|----------|--------------|
| `GET /cost-reports/{id}` | `GET /reports/openshift/costs/?filter[cluster]={cluster_id}` |
| `GET /cost-reports/{id}/breakdown` | `GET /reports/openshift/costs/?filter[cluster]={cluster_id}&group_by[project]=*` |
| `GET /cost-reports/{id}/forecast` | `GET /forecasts/openshift/costs/?filter[cluster]={cluster_id}` |

#### Bridge Component

The bridge watches NATS for cluster READY events and automatically creates
cost instances through DCM's catalog pipeline. It is essentially event-driven
automation on top of DCM's existing API: it subscribes to NATS CloudEvents,
watches for cluster READY/DELETED events from any cluster SP (ACM, kcli, k8s,
etc.), and automatically creates/deletes cost instances through DCM's standard
catalog pipeline — so every provisioned cluster gets cost tracking without
operator intervention per cluster.

**Future:** DCM's upcoming
[declarative API](https://github.com/dcm-project/enhancements/blob/main/enhancements/declarative-api/declarative-api.md)
will support multi-resource catalog items, enabling "provision cluster + attach
cost metering" in a single request. When that capability is available, the
bridge can be replaced by a composite catalog item. The bridge approach was
chosen for v1 because it works with DCM as it exists today.

Flow:

1. Receive `dcm.status.cluster` CloudEvent with `status: READY`.
2. Read the cluster's labels to select the appropriate catalog item.
3. Submit a `CatalogItemInstance` creation request through DCM's API.
4. The normal catalog → placement → policy → SP flow handles the rest.

Label-to-tier mapping (operator-configured):

| Cluster Label | Catalog Item | Tier |
|---------------|-------------|------|
| `cost-tier: basic` | `cluster-metering-basic` | 1 |
| `cost-tier: distribution` | `cluster-metering-distribution` | 2 |
| `environment: production` | `standard-cluster-cost-tracking` | 3 |
| `environment: development` | `dev-cluster-cost-tracking` | 3 |
| `chargeback: enabled` | `chargeback-cost-tracking` | 3 |
| (no match) | `standard-cluster-cost-tracking` | 3 |

On cluster deletion, the bridge triggers cost instance cleanup through DCM's
standard SPRM API.

#### Catalog Items

Six catalog items covering all three tiers:

| Catalog Item | Tier | Rates | Markup | Distribution | Use Case |
|-------------|------|-------|--------|-------------|----------|
| Basic Cluster Metering | 1 | — | — | — | Dev/test utilization visibility |
| Cluster Metering + Distribution | 2 | — | — | editable | Overhead attribution |
| Standard Cluster Cost Tracking | 3 | fixed | 0% | fixed (cpu) | Production default |
| Custom Cluster Cost Tracking | 3 | editable | editable | editable | Operator overrides |
| Internal Chargeback | 3 | fixed | editable (10-30%) | fixed (memory) | Tenant billing |
| Development Cost Tracking | 3 | fixed (lower) | 0% | fixed (cpu) | Dev/test with costs |

#### Policies

| Policy | Applies To | Effect |
|--------|-----------|--------|
| Rate Governance | `cost` | Constrains rate values to [0.001, 100] and markup to [0, 50%] |
| Production Markup | `cost` | Patches markup to ≥10% for production clusters |
| Budget Enforcement | `cluster` | Rejects cluster provisioning if projected spend exceeds budget |
| Provider Selection | `cost` | Routes all cost instances to `koku-cost-provider` |

### Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Koku API changes break the SP | Pin Koku API version; SP documents validated Koku version per release. |
| Operator bootstrap delay (~10-15 min) | Reconciler polls with configurable timeout (default 24h). |
| DCM has no SP-to-SP communication | Bridge subscribes to NATS independently; not reliant on SP-to-SP. |
| Koku API authentication on-prem | SP uses a pre-configured `x-rh-identity` service account. |
| Full-cluster data collection scales with cluster size | Expected behavior — same pipeline used by all Cost Management deployments. |

## Design Details

### Architecture

```
┌─────────────────┐    NATS     ┌──────────────┐
│ ACM Cluster SP  │───────────→│    Bridge     │
│ (provisions     │  CloudEvent │ (watches for  │
│  clusters)      │  READY/DEL  │  cluster      │
└─────────────────┘             │  events)      │
                                └──────┬───────┘
                                       │ POST /catalog-item-instances
                                       ▼
                                ┌──────────────┐
                                │  DCM Control  │
                                │  Plane        │
                                │  (catalog →   │
                                │   placement → │
                                │   policy →    │
                                │   SP mgr)     │
                                └──────┬───────┘
                                       │ POST /instances
                                       ▼
                                ┌──────────────┐     Koku REST API
                                │ koku-cost-   │────────────────→ Koku
                                │ provider     │  create source,
                                │ (this SP)    │  cost model
                                └──────┬───────┘
                                       │ CloudEvent
                                       ▼
                                     NATS
                                  (status updates)
```

### Technology Stack

| Component | Technology |
|-----------|-----------|
| Language | Go 1.25+ |
| API | OpenAPI 3.0.4 + oapi-codegen |
| HTTP | go-chi/chi |
| Persistence | SQLite (GORM) for ID mappings |
| Messaging | NATS JetStream (CloudEvents SDK) |
| Health | Three-state model (healthy/unhealthy/unavailable) |
| Koku client | HTTP client with `x-rh-identity` auth |

### Test Plan

- Unit tests for handler, Koku client, reconciler, and store layers.
- Integration tests against a mock Koku API.
- E2E tests against a running DCM control plane and Koku instance.
- CI: build, lint, test, and generated-code-check on every push and PR.

### Upgrade / Downgrade Strategy

The SP is stateless beyond its SQLite mapping database. Upgrading replaces the
binary and restarts. The reconciler rehydrates PROVISIONING instances on
startup. Downgrading is safe as long as the SQLite schema is backward
compatible.

## Implementation History

| Date | Milestone |
|------|-----------|
| 2026-04-17 | Design documents: Integration Architecture (v1.2), Service Provider Design (v1.3), white paper |
| 2026-04-18 | Initial implementation: Go SP with Koku client, handler, reconciler, store |
| 2026-04-18 | CI pipeline, lint fixes, architecture diagrams |
| 2026-04-19 | README, project structure documentation |
| 2026-06-16 | Enhancement proposal submitted |

## Drawbacks

- Adds a new service type (`cost`) to DCM's taxonomy. However, metering/cost
  tracking does not fit any existing type — it is a cross-cutting capability,
  not a compute resource.
- Requires a running Koku instance. The SP is a thin lifecycle manager, not a
  standalone cost engine.
- The bridge component is a custom NATS consumer outside the standard SP
  contract. This is a pragmatic choice given DCM's lack of SP-to-SP
  communication.

## Alternatives

### Alternative 1 — Metering fields inside `cluster` catalog items

#### Description

Add cost model configuration as fields in the existing cluster catalog items.

#### Pros

- No new service type needed.

#### Cons

- Couples cluster provisioning to cost management — different admins manage
  each.
- Metering can be added/removed independently of the cluster lifecycle.
- Cannot apply cost-specific policies.

#### Status

Rejected

#### Rationale

Separation of concerns. Cost tracking has its own lifecycle, governance needs,
and operational ownership.

### Alternative 2 — Background bridge with no DCM visibility

#### Description

A bridge service that calls Koku directly without registering as a DCM SP or
creating catalog instances.

#### Pros

- Simpler implementation — no catalog items, no policies.

#### Cons

- Invisible infrastructure. No catalog entry, no policy governance, no
  lifecycle management, no audit trail.
- Cost configuration becomes a side channel that DCM doesn't know about.

#### Status

Rejected

#### Rationale

Making cost tracking a first-class DCM resource is the whole point. Governance,
audit trail, and lifecycle management through the standard pipeline justify the
additional complexity.

### Alternative 3 — Embedded cost engine (no Koku dependency)

#### Description

Build a self-contained cost SP that collects metrics and calculates costs
independently.

#### Pros

- No external dependency.

#### Cons

- Reimplements most of Koku: metering pipeline, rate engine, distribution
  logic, reporting, RBAC, forecasting.
- Massive scope. Loses Koku's mature, battle-tested cost model system.

#### Status

Rejected

#### Rationale

Koku already solves this problem. The SP should be a thin lifecycle manager,
not a cost engine.

## Infrastructure Needed

- Repository: [pgarciaq/cost-dcm-provider](https://github.com/pgarciaq/cost-dcm-provider)
  (to be transferred to `dcm-project` if accepted).
- Container image: `quay.io/dcm-project/koku-cost-provider` (post-transfer).
- A running Koku instance for E2E testing.
