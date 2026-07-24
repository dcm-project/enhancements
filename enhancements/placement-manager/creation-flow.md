# Service Creation Flow — Diagram Options

This document compares two ways to document the Placement Manager service
creation flow.

Both options describe the same behavior:

1. Catalog calls `CreateResources` with `catalogItemInstanceId` and
   `resources[]`.
2. Placement compiles the DAG (CEL + `requiresResources`), stores intent, and
   fetches `available_agents` once from the Agent Registry.
3. Placement evaluates policy once per resource.
4. Placement persists each resource row and starts `dagLevel` 0 provisioning via
   SPRM.
5. Placement returns `202 Accepted` with `payload` to Catalog.
6. `dagLevel` 1+ continues asynchronously when dependencies reach `Running`
   state.
7. Queued-request timeout may re-evaluate policy with `exclude_agents`.

---

## Option 1 — Single full-flow sequence diagram

One diagram covering end to end flow: DAG compilation, policy, level 0
provisioning, status-driven provisioning, and queued-request handling.

```mermaid
sequenceDiagram
  autonumber
  participant CM as Catalog
  participant PM as Placement
  participant DB as Control Plane DB
  participant AR as Agent Registry
  participant PE as Policy
  participant SPRM as SP Resource Manager

  CM->>PM: CreateResources<br/>{catalogItemInstanceId, resources[]}
  activate PM

  PM->>PM: Build DAG (CEL + requiresResources)<br/>Detect circular deps, assign dagLevel
  alt Compile or DAG error
      PM-->>CM: 4xx compile error
      deactivate PM
  else Compile ok

      PM->>DB: Store intent<br/>{originalRequest}
      DB-->>PM: Intent stored

      PM->>AR: Fetch available agents<br/>(healthy, non-Congested)
      AR-->>PM: available_agents list

      loop each resource in graph
          PM->>PE: evaluateRequest<br/>{service_instance, available_agents}
          PE-->>PM: Validated/mutated payload<br/>{validatedPayload, selectedAgent}
      end

      alt Any resource denied
          PM-->>CM: Error response (policy rejection)
      else All resources pass

          PM->>DB: Persist per-resource rows<br/>(requires_resources, dagLevel,<br/>validated spec, agentName)

          loop each resource at dagLevel 0
              PM->>SPRM: POST /api/v1/service-type-instances<br/>{agentName, serviceType, spec}
              activate SPRM
              alt SPRM returns error
                  SPRM-->>PM: Error response
                  Note over PM: Tear down any provisioned <br/>level-0 resources
                  PM-->>CM: Error response
              else SPRM returns 202 Accepted
                  SPRM-->>PM: 202 Accepted<br/>{instanceId, agentName, status: PENDING}
              end
              deactivate SPRM
          end

          PM-->>CM: 202 Accepted<br/>{response payload}

          Note over SPRM,PM: dagLevel 1+ (async, after deps Running)

          SPRM->>DB: Update instance<br/>(status: Running, outputs)
          SPRM->>PM: OnResourceRunning (in-process)
          activate PM

          loop each resource at next dagLevel<br/>when all requires_resources Running
              PM->>PM: Bind dependency outputs into spec
              PM->>PE: validate/mutate payload
              PM->>SPRM: POST /api/v1/service-type-instances<br/>{agentName, spec}
              SPRM-->>PM: 202 Accepted
          end

          Note over PM: Repeat on each Running event<br/>until graph complete or failure
          deactivate PM

          Note over SPRM: Async: SPRM consumes response<br/>from dcm.agents.responses

          opt SPRM notifies PM of QUEUED status
              SPRM->>PM: Notify: instance QUEUED<br/>{instanceId, agentName}
              Note over PM: Start queuedRequestTimeout timer

              alt Timeout expires (or timeout = 0)
                  PM->>SPRM: DELETE /api/v1/service-type-instances/{instanceId}
                  Note over PM: Re-evaluate excluding current agent

                  PM->>PE: POST policies:evaluateRequest<br/>{spec, available_agents, exclude_agents: [agentName]}
                  PE-->>PM: New selectedAgent or no match

                  alt Alternative agent found
                      PM->>SPRM: POST /api/v1/service-type-instances<br/>{newAgentName, serviceType, spec}
                      SPRM-->>PM: 202 Accepted
                  else No agent available
                      PM-->>CM: Error: no agent available
                  end
              end
          end
      end
  end
```

---

## Option 2 — Split diagrams

Two diagrams with a clear boundary:

### 2a. End-to-end creation flow (single resource)

Unit-level path for one resource with no loops for policy.

