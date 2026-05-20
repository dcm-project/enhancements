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
**two end-state options** for combining them (one or two deployables), lists
trade-offs and open questions for team discussion, and outlines a migration plan once
an option is agreed. Async messaging and event-bus design are out of scope. This
document does not pick a default architecture.

**Option 1 — all managers in one process:** catalog, placement, policy, and SPM in a
single service. **Option 2 — core in one process, SPM separate:** catalog, placement,
and policy together; SPM stays its own service. See the glossary.

## Open questions

1. **Option 1 vs option 2?** See
   *Comparison for team discussion* and *Degraded mode* below. Input needed from
   product and UI on whether partial reads when core is down matter.
2. **Where does the public HTTP API listen after the merge?** Today Traefik (api-gateway
   stack) listens on the edge and forwards each `/api/v1alpha1/...` path to a different
   manager container. After merge there are fewer backends. Either keep
   Traefik in front of one or two services and keep path-based routing there,
   or **expose HTTP from the merged server** so that process owns the API surface and
   Traefik is optional.
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
| **Option 2** | Core in one process, SPM separate: monorepo + two runtimes + two images. |

"Monolith" here means choosing repository, process, and deployable shape on purpose.
One repo with four processes forever only fixes tagging, not HTTP hop cost on create.

## Analysis of the current architecture

Four manager services, each in its own dcm-project repository, CI pipeline, and Quay
image. Traefik in the api-gateway stack routes public API calls to the right service.

| Manager | Main data | Responsibility |
| --- | --- | --- |
| catalog-manager | Catalog item instance | Catalog lifecycle |
| placement-manager | Service type instance | Placement and service-type mapping |
| policy-manager | Policy evaluation | Synchronous checks on the provision path |
| service-provider-manager | Provider-facing instance | SP orchestration; status via NATS |

**Synchronous provision path (HTTP today):** catalog-manager calls placement-manager,
then policy-manager, then service-provider-manager (URLs from environment variables).

**Data:** each manager has its own Postgres database (four in total).

**Why four services existed:** steps in the DCM request model and parallel team work.
Independent scale and release were secondary; lockstep shipping and missing load data
weakens them as reasons to stay split.

**Costs of staying split:** extra latency and failure points, generated HTTP clients and
retries, repeated platform code, cross-service consistency work, little gain when
releases already move together.

## Analysis of the two end-state options

DCM is evaluating two ways to combine the four managers: fewer deployables, aligned
release, and in-process calls on the synchronous path instead of manager-to-manager HTTP.

### Option 1: All managers in one process

| Topic | End state |
| --- | --- |
| Git | One monorepo for catalog, placement, policy, SPM |
| Runtime | One process (e.g. `dcm-server`) |
| Ship | One control-plane image |
| catalog ↔ placement ↔ policy ↔ SPM | In-process |
| Failure | One outage affects the whole control plane |

### Option 2: Core in one process, SPM separate

| Topic | End state |
| --- | --- |
| Git | One monorepo, two entrypoints (`dcm-server` and SPM) |
| Runtime | Core process (catalog, placement, policy) + SPM process |
| Ship | Two images: `dcm-control-plane` and `service-provider-manager` |
| Core ↔ SPM | HTTP with a stable, versioned contract |
| Failure | SPM can keep running if core is down (limited APIs only) |

Service Providers and NATS stay outside the control plane in both options.

### Side-by-side: repository, process, and deployable

| | Today | Option 1 (all managers in one process) | Option 2 (core in one process, SPM separate) |
| --- | --- | --- | --- |
| Git repos | Four | One | One |
| OS processes | Four | One | Two |
| Container images | Four (+ gateway) | One | Two |

A monorepo with four processes can be a migration step; teams should decide whether
that interim state is enough or runtime should merge further.

## Comparison for team discussion

| Question | Option 1 (all managers in one process) | Option 2 (core in one process, SPM separate) |
| --- | --- | --- |
| Speed on create/delete | Fewest HTTP hops | One hop remains between core and SPM |
| If core crashes | Whole plane down | SPM may still serve some reads |
| NATS status handling | Same process as catalog APIs | Isolated in SPM |
| Release and hotfix | One binary to rebuild | Core and SPM can ship independently |
| Horizontal scaling | Scale the plane as a unit | Scale SPM separately if metrics justify it |

### Degraded mode (option 2 only)

If the core process is down and SPM is up, Traefik routing (api-gateway repo) allows:

| Still works | Does not work |
| --- | --- |
| List/get providers | Catalog items, instances, service-types |
| List/get service-type-instances | Policies |
| | Create, delete, rehydrate (full flow) |

**Discussion note:** open question 1 hinges on whether the partial API set above is
worth a second process and deployable. There is no production load data yet to justify
option 2 for scaling alone.

