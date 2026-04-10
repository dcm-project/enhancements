---
title: rehydration-flow
authors:
  - "@ygalblum"
reviewers:
  - "@gciavarrini"
  - "@machacekondra"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"
  - "@gabriel-farache"
  - "@jenniferubah"
creation-date: 2026-03-23
see-also:
  - "/enhancements/placement-manager/placement-manager.md"
  - "/enhancements/sp-resource-manager/sp-resource-manager.md"
  - "/enhancements/user-flows/user-flows.md"
---

# Rehydration Flow

## Summary

Rehydration is the process of recreating an existing resource from its original
request (intent). The flow re-evaluates policies against the stored intent and
creates a new resource before deleting the old one. This allows the system to
absorb changes in policies and environment that occurred since the original
resource was provisioned.

## Motivation

Over time, policies, Service Provider availability, and environment
configurations may change. A resource that was provisioned under a previous set
of policies may no longer comply with current rules, or a more suitable Service
Provider may have become available. Rehydration enables administrators and users
to bring existing resources in line with the current state of the system without
requiring manual recreation.

### Goals

- Define the end-to-end rehydration flow across Catalog Manager, Placement
  Manager, and SP Resource Manager
- Define new API endpoints for triggering rehydration
- Define how deletion failures are handled when the original Service Provider is
  unavailable
- Define the deferred cleanup mechanism for resources that could not be deleted

### Non-Goals

- Modifying the original CatalogItemInstance, ServiceType, or CatalogItem
  definitions as part of rehydration
- Supporting partial rehydration (e.g., updating policies without recreating the
  resource)
- Defining update-in-place semantics

## Proposal

### Overview

Rehydration is triggered on an existing CatalogItemInstance. The flow
intentionally does **not** regenerate the ServiceType payload from the
CatalogItem. Instead, it uses the original intent stored in the Placement DB to
ensure that only policy and environment changes are reflected, not changes to the
underlying ServiceType or CatalogItem definitions.

#### ID Separation

The CatalogItemInstance ID used by the Catalog Manager is separate from the
InstanceID used by the Placement Manager and SP Resource Manager. During the
initial create flow, the Catalog Manager generates a InstanceID and passes it
downstream. The Catalog Manager maintains a mapping between its
CatalogItemInstance ID and the InstanceID. This separation is critical for
rehydration: it allows the Catalog Manager to generate a **new** InstanceID for
the recreated resource while the old InstanceID is still in use, avoiding ID
conflicts in the downstream services.

The high-level flow is:

1. User triggers rehydration on a CatalogItemInstance via the Catalog Manager
2. Catalog Manager generates a new InstanceID and calls the Placement Manager
   rehydrate endpoint with both the current and the new InstanceID
3. Placement Manager retrieves the original intent using the current InstanceID
4. Placement Manager re-evaluates policies against the original intent
5. Placement Manager instructs SP Resource Manager to create the new resource
   using the new InstanceID
6. Once the new resource is provisioned, Placement Manager instructs SP Resource
   Manager to delete the old resource using the old InstanceID

### System Architecture

```mermaid
flowchart TD
    CM["Catalog Manager<br/>Trigger Rehydration"]

    subgraph DCM_Core [" "]
        PM["Placement Manager<br/>Orchestrate Rehydration"]

        PE["Policy Manager<br/>Re-evaluate Policies"]

        SPRM["SP Resource Manager<br/>Create New Instance<br/>Delete Old Instance<br/>Deferred Cleanup"]

        PM_DB[("Placement DB<br/>Original Intent<br/>Validated Request")]
    end

    CM --> PM
    PM --> PM_DB
    PM --> PE
    PM --> SPRM
```

### API Endpoints

#### Catalog Manager

| Method | Endpoint                                          | Description                        |
|--------|---------------------------------------------------|------------------------------------|
| POST   | /api/v1/catalog-item-instances/{catalogItemInstanceId}:rehydrate     | Trigger rehydration of an instance |

**POST /api/v1/catalog-item-instances/{catalogItemInstanceId}:rehydrate**

Triggers rehydration of an existing CatalogItemInstance. The Catalog Manager does
**not** regenerate the ServiceType payload. It generates a new InstanceID and
delegates to the Placement Manager rehydrate endpoint, passing both the current
InstanceID and the new InstanceID.

Response: Returns `202 Accepted` if the rehydration process has started.

#### Placement Manager

| Method | Endpoint                                  | Description                       |
|--------|-------------------------------------------|-----------------------------------|
| POST   | /api/v1/resources/{instanceId}:rehydrate  | Rehydrate an existing resource    |

**POST /api/v1/resources/{instanceId}:rehydrate**

Triggers the rehydration of an existing resource. The Placement Manager retrieves
the original intent from the Placement DB and orchestrates creation of the new
resource followed by deletion of the old one.

Request body:
```json
{
  "newInstanceId": "<new-instance-id>"
}
```

