---
title: kubevirt-sp
authors:
  - "@jenniferubah"
reviewers:
  - "@gciavarrini"
  - "@machacekondra"
  - "@ygalblum"
  - "@croadfel"
  - "@flocati"
  - "@pkliczewski"
  - "@gabriel-farache"
creation-date: 2025-12-15
---

# KubeVirt Service Provider

## Summary

The KubeVirt Service Provider API is a REST API that manages Virtual Machines
(VMs) in a Kubernetes cluster running KubeVirt. It exposes endpoints for
creating, reading and deleting VMs, and integrates with the DCM Service Provider
Registry.

## Motivation

### Goals

- Define the lifecycle of an SP running KubeVirt.
- Implement registration flow with SP API.
- Implement Create, Read and Delete endpoints for managing VMs
  running on a cluster.  
  **Note** Update is out of scope for the first version (v1).
- Implement status reporting for DCM requests.

### Non-Goals

- Implement endpoints for day 2 operations (stop, start and restart) a virtual
  machine instance.
- Mechanism for retrieving available computing, storage, etc., information from
  the SP infrastructure.
- Deployment for the KubeVirt SP API.

## Proposal

##### Assumptions

- The KubeVirt Service Provider API is connected to a Kubernetes cluster (OCP,
  KIND, Minikube) with KubeVirt installed.
- The KubeVirt Service Provider API should have the necessary permissions to
  either an entire cluster or a limited set of namespaces to create and manage
  VirtualMachine resources.
- The DCM Service Provider Registry is reachable for registration.
- The API service has valid Kubernetes credentials (kubeconfig or in-cluster
  service account).
- DCM status reporting endpoint is reachable for resource updates.
- DCM provider heartbeat endpoint is reachable for health updates.

##### Integration Points

###### KubeVirt Integration

- Uses kubevirt.io/client-go to interact with KubeVirt.
- Creates and manages VirtualMachine Custom Resources.
- Leverages KubeVirt's VM lifecycle management.

###### DCM SP Registry

- Auto-registration on startup with DCM SP Registrar.
- Metadata includes zone, region, and total availability of resources.

###### DCM Provider Status Heartbeat

- Periodically send heartbeat information (as designed in SP Heartbeat ADR) to DCM to
  indicate it (KubeVirt SP) is alive.
- Send updates about current resource availability.
- Send heartbeat to DCM endpoint `PUT /providers/{providerId}/status` with payload
  request conforming to schema defined in DCM API schema.

###### DCM SP Status Reporting

- Send status for virtual machine instance to DCM endpoint
  `/instances/{instanceId}/status`.
- Use a watcher loop to monitor VMI events.

##### Registration Flow
KubeVirt SP API must successfully complete a registration process to ensure
DCM is aware of it and can use it. During startup, the service uses the DCM
registration client to send a request to the SP API registration endpoint:
`PUT /service/{serviceType}/provider`. See DCM registration client library for more
information.

Example of request payload.

```golang
dcm "github.com/dcm-project/service-provider-api/pkg/registration/client"
...
request := &dcm.RegistrationRequest{
    Name: "kubevirt-sp",
    ServiceType: "vm",
    DisplayName: "Kubevirt Service Provider",
    Endpoint:  fmt.Sprintf("%s/api/v1/vm", apiHost),
    Metadata: dcm.Metadata{
      Zone:   "us-east-1b",
      Region: "us-east-1",
      Resources: dcm.ProviderResources{
          TotalCpu: "200",
          TotalMemory: "2TB",
          TotalStorage: "100TB"
      }
    },
    Operations: []string{"CREATE", "DELETE", "READ"},
}
```

**Note**: The registration payload above is not concluded and may change.

###### Registration Process

- API performs self-registration at startup.
- API server starts and initializes HTTP listener.
- After the server is ready, registration runs in a background goroutine.
- The service constructs the API host URL from the listener address or
  configuration.
- Registration request is sent to the DCM Service Provider Registry.
- On success, the service is registered and available for DCM to use.
- Registration failures are retried with exponential backoff and logged but do
  not block server startup. Alternatively, SP can fall back to manual
  registration.