## Analysis of release and scaling

| Topic | Option 1 (all managers in one process) | Option 2 (core in one process, SPM separate) |
| --- | --- | --- |
| CI | One pipeline, one version tag | One repo; build two artifacts |
| Rollout | Single deploy | Core and SPM on different cadence possible |
| Coupling | Compile-time between domains | OpenAPI contract at core↔SPM |

## Analysis of impact on the synchronous path

| Area | Today | Option 1 (all managers in one process) | Option 2 (core in one process, SPM separate) |
| --- | --- | --- | --- |
| catalog, placement, policy | HTTP | In-process | In-process |
| catalog to SPM | HTTP (via placement) | In-process | HTTP at core boundary |
| Gateway backends | Four services | One | Two |
| Postgres per domain | Four separate databases | Can stay four separate DBs in one process | Can stay four separate DBs in core process |
| OPA | HTTP from policy | Unchanged | Unchanged |

Provider NATS flows and external Service Providers are unchanged.

## Proposed migration plan

Pick the end-state option in **step 1** before merging runtime code. Steps 2–7 apply
to both; steps 4 and 5 branch on whether SPM runs in the same process as core.

### Step 1 — Team decision on end-state option

**Goal:** Record the outcome of discussion on open question 1 (and related trade-offs
in the comparison section).

**Actions:**

- Run review with product, UI, and manager owners using the comparison and degraded
  mode sections.
- Close or assign remaining open questions.

**Done when:** The agreed option is written down (either architecture); open questions
above are closed or explicitly deferred.

### Step 2 — Create the monorepo

**Goal:** One tree for all manager code; stop cross-repo version pins for internal calls.

**Actions:**

- Add a single repository (e.g. `dcm-platform`) or Go workspace.
- Move each manager into `internal/catalog`, `internal/placement`, `internal/policy`,
  `internal/serviceprovider` (names illustrative).
- Keep existing `main` packages temporarily if that reduces risk.
- Unify lint, test, and module boundaries.

**Done when:** One CI job builds all domains; imports do not pull manager code across
four separate repos.

### Step 3 — Introduce domain interfaces

**Goal:** Call sites depend on interfaces, not HTTP clients, so runtime can switch to
in-process calls without rewriting business logic.

**Actions:**

- Define interfaces for catalog → placement, placement → policy, placement → SPM
  (and any other cross-domain calls).
- Keep HTTP implementations behind those interfaces during cutover.
- Add tests that mock the interface.

**Done when:** Domain services take interfaces in constructors; HTTP is one implementation.

### Step 4 — Merge into one or two processes

**Goal:** Run the synchronous path in-process per the chosen option.

**Actions:**

- Add `cmd/dcm-server` (name illustrative) that wires stores, services, and handlers.
- **Option 1:** register SPM routes and NATS consumer in that binary.
- **Option 2:** register only catalog, placement, policy;
  keep `cmd/service-provider-manager` and HTTP between core and SPM.
- Remove env URLs used only for internal manager-to-manager calls on the merged path.
- Run subsystem and integration tests against the new binary.

**Done when:** Create/delete/rehydrate do not use HTTP between merged domains; health
checks pass on the new process setup.

### Step 5 — Update the API gateway

**Goal:** External clients hit the new backends.

**Actions:**

- Point Traefik routes for catalog, placement, and policy to the core server (or the
  single server when all managers share one process).
- **Option 1:** route SPM public paths to that same backend.
- **Option 2:** keep SPM routes on the SPM service.
- Retire routes to old manager containers when cutover is complete.

**Done when:** api-gateway compose (or production equivalent) runs the new service list
and e2e smoke tests pass.

### Step 6 — Align CI, images, and rollout

**Goal:** Operators ship the new deployables.

**Actions:**

- **Option 1:** one Containerfile, one Quay image, one Helm chart (or equivalent).
- **Option 2:** two images from one pipeline; document
  independent rollout if used.
- Deprecate four manager images on a published timeline.
- Update version and release notes process.

**Done when:** Demo and staging deploy only the new images; old manager images are
documented as deprecated.

### Step 7 — Databases and hardening (optional, later)

**Goal:** Stabilize databases and operations after the runtime merge.

**Actions:**

- Start with four separate databases unchanged inside one or two processes.
- Plan schema merge only if there is a clear benefit; treat as a separate project.
- Add tracing labels per domain inside one process; contract tests for core↔SPM if split.
- Set CODEOWNERS per `internal/` domain package.

**Done when:** Runbooks and observability match the chosen option; database strategy
closed.

## Illustrative repository structures

**Option 1:** one repo, `cmd/dcm-server`, domains under `internal/`, one image.

**Option 2:** same repo, `cmd/dcm-server` and
`cmd/service-provider-manager`, two images, one pipeline.
