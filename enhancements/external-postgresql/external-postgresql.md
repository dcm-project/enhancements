---
title: external-postgresql
authors:
  - "@tkiss28"
reviewers:
  - TBD
approvers:
  - TBD
creation-date: 2026-11-10
---

# External PostgreSQL for the Control Plane

## Open Questions

N/A - no open design questions

## Summary

DCM will offer a deployment option to use an existing PostgreSQL database
instead of deploying its bundled PostgreSQL container. The bundled database
remains the default for Helm and Compose. Only fresh installations are in-scope;
it does not migrate existing data.

## Motivation

Platform teams often already operate PostgreSQL with their own backup, security,
and availability policies. Today the DCM application accepts database connection
settings, but its Helm and Compose packaging always deploys and targets a
bundled PostgreSQL server. Operators cannot use their existing database through
a supported installation path without modifying deployment manifests. This
enhancement makes that choice explicit while preserving the local development
default.

### Goals

- Allow fresh Helm and Compose installations to connect the control plane to a
  pre-existing PostgreSQL database using a host, port, name, and credentials.
- Keep bundled PostgreSQL and existing default behavior unchanged.
- Require an explicit external host and validate the external port and database
  name before deployment.
- Document database provisioning, permissions, and connectivity, and the
  boundary between fresh installation and data migration.

### Non-Goals

- Migrating an existing DCM installation from bundled to external PostgreSQL.
- Creating the external database, managing its credentials or certificates, or
  providing database failover, replication, and backups.
- Adding another database engine or changing DCM's API, data model, or UDLM
  contracts.
- Adding TLS options, certificate mounts, or changes to database credential
  parsing.

## Proposal

An operator chooses exactly one PostgreSQL source for a fresh installation. Both
Helm and Compose use bundled PostgreSQL by default; disabling it requires the
address of an external server. `EXTERNAL_DB=true` selects the external
configuration. In external mode DCM does not deploy the bundled PostgreSQL
service, instead it connects to the configured host, port, and database. NATS
and optional authentication are unaffected.

Compose loads a shared base file plus exactly one database file: bundled by
default, or external when `EXTERNAL_DB=true`.

The operator supplies the external database, a dedicated login, and network
access. The database must exist **before** DCM starts. DCM runs GORM
`AutoMigrate` on every startup, so the login must retain permission to create
and alter objects in the target schema across restarts and upgrades. The control
plane does not create the database itself. Credentials remain outside Helm
values and Compose files.

### Assumptions

- An external PostgreSQL server exposes a reachable, stable read-write endpoint
  from inside the DCM container or pod
- The operator has created the target database, grants the DCM login `CONNECT`
  and ongoing schema creation/alteration rights, and arranges for backups.
  Making the DCM role the database owner is one straightforward way to grant
  appropriate rights on current PostgreSQL versions.

### User Stories

#### Platform operator installs with an existing database

An operator pre-creates a DCM database and a dedicated login on an existing
PostgreSQL server, provides credentials through the chart's database Secret or
the Compose environment, and selects external mode. DCM starts without deploying
another PostgreSQL server and initializes its tables in that database.

#### Developer retains the default installation

A developer runs the same Helm install or `make compose-up` command as before.
The bundled PostgreSQL instance starts and the control plane connects to it.

### Implementation Details/Notes/Constraints

- **Helm:** keep `postgres.enabled: true` as the default. Place external
  connection settings under `postgres.external` so the conditional schema rule
  lives with `postgres`. For example:

  ```yaml
  postgres:
    enabled: false
    dbSecretRef: dcm-db
    external:
      host: db.example.org
      port: 5433
      database: dcm-control-plane
  ```

  Existing `postgres.image` and `postgres.storage` defaults remain for bundled
  mode. In external mode, the chart renders no bundled PostgreSQL StatefulSet.
  The control-plane container receives the configured endpoint; the numeric port
  is rendered as a string-valued environment variable. The schema rejects an
  empty host or database and a port outside 1–65535; rendering also fails
  clearly on a missing external host, including when schema validation is
  skipped.

- **Compose:** `compose.yaml` defines shared services and NATS readiness, but no
  PostgreSQL service or dependency. `compose.db-bundled.yaml` adds bundled
  PostgreSQL and its readiness dependency; `compose.db-external.yaml` sets the
  external host, port, and database name and requires a nonempty host. Make
  selects exactly one database file, with bundled PostgreSQL as the default.
  Authentication remains an independent optional file. Direct Compose callers
  and utilities must include the appropriate database file explicitly.

