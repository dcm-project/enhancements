---
title: control-plane-monolith
authors:
  - "@gciavarrini"
reviewers:
  - "@jenniferubah"
  - "@machacekondra"
  - "@ygalblum"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"
  - "@gabriel-farache"
approvers:
  - TBD
creation-date: 2026-05-07
---

# Control Plane Monolith

## Summary

The control plane monolith merges `catalog-manager`, `placement-manager`,
`policy-manager`, and `service-provider-manager` into one Git repository, one
runtime process, and one deployable image. Today those managers run as separate
services with HTTP between them on the synchronous provision path. The monolith
uses in-process calls instead. Control plane state lives in one Postgres database
with a merged schema. Service Providers and NATS remain outside this deployable.

## Motivation

Four deployables made sense for parallel work and separation of concerns.
Releases already move together, and manager-to-manager HTTP adds latency,
failure points, and contract overhead without clear benefit at current scale.

A monolith runtime removes internal HTTP on create/delete/rehydrate, simplifies
local and demo stacks, and matches how the synchronous path is actually used
today.

### Goals

- One monorepo for `catalog-manager`, `placement-manager`, `policy-manager`, and
  `service-provider-manager`.
- One control-plane deployment instead of four manager deployments.
- One Postgres database with a merged schema for all manager domains.
- In-process calls between those managers on the synchronous path.
- Deprecate four manager images on a published timeline.

### Non-Goals

- Changing provider-side NATS status flows or external Service Provider
  processes.
- A separate api-gateway stack in the first phase (add edge routing when
  requirements justify it).

## Proposal

### Target architecture

| Topic | End state |
| --- | --- |
| Git | One monorepo for the four managers |
| Runtime | One process |
| Ship | One control-plane image |
| Data | One Postgres database, merged schema |
| Public HTTP | Monolith serves `/api/v1alpha1`. No separate api-gateway deployable initially |
| catalog ↔ placement ↔ policy ↔ service-provider | In-process |
| Failure | One outage affects the whole control plane |

Illustrative layout:

```bash
dcm-platform/
  cmd/dcm-server/
  internal/catalog/
  internal/placement/
  internal/policy/
  internal/serviceprovider/
  api/openapi/
  deploy/
```

### User Stories

#### Operator deploys one control-plane image

Operators run one manager container and one control-plane Postgres database
(plus NATS and providers as today) instead of four manager containers and four
databases. Versioning and rollout use a single tag.

#### Developer traces a create request in one process

A catalog-item-instance create runs catalog → placement → policy →
service-provider without inter-manager HTTP. Logs and traces stay in one process
with domain labels.

### Implementation Details/Notes/Constraints

**Current layout:** four dcm-project repos, four Quay images, Traefik
(api-gateway stack) path routing to four backends. Synchronous chain:
catalog-manager → placement-manager → policy-manager → service-provider-manager.
Each manager has its own Postgres database.

| Manager | Main data | Responsibility |
| --- | --- | --- |
| catalog-manager | Catalog item instance | Catalog lifecycle |
| placement-manager | Service type instance | Placement and provider selection |
| policy-manager | Policy evaluation | Synchronous checks on the provision path |
| service-provider-manager | Provider-facing instance | Provider registration, CRUD, and status via NATS |

**Migration plan:**

1. **Monorepo:** one Git tree, one root `go.mod`, domains under `internal/*`
   (for example `internal/catalog/`). Shared Makefile, lint config, and CI
   entrypoint. Keep unit and subsystem tests scoped per domain. CI runs separate
   jobs per domain in parallel on every PR at first. If that becomes too slow,
   skip jobs for domains whose paths did not change in the PR.

2. **Domain interfaces:** catalog → placement → policy → service-provider behind
   interfaces. HTTP implementations only during cutover.
3. **Single binary:** `cmd/dcm-server` wires all domains. Service-provider
   routes and the NATS consumer run in the same process. Remove internal manager
   URL env vars.
