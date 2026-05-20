# Use case example — Catalog-backed Application through orchestration

This walkthrough mirrors use-case example described
[here](https://github.com/machacekondra/dcm-arch/blob/main/docs/design/declarative-api/use-case-catalog-items.md) (same
CatalogItem and Application YAML) and traces how that Application moves through
DCM orchestration: `catalog resolution → Placement → Policy → provision queue
(wave by wave) → SPRM → Service Provider`, with Placement consuming a separate
state queue to advance DAG levels.

Orchestration flow: Placement owns the dependency gate. It
publishes to the provision queue only for resources whose DAG level is allowed
(same level in parallel when policy allows). It subscribes to a state queue 
so it learns when resources become Ready (or Failed) and can publish the next wave.
SPRM consumes the provision queue only—no “push back and wait for deps” on that 
queue; deferral is Placement’s job.

**Note**: Payloads and field names are conceptual until
OpenAPI is finalized. Full provider telemetry schemas (every CloudEvent field)
are not specified in this example flow.

## CatalogItem (platform-owned template)

```yaml
apiVersion: dcm.io/v1alpha1
kind: CatalogItem
metadata:
  name: payments-api-stack
spec:
  version: "2.1.0"
  status: published
  description: Payments API with Postgres, object storage, VPC, DNS.
  paramSchema:
    appId:
      type: string
      required: true
    image:
      type: string
      required: true
    dnsName:
      type: string
      required: true

  resources:
    - name: vpc
      type: network.virtual-network
      properties:
        name: "${params.appId}-payments-net"
        region: eu-central-1
        cidr: 10.40.0.0/16
    - name: storage
      type: storage.object-bucket
      properties:
        name: "${params.appId}-payments-artifacts"
        versioning: true
    - name: db
      type: database.postgresql
      properties:
        dbName: "${params.appId}-payments"
        tier: 1
        subnetIds: "${vpc.privateSubnetIds}"
    - name: api
      type: workloads.stateless-service
      properties:
        image: "${params.image}"
        subnetIds: "${vpc.publicSubnetIds}"
        env:
          DATABASE_URL: "${db.connectionString}"
          STORAGE_BUCKET: "${storage.name}"
        ports:
          - name: https
            port: 443
            targetPort: 8080
            public: true
    - name: api-dns
      type: dns.record-set
      properties:
        zone: example.com
        name: "${params.dnsName}"
        type: CNAME
        ttl: 300
        target: "${api.publicHostname}"
```

## Application (dev submit)

```yaml
apiVersion: dcm.io/v1alpha1
kind: Application
metadata:
  name: acme-payments
  labels:
    dcm.io/environment: staging-eu
spec:
  fromCatalog:
    name: payments-api-stack
    version: "2.1.0"
  params:
    appId: acme
    image: quay.io/acme/payments-api:v1.9.0
    dnsName: payments-acme.staging
```

## Orchestration flow (end to end)

High-level order:

1. Catalog resolution: Catalog Manager loads the CatalogItem, validates params
   against `paramSchema`, merges params into `spec.resources`, produces an
   Application-shaped graph (`spec.resources[]`) for downstream services.
2. Handoff to Placement: Placement Manager receives the resolved graph, 
   builds the DAG, classifies CEL edges, records run state (DAG levels,
   pending/ready resources).
3. Policy: Placement calls Policy Manager (`policies:evaluateRequest`) per
   resource or batch until the full-graph orchestration gate passes 
   (no api call to SPRM for creation before that).
4. Placement (First Wave): After Policy validation, Placement enqueues (`provision queue`) 
   only DAG level 0 resources (`vpc`, `storage` here), one message per resource,
   same level may publish in parallel.
5. SPRM: SPRM consumes messages from the `provision queue`, sends the validated
   request to SP and persists instance.
6. State Queue: As the Service Provider reaches Ready (and outputs are available as needed), 
   it publishes state / readiness messages to the state queue. SPRM consumes that queue,
   normalizes messages, and persists instance state in its database (current architecture)
   Placement consumes from same queue so it updates its view of the run.
