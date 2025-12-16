---
title: Service Provider Status Report Implementation
authors:
  - "@machacekondra"
reviewers:
  - gciavarrini
  - ygalblum
  - jubah
  - croadfel
  - flocati
  - pkliczewski
  - gabriel-farache
approvers:
  - ""
creation-date: 2025-12-15
last-updated: 2025-12-15
---

# Service Provider Status Report Implementation

## Summary

This proposal defines the architectural patterns and implementation guidelines for how a Service Provider captures the state of underlying resources (e.g., VMs, Containers) and reports it back to the DCM Control Plane. It establishes **Pattern A (Streaming)** as the standard and **Pattern B (Polling)** as a legacy fallback.

## Motivation

The DCM relies on Service Providers to be the "source of truth" for service state. However, underlying platforms (like AWS, vSphere, or Kubernetes) expose this state differently. Some offer real-time event streams (Kubernetes Watches), while others only offer snapshot APIs (GET requests).

To ensure scalability and prevent API exhaustion on both the DCM and the underlying platform, implementation patterns are be defined.

### Goals

* Define the architectural patterns and implementation guidelines for capturing the state of underlying resources.
* Standardize how state is reported back to the DCM Control Plane.
* Ensure implementation scalability regarding API limits and latency.

### Non-Goals

* Defining a protocol to report the state to DCM.
* Defining the internal health monitoring of the Service Provider itself.

## Proposed Architecture

We define two patterns for status reporting. **Pattern A (Streaming)** is the mandatory standard for any platform that supports it. **Pattern B (Polling)** is a fallback restricted to legacy platforms.

### Pattern A: Event-Driven Streaming (Preferred)

**Applicability:** Kubernetes-based platforms (CNV), modern Clouds with EventBridge/Webhooks.

In this model, the Service Provider establishes a persistent connection to the underlying platform's event stream. It reacts only when a relevant event occurs.

#### Workflow

1.  **Label Filtering:** The Provider watches only resources containing specific identification labels (e.g., `managed-by=dcm`, `dcm-instance-id=<uuid>`).
2.  **The Watch Loop:** The Provider maintains a resilient "Informer" or "Watch" loop. If the connection drops, it performs a re-list and resumes watching to ensure no events were missed.
3.  **Push to DCM:** The Provider send event using CloudEvents using message system.

#### Requirements for Implementation

2.  **Provider support:** The Provider must support streaming.

#### Benefits

* **Low Latency:** DCM is updated milliseconds after the change occurs.
* **Low Overhead:** No wasted CPU cycles or network bandwidth checking unchanged resources.

### Pattern B: Polling

**Applicability:** Legacy APIs, simple REST-only platforms.

In this model, the Service Provider periodically queries the underlying platform for the status of specific resources.

#### Workflow

1.  **Label Filtering:** The Provider poll only resources containing specific identification labels (e.g., `managed-by=dcm`, `dcm-instance-id=<uuid>`).
2.  **Change detection:** The Provider check if the resource/state has changed.
3.  **Push to DCM:** The Provider send event using CloudEvents using message system.


#### Requirements for Implementation

1.  **Adaptive Interval:** Polling must not happen more frequently than every `X` seconds (e.g., 10s).
2.  **Change Detection:** The Provider must cache the previous state internally. It must only call the DCM API if the new poll result differs from the cache.

## Design Details

### Reference Implementation: CNV (KubeVirt)

Since CNV (Container Native Virtualization) is built on Kubernetes, it must use **Pattern A (Streaming)**.

#### The Event Handler

The logic flows as follows:

1.  **Event Detected:** The KubeVirt API server pushes an `Update` event to the Service Provider.
2.  **ID Extraction:** The handler parses the VMI spec to find the `dcm-instance-id` annotation/label.
3.  **Call Status API:** The provider formats the payload and send CloudEvent to message system server.
