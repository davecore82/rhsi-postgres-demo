# ARO with Firewall NVA Scenario

## Scenario

Azure Red Hat OpenShift (ARO) cluster with:
- 0.0.0.0/0 UDR sending all egress traffic to firewall NVA
- All ingress traffic also routed through the NVA
- Need to connect to external database (on-prem, other cloud, etc.)

## Traditional EgressIP Approach vs RHSI

### Traditional EgressIP (What You're Trying to Avoid)

```
ARO Pod → EgressIP → UDR → Firewall NVA (egress) → Internet → External DB
```

### RHSI Approach (Reverse the Connection)

```
External Host → Internet → Firewall NVA (ingress) → ARO Route → skupper-router
ARO Pod → Service postgres:5432 → skupper-router → AMQP tunnel → External Host → DB
```

**Requirements:**
1. Allow HTTPS (443) ingress to ARO routes (already configured for apps)
2. External host can reach ARO route hostname
3. Install RHSI in ARO cluster
4. Install skupper on external host

**Advantages:**
- Uses existing ingress rules (HTTPS to routes)
- No egress firewall changes needed
- No EgressIP allocation needed
- Certificate-based security
- No database firewall rule needed (DB not exposed)

## What the Customer Needs to Do

### 1. On the Firewall NVA (Likely Already Done)

**Ingress Rule:**
```
Allow HTTPS (443) → *.apps.<aro-domain>
```

This is typically already configured for normal application traffic to ARO. If not, add:

```bash
# Azure Firewall example
az network firewall application-rule create \
  --collection-name "ARO-Ingress" \
  --firewall-name <firewall-name> \
  --name "Allow-ARO-Routes" \
  --protocols Https=443 \
  --resource-group <rg-name> \
  --target-fqdns "*.apps.<aro-domain>" \
  --source-addresses "*" \
  --priority 100 \
  --action Allow
```

**No Database Port Rules Needed:**
- No need to open port 5432 (PostgreSQL)
- No need to open port 3306 (MySQL)
- No need to open port 1521 (Oracle)
- Database port stays internal to external host

### 2. On the ARO Cluster

**Install RHSI Operator:**
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

# Create Subscription
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
EOF

# Verify
oc get csv -n rhsi-system | grep skupper
```

**Create RHSI Site:**
```bash
# Create project
oc new-project database-connectivity

# Create site with link access enabled
skupper site create aro-site --enable-link-access -n database-connectivity

# Generate link token (transfer this to external host)
skupper token issue ~/aro-token.yaml -n database-connectivity
```

**Create Listener (this creates the Kubernetes Service):**
```bash
# Example for PostgreSQL
skupper listener create postgres 5432 \
  --routing-key postgres \
  -n database-connectivity

# Verify service was created
oc get svc postgres -n database-connectivity
```

### 3. On the External Host (Database Server or Jump Host)

**Install Skupper CLI:**
```bash
curl -fsSL https://skupper.io/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
```

**Install Podman (if not already installed):**
```bash
# RHEL/CentOS
sudo dnf install -y podman

# Ubuntu/Debian
sudo apt-get install -y podman
```

**Enable Podman Socket:**
```bash
systemctl --user enable --now podman.socket
loginctl enable-linger $USER
```

**Create Skupper Site:**
```bash
skupper site create external-site --platform podman --enable-link-access
skupper system start --platform podman
```

**Redeem Link Token:**
```bash
# Copy aro-token.yaml from ARO cluster to external host
skupper token redeem ~/aro-token.yaml --platform podman
skupper system reload --platform podman
```

**Create Connector (expose database):**
```bash
# For PostgreSQL on localhost
skupper connector create postgres 5432 \
  --routing-key postgres \
  --host 127.0.0.1 \
  --platform podman

skupper system reload --platform podman
```

**Verify:**
```bash
skupper site status --platform podman
skupper connector status --platform podman
```

### 4. On the ARO Cluster - Deploy Application

**Deploy your application:**
```bash
oc apply -f your-app-deployment.yaml -n database-connectivity
```

**Application connects to database using service name:**
```yaml
# Example application config
env:
- name: DB_HOST
  value: "postgres"  # ← Service name created by RHSI listener
- name: DB_PORT
  value: "5432"