7. Placement evaluates the DAG (Next Wave): If level 0 is Ready (and outputs
   satisfy the next level’s CEL), it publishes wave 1 (`db`), then later `api`,
   then `api-dns`, each wave only after dependencies are satisfied. On Failed,
   Placement stops publishing further waves for that run (run-level cancel /
   terminal state).

The subsections below show example JSON at each hop (IDs and bodies are
example only).

### 1. Dev → Catalog Manager: create catalog item instance

`POST /api/v1alpha1/catalog-item-instances`.

```json
{
  "metadata": {
    "name": "acme-payments-instance",
    "labels": {
      "dcm.io/environment": "staging-eu"
    }
  },
  "spec": {
    "catalogItemId": "catalog-item-payments-api-stack-2-1-0",
    "user_values": [
      { "path": "params.appId", "value": "acme" },
      { "path": "params.image", "value": "quay.io/acme/payments-api:v1.9.0" },
      { "path": "params.dnsName", "value": "payments-acme.staging" }
    ]
  }
}
```

Catalog Manager response: instance id + status `Provisioning` or equivalent.

```json
{
  "metadata": {
    "name": "acme-payments-instance",
    "uid": "cii-8f3a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8"
  },
  "status": {
    "phase": "Provisioning"
  }
}
```

### 2. Catalog resolution

The engine materializes `${params.*}` and keeps CEL references until outputs
exist. Example below show the first two nodes only. The full graph matches the CatalogItem
`resources` list.

```json
{
  "kind": "Application",
  "metadata": {
    "name": "acme-payments",
    "uid": "app-run-38df7b22-9ecc-426a-a19b-c0ef831ac750",
    "labels": {
      "dcm.io/environment": "staging-eu",
      "dcm.io/catalog-item-instance": "cii-8f3a1b2c-4d5e-6f70-8192-a3b4c5d6e7f8"
    }
  },
  "spec": {
    "resources": [
      {
        "name": "vpc",
        "type": "network.virtual-network",
        "properties": {
          "name": "acme-payments-net",
          "region": "eu-central-1",
          "cidr": "10.40.0.0/16"
        }
      },
      {
        "name": "storage",
        "type": "storage.object-bucket",
        "properties": {
          "name": "acme-payments-artifacts",
          "versioning": true
        }
      }
    ]
  }
}
```

### 3. Catalog Manager → Placement Manager

Placement receives run id, generation, full graph (`resources[]`).

```json
{
  "runId": "run-7c9e2d1a-0001-4000-8000-000000000001",
  "application": {
    "metadata": {
      "name": "acme-payments",
      "uid": "app-run-38df7b22-9ecc-426a-a19b-c0ef831ac750"
    },
    "spec": {
      "resources": [
        {
          "name": "vpc",
          "type": "network.virtual-network",
          "properties": {
            "name": "acme-payments-net",
            "region": "eu-central-1",
            "cidr": "10.40.0.0/16"
          }
        },
        {
          "name": "storage",
          "type": "storage.object-bucket",
          "properties": {
            "name": "acme-payments-artifacts",
            "versioning": true
          }
        },
        {
          "name": "db",
          "type": "database.postgresql",
          "properties": {
            "dbName": "acme-payments",
            "tier": 1,
            "subnetIds": "${vpc.privateSubnetIds}"
          }
        },
        {
          "name": "api",
          "type": "workloads.stateless-service",
          "properties": {
            "image": "quay.io/acme/payments-api:v1.9.0",
            "subnetIds": "${vpc.publicSubnetIds}",
            "env": {
              "DATABASE_URL": "${db.connectionString}",
              "STORAGE_BUCKET": "${storage.name}"
            },
            "ports": [
              {
                "name": "https",
                "port": 443,
                "targetPort": 8080,
                "public": true
              }
            ]
          }
        },
        {
          "name": "api-dns",
          "type": "dns.record-set",
          "properties": {
            "zone": "example.com",
            "name": "payments-acme.staging",
            "type": "CNAME",
            "ttl": 300,
            "target": "${api.publicHostname}"
          }
        }
      ]
    }
  }
}
```

Placement then runs DAG build + CEL compile (cycle check, levels). DAG level 0
for this graph is `vpc` and `storage` (no dependencies on other resources in the
list).


