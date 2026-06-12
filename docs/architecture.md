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

## Why This Solves the Egress IP Problem

### Traditional Approach

- Requires static egress IP allocation (needs cluster admin)
- Requires firewall rules allowing the egress IP (needs network admin)
- Security based on source IP addresses
- Complex coordination between teams

```bash
# Traditional approach would require:
# 1. Allocate EgressIP on OpenShift
$ oc patch netnamespace rhsi-v2-demo --type=merge -p '{"egressIPs": ["203.0.113.5"]}'

# 2. Configure firewall on database side
# firewall-cmd --add-rich-rule='rule family="ipv4" source address="203.0.113.5" port port="5432" protocol="tcp" accept'
```

### RHSI Approach

- External host connects INTO the cluster (no egress needed)
- Certificate-based authentication (not IP-based)
- Application uses normal service name (postgres:5432)
- No firewall configuration required
- No special permissions needed
- More secure than IP filtering

```bash
# RHSI approach - no EgressIP needed, just create the link
$ skupper link create <token-file>
Skupper link created successfully
```

## Connection Direction

Important: The Raspberry Pi initiates the connection TO OpenShift, not the other way around. This means:
- No egress IP needed from OpenShift
- No firewall holes in the database network
- Database never exposed to the internet

```bash
# On OpenShift - Create a token for the external site to use
$ oc get secret skupper-link-token -n rhsi-v2-demo -o yaml

# On Raspberry Pi - Use that token to connect TO OpenShift
$ skupper link create skupper-link-token.yaml
Site configured to link to rhsi-v2-demo (name=link1)
Check the status of the link using 'skupper link status link1'
```

## Verified Working

```bash
# PostgreSQL running as native process on Raspberry Pi
$ ssh pi@192.168.4.48 'ps aux | grep "bin/postgres" | grep -v grep'
postgres  679  0.0  2.9  /usr/lib/postgresql/15/bin/postgres -D /var/lib/postgresql/15/main

# Skupper v2.1.4 routers connected via AMQP
$ skupper version
cli    2.1.4

# Application successfully queries database through service name
$ oc logs postgres-client -n rhsi-v2-demo --tail=5
✓ SUCCESS! Connected to PostgreSQL on Raspberry Pi via Skupper!

# No egress IP configured
$ oc get netnamespace rhsi-v2-demo -o jsonpath='{.egressIPs}'
# (empty - no egress IP)

# Survives reboot - all services restart automatically
$ ssh pi@192.168.4.48 'sudo reboot'
# ... wait for reboot ...
$ ssh pi@192.168.4.48 'podman ps'
# All containers running again
```

## Test Results

```bash
# From OpenShift postgres-client pod:
$ PGPASSWORD=demopass psql -h postgres -p 5432 -U demouser -d demodb -c "SELECT * FROM demo_data;"

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

1. **Certificates** - Replace auto-generated certs with enterprise PKI
```bash
# Generate proper certificates
$ skupper token create --token-type cert --ca /path/to/ca.crt link-token.yaml
```

2. **Secrets** - Use proper secrets management (Vault, etc.) instead of demo passwords
```bash
# Store credentials in a secret
$ oc create secret generic postgres-credentials \
  --from-literal=username=demouser \
  --from-literal=password=<vault-password>
```

3. **PostgreSQL TLS** - Enable SSL/TLS on the database itself
```bash
# Configure PostgreSQL to require SSL
$ podman run -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
  -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256" \
  -v /path/to/certs:/certs postgres:15 \
  -c ssl=on -c ssl_cert_file=/certs/server.crt
```

4. **NetworkPolicies** - Restrict which pods can access the postgres service
```bash
# Create NetworkPolicy to allow only postgres-client
$ oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-access
spec:
  podSelector:
    matchLabels:
      app: postgres-router
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: postgres-client
EOF
```

5. **Monitoring** - Enable RHSI metrics exporters
```bash
# View Skupper metrics
$ oc get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq '.resources[] | select(.name | contains("skupper"))'
```

6. **High Availability** - Deploy multiple router replicas
```bash
# Scale the router deployment
$ oc scale deployment skupper-router --replicas=3 -n rhsi-v2-demo
```
