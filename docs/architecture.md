# RHSI PostgreSQL Demo - Component Overview

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ OpenShift Cluster (apps.prime.davecore.xyz)                     │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Namespace: rhsi-v2-demo                                 │    │
│  │                                                         │    │
│  │  ┌──────────────────┐         ┌──────────────────┐    │    │
│  │  │ postgres-client  │────────▶│ Service: postgres│    │    │
│  │  │ (Test Pod)       │         │ (ClusterIP)      │    │    │
│  │  │                  │         │ 172.30.82.114    │    │    │
│  │  │ Connects to:     │         │ Port: 5432       │    │    │
│  │  │ postgres:5432    │         └─────────┬────────┘    │    │
│  │  └──────────────────┘                   │             │    │
│  │                                          │             │    │
│  │                                          ▼             │    │
│  │                            ┌──────────────────────┐   │    │
│  │                            │ Endpoints: postgres  │   │    │
│  │                            │ 10.128.0.110:1024   │   │    │
│  │                            └──────────┬───────────┘   │    │
│  │                                       │               │    │
│  │                                       ▼               │    │
│  │              ┌─────────────────────────────────────┐ │    │
│  │              │ skupper-router-7667dbb47f-5v5gq     │ │    │
│  │              │ (2 containers: router + controller) │ │    │
│  │              │                                      │ │    │
│  │              │ Pod IP: 10.128.0.110                │ │    │
│  │              │ Listener: routing-key=postgres      │ │    │
│  │              │ Port 1024 → AMQP tunnel to Pi      │ │    │
│  │              └──────────────────┬──────────────────┘ │    │
│  └──────────────────────────────────┼────────────────────┘    │
│                                     │                          │
│  ┌──────────────────────────────────┼────────────────────┐    │
│  │ OpenShift Routes (Ingress)       │                    │    │
│  │                                  │                    │    │
│  │  ▪ skupper-router-inter-router-rhsi-v2-demo          │    │
│  │    .apps.prime.davecore.xyz                           │    │
│  │    (Port 443 → 55671, TLS passthrough)               │    │
│  │                                                       │    │
│  │  ▪ skupper-router-edge-rhsi-v2-demo                  │    │
│  │    .apps.prime.davecore.xyz                           │    │
│  │    (Port 443 → 45671, TLS passthrough)               │    │
│  └────────────────────────┬──────────────────────────────┘    │
└───────────────────────────┼───────────────────────────────────┘
                            │
                            │ Internet
                            │ (TLS/AMQP connection initiated
                            │  FROM Pi TO OpenShift)
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ Raspberry Pi (192.168.4.48)                                     │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Podman Containers (rootless)                            │    │
│  │                                                         │    │
│  │  ┌──────────────────────────────────────────────┐     │    │
│  │  │ skupper-router (quay.io/..:2.7.5)            │     │    │
│  │  │ - Connects TO OpenShift route (outbound)     │     │    │
│  │  │ - Connector: routing-key=postgres            │     │    │
│  │  │ - Forwards to 127.0.0.1:5432                │     │    │
│  │  └──────────────────────────────────────────────┘     │    │
│  │                                                         │    │
│  │  ┌──────────────────────────────────────────────┐     │    │
│  │  │ skupper-controller-podman (quay.io/..:1.9.1) │     │    │
│  │  │ - Manages podman site lifecycle              │     │    │
│  │  └──────────────────────────────────────────────┘     │    │
│  │                                                         │    │
│  │  ┌──────────────────────────────────────────────┐     │    │
│  │  │ default-skupper-router (quay.io/..:3.5.1)    │     │    │
│  │  │ - Additional router instance                 │     │    │
│  │  └──────────────────────────────────────────────┘     │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                  │
│                          │                                      │
│                          ▼                                      │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ PostgreSQL 15 (Native Process)                          │    │
│  │                                                         │    │
│  │ PID: 58888                                             │    │
│  │ Listening: 127.0.0.1:5432                              │    │
│  │ Database: demodb                                       │    │
│  │ User: demouser / Password: demopass                    │    │
│  │                                                         │    │
│  │ demo_data table:                                       │    │
│  │   1 | Hello from Raspberry Pi!                         │    │
│  │   2 | Skupper makes networking easy                    │    │
│  │   3 | No egress IP needed!                             │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow (PostgreSQL Query)

