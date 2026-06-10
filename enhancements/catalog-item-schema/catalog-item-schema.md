---
title: catalog-item-schema
authors:
  - "@gciavarrini"
reviewers:
  - "@machacekondra"
  - "@ygalblum"
  - "@jenniferubah"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"
  - "@gabriel-farache"
approvers:
  - "@machacekondra"
  - "@ygalblum"
  - "@jenniferubah"
  - "@flocati"
  - "@gabriel-farache"
creation-date: 2025-12-05
see-also:
  - "/enhancements/service-type-definitions/service-type-definitions.md"
  - "/enhancements/declarative-api/declarative-api.md"
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
enabling administrators to create curated offerings. Items are either
**primitive** (one service type, one provisioned resource) or **composite**
(a blueprint of multiple resources, each with its own primitive
`serviceType`). Composite stacks are defined entirely in the catalog item;
there is no composite service type in the
[Service Type Definition](./service-type-definitions.md) registry.

### Goals

- Define the structure for Catalog Items
- Maintain independence between service types while applying consistent design
  patterns
- Add validation rule
- Enable administrators to create curated offerings for users
- Support **composite catalog items** for multi-resource stacks (n-tier apps)
- Design catalog schemas as provider-agnostic specifications that Service
  Providers translate to their native platform formats

### Non-Goals