4. **HTTP entrypoint:** clients and the
   [api-gateway](https://github.com/dcm-project/api-gateway) `compose.yaml`
   stack call the monolith directly instead of Traefik on port 9080. Document
   the monolith port. Reintroduce Traefik or cluster ingress later if TLS
   termination or multi-backend routing is needed.
5. **CI and images:** one Containerfile, one Quay image. Deprecate four manager
   images.
6. **Database:** merge the four manager schemas into one Postgres database and
   one migration stream. Update api-gateway postgres init, compose, and subsystem
   tests. We are not in production, so this is part of the first merge rather
   than a follow-up migration.

### Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Blast radius: any fatal error affects whole plane | Domain boundaries in code, tests per package, trace labels per domain |
| Longer CI when any domain changes | Accept for now. Split images rejected (see Alternatives) |
| Large binary / memory footprint | Profile after merge. Scale replicas as a unit |
| Schema merge across domains | Domain packages and migrations stay separated in code. Review FKs and naming in one schema |
| No edge proxy at first | Add Traefik or ingress when TLS or multi-backend routing is required |

## Design Details

### Synchronous path after merge

| Area | Interim | Proposed |
| --- | --- | --- |
| catalog, placement, policy | HTTP | In-process |
| catalog to service-provider | HTTP (via placement) | In-process |
| API entrypoint | Traefik to four backends | Monolith HTTP port |
| Postgres | Four separate databases | One database, merged schema |
| OPA | HTTP from policy | Unchanged |

### Test Plan

- Subsystem tests per domain inside the monorepo (existing suites moved or
  adapted).
- Integration tests for create/delete/rehydrate without inter-manager HTTP.
- Local compose smoke tests against the monolith HTTP port (no api-gateway hop).
- Merged schema migrations apply cleanly on a fresh database.
- Contract tests not required between in-process manager domains.

### Upgrade / Downgrade Strategy

- **Upgrade:** deploy monolith image with merged schema migrations, point clients
  and compose at monolith port, and retire four manager deployments and four
  control-plane databases.
- **Downgrade:** roll back to previous four-image layout via pinned image tags
  until the deprecation window ends.

## Drawbacks

- Cannot scale or patch the service provider manager independently of the other
  managers.
- No degraded service-provider-manager-only API slice when the monolith is down.
- A small change in any domain rebuilds and retests the full binary.

## Alternatives

### Alternative 1: Core and service provider manager separate (monorepo)

#### Description

Catalog, placement, and policy in one process. `service-provider-manager` in
another. One Git repo with two `cmd/` binaries and two images. HTTP contract
between core and the service provider manager.

#### Pros

- Service provider manager hotfix or scale without redeploying core.
- NATS consumer isolated from catalog APIs.
- If core fails, the service provider manager can still serve provider admin and
  service-type-instance reads.

#### Cons

- One HTTP hop on the synchronous path.
- OpenAPI and contract tests between core and the service provider manager.
- Two images to build and ship from one pipeline.

#### Status

Rejected

#### Rationale

The proposed design optimizes for one deployable and in-process handoffs. A
split runtime mainly helps when independent service provider manager rollout or
partial APIs during core outage are priorities. Those were not chosen for the
initial target.

### Alternative 2: Core and service provider manager separate (two repos)

#### Description

Same runtime as Alternative 1, but `dcm-control-plane` and
`service-provider-manager` stay in separate Git repositories with independent CI
pipelines.

#### Pros

- Service-provider-manager-only changes do not trigger a core build.
- Clearest ownership and release boundaries for the service provider manager.

#### Cons

- All cons of Alternative 1, plus cross-repo versioning and client modules
  between core and the service provider manager.

#### Status

Rejected

#### Rationale

Same trade-off as Alternative 1. Independent CI does not outweigh a single
monorepo and one synchronous path for the first merge.

### Alternative 3: Stay on four deployables

#### Description

Keep four manager services, four repos, and manager-to-manager HTTP.

#### Pros

- No migration cost.
- Failure isolation per manager image.

#### Cons

- HTTP latency and partial failure on every create.
- Continued contract and retry burden with little release independence in
  practice.

#### Status

Rejected

#### Rationale

Interim layout only. Costs of the split (hops, glue, consistency) exceed
benefits while releases stay lockstep.

### Alternative 4: Keep api-gateway (Traefik) after merge

#### Description

Keep the api-gateway stack in front of the monolith (or two backends if the
service provider manager were split).

#### Pros

- Familiar path-based routing and a place to add TLS or auth at the edge later.

#### Cons

- Extra container and config for a single backend.
- Another component to version and debug in local stacks.

#### Status

Rejected

#### Rationale

Start with one manager process exposing the API. Add edge routing when a
concrete requirement appears (TLS, multiple backends, or shared ingress
patterns).

## Infrastructure Needed

- New or renamed monorepo (e.g. `dcm-platform`) with CI producing one image.
- Merged Postgres schema and init scripts for local and test environments.
- Compose and docs updated to call the monolith port instead of api-gateway.
- Deprecation communication for four existing manager images on Quay.
