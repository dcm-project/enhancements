---
title: catalog-item-schema
authors:
  - "@gciavarrini"
reviewers:
  - "@omachace"
  - "@jubah"
  - "@yblum"
  - "@flocati"
approvers:
  - TBD
creation-date: 2025-12-05
see-also:
  - "/enhancements/service-type-definitions/service-type-definition.md"
replaces:
  - TBD
superseded-by:
  - TBD
---

# Catalog Item Schema

## Summary

This ADR defines the structure for Catalog Items in the DCM Service Catalog.

## Motivation

Catalog Items wrap service specifications with validation rules and defaults,
enabling administrators to create curated offerings. The design is both
provider-agnostic and service type-agnostic — Catalog Items work with any
service type defined in
[Service Type Definition](https://raw.githubusercontent.com/dcm-project/enhancements/37ce03b1fec251aafd346edf9de8f6ebc7e2e5a1/enhancements/sp-registration-flow/sp-registration-flow.md)

### Goals

- Define the structure for Catalog Items
- Maintain independence between service types while applying consistent design
  patterns
- Add validation rule
- Enable administrators to create curated offerings for users
- Design catalog schemas as service type and provider-agnostic and service
  type-agnostic specifications that Service Providers can translate to their
  native platform formats

### Non-Goals

- Defining the service schemas themselves (see
  [ADR - ServiceType](?tab=t.egv2hwot8psy) )

## Proposal

The catalog schema acts as a _translation layer_ between what the DCM users want
(abstract service specifications) and what providers deliver (platform-specific
implementations).

### Implementation Details/Notes/Constraints

#### Catalog Item

A catalog item wraps a service specification with validation rules and defaults.
Administrators create catalog offerings like "_Small Dev VM_" or "_Production
Database_" that users can request without knowing the underlying details.

```yaml
apiVersion: v1alpha1
kind: CatalogItem
metadata:
  name: production-postgres
spec:
  serviceType: database
  schemaVersion: v1alpha1
  fields:
    - path: "engine"
      default: "postgresql"
    - path: "version"
      editable: true
      default: "15"
      validationSchema: { enum: ["14", "15", "16"] }
    - path: "resources.cpu"
      editable: true
      default: 4
      validationSchema: { minimum: 2, maximum: 16 }
    - path: "resources.memory"
      editable: true
      default: "16GB"
```

See
[catalog-item-schema.yaml](https://github.com/gciavarrini/service-provider-api/blob/add-catalog-item/api/v1alpha1/catalog-item-schema.yaml)
for complete schema definition.

#### CatalogItem components

| Field         | Required | Type   | Description                                                                                                   |
| :------------ | :------- | :----- | :------------------------------------------------------------------------------------------------------------ |
| apiVersion    | Yes      | string | CatalogItem schema version (e.g., _v1alpha1_). Enables CatalogItem schema evolution                           |
| serviceType   | Yes      | string | Type of service (e.g., _vm, container, database, cluster_)                                                    |
| schemaVersion | Yes      | string | Version of the serviceType schema (e.g., _v1alpha1_). Used to determine which ServiceType payload to generate |
| fields        | Yes      | array  | List of field configurations (see below)                                                                      |

Each field in the _fields_ array has:

| Field            | Required | Type    | Default | Description                                                    |
| :--------------- | :------- | :------ | :------ | :------------------------------------------------------------- |
| path             | Yes      | string  | -       | Field path in service schema (e.g., _vcpu.count_)              |
| displayName      | No       | string  | -       | Human-readable label for UI. If not set, derived from the path |
| editable         | No       | boolean | false   | Whether users can modify this field                            |
| default          | No       | any     | -       | Default value for this field                                   |
| validationSchema | No       | object  | -       | JSON Schema rules (only applies if editable)                   |

Fields not listed are neither editable nor have default values. The catalog item
owner must ensure all mandatory fields are listed.

_Example "Development VM" CatalogItem - only CPU and memory required_

```yaml
apiVersion: v1alpha1
kind: CatalogItem
metadata:
  name: dev-vm
  displayName: "Development VM"
spec:
  serviceType: vm
  schemaVersion: v1alpha1
  fields:
    - path: "vcpu.count"
      displayName: "CPU Count"
      editable: true
      default: 2
      validationSchema: { minimum: 1, maximum: 4 }
    - path: "memory.size"
      displayName: "Memory"
      editable: true
      default: "4GB"
      validationSchema: { minimum: 2, maximum: 8 }
    - path: "guestOS.type"
      displayName: "Operating System"
      editable: false
      default: "rhel-9"
```

Multiple CatalogItems can reference the same ServiceType with different
constraints: a `Production VM` item could require `vcpu.count` between 4-16
instead of 1-4, while sharing the same underlying `vm` ServiceType definition.

#### Versioning

CatalogItems use two version fields:

- **`apiVersion`**: Versions the CatalogItem schema itself (e.g., `v1alpha1`).
  Enables evolution of the CatalogItem structure.
- **`schemaVersion`**: Versions the referenced ServiceType schema (e.g.,
  `v1alpha1`). Creates a contract for ServiceType payload generation.

The `schemaVersion` enables:

- **SP selection**: Version info can be used for placement decisions (e.g.,
  excluding SPs that don't support a given schema version)
- **Schema evolution**: New schema versions can add/modify fields while older
  catalog items continue working
- **Common naming**: All SPs serving the same `serviceType@schemaVersion` must
  understand the same field names

## Design Details

### Validation

The _validationSchema_ field follows
[JSON Schema (draft 2020-12)](https://json-schema.org/draft/2020-12/json-schema-validation).  
This
standard supports:

- Numeric constraints: _minimum, maximum, multipleOf_
- String patterns: _pattern, minLength, maxLength_
- Enumerations: _enum_
- Array constraints: _minItems, maxItems_
- Conditional logic: _if/then/else_

For the complete validation vocabulary, see the
[JSON Schema Validation specification](https://json-schema.org/draft/2020-12/json-schema-validation).

### Data Flow

1. Admin creates catalog item with template and validation rules
2. User requests service from catalog item
3. UI validates user input against validationSchema.
4. ServiceType payload created from template + user overrides
5. Placement Service calls policy engine for validation/mutation
6. Once approved, Placement Service selects a Service Provider and sends a
   request to it
7. The Service Provider receives the serviceType payload and translates it to
   their native format using simple struct-to-struct mapping.
