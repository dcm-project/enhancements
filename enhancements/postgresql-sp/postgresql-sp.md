---
title: postgresql-sp
authors:
  - "@NoamNakash"
reviewers:
  - "@gabriel-farache"
  - "@jenniferubah"
approvers:
  - TBD
creation-date: 2026-06-01
---

# PostgreSQL Database Service Provider

## Summary

The PostgreSQL Database Service Provider is a REST API that manages relational
databases using PostgreSQL as a platform. It exposes endpoints for creating,
reading, and deleting databases, and integrates the DCM Service Provider
Registry. The PostgreSQL Database Service Provider implements the `database`
service type schema.

## Motivation

Databases are used in a major amount of modern applications. Under the existing
service type definitions, there is no method to manage the storage of
persistent, searchable data. This leaves a gap in DCM's ability to manage the
full lifecycle of an application, and leaves the users having to manually
configure databases either in external deployments or inside virtual machines.
Applications deployed often need persistent storage. PostgreSQL provides such
solution mainly for structured, relational data, but also supports unstructured
data using the `JSONB` data type, making it ideal for the first engine to be
supported by DCM for the `database` type. Additionally, admins may want to
separate compute provisioning from database provisioning in order to allow
databases to be deployed on a 'lower tier' hardware (cheaper CPU cores).

### Goals

- Define the lifecycle of a Service Provider using PostgreSQL to provision
  PostgreSQL clusters.
- Define the registration flow with DCM SP registry.
- Define `CREATE`, `READ`, and `DELETE` endpoints for managing PostgreSQL
  clusters.
- Define how database credentials will be managed and created.
- Define how users can pick their prefered version of PostgreSQL to deploy.
- Define how storage will be allocated to the `database` service type.
- Define replica management mechanism for PostgreSQL clusters.
- Define status reporting mechanism for DCM requests.

### Non-Goals

- Define endpoints for day 2 operations (`backup`, `DR`, `upgrade`, `scale`,
  `migrate`).
- Database migration (migrating pre-existing databases to PostgreSQL and
  migrating existing PostgreSQL databases to PostgreSQL SP).
- Custom database management (with OS access).
- Multi-tenant DB instances
- Support of different database providers.
- Support connection pooling - out of scope for v1
- Define `UPDATE` endpoint.
- Define `QUERY` endpoint for databases.

## Proposal

### User Stories

#### Story 1

As a developer, I want to have a database as part of my application, and to be
able to read, write and update existing data in the database.

#### Story 2

As a developer, I want to retrieve credentials for my database instanse so that
I can connect my application to the database.

#### Story 3

As an administrator, I want to be able to list and monitor existing databases.

### Implementation Details/Notes/Constraints

### Risks and Mitigations

| Risk                         | Impact                          | Mitigation                                                     |
| ---------------------------- | ------------------------------- | -------------------------------------------------------------- |
| Credential exposure via logs | Passwords may leaked via logs   | Censor passwords in logs                                       |
| Credential exposure via API  | Passwords may be leaked via API | Use TLS, Consider implementing idp authentication using tokens |

## Design Details

### Assumptions

