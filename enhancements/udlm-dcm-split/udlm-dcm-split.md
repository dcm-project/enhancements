---
title: udlm-dcm-split
authors:
  - "@croadfeldt"
reviewers:
  - TBD
approvers:
  - TBD
creation-date: 2026-06-16
see-also:
  - "/enhancements/rehydration-flow/rehydration-flow.md"
replaces: []
superseded-by: []
---

# Separate UDLM (the wire-compatible substrate) from DCM (a realization)

## Open Questions

1. Governance and maintainer model for `udlm` (CNCF-readiness wants
   maintainers from more than one organization).
2. The exact conformance surface for v0 — which contracts are gating vs
   advisory.
3. Whether the split manifest is published in `dcm` as a permanent
   contributor artifact or kept internal.

## Summary

`dcm` today mixes two things that change for different reasons and at
different rates: a universal data-lifecycle **substrate** (entity types, the
four-state lifecycle, the provider / policy / event / data-store contracts,
provenance, identity, conformance) and **one operational realization** of it
(the convergence engine, control plane, runtime, orchestration, integrations).

This enhancement makes the boundary explicit by extracting the substrate into
its own repository — **UDLM** (Universal Data Lifecycle Model) — leaving `dcm`
as a realization that conforms to UDLM at a pinned version. The split is
conceptual before it is mechanical: this document asks for agreement on the
boundary and the compatibility model first. No files move until that lands.

`dcm-project/udlm` already exists, so this is about aligning on what it is
for, not whether to create it. (Authored with the Red Hat FlightPath team.)

## Motivation

While the substrate and a realization live in one repository:

- The substrate cannot be referenced, versioned, or conformance-tested
  independently. "What must any system honor to interoperate?" has no clean
  artifact to point at.
- A peer realization has nothing to build against. Federation between two
  platforms degrades into "architecturally similar systems requiring
  adapters" instead of literal interop.
- The spec cannot evolve at its own rate. Substrate invariants and
  implementation choices are versioned together.
- Conformance has no home. There is no place to say "this system is UDLM vX
  compatible," and no suite to prove it.

This matters now because multiple organizations are beginning to co-engineer,
several building their own limited-scope realizations. Without a
wire-compatible substrate to converge on, that effort fragments into
incompatible forks. The substrate is the common ground that makes one open
platform possible.

### Goals

- A standalone, versioned UDLM substrate any realization can conform to.
- A clear, testable boundary rule for classifying every concept as substrate
  or realization.
- Wire-level interop between conformant peers (federation = literal interop).
- DCM remains the reference realization, referencing UDLM at a pinned version.
- DAV continues to validate — now able to ask two questions instead of one:
  does the substrate support this use case, and does DCM realize it correctly?

### Non-Goals

- Formalizing a higher-order universal model above UDLM. Deferred until a real
  second realization creates the pressure to identify what is genuinely shared.
- Enforcing implementation portability (shared code). UDLM enforces wire
  compatibility, not internal mechanics.
- Re-litigating DCM's internal design.

## Proposal

### The boundary rule

For every file or section, the test is:

> "Could a peer of DCM, built independently, choose to do this differently and
> still be a valid realization of the same data?"
>
> - Yes -> it is an implementation choice -> DCM.
> - No, it would break interop or invalidate the data -> it is a substrate
>   invariant -> UDLM.

UDLM owns entity types; the four states (intent -> requested -> realized ->
discovered), their transitions and invariants; the provider / policy /
event-payload / data-store contracts; provenance, lineage, identity; and
reference taxonomies. The state vocabulary lives here because peers must share
it to interoperate.

DCM owns the convergence engine (the intent-to-realized loop), policy
evaluation at each transition, provider invocation / retry / dependency
orchestration, control-plane components and service boundaries, drift /
recovery / expiration, deployment topology, runtime concerns, and integrations
with specific external systems.

### Compatibility model — the load-bearing decision

UDLM enforces wire-level compatibility at the data / event / contract
boundary; it does not enforce implementation portability.

- Any system conformant to UDLM major version X produces data that any other
  system conformant to the same major version can read, interpret, and
  exchange (version-applicability rules withstanding).
- Federation between peers is literal interop, not "architecturally similar
  systems requiring adapters."
- A peer's storage, internal APIs, control-plane components, and runtime
  mechanics are not constrained by UDLM — those are DCM-layer choices.

