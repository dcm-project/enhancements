---
title: service-type-definition
authors:
  - "@github-handle"
reviewers:
  - TBD
approvers:
  - TBD
creation-date: 2025-12-05
---

# Service Type Definition

This ADR defines provider-agnostic schemas for DCM service types. These schemas
enable Service Providers to provision four core service types—virtual machines,
containers, databases, and Kubernetes clusters—across different infrastructure
platforms without vendor lock-in.  
The key principle is _portability first_: schemas contain only minimal fields
common across all implementations, with platform-specific configuration
delegated to _providerHints_.

## Open Questions

<!--
Call out areas of the design that require closure before deciding to implement.
Example:
> 1. This requires exposing previously private resources. Can we do this?
-->

## Summary

This ADR defines provider-agnostic schemas for DCM service types. These schemas
enable Service Providers to provision four core service types—virtual machines,
containers, databases, and Kubernetes clusters—across different infrastructure
platforms without vendor lock-in.  
The key principle is _portability first_: schemas contain only minimal fields
common across all implementations, with platform-specific configuration
delegated to _providerHints_.

## Motivation

Define a generic schema structure that ensures portability across infrastructure
platforms while allowing extensibility for platform-specific optimizations
without breaking compatibility.

### Goals

- Define a generic schema that works for any serviceType, ensure portability,
  and allows extensibility without schema changes.
- Define an initial set four primary service types applying this pattern:
  - _VM_  
    Virtual machines with compute, storage, and OS specifications
  - _Container_  
    Containerized workloads running on any container platform
  - _Kubernetes Cluster_  
    Kubernetes Container Platform of any distribution (Kubernetes, OpenShift,
    EKS, AWS, GKE, etc.)
  - _Database_  
    Database services with various engines (PostgreSQL, MySQL, etc.)

### Non-Goals

- Allow runtime editability through API operations so administrators can create
  and modify templates without code changes
- Tooling to validate Service Provider compliance with catalog schemas
  (conformance test suites, reference implementations, automated validation
  frameworks)
- Migration strategies for breaking schema changes
- Provider-specific implementation details (each provider handles translation
  independently)
- Additional service types beyond VMs, containers, databases, and Kubernetes
  clusters (deferred to future phases)
- Standalone storage volumes or separately provisioned networks are _not_
  included. All storage (disk size, ephemeral allocation) and networking
  (interfaces, IPs, subnets, security groups) must be defined and bundled
  directly with the compute specification. Future iterations may decouple these
  services, but the current principle is monolithic definition for simplified
  deployment.

## Proposal

### Implementation Details/Notes/Constraints

## Generic Service