1. **Application Request** (OpenShift):
   - Pod `postgres-client` runs: `psql -h postgres -p 5432`
   - DNS resolves `postgres` → Service IP `172.30.82.114`

2. **Service Routing** (OpenShift):
   - Service `postgres` routes to endpoint `10.128.0.110:1024`
   - Endpoint is the skupper-router pod

3. **RHSI Routing Layer** (OpenShift):
   - skupper-router receives TCP on port 1024
   - Matches routing-key `postgres` (listener configuration)
   - Encapsulates TCP over AMQP protocol
   - Sends through established AMQP link to Pi

4. **AMQP Link** (Internet):
   - TLS-encrypted AMQP connection
   - Initiated FROM Pi TO OpenShift (inbound to cluster)
   - Uses OpenShift route: skupper-router-inter-router-*.apps.prime.davecore.xyz
   - Certificate-based authentication (not IP-based)

5. **RHSI Decapsulation** (Raspberry Pi):
   - skupper-router container receives AMQP message
   - Matches routing-key `postgres` (connector configuration)
   - Decapsulates TCP from AMQP
   - Forwards to configured host: `127.0.0.1:5432`

6. **PostgreSQL Response** (Raspberry Pi):
   - PostgreSQL receives query on localhost:5432
   - Authenticates user `demouser` (scram-sha-256)
   - Executes query on `demodb.demo_data`
   - Returns result rows

7. **Return Path**:
   - Response flows back through same AMQP tunnel
   - skupper-router (Pi) → AMQP → skupper-router (OCP)
   - skupper-router (OCP) → TCP:1024 → Service → Pod
   - Application receives PostgreSQL result set

## Key Components Status

### OpenShift
```
Operator: skupper-operator.v2.1.4-rh-3 (Red Hat Service Interconnect)
Site: ocp-v2-site (Ready)
Router Pod: skupper-router-7667dbb47f-5v5gq (2/2 Running)
Service: postgres (ClusterIP 172.30.82.114:5432)
Listener: postgres (routing-key=postgres, Ready, matching-connector=true)
```

### Raspberry Pi
```
Skupper CLI: v2.2.1
Site: pi-v2-site (Ready)
Containers: 3 running (skupper-router, controller, default-router)
PostgreSQL: PID 58888 (listening 127.0.0.1:5432)
Connector: postgres (routing-key=postgres, host=127.0.0.1:5432)
Link Status: Pending (but functional - services working)
```

## Security Model

**Traditional Egress IP:**
- Requires firewall rule: `allow from <EgressIP> to PostgreSQL-IP:5432`
- Security based on source IP address
- Requires cluster admin to allocate EgressIP
- Requires network admin to configure firewall

**RHSI Approach:**
- PostgreSQL NOT exposed to internet
- Pi initiates connection INTO cluster (inbound only)
- Security via TLS certificate validation
- OpenShift NetworkPolicy controls which ServiceAccounts can access `postgres` service
- No firewall configuration required
- No egress IP allocation required

## Verified Working

✓ PostgreSQL running natively on Pi (not containerized)
✓ Skupper v2 routers connected via AMQP
✓ Routing-key matching (connector ↔ listener)
✓ TCP adaptation working (v2.x fixed v1.9.x bugs)
✓ Application can query database through service name
✓ No egress IP configured
✓ No firewall rules required
✓ Connection initiated from Pi TO cluster (inbound)

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

✓ SUCCESS! Connected to PostgreSQL on Raspberry Pi via Skupper!
```