This is the Kubernetes precedent: the Kubernetes API plus CRDs are
wire-compatible across distributions; controllers are not portable. UDLM is
the API-plus-CRD layer; DCM is one controller/distribution.

Consequences for UDLM authoring (formalized in `CONFORMANCE.md`):

1. Wire formats are normative (identifiers, timestamps, event payloads, error
   envelopes).
2. Error / code / state vocabularies that cross interop boundaries are closed.
3. UDLM defines a schema-sharing mechanism so peers can exchange schemas for
   custom types and resolve each other's data with context.
4. Versioning is first-class — every wire contract carries a version and a
   compatibility window.

### What moves

From the file-level classification:

- 22 pure-UDLM files move to `udlm` as-is.
- 18 pure-DCM files stay in `dcm`.
- 21 "both" files are split per-section between the two (per-section, not
  per-paragraph — cleaner and reviewable).
- Plus 7 net-new substrate contracts authored during the split:
  identifier-scheme, time-and-clock, error-model, retry-semantics,
  rate-limit-and-backpressure, schema-sharing, and CONFORMANCE.

Net substrate is roughly 55 specification documents.

### Repo mechanics

- `dcm-project/udlm` (exists, empty) holds the substrate; `main` carries
  `LICENSE` (Apache-2.0), `CONFORMANCE.md`, and the contract families.
- `dcm-project/dcm` declares the UDLM version it conforms to and references
  substrate contracts by link — it never re-defines them.
- DAV (the reference implementation, built to validate the DCM architecture
  and which represents its data in UDLM) verifies both: does UDLM support this
  use case, and does DCM realize it? DAV is the conformance dogfood.
- The two repos never have to land in one PR: UDLM PRs bump the substrate;
  DCM PRs reference a fixed UDLM version.

### The validating analogy

A stress-test for classifications — when unsure, ask: direction-or-requirement
(UDLM) vs infrastructure-or-enforcement (DCM)?

| Concept | Layer |
|---|---|
| Directions — where you can go, what destinations exist | UDLM |
| Goals for the rules of the road (safety, predictability) | UDLM |
| Rules-of-the-road requirements (what cars and drivers satisfy) | UDLM |
| Driver requirements (license classes, competencies) | UDLM |
| Published rules manual (cited substrate / standards) | UDLM |
| The road itself (control-plane components, persistence) | DCM |
| Turn signals (the physical signaling infrastructure) | DCM |
| Cars actually driving (convergence engine, intent->realized) | DCM |
| Enforcement (specific matrix evaluator) | DCM |
| DMV licensing process (profile thresholds, approval, GitOps) | DCM |

## Rollout

Concept-first. On agreement here:

1. Seed `dcm-project/udlm` — the irreducible interop core (conformance and
   versioning, wire contracts, event catalog, retry/rate-limit) first, then
   the remaining families.
2. Land DCM realization PRs that reference UDLM at the seeded version, each
   opening with a link to the UDLM contracts it implements.
3. Low-risk vocabulary / enum / corpus fixes can land in `dcm` in parallel
   (independent of the split).

Every PR is content-based, single-concern, and at most ~3,000 lines —
logical boundaries chosen first, size forcing only further compartmentalization
— dependency-ordered, each leading with its decision. (Two artifacts built
expressly for AI consumption ship as-is, labeled, exempt from the human-review
line ceiling.)

## Risks and Mitigations

- Two-repo overhead -> version pinning plus DAV-as-gate keeps them coherent;
  no PR ever spans both repos.
- Boundary disputes -> the boundary rule and the analogy are the tie-breaker;
  "both" files are split per-section and recorded in the manifest.
- Review volume -> single-concern PRs mapped to domain reviewers; the
  conformance core can land and pause (a peer can interoperate with just the
  wire layer).
- Premature abstraction -> the higher-order universal model is explicitly
  deferred until a real second realization creates pressure.

## Alternatives

- Keep one repo. Rejected: the substrate cannot be referenced, versioned, or
  conformance-tested independently, and a peer realization has nothing clean to
  build against.
- Per-paragraph split of the 21 "both" files. Rejected for per-section splits —
  cleaner and reviewable.
- Formalize the higher-order universal model now. Deferred (cost asymmetry; no
  second-realization pressure yet).
