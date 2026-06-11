# RHSI PostgreSQL Demo - Component Overview

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────┐
│ OpenShift Cluster                                            │
│                                                              │
│  ┌────────────────────────────────────────────────────┐     │
│  │ Namespace: rhsi-v2-demo                            │     │
│  │                                                    │     │
│  │  ┌──────────────┐      ┌────────────────┐        │     │
│  │  │ postgres-    │─────>│ Service:       │        │     │
│  │  │ client       │      │ postgres       │        │     │
│  │  │ (Test Pod)   │      │ (ClusterIP)    │        │     │
│  │  │              │      │ Port: 5432     │        │     │
│  │  │ Connects to: │      └───────┬────────┘        │     │
│  │  │ postgres:5432│              │                 │     │
│  │  └──────────────┘              │                 │     │
│  │                                │                 │     │
│  │                                ▼                 │     │
│  │                    ┌──────────────────┐          │     │
│  │                    │ Endpoints:       │          │     │
│  │                    │ postgres         │          │     │
│  │                    │ <pod-ip>:1024    │          │     │
│  │                    └────────┬─────────┘          │     │
│  │                             │                    │     │
│  │                             ▼                    │     │
│  │          ┌────────────────────────────────┐     │     │
│  │          │ skupper-router-<hash>          │     │     │
│  │          │ (2 containers)                 │     │     │
│  │          │ - router                       │     │     │
│  │          │ - controller                   │     │     │
│  │          │                                │     │     │
│  │          │ Listener:                      │     │     │
│  │          │   routing-key=postgres         │     │     │
│  │          │   Port 1024 → AMQP tunnel      │     │     │
│  │          └──────────────┬─────────────────┘     │     │
│  └─────────────────────────┼───────────────────────┘     │
│                            │                             │
│  ┌─────────────────────────┼───────────────────────┐     │
│  │ OpenShift Routes        │                       │     │
│  │ (Ingress)               │                       │     │
│  │                                                 │     │
│  │  • skupper-router-inter-router-rhsi-v2-demo   │     │
│  │    .apps.<cluster-domain>                      │     │
│  │    (Port 443 → 55671, TLS passthrough)         │     │
│  │                                                 │     │
│  │  • skupper-router-edge-rhsi-v2-demo            │     │
│  │    .apps.<cluster-domain>                      │     │
│  │    (Port 443 → 45671, TLS passthrough)         │     │
│  └──────────────────┬──────────────────────────────┘     │
└─────────────────────┼────────────────────────────────────┘
                      │
                      │ Internet
                      │ (TLS/AMQP connection initiated
                      │  FROM external host TO OpenShift)
                      │
                      ▼
┌──────────────────────────────────────────────────────────────┐
│ External Linux Host (Raspberry Pi / VM / etc.)               │
│                                                              │
│  ┌────────────────────────────────────────────────────┐     │
│  │ Podman Containers (rootless)                       │     │
│  │                                                    │     │
│  │  ┌──────────────────────────────────────┐         │     │
│  │  │ skupper-router                       │         │     │
│  │  │ - Connects TO OpenShift route        │         │     │
│  │  │ - Connector: routing-key=postgres    │         │     │
│  │  │ - Forwards to 127.0.0.1:5432         │         │     │
│  │  └──────────────────────────────────────┘         │     │
│  │                                                    │     │
│  │  ┌──────────────────────────────────────┐         │     │
│  │  │ skupper-controller-podman            │         │     │
│  │  │ - Manages podman site lifecycle      │         │     │
│  │  └──────────────────────────────────────┘         │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│                      │                                       │
│                      ▼                                       │
│  ┌────────────────────────────────────────────────────┐     │
│  │ PostgreSQL 15 (Native Process)                     │     │
│  │                                                    │     │
│  │ Listening: 127.0.0.1:5432                          │     │
│  │ Database: demodb                                   │     │
│  │ User: demouser / Password: demopass                │     │
│  │                                                    │     │
│  │ demo_data table:                                   │     │
│  │   1 | Hello from Raspberry Pi!                    │     │
│  │   2 | Skupper makes networking easy               │     │
│  │   3 | No egress IP needed!                        │     │
│  └────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

## Data Flow (PostgreSQL Query)

1. **Application Request** (OpenShift):
   - Pod `postgres-client` runs: `psql -h postgres -p 5432`
   - DNS resolves `postgres` → Service ClusterIP

2. **Service Routing** (OpenShift):
   - Service `postgres` routes to skupper-router pod endpoint (port 1024)
   - Endpoint is dynamically managed by RHSI

3. **RHSI Routing Layer** (OpenShift):
   - skupper-router receives TCP on port 1024
   - Matches routing-key `postgres` (listener configuration)
   - Encapsulates TCP over AMQP protocol
   - Sends through established AMQP link to external host