##### API Endpoints

The CRUD endpoints are consumed by the DCM SP API to create and manage virtual
machine resources.

###### Endpoints Overview

| Method | Endpoint                | Description                        |
| ------ | ----------------------- |------------------------------------|
| POST   | /api/v1/vm              | Create a new virtual machine       |
| GET    | /api/v1/vm              | List all virtual machines          |
| GET    | /api/v1/vm/{vmId}       | Get a virtual machine instance     |
| DELETE | /api/v1/vm/{vmId}       | Delete a virtual machine instance  |
| GET    | /api/v1/health          | KubeVirt API service health check  |

###### AEP Compliance

These endpoints are defined based on AEP standards and use aep-openapi-linter to
check for compliance with AEP.

**POST /api/v1/vm - Create a virtual machine.**

The POST endpoint follows the contract defined in the VM schema spec pre-defined
by DCM core. During creation of the resources, each virtual machine must be
labelled with _managed-by=dcm,dcm-instance-id=vmId_.

Example payload

```json
{
  "memory": { "size": "2GB" },
  "vcpu": { "count": 2 },
  "guestOS": { "type": "fedora-39" },
  "access":
    { "sshPublicKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample..." },
  "metadata": { "name": "fedora-vm" },
  "schemaVersion": "v1alpha1",
  "serviceType": "vm"
}
```

Response Payload: Returns 201 with payload and sets the status to **PROVISIONING**
after it is created.

```json
{
  "id": "123e4567-e89b-12d3-a456-426614174000",
  "name": "web-frontend",
  "namespace": "web-frontend-001",
  "status": "PROVISIONING"
}
```

**GET /api/v1/vm - List all virtual machines.**

- Handler receives GET request.
- Calls ListVMsFromCluster()
- Returns basic info: Request ID, Name, Namespace, Status
- Response: Array of VMInstance objects (minimal data)

Example payload

```json
[
  {
    "name": "web-frontend",
    "namespace": "web-frontend-001",
    "requestId": "696511df-1fcb-4f66-8ad5-aeb828f383a0",
    "status": "PROVISIONING"
  },
  {
    "name": "fedora-webserver",
    "namespace": "fedora-webserver-001",
    "requestId": "c66be104-eea3-4246-975c-e6cc9b32d74d",
    "status": "FAILED"
  },
  {
    "name": "ubuntu-vm",
    "namespace": "ubuntu-vm-001",
    "requestId": "08aa81d1-a0d2-4d5f-a4df-b80addf07781",
    "status": "PROVISIONING"
  }
]
```

**GET /api/v1/vm/{vmId}- Get Specific VM**

- Handler receives GET request with _vmId_ path parameter  
  Calls GetVMFromCluster(_vmId_)
- Cluster lookup:  
  Query KubeVirt API for VirtualMachine with matching
  `dcm-instance-id` label
- VMI details:  
  Query VirtualMachineInstance for runtime info  
  Extract IP address from network interfaces   
  Extract current phase (Running, Stopped, etc.)
- SSH configuration:  
  Check VM spec for SSH access credentials   
  Extract hostname from cloud-init user data   
  Query NodePort service for external SSH access  
  Build cluster SSH command and NodePort connection details
- Response payload:   
  Return complete VMInstance object

Example payload

```json
  {
    "name": "fedora-vm",
    "namespace": "fedora-vm-001",
    "status": "RUNNING",
    "ip": "10.244.0.12",
    "ssh":
      {
        "enabled": true,
        "username": "fedora",
        "secretName": "my-fedora-vm-ssh",
        "connectMethods":
          {
            "clusterSSH": "ssh fedora@10.244.0.12",
            "nodePort": { "node": "192.168.0.10", "port": 32222 }
          }
      }
  }
```

**Note**: In the example payload above, ssh is configured with nodeport.

**DELETE /api/v1/vm/{vmId}**

Remove a single virtual machine instance and returns 204 (No Content)