- The PostgreSQL service provider is connected to a Kubernetes cluster with
  [CloudNativePG](https://cloudnative-pg.io/) installed and available PVC
  storage configured.
- If The Kubernetes cluster does not have access to the default CloudNativePG
  images, or if it is desired to use a custom set of images, the Kubernetes
  cluster has a configured `Namespace` which contains an `ImageCatalog` resource
  with the desired PostgreSQL images properly tagged for the correct versions.
- The PostgreSQL service provider has the necessary RBAC permissions to manage
  `clusters.postgresql.cnpg.io` resources in its configured namespace (Also
  known as `Cluster` kind).
- The DCM Service Provider Registry is reachable for registration.
- The PostgreSQL service provider has valid Kubernetes credentials (`kubeconfig`
  or in-cluster service account).
- Network policies allow PostgreSQL service provider to communicate with DCM.
- DCM messaging system (NATS) is reachable for publishing status updates.

### Integration Points

#### Kubernetes Integration

- Uses `k8s.io/client-go` to interact with Kubernetes API.
- Uses `https://github.com/cloudnative-pg/cloudnative-pg/tree/main/api/v1` to
  interact with `Cluster` CRDs.
- Creates and manages `Cluster` resources.
- Each postgres cluster request creates a `Cluster`.
- Leverages CloudNativePG's `Cluster` lifecycle management.
- The `Cluster` resource manages services that provide stable endpoints for
  accessing PostgreSQL databases, abstracting Pod IP changes during restarts.

#### DCM SP Registry

- Auto-registration on startup with via environment agent. The environment agent
  handles registration with DCM SP Registrar on behalf of the Service Provider.
  See documentation for
  [Environment Agent](https://github.com/dcm-project/enhancements/blob/main/enhancements/environment-agent/environment-agent.md)

#### DCM SP Health Check

PostgreSQL SP must expose a health endpoint `http://<provider-ip>:<port>/health`
for DCM control plane to pole every 10 seconds. See documentation for
[SP Health Check](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-provider-health-check/service-provider-health-check.md).

#### DCM SP Status Reporting

- Publish status updates for Cluster instances to the messaging system using
  CloudEvents format. Uses a `SharedIndexInformer` to watch `Cluster` events.
- See documentation for
  [SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md).

### SP Configuration

The PostgreSQL SP supports configuration options that control default behavior
for all postgres clusters managed by this provider instance.

#### Namespace Configuration

| Field        | Type   | Default | Description                                                       |
| ------------ | ------ | ------- | ----------------------------------------------------------------- |
| namespace    | string | default | Kubernates namespace for all managed resources                    |
| imageCatalog | string | N/A     | Sets the default image catalog that is used for PostgreSQL images |

All resources created by this Service Provider (`Cluster`) are deployed in the
configured `namespace`. The `imageCatalog` field specifies the `ImageCatalog`
resource within the named `namespace` that manages the container images for
PostgreSQL, catalogged by version. If not specified, the PostgreSQL SP will use
the default images defined in the operator installation. These settings applies
to all resources managed by the SP and cannot be overridden per-resource.

#### Network Configuration

| Field               | Type   | Required | Description                                                           |
| ------------------- | ------ | -------- | --------------------------------------------------------------------- |
| externalServiceType | string | Yes      | Service type for `external` visibility (`LoadBalancer` or `NodePort`) |

Service creation is driven by the per-database `visibility` field defined in the
Database Service Type schema (see
[ServiceTypeDefinitions](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#database-network-object)).
Each database declares its visibility as `internal` or `external` (`none` is not
valid for database workloads as by default, an `internal` service is created)

#### Storage Configuration

| Field               | Type   | Default | Description                                        |
| ------------------- | ------ | ------- | -------------------------------------------------- |
| defaultStorageClass | string | N/A     | Default storage class for PVCs managed by Clusters |

When specified, the `defaultStorageClass` field sets the default storage class
where `PersistentVolumeClaims` managed by `Cluster` resources would be created,
otherwise, the default storage class of the cluster is used. Users can override
this default per `Cluster` resource via `providerHints.postgres.storage` (see
POST endpoint documentation).

#### Postgres Configuration

| Field          | Type | Default | Description                                              |
| -------------- | ---- | ------- | -------------------------------------------------------- |
| defaultVersion | int  | 18      | The default version of PostgreSQL that would be deployed |

The `defaultVersion` field sets the default version of PostgreSQL to run, and
CloudNativePG selects the correct image automatically for the container The
relevant images for the selected version must be available to CloudNativePG, and
mentioned in the `ImageCatalog` matching the tag to the correct major version,
if specified. Users can override these defaults per `Cluster` resource via the
`version` field (see POST endpoint documentation).

### Registration Flow

The PostgreSQL SP API must successfully complete a registration process to
ensure DCM is aware of it and can use it. During startup, the environment agent
handles the registration of the PostgreSQL Database SP with DCM. See
[Environment Agent](https://github.com/dcm-project/enhancements/blob/main/enhancements/environment-agent/environment-agent.md)
for more information.

Example request payload:

```json
{
  "name": "psql-sp",
  "serviceType": "database",
  "displayName": "PostgreSQL Database Service Provider",
  "endpoint": "https://psql-database-sp.example.com/api/v1alpha1/databases",
  "operations": ["CREATE", "DELETE", "READ"],
  "metadata": {
    "zone": "us-east-1b",
    "region": "us-east-1",
    "resources": {
      "totalCpu": "200",
      "totalMemory": "2TB",
      "totalStorage": "100TB"
    }
  }
}
```

#### Registration Request Validation

The registration payload must conform to the validation requirements defined in
the
[SP registration flow](https://github.com/dcm-project/enhancements/blob/main/enhancements/sp-registration-flow/sp-registration-flow.md).

**PostgreSQL Database SP-specific requirements:**

- `serviceType` field must be set to `database`
- `operations` field must include: `CREATE`, `READ`, `DELETE`
- `metadata.resources` fields may or may not define the cluster capacity **at
  the time of registration**

#### Registration Process

The environment agent handles the registration of the PostgreSQL Database SP.
The registration request includes the PostgreSQL database SP endpoint URL in the
format: `http://<apiHost>:<port>/api/v1alpha1/databases`

### API Endpoints

The CRUD endpoints are consumed by the DCM SP API to create and manage database
resources.

#### Endpoints Overview

| Method | Endpoint                             | Description                         |
| ------ | ------------------------------------ | ----------------------------------- |
| POST   | /api/v1alpha1/databases              | Create a new database               |
| GET    | /api/v1alpha1/databases              | List all databases                  |
| GET    | /api/v1alpha1/databases/{databaseId} | Get a database instance             |
| DELETE | /api/v1alpha1/databases/{databaseId} | Delete a database instance          |
| GET    | /api/v1alpha1/health                 | PostgreSQL Database SP health check |

##### AEP Complience

These endpoints are defined basedon AEP standards and use `aep-openapi-linter`
to check for compliance with AEP.

#### POST /api/v1alpha1/databases

**Description:** Create a new database instance.

The POST endpoint follows the contract defined in the Database schema spec
pre-defined by DCM core. See
[Database Schema](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#database)
for the complete specification.

During the creation of the resources, each `Cluster`, `Service`, `Secret`, and
`PersistentVolumeClaim` must be labled with:

- `dcm.project/managed-by=dcm`
- `dcm.project/dcm-instance-id=<UUID>`
- `dcm.project/dcm-service-type=database`

The `dcm-instance-id` is a unique identifier — either a server-generated UUID or
a client-specified ID provided via the `?id=` query parameter (validated against
AEP-122 pattern `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`). Kubernetes resource
names are server-assigned using the `generateName` mechanism with
`metadata.name` as the prefix (e.g., `"web-app-"`). If a database with the same
`dcm-instance-id` already exists, the PostgreSQL SP returns a `409 Conflict`
error response without modifying the existing resource.

**Service Configuration: Networking**

By default, CloudNativePG creates 3 services per cluster:

- **rw (read-write)** - points to the primary instance of the cluster
- **ro (read-only)** - points to a secondary replica of the cluster (if
  available)
- **r (read)** - points to any instance in the cluster

All 3 of which are of the `ClusterIP` type.

For simplicity of v1, the PostgreSQL SP disables the following services `ro`,
`r` and creates only the `rw` service.

Users can enable an additional external service of `rw` type on a per-Cluster
basis using `network.visibility` to `external` (the external service's type is
set in the SP configuration, see
[Network Configuration](#network-configuration)).

> **Note**: It is currently not possible to fully disable or re-configure
> CloudNativePG's default `rw` service (which is of `ClusterIP` type, so
> `visibility=external` would need to create both services

**ProviderHints:**

The request body supports an optional `providerHints` field (type: object,
additionalProperties: true) as defined in the
[Service Type Definitions](https://github.com/dcm-project/enhancements/blob/main/enhancements/service-type-definitions/service-type-definitions.md#providerhints-object).
The SP accepts `providerHints` on input but does not act on its content in the
current implementation.

> **Note**: It is not yet designed how `providerHints` can be leveraged within
> the DCM control plane to influence provider behavior. As a result, Service
> creation is currently driven by the `network.visibility` field (see Networking
> Configuration above), which is the canonical approach. Future iterations may
> define how provider hints flow from catalog to provider and influence resource
> creation.

**Service Configuration via providerHints: Storage**

Users can override the SP default storage configuration on a per-Cluster basis
using `providerHints.postgres.storage`:

| Field        | Type   | Description                                 |
| ------------ | ------ | ------------------------------------------- |
| storageClass | string | The storage class used for Cluster intances |

If `providerHints.postgres.storage` is not specified, the SP uses its configured
defaults.

**Service Configuration via providerHints: Initial DB state**:

Users can override default SP user creation behavior on a per-Cluster basis by
specifying the `providerHints.postgres.initdb` field:

| Field    | Type   | Description                                                                  |
| -------- | ------ | ---------------------------------------------------------------------------- |
| database | string | The default database to create in the cluster                                |
| user     | string | The name of the owner of the default database that is created in the cluster |
| password | string | The password of the user specified                                           |

The `database` specified would be automatically created is owned by the `user`
specified, that would be created with the `password` specified. To configure the
`user`'s password, the PostgreSQL SP would create and manage a `secret`
complying with the
[Kubernetes.io/basic-auth](https://kubernetes.io/docs/concepts/configuration/secret/#basic-authentication-secret)
type.

If any of the fields in `providerHints.postgres.initdb` are not specified, the
SP will follow the defaults defined in the
[CloudNativePG Bootstrap documentation](https://cloudnative-pg.io/docs/1.29/bootstrap#bootstrap-an-empty-cluster-initdb),
which are:

- database - app
- user - <same as database name>
- password - randomly generated

**Example Request Payload:**

```json
{
  "spec": {
    "engine": "postgresql",
    "version": "18",
    "replicas": 3,
    "resources": {
      "cpu": {
        "min": "1",
        "max": "2"
      },
      "memory": {
        "min": "1GB",
        "max": "2GB"
      },
      "storage": "100GB"
    },
    "network": {
      "port": 5432,
      "visibility": "external"
    },
    "providerHints": {
      "postgres": {
        "storage": {
          "storageClass": "az-b"
        },
        "initdb": {
          "database": "application",
          "user": "application",
          "password": "pass_123"
        }
      }
    }
  },
  "metadata": {
    "name": "pg-db"
  },
  "serviceType": "database"
}
```

> **Note**: The `providerHints.postgres.storage`, section is optional. If
> omitted, the SP uses it's configured defaults

> **Note**: The `providerHints.postgres.initdb` section is optional. If omitted,
> a default configuration is used as specified in
> [Bootstrap](https://cloudnative-pg.io/docs/1.29/bootstrap#bootstrap-an-empty-cluster-initdb)
> Additionally, the `providerHints.postgres.initdb` is a input only field,
> following [AEP-203](https://aep.dev/203/#input-only.)

> **Note**: The `resources` field is calculated per replica, so the resource
> usage of the example would be 6 cpu, 6GB of memory and 300GB of storage.

> **Note**: By default, 3 reserved users are created - `postgres` superuser,
> `streaming_replica` and `cnpg_pooler_pgbouncer`. While present, none of these
> is accessible by default. we can allow users to enable superuser access at a
> later stage, but it is not allowed for simplicity of v1.

The request body uses a `CreateDatabaseRequest` wrapper with a `spec` field
containing the database input fields. The response is a bare database without
the wrapper.

**Response:** Returns `201 Created` with the following payload. The status is
set to `PENDING` after the resource is created.

**Example Response Payload:**

```json
{
  "id": "123e4567-e89b-12d3-a456-426614174000",
  "path": "databases/123e4567-e89b-12d3-a456-426614174000",
  "status": "PENDING",
  "metadata": {
    "name": "pg-db",
    "namespace": "postgres-databases"
  },
  "version": "18",
  "replicas": 3,
  "resources": {
    "cpu": {
      "min": "1",
      "max": "2"
    },
    "memory": {
      "min": "1GB",
      "max": "2GB"
    },
    "storage": "100GB"
  },
  "services": [
    {
      "name": "pg-db-rw",
      "clusterIP": "10.2.30.1",
      "type": "ClusterIP",
      "ports": [
        {
          "port": 5432,
          "targetPort": 5432,
          "protocol": "TCP"
        }
      ]
    },
    {
      "name": "pg-db-yx3w7",
      "clusterIP": "10.96.15.6",
      "type": "LoadBalancer",
      "ports": [
        {
          "port": 5432,
          "targetPort": 5432,
          "protocol": "TCP"
        }
      ]
    }
  ],
  "connectionDetails": ""
}
```

> **Note**: The `connectionDetails` field is an output only field following
> [AEP-203](https://aep.dev/203/#output-only) The `connectionDetails` field is
> empty at creation time and will be populated once the `Cluster` reaches
> `RUNNING` status. The `connectionDetails` field will contain a base64-encoded
> version of the database application connection details

> **Note**: The `<database-name>-rw` service is always created and can not be
> disabled. It is an `internal` visibility service (`ClusterIP`) that points to
> the current primary PostgreSQL instance. This restriction is enforced by
> CloudNativePG.

**Error Handling:**

- **400 Bad Request:** Invalid request payload or missing required fields
- **409 Conflict:** Cluster with the same `dcm-instance-id` already exists in
  the configured namespace
- **422 Unprocessable Entity**: Requested StorageClass does not exist
- **500 Internal Server Error:** Unexpected error during resource creation

#### GET /api/v1alpha1/databases

**Description:** List all database instances with pagination support.

**Query Parameters:**

- `max_page_size` (optional): Maximum number or resources to return in a single
  page. Default: 50.
- `page_token` (optional): Token indicating the starting point for the page.

**Process Flow:**

1. Handler recieves `GET` request with optional pagination parameters.
2. Calls `ListDatabasesFromCluster()` with pagination context.
3. Returns fully-populated database resource per AEP-132.
4. Response includes pagination metadata (`next_page_token`).

**Example Response Payload:**

```json
{
  "results": [
    {/* database instance - same schema as POST response */},
    {/* database instance - same schema as POST response */}
  ],
  "next_page_token": "a1b2c3d4e5f6"
}
```

> **Note**: Per AEP-132, LIST returns fully-populated resources. Fields like
> `connectionDetails` may be empty for databases that are still provisioning or
> have failed.

**Error Handling:**

- **400 Bad Request:** Invalid pagination parameters
- **500 Internal Server Error:** Unexperted error querying Kubernetes API

#### GET /api/v1alpha1/databases/{databaseId}

**Description:** Get specific database instance.

1. Handler recieves `GET` request with `databaseId` path parameter.
2. Calls `GetDatabaseFromCluster(databaseId)`.
3. Cluster lookup: Query Kubernetes API for `Cluster` with matching
   `dcm.project/dcm-instance-id` label.
4. Database details: Query `Cluster` for runtime information. Extract IP address
   from Pod status. Extract current phase (`Running`, `Pending`, etc.).
5. Service details: Query `Service` with matching `dcm.project/dcm-instance-id`
   label. Extract clusterIP, type, and externalIP (if applicable).
6. for each database user:
   - Connection details: Query `Secrets` with matching
     `dcm.project/dcm-instance-id` label and named
     `<databaseName>-pguser-<userName>`. Encode with base64.
7. Response payload: Return complete database instance object

**Example Response Payload:**

```json
{
  "id": "123e4567-e89b-12d3-a456-426614174000",
  "path": "databases/123e4567-e89b-12d3-a456-426614174000",
  "status": "RUNNING",
  "metadata": {
    "name": "pg-db",
    "namespace": "postgres-databases"
  },
  "version": "18",
  "replicas": 3,
  "resources": {
    "cpu": {
      "min": "1",
      "max": "2"
    },
    "memory": {
      "min": "1GB",
      "max": "2GB"
    },
    "storage": "100GB"
  },
  "services": [
    {
      "name": "pg-db-rw",
      "clusterIP": "10.2.30.1",
      "type": "ClusterIP",
      "ports": [
        {
          "port": 5432,
          "targetPort": 5432,
          "protocol": "TCP"
        }
      ]
    },
    {
      "name": "pg-db-yx3w7",
      "clusterIP": "10.96.15.6",
      "type": "LoadBalancer",
      "ports": [
        {
          "port": 5432,
          "targetPort": 5432,
          "protocol": "TCP"
        }
      ]
    }
  ],
  "connectionDetails": ""
}
```

**Connection Details Field Behavior:**

The `connectionDetails` field is populated based on the cluster status:

- **RUNNING:** Contains base64-encoded credentials and connection details
- **PENDING:** Empty string. Credentials are not yet available as the Cluster is
  still being created.
- **FAILED:** Empty string. Cluster provisioning failed; no valid credentails
  exist.
- **UNKNOWN:** Empty string. Node lost; no valid credentials exist.

The `connectionDetails` field follows the schema of the <cluster>-app secret's
format that is generated in the case no password is specified. If a password is
specified, the PostgreSQL will generate the rest of the fields by querying the
cluster and aggragating with user configuration. The details in the
`connectionDetails` take on the following structure:

| Field         | Description                                                               |
| ------------- | ------------------------------------------------------------------------- |
| username      | Specified user's name                                                     |
| password      | Specified user's password                                                 |
| hostname      | Hostname of the Read-Write service (for the default ClusterIP RW service) |
| port          | Port on which the RW service is listening                                 |
| database      | Name of the database created under the specified user                     |
| pgpass        | A pgpass file constructed of the other details                            |
| uri           | The specified database's uri                                              |
| jdbc-uri      | The URI for connecting to PostgreSQL using JDBC                           |
| fqdn-uri      | The URI for connecting to PostgreSQL via the cluster's FQDN               |
| fqdn-jdbc-uri | The URL for connecting to PostgreSQL using JDBC via the cluster's FQDN    |

> **Note**: The cluster's FQDN can be specified in Operator installation via the
> `KUBERNETES_CLUSTER_DOMAIN` and defaults to `cluster.local`

**Security Considerations:**

The `connectionDetails` field contains sensitive credentials that grant access
to the provisioned Cluster. Implementations should:

- Protect the API with proper authentication and authorization mechanisms.
- Use TLS (Transport Layer Security) for all API communications to prevent
  credential interception.
- Consider implementing short-lived tokens or certificate rotation for
  production deployments.
- Log access to connectionDetails for audit purposes.

This considatarations need to be taken care of as soon as DCM will support
AuthN/Z (Authentication/Authorization) and RBAC.

**Error Handling:**

- **404 Not Found:** Database with the specified `databaseId` does not exist
- **500 Internal Server Error:** Unexpected error querying Kubernetes API

#### DELETE /api/v1alpha1/databases/{databaseId}

**Description:** Delete a database instance

Remove a database instance (`Cluster` with cascading delete for all child
resources including `Pods`, `PersistentVolumeClaims`, `Services`, and `Secrets`
managed by the `Cluster`, and `secrets` managed by DCM that are not managed by
CloudNativePG), and returns `204 No Content`.

**Process Flow:**

1. Handler receives `DELETE` request with `databaseId` path parameter.
2. Lookup `Cluster` resource by `dcm.project/dcm-instance-id` label.
3. Delete the resource with cascading delition.
4. Lookup `Secret` resources by `dcm.project/dcm-instance-id` label.
5. foreach `Secret` matching the `dcm.project/dcm-instance-id`:
   - Delete the resource.
     <!-- This exists for user defined passwords for database users -->
6. Return `204 No Content` on success.

This will start an asynchronous deletion process of the cluster. The PostgreSQL
SP will publish `DELETING` via CloudEvents, and when the deletion process is
complete, the PostgreSQL SP will publish a `DELETED` event.

> **Note**: Steps 4 and 5 exist to handle user defined passwords. The process
> should NOT fail if no secret is found.

**Error Handling:**

- **404 Not Found:** Database with specified `databaseId` does not exist
- **500 Internal Server Error:** Unexpected error during resource deletion

#### GET /api/v1alpha1/health

**Description:** Retrieve the health status for the PostgreSQL Database Service
Provider API.

The health check verifies:

- Connectivity to the Kubernetes cluster
- CloudNativePG Operator availability
- Storage infrastructure availability

### Status Reporting to DCM

The PostgreSQL Database SP uses a **layered monitoring approach** with three
`SharedIndexInformer` instances to watch `Cluster`, `Pod`, and
`PersistentVolumeClaim` resources labeled with `dcm.project/managed-by=dcm` and
`dcm.project/dcm-service-type=database`. This provides comprehensive visibility
into both the desired state (Cluster) and actual runtime (Pod and PVC), enabling
accurate status reporting to DCM.

#### Layered Monitoring Architecture

The PostgreSQL Database SP monitors Kubernetes resources and two levels:

1. **Cluster**: Tracks creation status, rollout status, replica failures, and
   desired state
2. **Pod and PersistentVolumeClaim**:
   - **Pod**: Tracks actual runtime state, IP addresses, and container statuses
   - **PersistentVolumeClaim**: Tracks actual storage state in runtime

All informers watch resurces labled with:

- `dcm.project/managed-by=dcm`
- `dcm.project/dcm-service-type=database`

**Rationale for Layered Monitoring**:

- **Cluster-only monitoring** misses runtime details like container-level
  failures
- **Pod-only monitoring** Misses Cluster-level failures (e.g. replica failures,
  can't create pod due to quota limits) and storage level failures
- **PersistentVolumeClaim-only monitoring** Misses pod/container level details,
  as well as replication failures
- **Layered approach** provides complete visibility into the full lifecycle from
  creation to runtime

#### Status Reconciliation Logic

When any informer receives an event, the PostgreSQL database SP reconciles
status from both resource types using the following precedence rules:

1. **Pod status** (highest priority if Pod exists):
   - Pod.Status.Phase → DCM status mapping
   - Pod.Status.PodIP → Instance IP address
   - Pod.Status.ContainerStatuses → Detailed failure reasons
2. **PersistentVolumeClaim status** (if Pod.Status.ContainerStatuses has a PVC
   related faiure)
   - PVC.Status.Phase → DCM status mapping
3. **Cluster status** (if Pod doesn't exist yet):
   - Cluster.Status.readyInstances = 0 → `PENDING`
   - Cluster.Status.Conditions.Ready = `False` → `PENDING`
   - Cluster.Status.instances = 0 → `FAILED` (Cluster couldn't create Pod)
4. **Resource not found** (neither exists):
   - Report `DELETED` to DCM
5. **Node lost** (Pod exists but node is unreachable)
   - Pod.Status.Phase = `Unknown` → `UNKNOWN`

**Implementation Notes**:

- Both informers use the same label selector: `dcm.project/managed-by=dcm`,
  `dcm.project/dcm-service-type=database`
- Status updates are debounced to avoid flooding the messaging system during
  rapid status oscillation (e.g., running→error→running within milliseconds)
- Status updates are published to the messaging system using CloudEvents format
- The `instanceId` of the DCM resource is stored in the label
  `dcm.project/dcm-instance-id`

For detailed implementation of the `SharedIndexInformer` pattern (setup phase,
event processing flow, pros and cons), see the
[KubeVirt SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/kubevirt-sp/kubevirt-sp.md#status-reporting-to-dcm)
section. The PostgreSQL Database SP applies the same pattern with three
informers instead of one.

#### CloudEvents Format

**NATS subject:** `dcm.database`

**CloudEvent attributes:**

| Attribute         | Value                          |
| ----------------- | ------------------------------ |
| `source`          | `dcm/providers/{providerName}` |
| `type`            | `dcm.status.database`          |
| `subject`         | `dcm.database`                 |
| `datacontenttype` | `application/json`             |

Instance identity is carried in the data payload `id` field (from the
`dcm.project/dcm-instance-id` label), not in the NATS subject.

**Data Payload Structure:**

```json
{
  "id": "<dcm-instance-id>",
  "status": "<DCM_STATUS>",
  "message": "<human-readable description>"
}
```

**Example Event:**

```json
{
  "specVersion": "1.0",
  "id": "event-123-456",
  "source": "dcm/providers/pgsql-database-sp-dev",
  "type": "dcm.status.database",
  "subject": "dcm.database",
  "dataContentType": "application/json",
  "data": {
    "id": "abc-123",
    "status": "RUNNING",
    "message": "Database is running successfully"
  }
}
```

See
[SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md)
for the complete CloudEvents contract and messaging system details.

#### Status Mapping from Kubernetes to DCM

The following tables map Kubernetes resource statuses to DCM generic statuses.
The PostgreSQL SP uses the **Priority Order** defined in the reconciliation
logic above (Pod and PVC first, then Cluster, then resource not found).

##### Single Instance Database Status Mapping (Primary instance only)

| DCM Status | Primary Source | Kubernetes Condition                           | Precedence |
| ---------- | -------------- | ---------------------------------------------- | ---------- |
| PENDING    | Pod            | Pod.Phase = `Pending`                          | 1          |
| PENDING    | Cluster        | Cluster.readyInstances = 0 AND no Pod exists   | 2          |
| RUNNING    | Pod            | Pod.Phase = `Running`                          | 1          |
| FAILED     | Pod            | Pod.Phase = `Failed`                           | 1          |
| FAILED     | PVC            | Pod.Phase = `Pending` AND PVC.Phase = `FAILED` | 1          |
| FAILED     | Cluster        | Cluster.instances = 0                          | 2          |
| UNKNOWN    | Pod            | Pod.Phase = `Unknown` (node lost)              | 1          |
| DELETED    | All            | Neither Cluster nor Pod found                  | 3          |

##### Multi Instance Database Status Mapping

Each Instance is created as a set of `Pod` and `PVC` resources. We can
distinguish all instances of the same cluster by 2 labels:
`cnpg.io/cluster: <clusterName>` and `cnpg.io/podRole: instance` The first label
is used to find all Pods associated with a certain cluster, and the second
isolates PostgreSQL instances fro the rest of the pods (for future compatibility
with services such as `backup` and `pgBouncer`) The following table maps each
instance's state by the following table:

**Per-Instance Status Mapping**

| Replica Status | Primary Source | Kubernetes Condition                               | Precedence |
| -------------- | -------------- | -------------------------------------------------- | ---------- |
| PENDING        | Pod            | Pod.Phase = `Pending` AND NOT PVC.Phase = `FAILED` | 1          |
| RUNNING        | Pod            | Pod.Phase = `Running`                              | 1          |
| FAILED         | Pod            | Pod.Phase = `Failed`                               | 1          |
| FAILED         | PVC            | Pod.Phase = `Pending` AND PVC.Phase = `FAILED`     | 1          |
| UNKNOWN        | Pod            | Pod.Phase = `Unknown` (node lost)                  | 1          |
| DELETED        | Both           | Pod not found in cluster                           | 2          |

> **Note**: In this context, instance is used to refer to both primary and
> non-primary nodes and for v1, we do not destinguish the two for status
> reconciliation

**Precedence Rules**:

- **1 (Pod)**: Highest priority - report Pod status if Pod exists (`PENDING`,
  `RUNNING`, `FAILED`, or `UNKNOWN`), while `PVC` failure takes priority over
  `POD`'s `PENDING` phase
- **2 (PVC)**: Fallback - report PVC status in case Pod is stuck in a pending
  state (`PENDING`/`BOUND` or `FAILED`)
- **3 (Both)**: Resource cleanup complete - report `DELETED` when neither PVC
  not Pod exists

**Cluster-level Status Mapping**

The instance's status is aggragated into a single DCM status using the following
mapping:

| DCM Status | Primary Source | Status                                                                                                                               | Precedence |
| ---------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ---------- |
| PENDING    | Any instance   | any instance PENDING AND (no instance FAILED OR UNKNOWN)                                                                             | 1          |
| PENDING    | Cluster        | (Cluster.Phase = `Creating a new replica` OR Cluster.Phase = `Waiting for the instances to become active`) AND any replica `DELETED` | 2          |
| RUNNING    | All instances  | all instances RUNNING                                                                                                                | 1          |
| FAILED     | Any instance   | any instance FAILED                                                                                                                  | 1          |
| UNKNOWN    | Any instance   | Any instance UNKNOWN AND no replica FAILED                                                                                           | 1          |
| DELETED    | All            | All instances DELETED and Cluster not found                                                                                          | 3          |

> **Note**: The `SUCCEEDED` status defined in the
> [SP Status Reporting](https://github.com/dcm-project/enhancements/blob/main/enhancements/state-management/service-provider-status-reporting.md)
> specification is intentionally excluded from the PostgreSQL database SP. This
> status only applies to Kubernetes resource types like Jobs that have a defined
> completion state. The PostgreSQL database SP uses Clusters which are designed
> for long-running services that continuously run and restart on failure.

**Precedence Rules**:

- **1 (Instance)**: Highest priority - report Replica state if replica exists
  (any `PENDING`, `FAILED` or `UNKNOWN`, or all `RUNNING`)
- **2 (Cluster)**: Fallback - report Cluster status
  (`Creating a new replica`/`Waiting for the instancaes to become active` ->
  `PENDING`)
- **3 (ALL)**: Resource cleanup complete - report `DELETED` when neither Cluster
  nor any replica exists

For official definitions, see

- [Kubernetes Pod Phase](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase)
- [Kubernetes PVC Phase](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#phase).

### Upgrade / Downgrade Strategy

- SP upgrades are rolling deployments; informers reconnect automatically.
- Downgrade: avoid schema changes without catalog compatibility review.
- Existing Clusters retain DCM labels; re-registration is idempotent per SP
  name.

## Alternatives

### Alternative 1: Use Percona/PostgresOperator

Percona's PostgreSQN operator is an operator that manages the lifecycle of
PostgreSQL clusters using StatefulSets, it automates the creation, modification
and deletion of PostgreSQL clusters

#### Pros

- Simple cluster configuration (specifically user and service configuration)
- Leverages built in k8s mechanisms to manage cluster lifecycle (`StatefulSets`)

#### Cons

- Less flexible than CNPG (CloudNative-PG)
- Limited to Percona's distribution of PostgreSQL
- No Prometheus/Graphana support (supports it's own monitoring solution instead
  called PMM)
- Enables by default a lot of features that wouldn't be implemented in v1
  (backups, PMM - monitoring, pgBouncer - connection pooling) and requires their
  images to be present - even if disabled
- Indirect lifecycle management - while leveraging existing mechanisms to manage
  cluster lifecycle could be an advantage, in Percona's case, this also leads to
  a very uninformative status section that can not be fully covered by the more
  "abstract" status of a `StatefulSet`, that does not cover PostgreSQL specific
  status information.
- Has less contributors than CNPG

#### Status

Rejected

#### Rationale

The PostgreSQL SP should have granular control of DCM's database instances, it
shouldn't be limited by operator configurations, such as connection pooling by
default that has to be disabled. additionally, DCM should not lock customers
looking to use PostgreSQL into a specific distribution or configuration, thus
the lack of support for Prometheus and Graphana in favor of a "private" (even if
open-source) solution, and vendor-locking into a specific distribution does not
align with DCM's goals. Additionally, Percona's PostgreSQL operator lacks in
status information with a very basic binary state (`initializing` or `ready`)

### Alternative 2: Use CrunchyData/PostgresOperator

#### Description

Percona's PostgreSQL operator is a fork of CruncyData's PostgreSQL operator,
thus there is a very small difference on the surface level. CrunchyData's
operator is a longer standing project, making it more robust and stable.

#### Pros

- Simple cluster configuration

#### Cons

- Not fully open source - air gapped customers trigger a license review if they
  want to host the images in a private repo
- Uses `Deployments` instead of `StatefulSets` for the databases, making
  management of the applciation more complex
- Despite existing for a longer time, CrunchyData's operator does not have more
  contributors than Percona's operator, this might indicate a lack of community
  behind it
- Indirect lifecycle management - while leveraging existing mechanisms to manage
  cluster lifecycle could be an advantage, in CrunchyData's case, this also
  leads to a very uninformative status section that can not be fully covered by
  the more "abstract" status of a `Deployment`, that while more informative than
  the status of `StatfulSets`, still does not cover Postgresql specific status
  information.
- Has less contributors than CNPG

#### Status

Rejected

#### Rationale

DCM's Current customer base is made up of mostly banks, and DCM is a product
that fits well into air gapped environments in general. The limitation on air
gapped environments would deter customers from using it. Additionally,
Deploymennts are not catered towards stateful applications, making the lifecycle
management more complicated. More so, the rationale to not use Percona's
operator also applies to CrunchyData's operator, as it is a fork of this
operator. CrunchyData's operator only advantage over Percona's operator is
support of Prometheus and Graphana (over Percona's PMM), but it does not cover
it's other flaws.

### Alternative 3: Use an aggragation of DCM Service Providers

#### Pros

- Native to DCM
- Minimizes dependency on 3rd parties
- Encourages usage of a wider suite of DCM Service Providers
- More control of configuration means we can create more generic deployments
  that could fit several engines with minimal configuration difference to
  minimize overhead for SP implementation

#### Cons

- Lack of implemented Service Providers - would need to wait for stateful
  application/persistent storage Service Providers to be implemented
- Less optimal per engine - While generic deployments would reduce
  implementation time of each SP, they would also reduce the per-engine
  optimizations by avoiding specialized tools (such as patroni for PostgreSQL)
- Longer initial implementation time

#### Status

Rejected

#### Rationale

Implementing a service that manages PostgrSQL from scratch would take longer and
more upkeep to stay up to date with latest versions, with a 3rd party operator,
we are delegating most of the work to the community, while only maintaining an
interface with the operator

## Infrastructure Needed

- New repository: `psql-database-service-provider` (Go), modeled on
  `k8s-container-service-provider`.
- OpenAPI spec: update `database/spec.yaml` in accordence with the relevant
  changes (resources field altered, replicas, and port fields added)
