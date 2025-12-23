---
title: Service Provider Health Check
authors:
  - "@machacekondra"
reviewers:
  - @gciavarrini
  - @ygalblum
  - @jubah
  - @croadfel
  - @flocati
  - @pkliczewski
  - @gabriel-farache
approvers:
  - ""
creation-date: 2025-12-15
last-updated: 2025-12-15
---

# Service Provider Health Check

## Summary
This enhancement proposes a mechanism for the DCM control plane to actively monitor the liveness of service providers. By implementing a heartbeat system similar to Kubernetes node health checks, DCM can ensure services are only placed on active and healthy providers.

## Motivation

Currently, the DCM control plane lacks a reliable way to determine if a service provider is accessible. Without a heartbeat mechanism, the control plane cannot distinguish between a provider that is idle and one that has crashed or lost network connectivity. This can lead to service placement failures.

### Goals

* Define a solution for DCM to detect if a service provider is alive.
* Ensure DCM can reliably verify a provider is ready to accept services before placement.

### Non-Goals

* Status reporting of the actual services running *on* the provider (only the provider level health is in scope).

## Proposal

### Overview

The proposed solution reuses the concept of node health checks from Kubernetes. We introduce a "Provider Health Check" which serves as a heartbeat mechanism. This allows the DCM control plane to know if a service provider is alive, healthy, and ready to accept services.

### Architecture

The architecture relies on a **Dual-Heartbeat Mechanism** to optimize for bandwidth and scalability.

1.  **Liveness Heartbeat (High Frequency):**
    * **Purpose:** Simply confirms "I am alive."
    * **Frequency:** Every 10 seconds (configurable).
    * **Payload:** Minimal status.

2.  **Provider Info Update (Low Frequency):**
    * **Purpose:** Provides comprehensive resource data (CPU, Memory, Capabilities).
    * **Frequency:** Every 5 minutes, or immediately upon configuration change.
    * **Payload:** Full resource details.

### Heartbeat Flow

1.  **Provider Side:** A process within the service provider calculates its status and sends it to the DCM Provider API.
    * *Reliability:* If the request fails, the provider uses exponential backoff to retry.
2.  **Control Plane Side:** The DCM Provider API receives the heartbeat and updates the status in the internal database.
3.  **Placement Logic:** The control plane monitors a configurable Failure Threshold (defaulting to 3 missed heartbeats); if this threshold is exceeded, the provider is transitioned to a NotReady state and strictly excluded from the scheduling pool until a successful heartbeat is received.

## Design Details

### API Definition

#### Liveness Heartbeat API

**Endpoint:** `PUT /providers/{providerName}/status`

**Summary:** Report Provider Heartbeat. Updates the liveness status of a specific provider.

* **Frequency:** Clients should send this every 10 seconds.
* **Optimization:** Heavy resource data should only be included if it has changed.

#### Request Parameters

| Name | In | Type | Required | Description |
| :--- | :--- | :--- | :--- | :--- |
| `providerName` | path | string | Yes | The unique name of the provider. |

#### Request Body (`HeartbeatPayload`)

Content-Type: `application/json`

```json
{
  "timestamp": "2025-12-16T10:00:00Z",
  "phase": "Ready"
}
```

* **timestamp** (string, date-time): Current time on the provider.
* **phase** (string): High-level lifecycle state (e.g., "Ready").

Response: 
```json
{
  "next_interval_seconds": 10
}
```

* **next_interval_seconds**: Control plane instruction to speed up or slow down heartbeats.

#### Provider Info Update API

**Endpoint:** `PATCH /providers/{providerName}/resources`

**Summary:** Update Provider Resource Specifications. This provides a comprehensive update of the provider's hardware and software capabilities.

* **Frequency:** Clients should send this every 5 minutes, or immediately when a significant hardware/configuration change occurs.
* **Optimization:** Uses a PATCH method to allow for partial updates of specific resource fields without re-sending the entire provider object.

#### Request Parameters

| Name | In | Type | Required | Description |
| :--- | :--- | :--- | :--- | :--- |
| `providerName` | path | string | Yes | The unique name of the provider. |

#### Request Body (`HeartbeatPayload`)

Content-Type: `application/json`

```json
{
  "timestamp": "2025-12-16T10:00:00Z",
  "capacity": {
    "memory": 1024,
  },
}
```

* **timestamp** (string, date-time): Current time on the provider.
* **capacity** (object): Total hardware resources physically present on the node.

Response:
```json
{
    "last_synced_at": "2025-12-16T10:00:05Z"
}
```