All service schemas share common fields defined once in
[common.yaml](https://github.com/gciavarrini/service-provider-api/blob/add-catalog-item/api/v1alpha1/common.yaml)

## Schema Structure

| Field         | Required | Type   | Description                                                                                                                       |
| :------------ | :------- | :----- | :-------------------------------------------------------------------------------------------------------------------------------- |
| kind          | Yes      | string | Service type identifier (_vm, database, etc._)                                                                                    |
| schemaVersion | Yes      | string | Schema version (e.g., _v1aplha1_)                                                                                                 |
| metadata      | Yes      | object | Service name (required) plus custom key-values pair for tagging (e.g., _labels: {environment: production, owner: platform-team}_) |
| providerHints | No       | object | Platform specific config (e.g., _"kubevirt: {instanceType: u1.large}", "vmware: {vmxVersion: 17}")_                               |

_providerHints_ is key to portability: providers use hints they recognize and
ignore the rest. This means catalog offering using only common fields (vcpu,
memory, guestOS) can be provisioned by any compatible provider. The
_providerHints_ section allows adding platform-specific optimizations: providers
use hints they recognize and silently ignore the rest, so the same catalog item
remains portable across platforms.

## Specific services

Any _serviceType_ can be defined by inheriting from
[common.yaml](https://github.com/gciavarrini/service-provider-api/blob/add-catalog-item/api/v1alpha1/common.yaml)
and adding type-specific fields. For the first milestone, we support the
following specific serviceTypes:

- Virtual Machine  
  Virtual machines with CPU, memory, storage, and OS specifications
- Container  
  Fields common to Kubernetes, Docker, Podman, Openshift, CRI-O, containerd
- Cluster  
  Fields common to Kubernetes, OpenShift, EKS, GKE, AKS, and other distributions
- Database  
  Fields common across all database types (SQL, NoSQL, search, time-series,
  etc.)

### Virtual Machine

The following sections detail the VM schema architecture.

```mermaid
flowchart TD
    classDef dbStyle text-align:center;
    classDef providerBox text-align:left;
    classDef note text-align:center;

    SC[("
    <div style='min-width: 350px; padding: 10px; line-height: 1;'>
        <div style='font-weight: bold; font-size: 16px; margin-bottom: 5px;'>Service Catalog</div>
        <div style='border: 1px solid; padding: 10px; text-align: left; font-family: monospace; font-size: 11px; margin-top: 0px;'>
    <b>Catalog Item</b><br/>
    {
    &quot;name&quot;: &quot;rhel9-medium&quot;,
    &quot;kind&quot;: &quot;vm&quot;,
    &quot;spec&quot;: {
        &quot;compute&quot;: { &quot;vcpu&quot;: 16, &quot;ram&quot;: 32 },
        &quot;guestOS&quot;: { &quot;type&quot;: &quot;rhel-9&quot; }
        }
    }
    </div>
</div>
    ")]:::dbStyle

    API[Service Provider API]

    subgraph SP [Service Provider]
        direction LR
        KV["<u>KubeVirt</u><br/>instancetype: o1.4xlarge"]:::providerBox
        VW["<u>VMware</u><br/>NumCPUs=16<br/>MemoryMB=32768"]:::providerBox
        OS["<u>OpenStack</u><br/>flavor lookup"]:::providerBox
        AWS["<u>AWS EC2</u><br/>c5.4xlarge"]:::providerBox
    end

    Note_Reg@{ shape: card, label: "During registration,<br>these providers<br>advertised that they<br>fulfill service type<br>&quot;vm&quot;" }
    Note_Trans@{ shape: card, label: "Each provider<br>translates the<br>catalog item to its<br>native resource<br>format" }

    SC --> API
    API --> SP

    Note_Reg -.- SP
    Note_Trans -.-> KV
    Note_Trans -.-> VW
    Note_Trans -.-> OS
    Note_Trans -.-> AWS

    class Note_Reg,Note_Trans note
```

#### Schema

For easier review, the schema is accessible here
[vmspec.yaml](https://github.com/gciavarrini/service-provider-api/blob/add-catalog-item/api/v1alpha1/vmspec.yaml)
.  
Plus common fields: _schemaVersion, metadata, providerHints_

| Field                      | Required | Type    | Description                                    |
| :------------------------- | :------- | :------ | :--------------------------------------------- |
| vcpu.count                 | No \*\*  | integer | Number of virtual CPUs                         |
| memroy.size                | No \*\*  | integer | Memory with unit                               |
| storage.disks\[\].name     | No       | string  | Disk identifier (e.g., _boot_, _data_)         |
| storage.disks\[\].capacity | No       | string  | Disk capacity with unit (e.g., _100GB, 2TB_)   |
| guestOS.type               | Yes      | string  | OS identifier (e.g., _rhel-9_, _ubuntu-22.04_) |
| access.sshPublicKey        | No       | string  | SSH public key for VM access (optional)        |

### Containers

The following sections detail the Container schema architecture.

#### Schema

For easier review, the schema is accessible here
[containerspec.yaml](https://github.com/gciavarrini/service-provider-api/blob/add-catalog-item/api/v1alpha1/containerspec.yaml).  
Plus
common fields: _schemaVersion, metadata, providerHints_

| Field                           | Required | Type    | Description                                                           |
| :------------------------------ | :------- | :------ | :-------------------------------------------------------------------- |
| image.reference                 | Yes      | string  | Container Image (e.g., "_quay.io/myapp:v1.2_")                        |
| resources.cpu.min               | No       | integer | Minimum guaranteed CPU                                                |
| resources.cpu.max               | No       | integer | Maximum guaranteed CPU                                                |
| resources.memory.min            | No       | integer | Minimum guaranteed memory with unit (e.g., _100GB, 2TB_)              |
| resources.memory.max            | No       | integer | Maximum allowed memory with unit (e.g., _100GB_, _1TB_)               |
| process.env\[\]                 | No       | array   | Environment variables (e.g., _{name: "DB_HOST", value: "localhost"}_) |
| network.ports\[\].containerPort | No       | integer | Ports to expose (e.g., _8080, 443_)                                   |

### Database

The following sections detail the Database schema architecture.

#### Schema

For easier review, the schema is accessible here
[databasespec.yaml](https://github.com/gciavarrini/service-provider-api/blob/add-catalog-item/api/v1alpha1/databasespec.yaml).  
Plus
common fields: schemaVersion, metadata, providerHints.

| Field             | Required | Type    | Description                                       |
| :---------------- | :------- | :------ | :------------------------------------------------ |
| engine            | Yes      | string  | Database type (e.g., _postgresql, elasticsearch_) |
| version           | No       | string  | Engine version (e.g., _15, 8.11_)                 |
| resources.cpu     | No       | integer | CPU cores                                         |
| resources.memory  | No       | string  | Memory in with unit (e.g., _100GB, 2TB_)          |
| resources.storage | No       | string  | Storage size with unit (e.g., _100GB, 2TB_)       |

### Kubernetes Cluster

The cluster schema works across all Kubernetes distributions: OpenShift, EKS,
GKE, AKS, etc.

#### Schema

For easier review, the schema is available here:
[clusterspec.yaml](https://github.com/gciavarrini/service-provider-api/blob/add-catalog-item/api/v1alpha1/clusterspec.yaml).  
Plus
common fields: schemaVersion, metadata, providerHints.

| Field                      | Required | Type    | Description                                                  |
| :------------------------- | :------- | :------ | :----------------------------------------------------------- |
| version                    | Yes      | string  | Kubernetes version (e.g., _1.29, 1.30_)                      |
| nodes.controlPlane.count   | No       | integer | Number of control plane nodes                                |
| nodes.controlPlane.cpu     | No       | integer | Number of CPU per control plane node                         |
| nodes.controlPlane.memory  | No       | string  | Memory with unit (e.g., _100GB, 2TB_) per control plane node |
| nodes.controlPlane.storage | No       | string  | Storage per control plane node (e.g., 120GB)                 |
| nodes.worker.count         | No       | integer | Number of worker nodes                                       |
| nodes.worker.cpu           | No       | integer | Number of CPU per worker node                                |
| nodes.worker.memory        | No       | integer | Memory with unit (e.g., _100GB, 2TB_) per worker node        |
| nodes.worker.storage       | No       | string  | Storage per worker node (e.g., 120GB)                        |

### Risks and Mitigations

TBD

## Design Details

TBD

### Upgrade / Downgrade Strategy

Schemas evolve over time as requirements change. Each catalog item carries a
_schemaVersion_ field that tells providers which translation logic to use. This
allows us to introduce new schema versions while maintaining backward
compatibility (this means that older catalog items continue working with their
original schema, newer items use enhanced versions). During transitions,
providers support multiple versions simultaneously.

## Implementation History

<!-- TBD -->

## Drawbacks

<!-- TBD -->

## Alternatives

### Comprehensive schemas with all platform features

**Description:** We considered including all possible fields (CPU topology,
security contexts, HA configuration, etc.) in the core schema.

**Why rejected:** Not all fields exist on all platforms. This would force
providers to handle features they don't support, or force users to understand
which fields work where. Portability would be compromised.

### Virtual Machine Alternatives

#### Pure OVF XML Format

**Description:** We considered using OVF XML directly as our catalog format.
This would provide perfect alignment with the standard but creates practical
problems. OVF XML is verbose with complex nested structures, XML namespaces, and
numeric resource type codes (3 for CPU, 4 for memory).

**Pros:** Perfect standard compliance, well-understood by virtualization teams

**Cons:** XML complexity, poor API ergonomics, includes packaging concepts
irrelevant to catalog specs

#### TOSCA Cloud Orchestration

**Description:** TOSCA (Topology and Orchestration Specification for Cloud
Applications) is an OASIS standard designed specifically for cloud resource
orchestration. It provides a comprehensive model with node templates,
capabilities, requirements, and relationship definitions. While powerful, TOSCA
introduces significant complexity with its topology-based approach. For a
catalog specification that describes individual resource templates, TOSCA's
relationship modeling and orchestration features are overkill.

**Pros:** Purpose-built for cloud, handles complex deployments

**Cons:** Steep learning curve, heavyweight for simple resource specs, less
tooling ecosystem

#### Custom Schema from Scratch

**Description:** We could design a completely custom schema without reference to
existing standards, optimizing purely for our immediate needs. This provides
maximum flexibility and simplicity initially but loses the benefit of industry
knowledge embedded in standards like OVF. Provider translation becomes harder
because engineers must learn our invented vocabulary rather than mapping to
familiar concepts they already know from OVF, OpenStack, or other systems.

**Pros:** Perfect fit for current needs, no standard overhead

**Cons:** Reinventing solved problems, harder provider adoption, no external
validation

#### OpenStack-Style Flavors

**Description:** OpenStack's approach separates compute templates (_flavors_)
from images. Users select a flavor (_m1.small, m1.medium_) and an image
separately. While simple, this creates a two-level hierarchy that feels
unnatural for a general catalog system. It also doesn't handle the full richness
of VM configuration, storage configuration, and network interfaces.
Initialization is handled separately rather than as part of a cohesive
specification.

**Pros:** Simple flavor model, proven in OpenStack

**Cons:** Limited to compute specs, doesn't handle full VM configuration,
creates artificial separation

### Container Alternatives

#### Kubernetes Pod Specification

**Description:** Using Kubernetes Pod/Deployment YAML directly as the catalog
format would provide immediate familiarity for Kubernetes users but creates
vendor lock-in.

**Pros:** Familiar to Kubernetes users, rich feature set, comprehensive
documentation, established ecosystem

**Cons:** Kubernetes-specific (incompatible with Docker/Podman standalone),
includes orchestration concepts unnecessary for resource specifications, ties
catalog to Kubernetes API versions, prevents portability to non-Kubernetes
platforms

#### Compose Specification

**Description:** The Compose Specification provides a YAML format for defining
multi-container applications, now an open specification supported by Docker,
Podman, and other runtimes.

**Pros:** Simple and approachable, widely known format, open specification, good
for multi-container applications

**Cons:** Designed for application composition not individual resource
specifications, doesn't map cleanly to single-container catalog items, less
granular than OCI for runtime configuration, focuses on orchestration rather
than resource provisioning

#### Containerfile Build Instructions

**Description:** Define containers through Dockerfile/Containerfile rather than
runtime specifications.

**Pros:** Reproducible builds, version control friendly, defines complete
container image

**Cons:** Build-time specification not runtime specification, requires build
infrastructure in catalog system, doesn't address runtime configuration
(resources, networking, security), mixes build concerns with deployment concerns

#### Custom Schema

**Description:** Design a container schema without reference to existing
standards like OCI, optimizing purely for DCM's immediate needs.

**Pros:** Optimized for DCM requirements, simpler for current use cases, no
standard overhead

**Cons:** Reinventing problems OCI already solved, harder provider adoption
(engineers learn new vocabulary instead of familiar OCI concepts), no external
validation, loses portability benefits, incompatible with existing container
tooling

### Database Alternatives

#### Single Cloud Provider Model

**Description:** Using AWS RDS, Azure Database, or Google Cloud SQL
specification directly as the catalog format.

**Pros:** Complete feature coverage, well-documented, proven in production

**Cons:** Vendor lock-in, cloud-specific terminology and features, doesn't work
with on-premise or Kubernetes-based databases, prevents multi-cloud portability

#### Kubernetes Operator CRD

**Description:** Using a specific Kubernetes database operator CRD
(CloudNativePG, Percona) as the standard.

**Pros:** Kubernetes-native, rich feature set, battle-tested

**Cons:** Kubernetes-specific, incompatible with cloud DBaaS providers, ties
catalog to specific operator versions, doesn't support VM-based database
deployments

#### SQL Standard Only

**Description:** Focus purely on SQL standards (ANSI SQL, SQL:2016) for database
specifications.

**Pros:** Well-established standard, vendor-neutral

**Cons:** Only covers query language not provisioning/infrastructure, no
coverage for NoSQL databases, doesn't address compute/storage/backup
configuration, mixes application concerns with infrastructure.

#### Custom Schema

**Description:** Design database schema without reference to existing patterns.

**Pros:** Optimized for DCM needs, simpler initially

**Cons:** Reinventing patterns cloud providers and operators already solved,
harder adoption, no external validation, incompatible with existing tooling and
knowledge

### Kubernetes Cluster Alternatives

#### Full install-config.yaml

**Description:** Using OpenShift's complete _install-config.yaml_ format as the
catalog schema.

**Pros:** Comprehensive coverage of all OpenShift deployment options, official
Red Hat format, well-documented

**Cons:** Platform-specific sections create complexity, includes infrastructure
credentials and bootstrapping details inappropriate for catalog specifications,
ties catalog to OpenShift installer API versions, verbose for users who just
want node sizing

#### Cluster API (CAPI) Specification

**Description:** Adopting Kubernetes Cluster API CRDs as the standard for all
cluster provisioning.

**Pros:** Kubernetes community standard, cloud-agnostic, supports multiple
platforms

**Cons:** Still maturing as a standard, OpenShift has its own established
patterns, CAPI abstractions don't always align with OpenShift's architecture,
requires CAPI operator infrastructure

#### Managed OpenShift Service APIs

**Description:** Using cloud provider managed OpenShift APIs (ROSA for AWS, ARO
for Azure) as the specification format.

**Pros:** Native to cloud providers, optimized for managed OpenShift services

**Cons:** Cloud-specific, incompatible with on-premise and self-managed
OpenShift deployments, each provider has different API structure, doesn't work
with standard OpenShift IPI/UPI installations, prevents portability to vSphere
or bare metal

#### Custom Cluster Schema

**Description:** Design a cluster schema without reference to existing standards
or patterns.

**Pros:** Optimized for DCM requirements, simpler for current use cases

**Cons:** Ignores established OpenShift configuration patterns, harder for users
familiar with install-config.yaml, no validation against industry knowledge,
incompatible with existing automation and tooling

## Infrastructure Needed

TBD