- name: DB_NAME
  value: "yourdb"
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: db-credentials
      key: username
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: db-credentials
      key: password
```

## Traffic Flow Analysis

### Ingress Path (External Host → ARO)

1. External host makes HTTPS connection to: `skupper-router-inter-router-<namespace>.apps.<aro-domain>:443`
2. Traffic hits Azure Load Balancer (ARO ingress)
3. **May pass through NVA if configured** (depends on Azure route table)
4. Load Balancer routes to ARO router pod
5. AMQP/TLS connection established
6. Certificate-based authentication (no IP whitelisting)

**Firewall Requirements:**
- Allow HTTPS (443) to ARO routes (typically already allowed)
- No special database port rules

### Data Path (ARO Application → Database)

1. App connects to `postgres:5432` (ClusterIP service)
2. Service routes to skupper-router pod endpoint
3. skupper-router encapsulates TCP over existing AMQP tunnel
4. **No egress through UDR/firewall** - uses existing ingress tunnel
5. External host skupper-router decapsulates TCP
6. Forwards to `127.0.0.1:5432` (localhost database)

**Key Point:** Application data flow uses the AMQP tunnel that was established inbound. No outbound connection from ARO to database = no egress firewall rules needed.

## Comparison Table

| Aspect | EgressIP + Firewall | RHSI |
|--------|-------------------|------|
| Firewall rule needed | Yes (egress to DB port) | No (uses HTTPS ingress) |
| EgressIP allocation | Required | Not needed |
| Database exposed | Yes (to specific IP) | No (localhost only) |
| Firewall port | Database port (5432, etc.) | HTTPS (443) only |
| Security model | IP-based | Certificate-based |
| Azure egress charges | Yes | No (uses ingress) |
| UDR latency impact | Every query | Only tunnel setup |
| Multi-team coordination | High | Low |
| Network admin involvement | Required | Not required |

## Security Considerations

### RHSI Security Benefits

1. **Database Not Exposed:**
   - Database listens on 127.0.0.1 only
   - No internet exposure
   - No firewall rules pointing to database

2. **Certificate-Based Authentication:**
   - TLS mutual authentication
   - More secure than IP whitelisting
   - Automatic certificate rotation

3. **NetworkPolicy Support:**
   - Control which pods can access the service
   - ServiceAccount-based access control
   - Namespace isolation

4. **No Egress Trust:**
   - Don't need to trust egress IP won't be hijacked
   - Connection direction is reversed
   - External host authenticates to ARO, not vice versa

### Additional Production Hardening

```yaml
# Example NetworkPolicy - only allow specific pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-access
  namespace: database-connectivity
spec:
  podSelector:
    matchLabels:
      app: postgres  # RHSI listener pods
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: myapp  # Only your application
    ports:
    - protocol: TCP
      port: 5432
```

## Troubleshooting

### If External Host Can't Reach ARO Route

**Check DNS:**
```bash
nslookup skupper-router-inter-router-<namespace>.apps.<aro-domain>
```

**Check Network Path:**
```bash
curl -k -v https://skupper-router-inter-router-<namespace>.apps.<aro-domain>
```

**Expected:** SSL/TLS handshake, possibly connection error (router expects AMQP, not HTTP)

**If fails:** Check firewall NVA rules for outbound HTTPS from external host network

### If Application Can't Connect

**Verify service exists:**
```bash
oc get svc postgres -n database-connectivity
oc get endpoints postgres -n database-connectivity
```

**Verify listener:**
```bash
skupper listener status -n database-connectivity
```

**Verify connector:**
```bash
skupper connector status --platform podman  # On external host
```

**Check skupper-router logs:**
```bash
oc logs -l application=skupper-router -c router -n database-connectivity
```

## Summary

For an ARO customer with firewall NVA and 0.0.0.0 UDR:

**What they DON'T need:**
- ❌ EgressIP allocation
- ❌ Firewall rules for database ports
- ❌ IP whitelisting on database
- ❌ Network admin involvement for database access
- ❌ Changes to UDR egress rules

**What they DO need:**
- ✅ HTTPS (443) ingress to ARO routes (likely already configured)
- ✅ External host able to reach ARO route hostname
- ✅ RHSI operator installed in ARO
- ✅ Skupper installed on external host

**Result:** Database connectivity without touching firewall rules, UDRs, or EgressIP configuration.
