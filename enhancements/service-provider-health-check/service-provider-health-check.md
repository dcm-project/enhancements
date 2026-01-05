---
title: Service Provider Health Check
authors:
  - "@machacekondra"
reviewers:
  - "@gciavarrini"
  - "@ygalblum"
  - "@jubah"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"
  - "@gabriel-farache"
approvers:
  - ""
creation-date: 2025-12-15
---

# Service Provider Health Check

## Summary
This enhancement proposes a mechanism for the DCM control plane to actively monitor the health of service providers. Instead of providers pushing heartbeats, the DCM control plane will poll a `/health` endpoint on the service provider to verify liveness.

## Motivation
Define the DCM control plane way to determine if a service provider is accessible. Without an active check, the control plane might attempt to schedule services on providers that are down.

### Goals
* Implement a polling mechanism where DCM checks provider health.
* Define a standard `/health` endpoint for all Service Providers.

### Non-Goals
* Status reporting of individual services running *on* the provider.
* Deep provider diagnostics (out of scope for liveness check).
* Ensure DCM excludes "Unhealthy" or "Unreachable" providers from scheduling.

## Proposal

### Overview
The DCM Control Plane will act as the "prober." It will maintain a list of registered service providers URLs. At a configurable interval, DCM will perform an HTTP GET request to the provider's `/health` endpoint.

### Architecture

1.  **Health Polling (High Frequency):**
    * **Initiator:** DCM Control Plane.
    * **Target:** Service Provider `/health` endpoint.
    * **Frequency:** Every 10 seconds (default).
    * **Success Criteria:** HTTP 200 OK.

2.  **Resource Synchronization (Low Frequency/On-Demand):**
    * **Note:** Detailed resource data (CPU/Memory) continues to be handled via the Provider Info API, but the "Ready" state is governed by the Health Check results.

### Health Check Flow

1.  **DCM Controller:** Iterates through the list of active providers in the database.
2.  **Probing:** For each provider, DCM executes: `GET http://<provider-ip>:<port>/health`.
3.  **State Machine:**
    * **Success:** If response is `200 OK`, reset failure counter and mark as `Ready`.
    * **Failure:** If timeout or non-200 response, increment failure counter.
    * **Threshold:** If failures exceed the `FailureThreshold` (default: 3), transition provider to `NotReady`.
4.  **Recovery:** A single successful `200 OK` transitions a `NotReady` provider back to `Ready`.

## Design Details

### Service Provider Implementation

The Service Provider must expose a lightweight unauthenticated (or internally secured) endpoint.

#### Health Endpoint

**Endpoint:** `GET /health`

**Expected Response:**
* **Code:** `200 OK`
* **Body:** (Optional) 
```json
{
  "status": "pass",
  "version": "v1.2.3",
  "uptime": 3600
}