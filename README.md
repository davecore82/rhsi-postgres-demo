# RHSI PostgreSQL Demo

Demonstrates Red Hat Service Interconnect (RHSI) v2 connecting an OpenShift cluster to a PostgreSQL database running on a Raspberry Pi without requiring egress IP or firewall configuration.

## Overview

This demo implements a recommended approach for service connectivity as an alternative to traditional Egress IP solutions. Instead of relying on source IP-based firewall rules, RHSI establishes secure, certificate-based connections where the external service connects into the cluster.

## Architecture

**Traditional Egress (problematic):**
```
App → EgressIP → Firewall → External Service
```
Issues: IP stability, failover complexity, firewall dependency

**RHSI Approach (recommended):**
```
1. External Service (Pi) → connects INTO cluster → RHSI Router (via TLS)
2. App → connects to local service → RHSI Router → Pi
```

Security via:
- TLS certificates (not source IP)
- NetworkPolicies (ServiceAccount-based access control)
- No egress IP needed
- No firewall holes required

## Key Benefits

1. **No Egress IP needed** - Application connects to local service name
2. **No firewall configuration** - External service connects INTO the cluster (inbound)
3. **Certificate-based authentication** - More secure than IP filtering
4. **Resilient** - Survives pod/node failures
5. **Fine-grained access control** - Via ServiceAccount and NetworkPolicy

## Components

### Raspberry Pi
- PostgreSQL 15 (native, not containerized)
- Skupper v2.2.1 in Podman mode
- PostgreSQL exposed via RHSI connector

### OpenShift Cluster
- RHSI Operator v2.1.4-rh-3 (productized Red Hat version)
- RHSI site configured with link access enabled
- PostgreSQL listener service

## Prerequisites

- OpenShift cluster (tested on v4.18)
- Raspberry Pi or similar Linux host with:
  - Podman v4+
  - Network connectivity to OpenShift routes
- PostgreSQL database

## Installation

### 1. Install RHSI Operator in OpenShift

```bash
# Create operator namespace
oc create namespace rhsi-system

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhsi-operator-group
  namespace: rhsi-system
spec: {}
EOF

# Create Subscription for RHSI v2.1
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: skupper-operator
  namespace: rhsi-system
spec:
  channel: stable-2.1
  name: skupper-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
  startingCSV: skupper-operator.v2.1.4-rh-3
EOF

# Verify installation
oc get csv -n rhsi-system | grep skupper
```

### 2. Set Up PostgreSQL on Raspberry Pi

```bash
# Install PostgreSQL
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib

# Create demo database and user
sudo -u postgres psql -c "CREATE DATABASE demodb;"
sudo -u postgres psql -c "CREATE USER demouser WITH PASSWORD 'demopass';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE demodb TO demouser;"

# Create demo table with sample data
sudo -u postgres psql demodb -c "
CREATE TABLE demo_data (
  id SERIAL PRIMARY KEY,
  message TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO demo_data (message) VALUES
  ('Hello from Raspberry Pi!'),
  ('Skupper makes networking easy'),
  ('No egress IP needed!');
"

# Grant table privileges
sudo -u postgres psql demodb -c "
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO demouser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO demouser;
"

# Configure PostgreSQL to listen on localhost
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/g" \
  /etc/postgresql/15/main/postgresql.conf

# Add authentication rule
echo "host    demodb          demouser        127.0.0.1/32            scram-sha-256" | \
  sudo tee -a /etc/postgresql/15/main/pg_hba.conf

# Restart PostgreSQL
sudo systemctl restart postgresql
```

### 3. Install Skupper CLI on Raspberry Pi

```bash
curl -fsSL https://skupper.io/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

# Verify installation
skupper version
```

### 4. Initialize RHSI Sites

**On OpenShift:**
```bash
# Create namespace
oc new-project rhsi-demo

# Create RHSI site
skupper site create ocp-site --enable-link-access -n rhsi-demo

# Verify
skupper site status -n rhsi-demo
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
skupper token issue ~/rhsi-token.yaml -n rhsi-demo
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
  -n rhsi-demo

# Verify service was created
oc get svc postgres -n rhsi-demo
```

### 7. Deploy Test Application

```bash
oc apply -f openshift/postgres-client-pod.yaml -n rhsi-demo
```

### 8. Verify Connection

```bash
oc logs postgres-client -n rhsi-demo
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

### RHSI Version Compatibility

This demo requires RHSI v2.0 or later. RHSI v1.9.x has known issues with TCP services between Kubernetes and Podman deployments.

If using RHSI v1.9.x, upgrade to v2.1+ for proper TCP adaptation:
```bash
oc patch subscription.operators.coreos.com skupper-operator \
  -n rhsi-system \
  --type=merge \
  -p '{"spec":{"channel":"stable-2.1"}}'
```

### Link Status Shows "Pending"

The link may show as "Pending" on the Podman side but services can still work. Verify by checking service status:
```bash
skupper listener status -n rhsi-demo
skupper connector status --platform podman
```

### Connection Refused

Check that:
1. PostgreSQL is running and listening on 127.0.0.1:5432
2. Skupper router is running in Podman
3. Service endpoints are correctly configured

```bash
# On Pi
podman ps | grep skupper
PGPASSWORD=demopass psql -h 127.0.0.1 -U demouser -d demodb -c "SELECT 1;"

# On OpenShift
oc get endpoints postgres -n rhsi-demo
oc logs -l application=skupper-router -n rhsi-demo
```

## Production Considerations

1. **Use strong passwords** - Replace demo credentials with secure values
2. **Enable TLS** - Configure PostgreSQL with SSL/TLS
3. **Network Policies** - Implement fine-grained access control via NetworkPolicies
4. **Service Account isolation** - Use dedicated ServiceAccounts per application
5. **Monitoring** - Enable RHSI metrics and integrate with Prometheus
6. **High Availability** - Deploy multiple RHSI router replicas

## Known Issues

### RHSI v1.9.x TCP Limitations

RHSI v1.9.x has documented issues with TCP services between Kubernetes and Podman:
- L4 flow creation failures with "legacy encap" mode
- Connection reset errors with TCP adaptor
- Related JIRA issues: DISPATCH-1931, DISPATCH-2036, DISPATCH-2073

**Solution:** Upgrade to RHSI v2.0+ which includes a completely rewritten TCP adaptation layer.

### Podman Socket Requirement

Skupper in Podman mode requires the Podman socket to be running:
```bash
systemctl --user enable --now podman.socket
```

For persistence across reboots, enable lingering:
```bash
loginctl enable-linger $USER
```

## References

- [Red Hat Service Interconnect Documentation](https://docs.redhat.com/en/documentation/red_hat_service_interconnect/)
- [Skupper Project](https://skupper.io/)
- [Apache Qpid Dispatch Router](https://qpid.apache.org/components/dispatch-router/)

## Credits


## License

MIT
