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
kind: CatalogItem
metadata:
name: production-postgres
spec:
  serviceType: database
  fields:
    - name: "engine"
      default: "postgresql"
    - name: "version"
      editable: true
      default: "15"
      validationSchema: { enum: ["14", "15", "16"] }
    - name: "resources.cpu"
      editable: true
      default: 4
      validationSchema: { minimum: 2, maximum: 16 }
    - name: "resources.memory"
      editable: true
      default: "16GB"
```

See
[catalog-item-schema.yaml](https://github.com/gciavarrini/service-provider-api/blob/add-catalog-item/api/v1alpha1/catalog-item-schema.yaml)
for complete schema definition.

#### CatalogItem components

| Field       | Required | Type   | Description                                                |
| :---------- | :------- | :----- | :--------------------------------------------------------- |
| serviceType | Yes      | string | Type of service (e.g., _vm, container, database, cluster_) |
| fields      | Yes      | array  | List of field configurations (see below)                   |

Each field in the _fields_ array has:

| Field            | Required | Type    | Default | Description                                       |
| :--------------- | :------- | :------ | :------ | :------------------------------------------------ |
| name             | Yes      | string  | -       | Field path in service schema (e.g., _vcpu.count_) |
| editable         | No       | boolean | false   | Whether users can modify this field               |
| default          | No       | any     | -       | Default value for this field                      |
| validationSchema | No       | object  | -       | JSON Schema rules (only applies if editable)      |

Fields not listed are neither editable nor have default values. The catalog item
owner must ensure all mandatory fields are listed.

_Example "Development VM" CatalogItem - only CPU and memory required_

```yaml
kind: CatalogItem
metadata:
  name: dev-vm
  labels:
  displayName: "Development VM"
  spec:
    serviceType: vm
    fields:
      - name: "vcpu.count"
        editable: true
        default: 2
        validationSchema: { minimum: 1, maximum: 4 }
      - name: "memory.size"
        editable: true
        default: "4GB"
        validationSchema: { minimum: 2, maximum: 8 }
      - name: "guestOS.type"
        editable: false
        default: "rhel-9"
```

Multiple CatalogItems can reference the same ServiceType with different
constraints: a `Production VM` item could require `vcpu.count` between 4-16
instead of 1-4, while sharing the same underlying `vm` ServiceType definition.

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
