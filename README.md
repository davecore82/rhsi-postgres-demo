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

### 2. Set Up PostgreSQL on Raspberry Pi

### 3. Install Red Hat Service Interconnect CLI on Raspberry Pi

**Download from Red Hat Customer Portal:**

1. Go to https://access.redhat.com/downloads/
2. Search for "Red Hat Service Interconnect"
3. Download **Skupper CLI for Linux on aarch64** (v2.1.4 or later)

**Install:**

```bash
# Extract the archive
tar -xzf skupper-cli-linux-on-aarch64-2.1.4.tar.gz

# Install to /usr/local/bin
sudo cp skupper-cli-linux-on-aarch64-2.1.4.GA/skupper /usr/local/bin/
sudo chmod +x /usr/local/bin/skupper

# Verify installation
skupper version
# Expected: cli 2.1.4
```

### 4. Initialize RHSI Sites

**On OpenShift:**
```bash
# Create namespace
oc new-project rhsi-v2-demo

# Create RHSI site
skupper site create ocp-site --enable-link-access -n rhsi-v2-demo

# Verify
skupper site status -n rhsi-v2-demo
```

**On Raspberry Pi:**
```bash
# Enable podman socket
systemctl --user enable --now podman.socket

# Create RHSI site in podman mode
skupper site create pi-site --platform podman --enable-link-access

# Start the site
skupper system start --platform podman

# Verify
skupper site status --platform podman
```

### 5. Create Link Between Sites

**On OpenShift (create token):**
```bash
skupper token issue ~/rhsi-token.yaml -n rhsi-v2-demo
```

**Transfer token to Raspberry Pi, then:**
```bash
# Redeem token
skupper token redeem ~/rhsi-token.yaml --platform podman

# Reload to activate
skupper system reload --platform podman

# Verify link
skupper link status --platform podman
```

### 6. Expose PostgreSQL Service

**On Raspberry Pi (create connector):**
```bash
skupper connector create postgres 5432 \
  --routing-key postgres \
  --host 127.0.0.1 \
  --platform podman

skupper system reload --platform podman
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

## Troubleshooting

### Link Status Shows "Pending"

The link may show as "Pending" on the Podman side but services can still work. Verify by checking service status:
```bash
skupper listener status -n rhsi-v2-demo
skupper connector status --platform podman
```