##### Status Reporting To DCM

Following the design and recommendation in the DCM status reporting ADR, the
VMStatusSyncService within KubeVirt SP implements a watcher loop that uses
Kubernetes watch APIs to stream VMI events per VM instance and update DCM in
real time. These resources must be labeled with
`managed-by=dcm,dcm-instance-id=vmId` during creation to enable filtering.

VM Status Update Flow - Using Informer

###### Setup Phase:
* Create a single SharedIndexInformer for VirtualMachineInstances
* Add a custom indexer for `dcm-instance-i` labels for fast lookups
* Register event handlers - AddVMI(), UpdateVMI(), DeleteVMI()
* Start the informer in a background goroutine
* Initial list - fetch all VMIs from the cluster (one API call)
* Establish a single watch connection for all VMIs
* Wait for cache sync before processing events

###### Event Processing Flow
* Watch receives a VMI event (Added/Updated/Delete)
* Informer updates the local cache (thread-safe)
* Handler extracts `dcm-instance-id` from VMI labels
* Map VMI phase to DCM status (Scheduled → Provisioning, etc.)
* Send status update to DCM status endpoint `/instances/{instanceId}/status`.

###### Periodic Resync
* Resync periodically - every 10 minutes
* Automatic reconnection (with exponential backoff) on disconnect
* Cache indexed queries (no API calls needed)

###### Pros
* Single shared watch connection (scales better)
* Local cache for fast queries (no API calls)
* Automatic reconnection with exponential backoff
* Periodic resync for consistency
* Faster startup
* Lower API server load (one connection)
* Good for large scale (> 100 VMs)
* Indexed queries (e.g., by `dcm-instance-id`)
* Handles missed events via resync

###### Cons
* Higher memory usage (caches all VMIs)
* More complex setup (indexers, handlers)
* Receives all VMI events (filter in handlers)
* Slightly high latency (cache + handler overhead)
* Requires understanding of cache/indexers
* More code to maintain
* Cache can become stale if not properly synced
* Overkill for small scale ( <50 VMs)


**Note**: The implementation of the status report flow will
be updated (in v2) to Event driven architecture following the design
in the updated version of the Status reporting ADR.

###### Alternative/Rejected
VM Status Update Flow - Using Watch Loop
* Spawns a goroutine to run a watcher per VM instance.
* Context cancellation will stop all watchers.
* Each VM instance has its own watcher loop, hence monitored independently.
* Process VM instance event
* Map VMI phase to DCM status

###### Pros
* Simple implementation
* Lower memory usage (no cache)
* Direct event stream (minimal latency)
* API-level filtering (label selector)
* Only receives relevant events
* Easy to understand and debug
* Less code to maintain
* No cache synchronization needed
* Good for small scale (< 50 VMs)
* Per-VM isolation (one failure doesn't affect others)

###### Cons
* Multiple connections (N VMs = N connections)
* No local cache (queries require API calls)
* Manual reconnection logic needed
* Slower startup
* Higher API server load
* No automatic resync
* Can miss events on disconnect
* Doesn't scale well (> 100 VMs)

##### Status Mapping from DCM to KubeVirt
This maps the DCM generic status to the lifecycle phase within 
the VMI status. See Status reporting ADR for more information.

| DCM          | KubeVirt                       | Description                    |
|--------------|--------------------------------|--------------------------------|
| PROVISIONING | Pending, Scheduling, Scheduled | VMI is in a provisioning state |
| RUNNING      | Running                        | VMI is in a running state      |
| STOPPING     | Succeeded                      | VMI is in a stopped state      |
| FAILED       | Failed                         | VMI is in a failed state       |
| FAILED       | Unknown                        | VMI is in an unknown state     |
| DELETED      | N/A                            | VMI & VM spec are not found    |

See 
[KubeVirt VMI Phase](https://github.com/kubevirt/kubevirt/blob/main/staging/src/kubevirt.io/api/core/v1/types.go#L1086) 
definitions.

## Infrastructure Needed
TBD
