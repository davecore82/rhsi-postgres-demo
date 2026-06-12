# RHSI PostgreSQL Demo - Architecture

## Overview

This demo shows how Red Hat Service Interconnect (RHSI) enables OpenShift applications to connect to external databases without requiring egress IP addresses or firewall rules.

## Components

### OpenShift Cluster (rhsi-v2-demo namespace)

- **postgres-client pod** - Test application that queries the database
- **postgres service** - ClusterIP service (port 5432) that routes to Skupper
- **skupper-router pod** - Two containers (router + controller) that handle the RHSI networking
- **Listener** - Configured with `routing-key=postgres`, creates the postgres service endpoint
- **Routes** - OpenShift routes for external connectivity (inter-router and edge)

### Raspberry Pi (External Linux Host)

- **Skupper CLI** - v2.1.4 (Red Hat Service Interconnect)
- **skupper-router container** - Connects TO OpenShift and forwards traffic
- **skupper-controller-podman container** - Manages the podman site lifecycle
- **postgres container** - PostgreSQL 15 database
  - Listening on 127.0.0.1:5432
  - Database: demodb
  - User: demouser / Password: demopass
  - Sample data: 3 rows in demo_data table
- **Connector** - Configured with `routing-key=postgres`, forwards to localhost:5432

## How It Works

### Data Flow

1. **Application makes request**
   - postgres-client pod runs `psql -h postgres -p 5432`
   - DNS resolves service name to ClusterIP

2. **Service routes to Skupper**
   - postgres service directs traffic to skupper-router pod (port 1024)

3. **Skupper encapsulates traffic**
   - Router matches `routing-key=postgres` from listener config
   - Wraps TCP connection in AMQP protocol
   - Sends encrypted over the established link

4. **Traffic goes over internet**
   - TLS-encrypted AMQP connection
   - Connection was initiated FROM Raspberry Pi TO OpenShift (inbound)
   - Uses certificate-based authentication

5. **Skupper decapsulates on Pi**
   - Router receives AMQP message
   - Matches `routing-key=postgres` from connector config
   - Unwraps TCP and forwards to 127.0.0.1:5432

6. **PostgreSQL processes request**
   - Database receives query
   - Returns results back through the same tunnel

### Key Concept: Routing Keys

The routing-key acts like a pub/sub topic. When a listener and connector both use `routing-key=postgres`, RHSI automatically creates a bidirectional TCP tunnel between them.

## Why This Solves the Egress IP Problem

### Traditional Approach

- Requires static egress IP allocation (needs cluster admin)
- Requires firewall rules allowing the egress IP (needs network admin)
- Security based on source IP addresses
- Complex coordination between teams

### RHSI Approach

- External host connects INTO the cluster (no egress needed)
- Certificate-based authentication (not IP-based)
- Application uses normal service name (postgres:5432)
- No firewall configuration required
- No special permissions needed
- More secure than IP filtering

## Connection Direction

Important: The Raspberry Pi initiates the connection TO OpenShift, not the other way around. This means:
- No egress IP needed from OpenShift
- No firewall holes in the database network
- Database never exposed to the internet

## Verified Working

- PostgreSQL running in Podman container on Raspberry Pi
- Skupper v2.1.4 routers connected via AMQP
- Application successfully queries database through service name
- No egress IP configured
- No firewall rules required
- Survives reboot - all services restart automatically

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
```

## Production Considerations

1. **Certificates** - Replace auto-generated certs with enterprise PKI
2. **Secrets** - Use proper secrets management (Vault, etc.) instead of demo passwords
3. **PostgreSQL TLS** - Enable SSL/TLS on the database itself
4. **NetworkPolicies** - Restrict which pods can access the postgres service
5. **Monitoring** - Enable RHSI metrics exporters
6. **High Availability** - Deploy multiple router replicas
