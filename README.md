# RHSI PostgreSQL Demo

Demonstrates Red Hat Service Interconnect (RHSI) v2 connecting an OpenShift cluster to a PostgreSQL database running on a Raspberry Pi without requiring egress IP or firewall configuration.

## Overview

This demo implements an approach for service connectivity as an alternative to traditional Egress IP solutions. Instead of relying on source IP-based firewall rules, RHSI establishes secure, certificate-based connections where the external service connects into the cluster.

## Architecture

**Traditional Egress:**
```
App → EgressIP → Firewall → External Service
```

**RHSI Approach:**
```
1. External Service (Pi) → connects INTO cluster → RHSI Router (via TLS)
2. App → connects to local service → RHSI Router → Pi
```

Security via:
- TLS certificates (not source IP)
- NetworkPolicies (ServiceAccount-based access control)
- No egress IP needed
- No firewall holes required

## Components

### Raspberry Pi
- PostgreSQL (native, not containerized)
- PostgreSQL exposed via RHSI connector

### OpenShift Cluster
- RHSI Operator
- RHSI site configured with link access enabled
- PostgreSQL listener service

## Prerequisites

- OpenShift cluster (tested on v4.18)
- Raspberry Pi or similar Linux host with:
  - Podman v4+
  - Network connectivity to OpenShift routes
- PostgreSQL database

## Installation

### 1. Install RHSI Operator 2.1.4-rh-3 in OpenShift

Install the Red Hat Service Interconnect Operator from the OperatorHub:

```bash
# Option 1: Via OpenShift Web Console
# Navigate to: Operators → OperatorHub → Search "Red Hat Service Interconnect"
# Click Install → Select channel "stable-2.1" → Install

# Option 2: Via CLI (using the provided manifest)
oc apply -f openshift/rhsi-operator.yaml
```

Wait for the operator to be ready:
```bash
oc get csv -n rhsi-system | grep skupper
# Expected: skupper-operator.v2.1.4-rh-3   Red Hat Service Interconnect   2.1.4-rh-3   Succeeded
```

### 2. Set Up PostgreSQL on Raspberry Pi

Run the setup script on your Raspberry Pi:

```bash
# Clone this repository
git clone https://github.com/davecore82/rhsi-postgres-demo.git
cd rhsi-postgres-demo

# Run the PostgreSQL setup script
chmod +x scripts/setup-postgresql.sh
./scripts/setup-postgresql.sh
```

This will install PostgreSQL 15, create the `demodb` database, `demouser` user, and populate the `demo_data` table with sample records.

### 3. Install Red Hat Service Interconnect CLI on Raspberry Pi

**Download from Red Hat Customer Portal:**

1. Go to https://access.redhat.com/downloads/
2. Search for "Red Hat Service Interconnect"
3. Download **Skupper CLI for Linux on aarch64** (v2.1.4 or later)

**Install:**

```bash
# Extract the archive (filename may vary by version)
tar -xzf skupper-cli-*.tar.gz

# Install to /usr/local/bin
sudo cp skupper-cli-*/skupper /usr/local/bin/
sudo chmod +x /usr/local/bin/skupper

# Verify installation
skupper version
# Expected output should include: cli 2.1.4
```

### 4. Initialize RHSI Sites

**On OpenShift:**
```bash
# Create namespace
oc new-project rhsi-v2-demo

# Create RHSI site with link access enabled
skupper site create ocp-site --enable-link-access -n rhsi-v2-demo

# Verify site is ready
oc get pods -n rhsi-v2-demo
# Expected: skupper-router pod running with 2/2 containers ready
```

**On Raspberry Pi:**
```bash
# Enable podman socket
systemctl --user enable --now podman.socket

# Create RHSI site in podman mode
skupper site create pi-site --platform podman --enable-link-access

# Verify site is running
podman ps
# Expected: default-skupper-router container running
```

### 5. Create Link Between Sites

**On OpenShift (create token):**
```bash
skupper token issue ~/rhsi-token.yaml -n rhsi-v2-demo
```

**Transfer token to Raspberry Pi, then:**
```bash
# Redeem token to create the link
skupper token redeem ~/rhsi-token.yaml --platform podman

# Verify link (may show as "Pending" but still functional)
skupper link status --platform podman
```

### 6. Expose PostgreSQL Service

**On Raspberry Pi (create connector):**
```bash
skupper connector create postgres 5432 \
  --routing-key postgres \
  --host 127.0.0.1 \
  --platform podman

# Verify connector was created
podman logs default-skupper-router 2>&1 | grep postgres | tail -5
# Expected: "Configured TcpConnector for postgres, 127.0.0.1:5432"
```

**On OpenShift (create listener):**
```bash
skupper listener create postgres 5432 \
  --routing-key postgres \
  -n rhsi-v2-demo

# Verify service was created
oc get svc postgres -n rhsi-v2-demo
```

### 7. Deploy Test Application

```bash
oc apply -f openshift/postgres-client-pod.yaml -n rhsi-v2-demo
```

### 8. Verify Connection

```bash
oc logs postgres-client -n rhsi-v2-demo
```

Expected output:
```
Connected to PostgreSQL on Raspberry Pi via Skupper!
 id |            message            |        created_at         
----+-------------------------------+---------------------------
  1 | Hello from Raspberry Pi!      | 2026-06-11 14:55:24.10867
  2 | Skupper makes networking easy | 2026-06-11 14:55:24.10867
  3 | No egress IP needed!          | 2026-06-11 14:55:24.10867
```

## Additional Documentation

For detailed architecture information, component diagrams, and command references, see:
- [Architecture Documentation](docs/architecture.md)

## Troubleshooting

### Link Status Shows "Pending"

The link may show as "Pending" on the Podman side but services can still work. Verify by checking service status:
```bash
skupper listener status -n rhsi-v2-demo
skupper connector status --platform podman
```

### Connection Failures

If the postgres-client pod shows connection failures:

1. Verify PostgreSQL is running on the Pi:
```bash
ps aux | grep postgres | grep -v grep
ss -tlnp | grep 5432
```

2. Check the skupper router logs:
```bash
podman logs default-skupper-router 2>&1 | grep -i error
```

3. Verify the connector is configured:
```bash
cat ~/.local/share/skupper/namespaces/default/input/resources/Connector-postgres.yaml
```

### Reboot Survival

After rebooting the Raspberry Pi, verify all services restart:
```bash
# Check skupper router
podman ps

# Check PostgreSQL
ps aux | grep postgres | grep -v grep

# If postgres-client shows errors, wait 1-2 minutes for the link to re-establish
oc logs postgres-client -n rhsi-v2-demo --tail=10
```
