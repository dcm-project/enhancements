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
request (intent). The flow deletes the current resource and creates a new one by
re-evaluating policies against the stored intent. This allows the system to
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

The high-level flow is:

1. User triggers rehydration on a CatalogItemInstance via the Catalog Manager
2. Catalog Manager calls the Placement Manager rehydrate endpoint
3. Placement Manager instructs SP Resource Manager to delete the existing
   resource
4. Placement Manager re-evaluates policies against the original intent
5. Placement Manager instructs SP Resource Manager to create the new resource

### System Architecture

```mermaid
flowchart TD
    CM["Catalog Manager<br/>Trigger Rehydration"]

    subgraph DCM_Core [" "]
        PM["Placement Manager<br/>Orchestrate Rehydration"]

        PE["Policy Manager<br/>Re-evaluate Policies"]

        SPRM["SP Resource Manager<br/>Delete Old Instance<br/>Create New Instance<br/>Deferred Cleanup"]

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
**not** regenerate the ServiceType payload. It delegates directly to the
Placement Manager rehydrate endpoint.

Response: Returns `202 Accepted` if the rehydration process has started.

#### Placement Manager

| Method | Endpoint                                  | Description                       |
|--------|-------------------------------------------|-----------------------------------|
| POST   | /api/v1/resources/{resourceId}:rehydrate  | Rehydrate an existing resource    |

**POST /api/v1/resources/{resourceId}:rehydrate**

Triggers the rehydration of an existing resource. The Placement Manager retrieves
the original intent from the Placement DB and orchestrates deletion and
recreation.

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
    CM->>PM: POST /api/v1/resources/{resourceId}:rehydrate

    activate PM

    PM->>DB: Retrieve original intent
    activate DB
    DB-->>PM: {originalRequest, providerName, instanceId}
    deactivate DB

    %% Delete existing resource
    PM->>SPRM: DELETE /api/v1/service-type-instances/{instanceId}
    activate SPRM
    SPRM->>SR: Lookup provider by name
    SR-->>SPRM: {endpoint, metadata, healthStatus}

    alt Service Provider available
        SPRM->>SP: DELETE {endpoint}/api/v1/{serviceType}/{instanceId}
        alt Deletion succeeded
            SP-->>SPRM: 200 OK (deleted)
            SPRM-->>PM: 200 OK
        else Deletion failed
            SP-->>SPRM: Error
            SPRM->>SPRM: Record pending cleanup<br/>{instanceId, providerName}
            SPRM-->>PM: 200 OK (deletion deferred)
        end
    else Service Provider unavailable
        SPRM->>SPRM: Record pending cleanup<br/>{instanceId, providerName}
        SPRM-->>PM: 200 OK (deletion deferred)
    end
    deactivate SPRM

    %% Re-evaluate policies on original intent
    PM->>PE: POST /api/v1alpha1/policies:evaluateRequest<br/>{service_instance: {originalSpec}}

    alt Policy rejects
        PE-->>PM: 406 Not Acceptable
        PM->>DB: Update record (policy rejected)
        PM-->>CM: Error (policy rejected)
        CM-->>User: Rehydration failed (policy rejected)
    else Policy approves
        PE-->>PM: 200 OK<br/>{evaluatedServiceInstance, selectedProvider, status}

        PM->>DB: Update validated request<br/>{validatedPayload, new providerName}
        activate DB
        DB-->>PM: Updated
        deactivate DB

        %% Create new resource
        PM->>SPRM: POST /api/v1/service-type-instances<br/>{providerName, spec}
        activate SPRM

        SPRM->>SR: Lookup provider by name
        SR-->>SPRM: {endpoint, metadata, healthStatus}

        alt Provider not found or unhealthy
            SPRM-->>PM: Error response
            PM-->>CM: Error (provider unavailable)
            CM-->>User: Rehydration failed
        else Provider healthy
            SPRM->>SP: POST {endpoint}/api/v1/{serviceType}<br/>{spec}
            SP-->>SPRM: {instanceId, status: PROVISIONING}
            SPRM-->>PM: 202 Accepted {instanceId, status}
            PM->>DB: Update instance metadata
            PM-->>CM: 202 Accepted {instanceId, status}
            CM-->>User: Rehydration started<br/>{instanceId, status: PROVISIONING}
        end
        deactivate SPRM
    end
    deactivate PM
```