Response: Returns `202 Accepted` if the rehydration process has started.

## Design Details

### Rehydration Flow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant CM as Catalog Manager
    participant PM as Placement Manager
    participant DB as Placement DB
    participant PE as Policy Manager
    participant SPRM as SP Resource Manager
    participant SR as Service Registry
    participant SP as Service Provider

    User->>CM: POST /api/v1/catalog-item-instances/{catalogItemInstanceId}:rehydrate
    CM->>CM: Generate newInstanceId
    CM->>PM: POST /api/v1/resources/{instanceId}:rehydrate<br/>{newInstanceId}

    activate PM

    PM->>DB: Retrieve original intent by instanceId
    activate DB
    DB-->>PM: {originalRequest, providerName, oldInstanceId}
    deactivate DB

    %% Re-evaluate policies on original intent
    PM->>PE: POST /api/v1alpha1/policies:evaluateRequest<br/>{service_instance: {originalSpec}}

    alt Policy rejects
        PE-->>PM: 406 Not Acceptable
        PM->>DB: Update record (policy rejected)
        PM-->>CM: Error (policy rejected)
        CM-->>User: Rehydration failed (policy rejected)
    else Policy approves
        PE-->>PM: 200 OK<br/>{evaluatedServiceInstance, selectedProvider, status}

        PM->>DB: Store validated request with newInstanceId<br/>{validatedPayload, new providerName}
        activate DB
        DB-->>PM: Updated
        deactivate DB

        %% Create new resource with new InstanceID
        PM->>SPRM: POST /api/v1/service-type-instances<br/>{newInstanceId, providerName, spec}
        activate SPRM

        SPRM->>SR: Lookup provider by name
        SR-->>SPRM: {endpoint, metadata, healthStatus}

        alt Provider not found or unhealthy
            SPRM-->>PM: Error response
            PM-->>CM: Error (provider unavailable)
            CM-->>User: Rehydration failed
        else Provider healthy
            SPRM->>SP: POST {endpoint}/api/v1/{serviceType}<br/>{spec}
            SP-->>SPRM: {newInstanceId, status: PROVISIONING}
            SPRM-->>PM: 202 Accepted {newInstanceId, status}
        end
        deactivate SPRM

        %% Delete old resource (deferred) after new one is created
        PM->>SPRM: DELETE /api/v1/service-type-instances/{oldInstanceId}?deferred=true
        activate SPRM
        SPRM->>SPRM: Record pending cleanup<br/>{oldInstanceId, providerName}
        SPRM-->>PM: 200 OK (deletion deferred)
        deactivate SPRM

        PM->>DB: Remove old instance record
        PM-->>CM: 202 Accepted {newInstanceId, status}
        CM->>CM: Update InstanceID reference to newInstanceId
        CM-->>User: Rehydration started<br/>{status: PROVISIONING}
    end
    deactivate PM
```

### Flow Description

1. **Rehydration Trigger**
   - User sends a POST request to the Catalog Manager rehydrate endpoint
   - Catalog Manager does **not** regenerate the ServiceType payload from the
     CatalogItem. This ensures that only policy and environment changes are
     applied, not changes to the underlying CatalogItem or ServiceType
   - Catalog Manager generates a new InstanceID for the downstream services
   - Catalog Manager forwards the request to the Placement Manager rehydrate
     endpoint with the current InstanceID (in the URL) and the new InstanceID
     (in the request body)

2. **Intent Retrieval**
   - Placement Manager retrieves the original intent (the user's original
     request) from the Placement DB using the current InstanceID
   - The original intent includes the spec, the current providerName, and the
     old InstanceID

3. **Policy Re-evaluation**
   - Placement Manager sends the original intent to the Policy Manager for
     evaluation against the current policy set
   - Policy Manager evaluates the request through the full policy chain
     (Global, Tenant, User)
   - If the policy rejects the request, the Placement Manager updates the
     record and returns an error
   - If the policy approves, the Placement Manager receives the evaluated
     payload and the newly selected Service Provider

4. **Resource Creation**
   - Placement Manager stores the new validated request in the Placement DB
     with the new InstanceID
   - Placement Manager delegates instance creation to SP Resource Manager with
     the new InstanceID, the new providerName, and the evaluated spec
   - Since the new InstanceID is different from the old one, there is no ID
     conflict in SP Resource Manager
   - Standard creation flow applies (SP lookup, health check, instance creation)
   - On success, the resource enters `PROVISIONING` state

5. **Delete Old Resource**
   - Once the new resource is created, Placement Manager requests SP Resource
     Manager to delete the old resource using the old InstanceID with the
     `deferred` flag set to `true`
   - SP Resource Manager immediately records the instance in the cleanup queue
     for background deletion without contacting the Service Provider (see
     [Deferred Deletion](#deferred-deletion))
   - SP Resource Manager returns success to allow the flow to continue
   - Placement Manager removes the old instance record from the Placement DB
     and returns success to the Catalog Manager

6. **Update Reference**
   - Catalog Manager updates its CatalogItemInstance reference to the new
     InstanceID

### Handling Deletion of the Old Resource

#### Deferred Deletion

During rehydration, the deletion request is sent with the `deferred` flag set to
`true`. When the SP Resource Manager receives a deferred deletion request, it
does **not** attempt to contact the Service Provider. Instead, it immediately
enqueues the instance for background cleanup:

1. The SP Resource Manager records the pending deletion in a **cleanup queue**
   (persisted in the database) with the following information:
   - `instanceId`: The instance to be deleted
   - `providerName`: The Service Provider that hosts the instance
   - `serviceType`: The type of the service
   - `timestamp`: When the deletion was requested
2. The SP Resource Manager returns success to the Placement Manager, allowing
   the rehydration flow to continue

#### Cleanup Mechanism

The SP Resource Manager runs a background cleanup process that periodically
attempts to complete deferred deletions:

```mermaid
flowchart TD
    A[Cleanup scheduler triggers] --> B[Query cleanup queue<br/>for pending deletions]
    B --> C{Any pending?}
    C -->|No| D[Sleep until next interval]
    C -->|Yes| E[For each pending deletion]
    E --> F[Lookup provider<br/>in Service Registry]
    F --> G{Provider available?}
    G -->|No| H[Skip, retry next cycle]
    G -->|Yes| I[DELETE instance<br/>on provider]
    I --> J{Deletion succeeded?}
    J -->|Yes| K[Remove from cleanup queue]
    J -->|No| L[Increment retry count]
    L --> M{Max retries exceeded?}
    M -->|No| H
    M -->|Yes| N[Mark as FAILED,<br/>alert for manual intervention]
    K --> D
    H --> D
    N --> D
