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

```bash
# View running pods
$ oc get pods -n rhsi-v2-demo
NAME                              READY   STATUS    RESTARTS   AGE
postgres-client                   1/1     Running   0          19h
skupper-router-7667dbb47f-5v5gq   2/2     Running   0          19h

# View the postgres service
$ oc get svc postgres -n rhsi-v2-demo
NAME       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
postgres   ClusterIP   172.30.82.114   <none>        5432/TCP   19h

# View Skupper routes (for external connectivity)
$ oc get routes -n rhsi-v2-demo
NAME                          HOST/PORT
skupper-router-edge           skupper-router-edge-rhsi-v2-demo.apps.prime.davecore.xyz
skupper-router-inter-router   skupper-router-inter-router-rhsi-v2-demo.apps.prime.davecore.xyz
```

### Raspberry Pi (External Linux Host)

- **Skupper CLI** - v2.1.4 (Red Hat Service Interconnect)
- **default-skupper-router container** - Router that connects TO OpenShift and forwards traffic
- **PostgreSQL 15** - Native system process (not containerized)
  - Listening on 127.0.0.1:5432
  - Database: demodb
  - User: demouser / Password: demopass
  - Sample data: 3 rows in demo_data table
- **Connector** - Configured with `routing-key=postgres`, forwards to localhost:5432

```bash
# Check Skupper version on Raspberry Pi
$ skupper version
COMPONENT		VERSION
router			3.4.2
controller		2.1.4
network-observer	2.1.4
cli			2.1.4

# View running Skupper container
$ podman ps
CONTAINER ID  IMAGE                                 COMMAND               CREATED       STATUS
9f1880cfe376  quay.io/skupper/skupper-router:3.5.1  /home/skrouterd/b...  20 hours ago  Up 21 minutes

# Verify PostgreSQL is running as a native process
$ ps aux | grep postgres | head -1
postgres     679  0.0  2.9 221236 27716 ?  Ss  11:29  0:00 /usr/lib/postgresql/15/bin/postgres

# Check what's listening on port 5432
$ ss -tlnp | grep 5432
tcp  LISTEN  0  244  127.0.0.1:5432  0.0.0.0:*
```

## How It Works

### Data Flow

1. **Application makes request**
   - postgres-client pod runs `psql -h postgres -p 5432`
   - DNS resolves service name to ClusterIP

```bash
# From inside the postgres-client pod
$ psql -h postgres -p 5432 -U demouser -d demodb -c "SELECT * FROM demo_data;"
```

2. **Service routes to Skupper**
   - postgres service (172.30.82.114:5432) directs traffic to skupper-router pod endpoint (port 1024)
   - This endpoint is dynamically created by the RHSI listener

```bash
# View service endpoints
$ oc get endpoints postgres -n rhsi-v2-demo
NAME       ENDPOINTS          AGE
postgres   10.128.2.45:1024   19h
```

3. **Skupper encapsulates traffic**
   - Router matches `routing-key=postgres` from listener config
   - Wraps TCP connection in AMQP protocol
   - Sends encrypted over the established link

```bash
# View the listener configuration
$ oc get listener postgres -n rhsi-v2-demo -o yaml
apiVersion: skupper.io/v2alpha1
kind: Listener
metadata:
  name: postgres
spec:
  routingKey: postgres
  port: 5432
  type: tcp
```

4. **Traffic goes over internet**
   - TLS-encrypted AMQP connection
   - Connection was initiated FROM Raspberry Pi TO OpenShift (inbound)
   - Uses certificate-based authentication
   - Routes through: `skupper-router-inter-router-rhsi-v2-demo.apps.prime.davecore.xyz`

5. **Skupper decapsulates on Pi**
   - Router receives AMQP message
   - Matches `routing-key=postgres` from connector config
   - Unwraps TCP and forwards to 127.0.0.1:5432

```bash
# View the connector status on Raspberry Pi
$ skupper connector status postgres --platform podman
Name:		postgres
Status:		Pending
Routing key:	postgres
Host:		127.0.0.1
Port:		5432
```

6. **PostgreSQL processes request**
   - Database receives query
   - Returns results back through the same tunnel

```bash
# Result received by postgres-client pod
 id |            message            |        created_at         
----+-------------------------------+---------------------------
  1 | Hello from Raspberry Pi!      | 2026-06-11 14:55:24.10867
  2 | Skupper makes networking easy | 2026-06-11 14:55:24.10867
  3 | No egress IP needed!          | 2026-06-11 14:55:24.10867
```

### Key Concept: Routing Keys

The routing-key acts like a pub/sub topic. When a listener and connector both use `routing-key=postgres`, RHSI automatically creates a bidirectional TCP tunnel between them.

```bash
# On OpenShift - Listener with routing-key=postgres
$ oc get listener postgres -n rhsi-v2-demo
NAME       ROUTING KEY   PORT   TYPE
postgres   postgres      5432   tcp

# On Raspberry Pi - Connector with routing-key=postgres
$ skupper connector status postgres
Name: postgres
Routing Key: postgres
Connected: true
```

## Connection Direction

Important: The Raspberry Pi initiates the connection TO OpenShift, not the other way around. This means:
- No egress IP needed from OpenShift
- No firewall holes in the database network
- Database never exposed to the internet

```bash
# On OpenShift - Create a token for the external site to use
$ skupper token issue ~/rhsi-token.yaml -n rhsi-v2-demo
Token written to /home/user/rhsi-token.yaml

# Transfer the token file to the Raspberry Pi, then redeem it
# On Raspberry Pi - Use that token to connect TO OpenShift
$ skupper token redeem ~/rhsi-token.yaml --platform podman
Site configured to link to rhsi-v2-demo

# Verify the link status
$ skupper link status --platform podman
Links created from this site:
   Link link1 is connected
```
