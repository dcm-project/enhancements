---
title: control-plane-architecture-analysis
authors:
  - TBD
reviewers:
  - TBD
approvers:
  - TBD
creation-date: 2026-05-07
---

# Control plane manager merge — analysis

This analysis compares the **current** control plane (four manager services) with
**three end-state options** for combining them, lists trade-offs and open questions for
team discussion, and outlines a migration plan once an option is agreed. Async messaging
and event-bus design are out of scope. This document does not pick a default architecture.

- **Option 1 — all managers in one process:** catalog, placement, policy, and SPM in one
  service and one image.
- **Option 2 — core and SPM separate (monorepo):** core in one process; SPM in another;
  one Git repo, two binaries, two images.
- **Option 3 — core and SPM separate (two repos):** same runtime split as option 2;
  core and SPM stay in separate repositories with separate CI.

See the glossary. Options 2 and 3 share the same process and API boundaries; they differ
only in Git and CI layout.

## Open questions

1. **Option 1 vs option 2 or 3?** With option 2 or 3, catalog/placement/policy can fail
   while SPM still serves a limited API set (provider registration and updates, reads of
   service-type-instances; see [*Degraded mode*](#degraded-mode-options-2-and-3-only)).
   Full catalog provision still needs core.
   With option 1, that split is not possible: if the single process is down, the whole
   control plane API is down. Product and UI should say whether the limited SPM-only
   behavior during a core outage is required, or whether full downtime is acceptable.
   Option 2 is one monorepo; option 3 is two repos (same two processes). See also
   [*Comparison for team discussion*](#comparison-for-team-discussion).
2. **Where does the public HTTP API listen after the merge?** Today Traefik (api-gateway
   stack) listens on the edge and forwards each `/api/v1alpha1/...` path to a different
   manager container. After merge there are fewer backends. Choices:

   - Keep Traefik in front of one or two services.
   - Expose HTTP from the merged server directly (Traefik optional).
   - Drop the separate api-gateway stack for now; add edge routing again when needed
     (e.g. TLS termination or multi-backend routing).
3. **Databases:** keep four separate databases vs merge schemas (see step 7 in the
   migration plan).

## Glossary

| Term | Meaning |
| --- | --- |
| **Monorepo** | One Git repository (or Go workspace) for catalog, placement, policy, and SPM. |
| **Monolith runtime** | One OS process: one listen socket, shared HTTP server, domain logic as packages. |
| **Deployable** | What operators ship (container image, Helm chart). Usually one image per process. |
| **Core in one process** | catalog-manager, placement-manager, and policy-manager in a single runtime. |
| **Option 1** | All managers in one process: monorepo + one runtime + one image. |
| **Option 2** | Core and SPM separate: monorepo + two runtimes + two images. |
| **Option 3** | Core and SPM separate: two Git repos + two runtimes + two images + separate CI. |

"Monolith" here means choosing repository, process, and deployable shape on purpose.
One repo with four processes forever only fixes tagging, not HTTP hop cost on create.

## Analysis of the current architecture

Four manager services, each in its own dcm-project repository, CI pipeline, and Quay
image. Traefik in the api-gateway stack routes public API calls to the right service.

| Manager | Main data | Responsibility |
| --- | --- | --- |
| catalog-manager | Catalog item instance | Catalog lifecycle |
| placement-manager | Service type instance | Placement and provider selection |
| policy-manager | Policy evaluation | Synchronous checks on the provision path |
| service-provider-manager | Provider-facing instance | Provider registration and CRUD; status via NATS |

**Synchronous provision path (HTTP today):** catalog-manager calls placement-manager,
then policy-manager, then service-provider-manager (URLs from environment variables).

**Data:** each manager has its own Postgres database (four in total).

**Why four services existed:** steps in the DCM request model and parallel team work.
Independent scale and release were secondary; lockstep shipping and missing load data
weakens them as reasons to stay split.

**Costs of staying split:** extra latency and failure points, generated HTTP clients and
retries, repeated platform code, cross-service consistency work, little gain when
releases already move together.

## Analysis of the three end-state options

DCM is evaluating three ways to combine the four managers: fewer deployables, aligned
release, and in-process calls on the synchronous path instead of manager-to-manager HTTP.

### Option 1: All managers in one process

| Topic | End state |
| --- | --- |
| Git | One monorepo for catalog, placement, policy, SPM |
| Runtime | One process (e.g. `dcm-server`) |
| Ship | One control-plane image |
| catalog ↔ placement ↔ policy ↔ SPM | In-process |
| Failure | One outage affects the whole control plane |

### Option 2: Core and SPM separate (monorepo)

| Topic | End state |
| --- | --- |
| Git | One monorepo, two entrypoints (`dcm-server` and SPM) |
| Runtime | Core process (catalog, placement, policy) + SPM process |
| Ship | Two images: `dcm-control-plane` and `service-provider-manager` |
| SPM APIs | Provider CRUD and registration; NATS status consumption |
| Core ↔ SPM | HTTP with a stable, versioned contract |
| Failure | SPM can keep running if core is down (limited APIs; see degraded mode) |

### Option 3: Core and SPM separate (two repos)

| Topic | End state |
| --- | --- |
| Git | Two repositories: core (`dcm-control-plane`) and `service-provider-manager` |
| Runtime | Same as option 2: core process + SPM process |
| Ship | Same as option 2: two images |
| SPM APIs | Same as option 2 |
| Core ↔ SPM | HTTP contract; cross-repo OpenAPI or shared client modules |
| CI | Independent pipeline per repo (SPM-only changes do not build core) |

Service Providers and NATS stay outside the control plane in all options.

### Side-by-side: repository, process, and deployable

| | Today | Option 1 | Option 2 | Option 3 |
| --- | --- | --- | --- | --- |
| Git repos | Four | One | One | Two |
| OS processes | Four | One | Two | Two |
| Container images | Four (+ gateway) | One | Two | Two |

A monorepo with four processes can be a migration step; teams should decide whether
that interim state is enough or runtime should merge further.

## Comparison for team discussion

| Question | Option 1 | Option 2 | Option 3 |
| --- | --- | --- | --- |
| Speed on create/delete | Fewest HTTP hops | One hop core↔SPM | Same as option 2 |
| If core crashes | Whole plane down | SPM keeps some APIs (degraded mode) | Same as option 2 |
| SPM provider APIs | Same process as catalog | In SPM process | Same as option 2 |
| Small change in SPM only | Rebuild whole binary | Rebuild SPM image (monorepo CI may still build both) | Rebuild SPM repo only |
| Small change in core only | Rebuild whole binary | Rebuild core image | Rebuild core repo only |
| Shared types / refactor across core↔SPM | In-process | Same repo, compile-time | Two repos; versioned contract |
| Release and hotfix | One binary | Two images, one repo | Two images, two repos |
| Horizontal scaling | Scale plane as a unit | Scale SPM separately if justified | Same as option 2 |

### Degraded mode (options 2 and 3 only)

When core is down and SPM is still up, operators get **provider admin** (list, create,
update, delete providers) and **reads of service-type-instances**. They do **not** get
catalog, policies, or catalog-item-instance create/delete/rehydrate. That is only useful
if the product needs provider work to continue during a core outage.

Traefik routing (api-gateway repo) allows:

| Still works (SPM routes) | Does not work (core routes) |
| --- | --- |
| Provider GET, POST, PUT, DELETE (registration and updates) | Catalog items and catalog-item-instances |
| Read service-type-instances | Catalog service-types, policies |
| | Catalog-item-instance create, delete, rehydrate |

Provider paths are routed to SPM in the api-gateway repo; catalog and policy paths
stay on the core. Full provision flows that start at catalog still need core.

**Discussion note:** options 2 and 3 only pay off for operations if that SPM-only slice
during a core outage is required. Option 3 adds simpler CI when SPM and core evolve
independently; option 2 favors atomic refactors across the HTTP boundary in one repo.
There is no production load data yet to justify a split mainly for scale.

## Analysis of release and scaling

| Topic | Option 1 | Option 2 | Option 3 |
| --- | --- | --- | --- |
| CI | One pipeline, one tag | One repo; build two artifacts | Two pipelines, two repos |
| Rollout | Single deploy | Core and SPM on different cadence | Same as option 2 |
| Coupling | Compile-time, all domains | Compile-time in monorepo; HTTP at boundary | OpenAPI/contract at core↔SPM |

## Analysis of impact on the synchronous path

| Area | Today | Option 1 | Option 2 | Option 3 |
| --- | --- | --- | --- | --- |
| catalog, placement, policy | HTTP | In-process | In-process | In-process |
| catalog to SPM | HTTP (via placement) | In-process | HTTP at core boundary | Same as option 2 |
| Gateway backends | Four services | One | Two | Two |
| Postgres per domain | Four separate databases | Four DBs in one process | Four DBs (core + SPM processes) | Same as option 2 |
| OPA | HTTP from policy | Unchanged | Unchanged | Unchanged |

Provider NATS flows and external Service Providers are unchanged.

## Proposed migration plan

Pick the end-state option in **step 1** before merging runtime code. Steps 2–7 apply
to all options; steps 4 and 5 branch on whether SPM shares a process with core (option 1
vs options 2 and 3).

### Step 1 — Team decision on end-state option

**Goal:** Record agreement on option 1, 2, or 3 (see comparison and open question 1).

**Actions:**

- Run review with product, UI, and manager owners.
- If choosing a split runtime, decide option 2 vs 3 (monorepo vs two repos).
- Close or assign remaining open questions.

**Done when:** The agreed option is written down; open questions above are closed or
explicitly deferred.

### Step 2 — Unify source layout

**Goal:** Stop ad-hoc cross-repo pins for internal calls.

**Actions:**

- **Option 1 or 2:** one repository (e.g. `dcm-platform`) or Go workspace; move domains
  under `internal/catalog`, `internal/placement`, `internal/policy`,
  `internal/serviceprovider` (names illustrative).
- **Option 3:** merge catalog, placement, policy into `dcm-control-plane`; keep
  `service-provider-manager` as its own repo; publish versioned OpenAPI or client
  modules for core↔SPM.
- Unify lint and test within each repo.

**Done when:** Layout matches the chosen option; core↔SPM boundary is explicit for 2 and 3.

### Step 3 — Introduce domain interfaces

**Goal:** Call sites depend on interfaces, not HTTP clients, so runtime can switch to
in-process calls without rewriting business logic.

**Actions:**

- Define interfaces for catalog → placement, placement → policy, placement → SPM.
- Keep HTTP implementations behind those interfaces during cutover.
- Add tests that mock the interface.

**Done when:** Domain services take interfaces in constructors; HTTP is one implementation.

### Step 4 — Merge into one or two processes

**Goal:** Run the synchronous path in-process per the chosen option.

**Actions:**

- Add `cmd/dcm-server` (name illustrative) for core domains.
- **Option 1:** register SPM routes and NATS consumer in that binary.
- **Options 2 and 3:** register only catalog, placement, policy in core; keep SPM in
  `cmd/service-provider-manager` with HTTP between core and SPM.
- Remove env URLs used only for internal manager-to-manager calls on the collapsed path.

**Done when:** Create/delete/rehydrate do not use HTTP between merged core domains;
health checks pass.

### Step 5 — Update the API gateway

**Goal:** External clients hit the new backends.

**Actions:**

- Point catalog, placement, and policy routes to the core server (or single server for
  option 1).
- **Option 1:** route SPM paths to the same backend.
- **Options 2 and 3:** keep SPM routes on the SPM service.
- Retire routes to old manager containers when cutover is complete.

**Done when:** api-gateway compose (or production equivalent) passes e2e smoke tests.

### Step 6 — Align CI, images, and rollout

**Goal:** Operators ship the new deployables.

**Actions:**

- **Option 1:** one Containerfile, one Quay image.
- **Option 2:** two images from one repo pipeline.
- **Option 3:** two images from two repo pipelines.
- Deprecate four manager images on a published timeline.

**Done when:** Demo and staging use the new layout; old manager images are deprecated.

### Step 7 — Databases and hardening (optional, later)

**Goal:** Stabilize databases and operations after the runtime merge.

**Actions:**

- Start with four separate databases unchanged inside one or two processes.
- Plan schema merge only if there is a clear benefit.
- Contract tests for core↔SPM for options 2 and 3.
- Set CODEOWNERS per domain package (per repo for option 3).

**Done when:** Runbooks and observability match the chosen option; database strategy closed.

## Illustrative repository structures

**Option 1:** one repo, `cmd/dcm-server`, domains under `internal/`, one image.

**Option 2:** one repo, `cmd/dcm-server` and `cmd/service-provider-manager`, two images.

**Option 3:** `dcm-control-plane/` (catalog, placement, policy) and
`service-provider-manager/` as separate repos, two images, two CI pipelines.
