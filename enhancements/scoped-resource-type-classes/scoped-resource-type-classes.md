---
title: scoped-resource-type-classes
authors:
  - "@croadfeldt"
reviewers:
  - TBD
creation-date: 2026-07-22
status: provisional
---

# Scoped resource-type Class hierarchy (Base / Type / Provider Class)

> **Note (please read first):** this was written under time pressure to get the *gist* in front of the team
> quickly. There may be small inconsistencies in the examples/wording; the intent and the mechanisms are what
> matter for this round. Full, self-consistent detail lives in the upstream ADRs linked under *Design Details*.

## Open Questions
- Rollout order beyond Compute, and the exact meta-schema shape for `extends` / effective-schema flattening.
- Instantiability of a bare Base Class (the generic-instance / "give me compute, VM-or-metal" request) — proposed **yes**; UX TBD.
- Federation resolution mechanics (its own follow-on; demand-driven, `peer` root first).

## Summary
Resource types are modeled as **layered Classes** — **Base Class** (Category, `Compute`) → **Type Class**
(`Compute.VM`) → **Provider Class** (`Compute.VM.OCPVirt`) — each composed of scoped `SharedDataElement`s and
extending the one above under a Liskov invariant (add/refine, never contradict). Portability is read off scope,
addressing is a URL-native coordinate, and the model unifies three constructs we had separately (base fields,
shared vocabularies, provider extensions) into one.

## Motivation
Types with overlapping concepts (`Compute.VM` and `Compute.BareMetalHost` both carry cpu/memory/OS/storage/
network) define them **independently** → cross-type drift; and selectable values keep leaking as free strings or
inline re-expressions of adopted standards. One meta-model settles both.

### Goals
- Kill cross-type drift structurally (shared elements are *shared*, not duplicated).
- A single portability gradient across **both** the type axis and the provider axis.
- One addressing/query/filter mechanism; one reference model; enforce the reference discipline (PVD).

### Non-Goals
- A big-bang re-type of the registry (rollout is demand-driven, proven on Compute first).
- Implementation portability of the DCM engine (wire-compat only, per ADR-008).

## Proposal
Key decisions (full text in the ADRs):
1. **Base/Type/Provider Class**, `SharedDataElement` as the unit; `extends` + Liskov; **subsumes**
   `provider_extensions` + the Vendor.Type fork.
2. **Two-axis portability, never zero** — a Provider Class is a provider *set*; portability narrows progressively
   and re-derives when requirements change (re-porting is reversible).
3. **Instantiable at every level** + **policy-fill** completes type/provider-specific blanks.
4. **URL-native addressing coordinate** — `https://<authority>/<entity-path>?<filters>#<field>` (dotted is the
   compact identity alias); **dual anchor** (immutable pin + named head); **`covers`/`skip`** layers; **one filter
   mechanism** (the coordinate predicate; a k8s label selector is a `.labels` predicate, not a second mechanism).
5. **Three relationship axes** — is-a (Class), has-a (Composite `catalog-item`), references-context
   (`data_reference` → `reference_data` layer).
6. **PVD** (portable-value discipline): a selectable value is a reference, codelist, or requirement — never a free
   string; adopted-standard/typed shapes are bound by reference, never restated inline.

### The UDLM vs DCM split (the important part for repo ownership)
Per the ADR-008 peer test: **UDLM owns the model, grammar, classification, and data** (the portable substrate);
**DCM owns the engine** — placement, policy-fill, assembly, resolution, promotion, matching, migration,
governance. `Compute.VM.OCPVirt` and the coordinate are UDLM; every *decision* about them is DCM. Full split table
in ADR-038. The DCM engine half maps almost entirely onto **existing** DCM engines (DCM ADR-025).

### Risks and Mitigations
- **Reshapes settled ground** (amends UDLM ADR-027, the `Category.Type` naming, subsumes PRV-010) → introduce as a
  reviewed proposal (this doc), roll out demand-driven, prove on Compute.
- **Notation overload of the dot** → mitigated by URL-native addressing + case discipline (identity dotted,
  address/selector URL).

## Design Details
Authoritative, self-consistent detail (Accepted on the croadfeldt upstream; this proposal seeks downstream
alignment):
- **UDLM** — ADR-038 (paradigm) + ADR-035/036/037 (reference discipline + PVD) + ADR-039 (vocab ingest) +
  ADR-040 (federation stub). PR: **croadfeldt/udlm#180**.
- **DCM** — ADR-025 (realizing the paradigm; the engine mapping). PR: **croadfeldt/dcm#59**.
- Worked artifacts (in the udlm PR): Compute + Identity conversion renders; request-pipeline-layers.

## Alternatives
- **Independent per-type definitions + `provider_extensions` + Vendor.Type fork** (status quo) — rejected: three
  mechanisms, structural drift, opaque blobs, no portability gradient.
- **Org-specific class forks** (`Compute.ORG.VM`) — rejected: fragments portability; org standards are Policy
  (Template/Profile/constraint-profile) *over* the shared classes, not a fork of them.

## Implementation History
- 2026-07-22 — provisional; upstream ADRs Accepted on croadfeldt; opened for downstream review.