- **Credentials:** the existing `postgres.dbSecretRef` identifies a pre-created
  Secret in the Helm release namespace in either mode. External mode uses
  `DB_USER` and `DB_PASSWORD` for the control plane (`DB_PASS` remains a
  supported fallback). `POSTGRES_USER` and `POSTGRES_PASSWORD` are needed only
  to initialize the bundled server; external mode does not use them. Compose
  takes the same application credentials from its private `.env` file.

- **Readiness:** external mode must not wait for the bundled PostgreSQL service,
  omit the bundled PostgreSQL wait init container in external mode.

### Risks and Mitigations

| Risk                                                                                            | Mitigation                                                                                                                                                                                           |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Selecting external mode against a missing or inaccessible database prevents DCM startup.        | Fail with a clear message. Document DB pre-creation and privileges.                                                                                                                                  |
| A Compose override removes NATS or auth readiness, or leaves a dependency on absent PostgreSQL. | Move bundled PostgreSQL and its dependency to a separate file, `compose.db-bundled.yaml` . Make loads exactly one database file, so external mode needs no dependency-removal override.              |
| Switching an existing install starts with empty state                                           | External PostgreSQL is for fresh installations only, switching the database source is not supported. Helm and Compose do not reject such a switch. Adding installation-state checks is out of scope. |

## Design Details

### Deployment contract

The Helm and Compose options configure the same control-plane database
connection: `DB_TYPE=pgsql`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, and
`DB_PASSWORD`. The bundled path still creates the database on first start; the
external path never attempts to create it. DCM owns only its tables in the
chosen database. No consumer API, provider API, or UDLM entity-lifecycle
behavior changes.

### Verification

- Compare default and auth-enabled Helm renders before and after the change to
  ensure bundled behavior is unchanged. Check external renders omit all bundled
  PostgreSQL resources, do not wait for the bundled database, use a nondefault
  host/port/database, keep NATS/auth, and reference the database Secret exactly
  as intended.
- Exercise positive and negative Helm validation, including missing host,
  invalid port, and empty database; run the chart's schema, lint, and render
  checks.
- Inspect and start the merged Docker Compose and podman-compose configurations
  in bundled/external modes, both with and without auth. Confirm each supported
  invocation loads exactly one database file, NATS and Keycloak dependencies
  remain where appropriate, and no PostgreSQL service or dependency appears in
  external mode. Check utilities' default invocation includes the bundled file.
- Start against a real external PostgreSQL database with nondefault connection
  settings. Check wrong credentials, missing database, and insufficient schema
  permissions. Test with a fresh empty database, not a live cutover.

### Upgrade / Downgrade Strategy

Existing installations stay on the bundled default after upgrading packaging.
For a **new** installation, selecting external mode starts against an already
provisioned, empty DCM database. Changing an existing install's mode is
**unsupported** in this release: data must be backed up, transferred, checked,
and cut over under a separately validated migration procedure.

## Implementation History

- 2026-11-10: Initial proposal

## Drawbacks

External database mode transfers database provisioning, security, privileges,
backups, and recovery to the operator. Compose deployment changes must also
update direct Compose callers to include the bundled database file; the Make
default remains unchanged. These costs are acceptable to provide a supported
bring-your-own-database path.

## Alternatives

### Automatically create the external database

#### Description

Run an installation job with privileges to create the external database before
the control plane starts.

#### Pros

- Reduces pre-installation work for operators.

#### Cons

- Requires elevated database credentials and lifecycle handling for the job.
- Conflicts with operators who provision databases through separate governance.

#### Status

Deferred

#### Rationale

Pre-creation keeps the first release's permission boundary small: the DCM login
needs rights to manage its schema, not to create databases on a shared server.
Revisit only if pre-creation proves a significant adoption barrier.

## Infrastructure Needed

- A reachable external PostgreSQL endpoint, a pre-created database, and a
  dedicated DCM login with schema privileges.
- Coordinated updates to control-plane Helm/Compose packaging and documentation,
  and to utilities' direct Compose invocation. Existing chart checks and Compose
  smoke tests provide verification; no new repository is needed.