### Flow Description

1. **Rehydration Trigger**
   - User sends a POST request to the Catalog Manager rehydrate endpoint
   - Catalog Manager does **not** regenerate the ServiceType payload from the
     CatalogItem. This ensures that only policy and environment changes are
     applied, not changes to the underlying CatalogItem or ServiceType
   - Catalog Manager forwards the request to the Placement Manager rehydrate
     endpoint

2. **Intent Retrieval**
   - Placement Manager retrieves the original intent (the user's original
     request) from the Placement DB
   - The original intent includes the spec, the current providerName, and the
     instanceId

3. **Delete Existing Resource**
   - Placement Manager requests SP Resource Manager to delete the existing
     resource
   - SP Resource Manager looks up the Service Provider in the Service Registry
   - If the Service Provider is available and deletion succeeds, the resource is
     deleted normally
   - If the deletion fails for any reason (Service Provider unavailable, Service
     Provider returns an error, etc.), the deletion is deferred (see
     [Handling Unavailable Service Providers](#handling-deletion-failures))
   - In all cases, SP Resource Manager returns success to allow the flow to
     continue

4. **Policy Re-evaluation**
   - Placement Manager sends the original intent to the Policy Manager for
     evaluation against the current policy set
   - Policy Manager evaluates the request through the full policy chain
     (Global, Tenant, User)
   - If the policy rejects the request, the Placement Manager updates the
     record and returns an error
   - If the policy approves, the Placement Manager receives the evaluated
     payload and the newly selected Service Provider

5. **Resource Recreation**
   - Placement Manager stores the new validated request in the Placement DB
   - Placement Manager delegates instance creation to SP Resource Manager with
     the new providerName and evaluated spec
   - Standard creation flow applies (SP lookup, health check, instance creation)
   - On success, the resource enters `PROVISIONING` state

### Handling Deletion Failures

A core requirement of rehydration is the ability to proceed even when the
deletion of the original resource fails. This can happen when the Service
Provider is unavailable, or when the Service Provider is available but returns
an error. Since the same resource ID is used throughout the pipeline, a failed
deletion would normally block recreation. To support this, the SP Resource
Manager implements the following behavior:

#### Deferred Deletion

When the SP Resource Manager fails to delete the original resource during
a rehydration request (whether because the Service Provider is unreachable or
because it returned an error):

1. The SP Resource Manager records the pending deletion in a **cleanup queue**
   (persisted in the database) with the following information:
   - `instanceId`: The instance to be deleted
   - `providerName`: The Service Provider that hosts the instance
   - `serviceType`: The type of the service
   - `timestamp`: When the deletion was requested
2. The SP Resource Manager removes the instance record from its database so
   that the same ID can be reused for the new resource
3. The SP Resource Manager returns success to the Placement Manager, allowing
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

- **Non-blocking**: Deletion failures do not block the rehydration flow
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
    A[Receive rehydrate request<br/>for resourceId] --> B[Retrieve original intent<br/>from Placement DB]
    B --> C{Intent found?}
    C -->|No| D[Return 404 Not Found]
    C -->|Yes| E[Request SP Resource Manager<br/>to delete existing resource]
    E --> F[Send original intent to<br/>Policy Manager for evaluation]
    F --> G{Policy approved?}
    G -->|No| H[Update record in Placement DB]
    H --> I[Return error to Catalog Manager]
    G -->|Yes| J[Store validated request<br/>in Placement DB]
    J --> K[Forward to SP Resource Manager<br/>with new providerName and spec]
    K --> L{Creation succeeded?}
    L -->|No| I
    L -->|Yes| M[Return 202 Accepted<br/>to Catalog Manager]
```

### Key Characteristics

- **Intent Preservation**: Rehydration operates on the original user intent, not
  the current CatalogItem or ServiceType definitions. This ensures that only
  policy and environment changes are reflected
- **Policy Re-evaluation**: Every rehydration re-evaluates the full policy
  chain, potentially selecting a different Service Provider or applying different
  mutations
- **Graceful Degradation**: The flow continues even when deletion of the
  original resource fails (whether the Service Provider is unavailable or returns
  an error), with a cleanup mechanism to handle deferred deletions
- **Idempotent Rehydration**: Rehydrating an already-rehydrated resource works
  the same way; the current resource is deleted and recreated from the original
  intent
