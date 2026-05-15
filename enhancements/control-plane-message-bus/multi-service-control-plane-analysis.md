---
title: multi-service-control-plane-analysis
authors:
  - TBD
reviewers:
  - TBD
approvers:
  - TBD
creation-date: 2026-05-07
---

# Microservice-style decomposition versus consolidated runtime

Document goal: give technical pros and cons for keeping the control plane as
many deployable managers versus consolidating toward fewer processes and a
modular monolith-style layout when team scale and domain cohesion support it.

## Baseline: today’s decomposed control plane

- Multiple manager deployables plus gateway peers instead of one fused
  control-plane binary per concern.
- Synchronous HTTP carries most command traffic and manager-to-manager chains.
- Persistence is usually split per manager where the model encodes separate
  owner domains.
- Messaging appears on selected flows not on every internal manager edge.

## Pros of the current decomposed layout

Independent release and rollback when teams truly own separate lifecycles.

Fault and load can stay local to a deployable when the split matches real
failure domains and scaling units.

Different subsystems can carry different SLO or capacity policies without gating
the entire plane on the slowest neighbor.

The split can mirror how teams own parts of the plane so catalog, placement,
policy, SPM, gateway, and peers can follow parallel roadmaps without one group
blocking every release.

Keeps an escape hatch before large in-process merges when future ownership or
load growth eventually forces consolidation.

## Cons of the current decomposed layout

Network hop tax on latency, partial failure, version skew, tracing noise, and
strict API contracts.

Deep synchronous REST chains need disciplined retries, idempotency keys, and
contract versioning.

Platform concerns repeat at every boundary unless central tooling removes
ceremony.

Cross-manager state changes need explicit patterns such as transactional outbox,
saga orchestration, or compensation instead of implicit shared transactions.

Payoff may miss expectations when teams rarely ship independently, async fan-out
for observers is thin, and HTTP chatter dominates without isolation benefits.
That matches the concern "we do not really leverage microservices here so why
pay the tax".

## Pros of consolidating toward a modular monolith or fewer deployables

Small team scale benefits from fewer binaries, shared modules, and mostly
in-process calls once domain packing is intentional.

Refactors stay inside one repository graph so type systems and tests flag broken
assumptions earlier than cross-repo drift.

Operations staff page fewer moving targets for logging, deployment, and
dashboards.

You can still extract services later along module seams when staffing and
telemetry prove the split.

Synchronized critical paths shrink when former HTTP neighbors become local
calls.

### Typical repository and release patterns when consolidated

In practice consolidated control planes tend toward fewer Git repositories.
Internal boundaries are folders or modules in one repo (a monorepo) or two to
three repos at most plus shared libs. Builds pull the same commit into one CI
pipeline that produces either a single runnable artifact per environment or a
fixed set of binaries that always ship together. Cross-repo versioning drifts out
because everything tags off one history.

Release steps usually move together: one staged rollout or one image tag binds
catalog, placement, policy, SPM, gateway-adjacent code, and whichever modules were
formerly separate managers. Rolling back rewinds that whole artifact so hotfixes
either roll forward or revert the unified tag. Partial channel deploys need feature
flags or internal toggles instead of shipping one manager without its neighbors.
That trades independent per-service delivery for fewer moving parts in the pipeline.

## Cons of consolidating

Widespread shared databases collapse logical boundaries. Schema coupling,
migration risk, lock contention, and unclear table ownership follow until data
is sharded again.

Internal async decoupling can vanish unless you engineer explicit emitters and
subscriptions. A workshop-style worry about "no async communication" is real if
consolidation removes messaging paths without replacement.

Blast radius grows when one fat binary hosts catalog, placement, policy, and
gateway-adjacent code without circuit breaking or resource isolation.

Vertical scaling limits treat the whole bundle as one autoscaler target which
can waste capacity compared to targeted scaling per former service.

Many teams contending in one repository recreates political bottlenecks similar
to immature microservice meshes.

If nominally separate deployables remain tightly synchronous on one datastore
you drift toward a distributed monolith: network latency persists without
autonomous lifecycles.

When independent velocity or clear bounded contexts never materialize, shrinking
deployables or simplifying synchronous graphs deserves measurement ahead of
deeper distributed tooling.

## Illustrative monorepo layout (hypothetical)

The tree below maps today’s sibling repositories (such as api-gateway,
catalog-manager, placement-manager, policy-manager, service-provider-manager on
the main DCM source tree) into one Go-style monorepo. Treat the tree as an
informal sketch for debating layout and boundaries, not as an approved design.
Package names, migration strategy, and whether persistence stays per-domain or
merges would be decided separately.

```
dcm-control-plane/
  cmd/
    dcm-server/
      main.go                 # process entry, config load, server start
  internal/
    gateway/                  # former api-gateway: routing, authn edge, delegation
    catalog/                  # former catalog-manager domain and HTTP adapters
    placement/                # former placement-manager
    policy/                   # former policy-manager
    serviceprovider/          # former service-provider-manager
    messaging/                # optional: bus clients, consumers, publishers
    integration/              # optional: cross-domain orchestration helpers
    platform/                 # shared: logging, tracing, metrics, HTTP middleware
      config/
      persistence/            # drivers, transaction helpers (migrations live with domain or here)
      clients/                # generated or hand HTTP when still calling externals
  api/
    openapi/                  # bundled or split specs for external surface
  deploy/
    Containerfile             # single image build context
    kubernetes/               # one Deployment manifest or Kustomize base
```

Each `internal/<domain>/` would own domain models, repositories, handlers, and
domain-specific DB migrations if you keep logical database separation inside one
server. Alternatively migrations could sit under `internal/<domain>/store/` with
connection strings still pointing at separate databases until a shared database
decision is made.

The release pipeline builds `cmd/dcm-server` into one container image. Rollouts
replace that image everywhere the control plane runs. Feature work still lands
through normal merge requests but every change shares the same binary version
unless you introduce build tags or split binaries again.

## Decision cues

Favor consolidating toward fewer deployables or a modular monolith when most of these apply:

- Roadmaps stay narrow relative to staffing.
- Coordinated state changes rarely need to lock or commit across old domain seams.
- Most pain traces to synchronous HTTP depth or weak contracts rather than mismatched splits.
- The organization can tolerate shared migration windows for schema or datastore moves.
- The team writes down how it would split back out later if ownership or scale changes.

Favor keeping the current decomposition when most of these apply:

- Some deployables genuinely need isolation for failure or workload reasons.
- Release cadences or ownership already diverge in practice across managers.
- Many subscribers consume the same lifecycle signals and benefit from clearer async contracts.
- Measurements tie distributed boundaries to observable payoff versus hop cost.