4. **AMQP Link** (Internet):
   - TLS-encrypted AMQP connection
   - Initiated FROM external host TO OpenShift (inbound to cluster)
   - Uses OpenShift route: `skupper-router-inter-router-rhsi-v2-demo.apps.<cluster-domain>`
   - Certificate-based authentication (not IP-based)

5. **RHSI Decapsulation** (External Host):
   - skupper-router container receives AMQP message
   - Matches routing-key `postgres` (connector configuration)
   - Decapsulates TCP from AMQP
   - Forwards to configured host: `127.0.0.1:5432`

6. **PostgreSQL Response** (External Host):
   - PostgreSQL receives query on localhost:5432
   - Authenticates user `demouser` (scram-sha-256)
   - Executes query on `demodb.demo_data`
   - Returns result rows

7. **Return Path**:
   - Response flows back through same AMQP tunnel
   - skupper-router (external) → AMQP → skupper-router (OCP)
   - skupper-router (OCP) → TCP:1024 → Service → Pod
   - Application receives PostgreSQL result set

## Key Components

### OpenShift
- **Operator**: Red Hat Service Interconnect v2.1+ (skupper-operator)
- **Site**: RHSI site with link access enabled
- **Router Pod**: skupper-router (2 containers: router + controller)
- **Service**: `postgres` (ClusterIP, port 5432)
- **Listener**: postgres (routing-key=postgres, points to service)
- **Routes**: Inter-router and edge routes for external connectivity

### External Linux Host
- **Skupper CLI**: v2.2+ compatible with RHSI v2
- **Site**: RHSI site in podman mode
- **Containers**: skupper-router, skupper-controller-podman
- **PostgreSQL**: Native process listening on 127.0.0.1:5432
- **Connector**: postgres (routing-key=postgres, host=127.0.0.1:5432)
- **Link**: TLS connection TO OpenShift cluster

## Security Model

**Traditional Egress IP:**
- Requires firewall rule: `allow from <EgressIP> to PostgreSQL-IP:5432`
- Security based on source IP address
- Requires cluster admin to allocate EgressIP
- Requires network admin to configure firewall

**RHSI Approach:**
- PostgreSQL NOT exposed to internet
- External host initiates connection INTO cluster (inbound only)
- Security via TLS certificate validation
- OpenShift NetworkPolicy controls which ServiceAccounts can access `postgres` service
- No firewall configuration required
- No egress IP allocation required

## How This Solves the EgressIP Problem

**The Problem**: Applications need to connect to external databases that use IP-based firewall rules. Traditional solutions require:
1. Allocating static EgressIP addresses
2. Configuring firewall rules on the database side
3. Cluster admin permissions
4. Network admin coordination

**The RHSI Solution**: 
1. External database host connects INTO the cluster (no egress needed)
2. Certificate-based authentication (no IP whitelisting)
3. Application uses normal service name (`postgres:5432`)
4. Works without cluster admin or network admin involvement
5. More secure (certificate validation vs IP filtering)

## Routing Key Matching

The routing-key is how RHSI connects listeners to connectors across sites:

- **Listener** (OpenShift): Creates a Kubernetes Service with routing-key `postgres`
- **Connector** (External Host): Exposes local PostgreSQL with routing-key `postgres`
- **Match**: When keys match, traffic flows bidirectionally through AMQP tunnel

This is similar to pub/sub messaging - the routing-key is the topic name.

## Verified Working

✓ PostgreSQL running natively on external host (not containerized)  
✓ Skupper v2 routers connected via AMQP  
✓ Routing-key matching (connector ↔ listener)  
✓ TCP adaptation working (v2.x fixed v1.9.x bugs)  
✓ Application can query database through service name  
✓ No egress IP configured  
✓ No firewall rules required  
✓ Connection initiated from external host TO cluster (inbound)

## Test Results

```bash
# From OpenShift postgres-client pod:
PGPASSWORD=demopass psql -h postgres -p 5432 -U demouser -d demodb -c "SELECT * FROM demo_data;"

# Result:
 id |            message            |        created_at         
----+-------------------------------+---------------------------
  1 | Hello from Raspberry Pi!      | 2026-06-11 14:55:24.10867
  2 | Skupper makes networking easy | 2026-06-11 14:55:24.10867
  3 | No egress IP needed!          | 2026-06-11 14:55:24.10867
(3 rows)

✓ SUCCESS! Connected to PostgreSQL via RHSI!
```

## Production Considerations

1. **Certificates**: RHSI auto-generates certificates, but production should use proper PKI
2. **Passwords**: Replace demo credentials with secrets management (Vault, etc.)
3. **PostgreSQL TLS**: Enable SSL/TLS on PostgreSQL itself
4. **NetworkPolicies**: Restrict which pods can access the postgres service
5. **Monitoring**: Enable RHSI metrics for observability
6. **High Availability**: Deploy multiple router replicas for resilience