### 4. Placement → Policy Manager

Send resource to endpoint `POST /api/v1alpha1/policies:evaluateRequest`
for policy mutation/validation. Example with `vpc`

```json
{
  "resource": {
    "name": "vpc",
    "type": "network.virtual-network",
    "properties": {
      "name": "acme-payments-net",
      "region": "eu-central-1",
      "cidr": "10.40.0.0/16"
    }
  },
  "context": {
    "runId": "run-7c9e2d1a-0001-4000-8000-000000000001",
    "environment": "staging-eu",
    "graph": {
      "resourceNames": ["vpc", "storage", "db", "api", "api-dns"],
      "dagLevel": 0
    }
  }
}
```

**Policy response payload**

```json
{
  "status": "APPROVED",
  "providerName": "network-sp-east"
}
```

Placement repeats (or batches) evaluate for each resource until the
orchestration gate passes, then enqueues only wave 0 (`vpc`, `storage`) to the
`provision queue`. It does not enqueue `db` or `api` or `api-dns` until state shows
the dependencies for the next level are in `Ready` state.


### 5. Placement → provision queue (wave 0)

Publish `vpc` resource message to the provision queue 

```json
{
  "runId": "run-7c9e2d1a-0001-4000-8000-000000000001",
  "dagLevel": 0,
  "resourceName": "vpc",
  "serviceType": "network.virtual-network",
  "operation": "Create",
  "spec": {
    "name": "acme-payments-net",
    "region": "eu-central-1",
    "cidr": "10.40.0.0/16"
  }
}
```

A second message at the same wave for `storage` shares the same `runId` /
`dagLevel` but different `resourceName` / `serviceType` / `spec`.

### 6. SPRM consumes from provision queue → call Service Provider

SPRM consumes from provision queue, records service-type instance, resolves
Service Provider URL from registry, and calls create to the Service
Provider.

```json
{
  "uid": "run-7c9e2d1a-0001-4000-8000-000000000001:vpc:1", // could be combination of run id + random str
  "serviceType": "network.virtual-network",
  "runId": "run-7c9e2d1a-0001-4000-8000-000000000001",
  "resourceName": "vpc",
  "spec": {
    "name": "acme-payments-net",
    "region": "eu-central-1",
    "cidr": "10.40.0.0/16"
  }
}
```

### 7. State queue

Placement consumes from the state queue and learns `vpc` and `storage` 
are in Ready state with complete output information.

```json
{
  "runId": "run-7c9e2d1a-0001-4000-8000-000000000001",
  "resourceName": "vpc",
  "phase": "Ready",
  "outputs": {
    "privateSubnetIds": ["subnet-a", "subnet-b"],
    "publicSubnetIds": ["subnet-c", "subnet-d"]
  },
  "observedAt": "2026-05-20T14:32:01Z"
}
```

A similar event arrives for `storage` with `phase: "Ready"` and outputs such as
`name` or `bucket id`. Placement merges these into run state, evaluates the DAG,
and decides wave 1 may include `db` which depends on `vpc`.

### 8. Placement → provision queue

Only after level 0 is Ready with the outputs CEL needs does Placement
publish wave 1 resource (`db`)

```json
{
  "runId": "run-7c9e2d1a-0001-4000-8000-000000000001",
  "dagLevel": 1,
  "resourceName": "db",
  "serviceType": "database.postgresql",
  "operation": "Create",
  "spec": {
    "dbName": "acme-payments",
    "tier": 1,
    "subnetIds": ["subnet-a", "subnet-b"]
  }
}
```

**Notes**: DAG level 2 resource, `api` (which depends on`db` and `storage` outputs)
and DAG level 3 resource, `api-dns` (which depends on
`api` to have the output `publicHostname`) follow the same pattern.
Placement publishes each wave to the provision queue,
SPRM consumes and dispatches each message independently.

---

### 9. Failure Flow

For example, `vpc` reaches `Failed`, Placement marks the run terminal, stops publishing
new provision messages for that `runId`, and downstream waves are not enqueued.
Rollback and cleanup process will be initiated (TBD).