```mermaid
sequenceDiagram
    autonumber
    participant CM as Catalog
    participant PM as Placement
    participant DB as Control Plane DB
    participant AR as Agent Registry
    participant PE as Policy
    participant SPRM as SP Resource Manager

    CM->>PM: CreateResources<br/>{catalogItemInstanceId, resources[]}
    activate PM

    PM->>DB: Store intent<br/>{originalRequest}
    DB-->>PM: Intent stored

    PM->>AR: Fetch available agents<br/>(healthy, non-Congested)
    AR-->>PM: available_agents list

    PM->>PE: evaluateRequest<br/>{service_instance, available_agents}
    PE-->>PM: Validated/mutated payload<br/>{validatedPayload, selectedAgent}

    alt Policy denied
        PM-->>CM: Error response (policy rejection)
    else Policy approved

        PM->>DB: Persist resource row<br/>(validated spec, agentName)

        PM->>SPRM: POST /api/v1/service-type-instances<br/>{agentName, serviceType, spec}
        activate SPRM
        alt SPRM returns error
            SPRM-->>PM: Error response
            PM-->>CM: Error response
        else SPRM returns 202 Accepted
            SPRM-->>PM: 202 Accepted<br/>{instanceId, agentName, status: PENDING}
            PM-->>CM: 202 Accepted<br/>{response payload}
        end
        deactivate SPRM
    end

    Note over SPRM: Async: SPRM consumes response<br/>from dcm.agents.responses

    opt SPRM notifies PM of QUEUED status
        SPRM->>PM: Notify: instance QUEUED<br/>{instanceId, agentName}
        Note over PM: Start queuedRequestTimeout timer

        alt Timeout expires (or timeout = 0)
            PM->>SPRM: DELETE /api/v1/service-type-instances/{instanceId}
            Note over PM: Re-evaluate excluding current agent

            PM->>PE: evaluateRequest<br/>{resource, available_agents,<br/> exclude_agents: [agentName]}
            PE-->>PM: New selectedAgent or no match

            alt Alternative agent found
                PM->>SPRM: POST /api/v1/service-type-instances<br/>{newAgentName, serviceType, spec}
                SPRM-->>PM: 202 Accepted
            else No agent available
                PM-->>CM: Error: no agent available
            end
        end
    end
    deactivate PM
```

### 2b. Multi-resource DAG orchestration

Multiple resource orchestration with DAG compilation, policy loop with status
driven provisioning. Each SPRM create follows the same unit path as diagram 2a.

```mermaid
sequenceDiagram
    autonumber
    participant CM as Catalog
    participant PM as Placement
    participant DB as Control Plane DB
    participant AR as DCM Agent Registry
    participant PE as Policy
    participant SPRM as SP Resource Manager

    CM->>PM: CreateResources<br/>{catalogItemInstanceId, resources[]}
    activate PM

    PM->>PM: Build DAG (CEL + requiresResources)<br/>Detect circular deps, assign dagLevel
    alt Compile or DAG error
        PM-->>CM: 4xx compile error
        deactivate PM
    else Compile ok

        PM->>DB: Store intent<br/>{originalRequest}
        DB-->>PM: Intent stored

        PM->>AR: Fetch available agents<br/>(healthy, non-Congested)
        AR-->>PM: available_agents list

        loop each resource in graph
            PM->>PE: evaluateRequest<br/>{service_instance, available_agents}
            PE-->>PM: Validated/mutated payload<br/>{validatedPayload, selectedAgent}
        end

        alt Any resource denied
            PM-->>CM: Error response (policy rejection)
        else All resources pass

            PM->>DB: Persist per-resource rows<br/>(requires_resources, dagLevel,<br/>validated spec, agentName)

            loop each resource at dagLevel 0
                Note over PM,SPRM: SPRM create is the same<br/>unit of work as diagram 2a
                PM->>SPRM: POST /api/v1/service-type-instances<br/>{agentName, serviceType, spec}
                activate SPRM
                alt SPRM returns error
                    SPRM-->>PM: Error response
                    Note over PM: Tear down any provisioned<br/>level-0 resources
                    PM-->>CM: Error response
                else SPRM returns 202 Accepted
                    SPRM-->>PM: 202 Accepted<br/>{instanceId, agentName, status: PENDING}
                end
                deactivate SPRM
            end

            PM-->>CM: 202 Accepted<br/>{response payload}

            Note over SPRM,PM: dagLevel 1+ (async, after deps Running)

            SPRM->>DB: Update instance<br/>(status: Running, outputs)
            SPRM->>PM: OnResourceRunning (in-process)
            activate PM

            loop each resource at next dagLevel<br/>when all requires_resources Running
                PM->>PM: Bind dependency outputs into spec
                PM->>PE: validate/mutate payload
                Note over PM,SPRM: SPRM create is the same<br/>unit of work as diagram 2a
                PM->>SPRM: POST /api/v1/service-type-instances<br/>{agentName, spec}
                SPRM-->>PM: 202 Accepted
            end

            Note over PM: Repeat on each Running event<br/>until graph complete or failure
            deactivate PM
        end
    end
```