```

**Cleanup queue record:**
```json
{
  "instanceId": "08aa81d1-a0d2-4d5f-a4df-b80addf07781",
  "providerName": "kubevirt-sp",
  "serviceType": "vm",
  "requestedAt": "2026-03-23T10:00:00Z",
  "retryCount": 0,
  "status": "PENDING",
  "lastAttempt": null
}
```

#### Key Characteristics

- **Non-blocking**: Deferred deletion does not contact the Service Provider,
  so the rehydration flow is never blocked by provider latency or availability
- **Persistent**: The cleanup queue is stored in the database to survive
  restarts
- **Automatic retry**: The cleanup process automatically retries deletions as
  Service Providers become available
- **Bounded retries**: After a configurable maximum number of retries, the
  entry is marked as `FAILED` for manual intervention
- **Idempotent**: Cleanup deletions are idempotent; repeated attempts to delete
  an already-deleted resource are safe

### Placement Manager Rehydration Flowchart

```mermaid
flowchart TD
    A[Receive rehydrate request<br/>for instanceId with newInstanceId] --> B[Retrieve original intent<br/>from Placement DB]
    B --> C{Intent found?}
    C -->|No| D[Return 404 Not Found]
    C -->|Yes| F[Send original intent to<br/>Policy Manager for evaluation]
    F --> G{Policy approved?}
    G -->|No| H[Update record in Placement DB]
    H --> I[Return error to Catalog Manager]
    G -->|Yes| J[Store validated request<br/>with newInstanceId in Placement DB]
    J --> K[Forward to SP Resource Manager<br/>with newInstanceId, providerName, and spec]
    K --> L{Creation succeeded?}
    L -->|No| I
    L -->|Yes| M[Request SP Resource Manager<br/>to delete old resource<br/>with deferred flag]
    M --> N[Remove old instance record<br/>from Placement DB]
    N --> O[Return 202 Accepted<br/>to Catalog Manager]
```

### Key Characteristics

- **Intent Preservation**: Rehydration operates on the original user intent, not
  the current CatalogItem or ServiceType definitions. This ensures that only
  policy and environment changes are reflected
- **Create-before-Delete**: The new resource is created before the old one is
  deleted. This ensures the system is never left without a running resource
  during the rehydration process
- **ID Separation**: The CatalogItemInstance ID is separate from the InstanceID
  used downstream. This allows the Catalog Manager to issue a new InstanceID
  for the recreated resource, avoiding ID conflicts in downstream services
- **Policy Re-evaluation**: Every rehydration re-evaluates the full policy
  chain, potentially selecting a different Service Provider or applying different
  mutations
- **Deferred Cleanup**: Deletion of the old resource is always deferred during
  rehydration. The SP Resource Manager enqueues the old instance for background
  cleanup without contacting the Service Provider, ensuring the rehydration flow
  is never blocked by provider availability or errors
- **Idempotent Rehydration**: Rehydrating an already-rehydrated resource works
  the same way; a new resource is created from the original intent and the
  current resource is deleted afterward