- Defining the service schemas themselves (see
  [Service Type Definition](https://raw.githubusercontent.com/dcm-project/enhancements/main/enhancements/service-type-definitions/service-type-definitions.md)
  )

## Proposal

The catalog schema acts as a _translation layer_ between what the DCM users want
(abstract service specifications) and what providers deliver (platform-specific
implementations).

### Implementation Details/Notes/Constraints

#### Catalog Item kinds

Catalog items are **primitive** or **composite**. The shape is discriminated
by which top-level fields are present:

| Kind | Required fields | Template source |
| :--- | :-------------- | :---------------- |
| **Primitive** | `serviceType`, `fields` | [ServiceType](../service-type-definitions/service-type-definitions.md) registry |
| **Composite** | `resources` | Blueprint embedded in the catalog item (no composite service type) |

A catalog item must not set both `serviceType` (primitive) and `resources`
(composite).

#### Primitive catalog item

A primitive catalog item wraps a single service type with validation rules and
defaults. Administrators create offerings like "_Small Dev VM_" or "_Production
Database_" that users request as one resource.

```yaml
apiVersion: v1alpha1
kind: CatalogItem
metadata:
  name: production-postgres
spec:
  serviceType: database
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
[catalog-item-schema.yaml](https://github.com/gciavarrini/service-provider-api-archived/blob/add-catalog-item/api/v1alpha1/catalog-item-schema.yaml)
for complete schema definition.

#### CatalogItem components (primitive)

| Field         | Required | Type   | Description |
| :------------ | :------- | :----- | :---------- |
| apiVersion    | Yes      | string | CatalogItem schema version (e.g., _v1alpha1_) |
| serviceType   | Yes      | string | Primitive service type (_vm_, _container_, _database_, _cluster_) |
| fields        | Yes      | array  | Field configurations (see below) |

Each field in the _fields_ array has:

| Field            | Required | Type    | Default | Description                                                                   |
| :--------------- | :------- | :------ | :------ | :---------------------------------------------------------------------------- |
| path             | Yes      | string  | -       | Field path in service schema (e.g., _vcpu.count_)                             |
| displayName      | No       | string  | -       | Human-readable label for UI. If not set, derived from the path                |
| editable         | No       | boolean | false   | Whether users can modify this field                                           |
| default          | No       | any     | -       | Default value for this field                                                  |
| validationSchema | No       | object  | -       | JSON Schema rules (only applies if editable)                                  |
| dependsOn        | No       | object  | -       | Conditional options derived from another field (single option when read-only) |

The `dependsOn` object specifies conditional options for this field based on
another field's value. It has:

| Field         | Required | Type   | Description                                                              |
| :------------ | :------- | :----- | :----------------------------------------------------------------------- |
| path          | Yes      | string | JSON path of the field this one depends on (e.g., `region`)              |
| allowedValues | Yes      | object | If the field at path equals key K, this field's options are the array at |
|               |          |        | `allowedValues[K]`.                                                      |

When `dependsOn` is set, the field's options are derived from the field at path.
Each `allowedValues` entry is the list of options for that key (one or more). If
the field at path has a value with no corresponding key in `allowedValues`,
there are no value restrictions for this field. UIs use this to show the right
options; the chosen or derived values are sent when ordering the catalog item.

Object keys are always strings. When the field at path is a boolean or number,
use the JSON string representation as the key.

For example, to model `backup.retention_days` (retention in days) depending on
`backup.enabled`:

```yaml
- path: backup.retention_days
  displayName: Retention (days)
  editable: true
  dependsOn:
    path: backup.enabled
    allowedValues:
      "true": ["7", "30", "90"]
      "false": ["0"]
```

When backup is disabled, retention is 0; when enabled, the user selects 7, 30,
or 90 days.

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

Multiple primitive catalog items can reference the same ServiceType with
different constraints: a `Production VM` item could require `vcpu.count`
between 4-16 instead of 1-4, while sharing the same underlying `vm` ServiceType
definition.

#### Composite catalog item

A composite catalog item defines a **multi-resource blueprint**: a list of
named resources. Each resource declares its primitive `serviceType`, optional
`requiresResources`, optional static `properties`, and a **`fields`** array
(same shape as primitive catalog items) for defaults and governance on that
resource's spec.

Catalog resolution merges **per-resource `fields`** and user values, evaluates
**CEL** (`${…}`) where present, validates each resource, and produces an
**effective resource graph** for placement. Orchestration (DAG, per-node policy,
per-level `create`) is defined in
[Declarative API](/enhancements/declarative-api/declarative-api.md).

##### Composite catalog item fields

| Field        | Required | Type   | Description |
| :----------- | :------- | :----- | :---------- |
| apiVersion   | Yes      | string | CatalogItem schema version |
| description  | No       | string | Human-readable offering description |
| paramSchema  | No       | object | User-supplied parameters at order time (optional; defer for v1 — use `fields` defaults and `userValues`) |
| resources    | Yes      | array  | Blueprint resources (min 1); see below |

Composite catalog items do **not** have top-level `fields` or `serviceType`.
Governance lives on each entry in `resources`.

Each entry in `resources`:

| Field              | Required | Type   | Description |
| :----------------- | :------- | :----- | :---------- |
| name               | Yes      | string | Stable identifier within the blueprint (e.g., _database_, _app_) |
| serviceType        | Yes      | string | Primitive type (_vm_, _container_, _database_, _cluster_) |
| requiresResources  | No       | array  | Names of other blueprint resources that must reach Ready before this one |
| properties         | No       | object | Static blueprint fragments not modeled as `fields` (optional; prefer `fields`) |
| fields             | No       | array  | Defaults and validation for this resource (same shape as primitive `fields`) |

`requiresResources` controls **provision order** between blueprint resources.
Do not confuse it with **`dependsOn`** on a field entry, which controls
**conditional field options** based on another field's value (for example version
choices when `database.engine` changes).

**Field paths:** use the **`serviceType.` prefix** plus the field path in that
service type's OpenAPI schema — for example `database.engine`,
`container.image.reference`. Do **not** use the blueprint resource `name` as the
path prefix (not `db.engine` when `name` is `db`). The resource `name` is used
for `requiresResources` and graph identity only. Paths do not include a
`resources` prefix.

When a composite item contains **more than one resource with the same
`serviceType`**, path and CEL disambiguation is an open team decision (for
example a suffix or the resource `name` only where duplicates exist).

**Cross-resource bindings** use CEL in field defaults — for example
`container.process.env[0].value: "${database.connectionString}"`. Placement
infers DAG edges from CEL references and `requiresResources`.

**CEL references to other resources** (for example `${database.connectionString}`)
are **not** catalog input fields. They refer to **outputs** published by the
provider when the source resource reaches Ready (stored in placement run state).
The reference prefix is the source resource's **`serviceType`** when unique; the
suffix (`connectionString`) is an output attribute for that node.

Today [`DatabaseSpec`](https://github.com/dcm-project/control-plane/blob/main/api/catalog/v1alpha1/servicetypes/database/spec.yaml)
does **not** define `connectionString` — only inputs (`engine`, `version`,
`resources`) plus read-only common fields (`status`, `id`, …). Defining standard
database outputs (for example `connectionString`, `host`, `port`) in the service
type schema or a separate outputs contract is **follow-up work**. Until then,
either document provider-specific output names in the declarative API layer or
rely on **provider inference** (`requiresResources: [database]` on a `container`
without explicit `DATABASE_URL` in the catalog).

**paramSchema (v1):** not required for the first iteration. Use explicit
`default` values on `fields` and optional `userValues` on the catalog item
instance (same as primitive items). Add `paramSchema` later when offerings need
user params referenced as `${params.*}` across resources (see Payments example).

**Placement** expands each blueprint resource into one graph node. Each node is
provisioned by the provider for its primitive `serviceType`. All nodes share the
same `catalogItemInstanceId` and placement **run**.

##### Example: Orders API (database + container)

```yaml
apiVersion: v1alpha1
kind: CatalogItem
metadata:
  name: dev-container-db
  displayName: "Dev Application"
spec:
  resources:
    - name: database
      serviceType: database
      fields:
        - path: "database.engine"
          editable: true
          default: postgres
          validationSchema: { enum: [postgres, mysql] }
        - path: "database.version"
          editable: true
          default: "16"
          dependsOn:
            path: database.engine
            allowedValues:
              postgres: ["14", "15", "16", "17"]
              mysql: ["8.0"]
        - path: "database.resources.cpu"
          default: 1
        - path: "database.resources.memory"
          default: 512MB
        - path: "database.resources.storage"
          default: 10GB
        - path: "database.metadata.name"
          default: orders-db

    - name: app
      serviceType: container
      requiresResources: [database]
      fields:
        - path: "container.image.reference"
          editable: false
          default: registry.example.com/orders-api:1.0
        - path: "container.metadata.name"
          default: orders-api
        - path: "container.process.env[0].name"
          default: DATABASE_URL
        - path: "container.process.env[0].value"
          default: "${database.connectionString}"
        - path: "container.network.ports[0].container_port"
          default: 8080
        - path: "container.network.ports[0].visibility"
          default: internal
```

The `DATABASE_URL` field shows the target CEL shape once database outputs
exist.

User order:

```yaml
kind: CatalogItemInstance
spec:
  catalogItemId: dev-container-db
  userValues:
    - path: database.version
      value: "17"
```

Resolution output (effective graph — conceptual):

```yaml
resources:
  - name: database
    serviceType: database
    spec: { ... }
  - name: app
    serviceType: container
    requiresResources: [database]
    spec: { ... }
```

#### Versioning

The **`apiVersion`** field versions the CatalogItem schema itself (e.g.,
`v1alpha1`), enabling evolution of the CatalogItem structure.

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

#### Primitive catalog item

1. Admin creates CatalogItem with `serviceType`, defaults, and validation rules
2. User requests service from CatalogItem
3. User submits request (UI may validate against `validationSchema` for early
   feedback)
4. DCM validates input, loads the ServiceType template, merges `fields` and
   user values into one primitive spec
5. Placement creates one resource; policy evaluates once; SPRM provisions

#### Composite catalog item

1. Admin creates CatalogItem with `resources` blueprint (per-resource `fields`,
   optional `properties`)
2. User submits CatalogItemInstance with `userValues` (paths use the
   `serviceType.fieldPath` convention, for example `database.version`)
3. Catalog resolution: merge per-resource fields and user values, evaluate CEL
   against params (when `paramSchema` is used) and resource outputs (when
   dependencies are Ready), validate each resource, produce effective resource graph
4. Placement admits a **run**, builds DAG from `requiresResources` and CEL edges,
   evaluates policy **per graph node**, applies creates **per DAG level**
5. Each node is provisioned by the provider for its `serviceType`; status
   aggregates to the catalog item instance / run

See [Declarative API](/enhancements/declarative-api/declarative-api.md) for
CEL, DAG levels, and status-driven progression.

Note: The validationSchema is used by both UI (for UX) and DCM (for
enforcement). Users may bypass the UI (CLI, Ansible, cURL), so DCM must always
validate.
