# Troubleshooting Guide

## Common Issues and Solutions

### RHSI v1.9.x TCP Service Issues

**Problem:** TCP connections fail between OpenShift and Podman sites with errors like "connection closed unexpectedly" or "connection refused".

**Symptoms:**
- TCP listener configured but no L4 flows created
- Router logs show "legacy encap" mode
- Service status shows targets but connections fail
- Error: `psql: error: server closed the connection unexpectedly`

**Root Cause:**
RHSI v1.9.x has documented issues with TCP adaptation between Kubernetes and Podman deployments:
- L4 flow creation failures
- TCP adaptor "legacy encap" mode bugs
- Connection reset errors

**Related Issues:**
- DISPATCH-1931: HTTP client not seeing reply through TCP adaptor (Kubernetes)
- DISPATCH-2036: TCP adaptor deliveries reported as "stuck"
- DISPATCH-2073: TCP adaptor end-to-end flow control implementation
- SKUPPER-869: Idle connection timeouts for TCP transport

**Solution:**
Upgrade to RHSI v2.0 or later, which includes a completely rewritten TCP adaptation layer:

```bash
# Delete old subscription
oc delete subscription.operators.coreos.com skupper-operator -n rhsi-system

# Delete old CSV
oc delete csv skupper-operator.v1.9.5-rh-1 -n rhsi-system

# Create new subscription for v2.1
oc apply -f openshift/rhsi-operator.yaml

# Verify upgrade
oc get csv -n rhsi-system | grep skupper
```

### Link Status Shows "Pending" or "Not Operational"

**Problem:** `skupper link status` shows link as "Pending" even though services work.

**Diagnosis:**
```bash
# Check link status on both sides
skupper link status -n rhsi-demo
skupper link status --platform podman

# Check service connectivity
skupper listener status -n rhsi-demo
skupper connector status --platform podman
```

**Common Causes:**
1. Certificate synchronization delay (wait 30-60 seconds)
2. Router pods restarting
3. Network connectivity issues

**Solution:**
If services are working despite "Pending" status, the link is functional. The status reporting may be delayed.

### Podman Socket Connection Refused

**Problem:**
```
Failed to bootstrap: failed to create container client: Container engine is not available
stat /run/user/1000/podman/podman.sock: no such file or directory
```

**Solution:**
```bash
# Enable podman socket
systemctl --user enable --now podman.socket

# Verify socket exists
ls -la /run/user/$(id -u)/podman/podman.sock

# Enable lingering for persistence across reboots
loginctl enable-linger $USER
```

### PostgreSQL Connection Refused Locally

**Problem:** Cannot connect to PostgreSQL on localhost.

**Diagnosis:**
```bash
# Check if PostgreSQL is running
sudo systemctl status postgresql

# Check listening ports
sudo netstat -tlnp | grep 5432

# Try direct connection
PGPASSWORD=demopass psql -h 127.0.0.1 -U demouser -d demodb -c "SELECT 1;"
```

**Common Issues:**
1. PostgreSQL not configured to listen on 127.0.0.1
2. pg_hba.conf missing authentication rule
3. Wrong password

**Solution:**
```bash
# Check postgresql.conf
grep listen_addresses /etc/postgresql/15/main/postgresql.conf

# Should show:
# listen_addresses = 'localhost'

# Check pg_hba.conf
sudo grep demodb /etc/postgresql/15/main/pg_hba.conf

# Should include:
# host    demodb    demouser    127.0.0.1/32    scram-sha-256

# Restart if changes made
sudo systemctl restart postgresql
```

### Service Endpoints Not Created in OpenShift

**Problem:** `oc get endpoints postgres` shows no endpoints or wrong port.

**Diagnosis:**
```bash
# Check service
oc get svc postgres -n rhsi-demo

# Check endpoints
oc get endpoints postgres -n rhsi-demo -o yaml

# Check skupper listener
skupper listener status -n rhsi-demo -v
```

**Solution:**
Endpoints are managed by RHSI. If missing:
1. Verify listener was created: `skupper listener status`
2. Check connector on Pi: `skupper connector status --platform podman`
3. Verify link is established between sites
4. Check skupper-router pod logs for errors

### Multiple Site Files Causing Bootstrap Failure

**Problem:**
```
Failed to bootstrap: multiple sites found, but only one site is allowed for bootstrapping
```

**Solution:**
```bash
# List all site files
ls -la ~/.local/share/skupper/namespaces/default/input/resources/Site-*.yaml

# Remove old site files, keep only the current one
rm ~/.local/share/skupper/namespaces/default/input/resources/Site-old-name.yaml

# Reload
skupper system reload --platform podman
```

### Router Logs Show SSL/TLS Errors

**Problem:** Connection failures with TLS errors in router logs.

**Example Errors:**
```
Connection failed: amqp:connection:framing-error SSL Failure: error:0A000126:SSL routines::unexpected eof while reading
```

**Diagnosis:**
```bash
# Check router logs on OpenShift
oc logs -l application=skupper-router -c router -n rhsi-demo | grep -i ssl

# Check router logs on Pi
podman logs skupper-router | grep -i ssl
```

**Common Causes:**
1. Certificate mismatch between v1 and v2 sites
2. Expired token
3. Network interruption during TLS handshake

**Solution:**
1. Regenerate link token and recreate link
2. Ensure both sites are using compatible versions
3. Check firewall/network allows HTTPS (443) to OpenShift routes

## Diagnostic Commands

### Check Overall Status

```bash
# OpenShift side
skupper site status -n rhsi-demo
skupper link status -n rhsi-demo
skupper listener status -n rhsi-demo
oc get pods -n rhsi-demo
oc get svc -n rhsi-demo

# Raspberry Pi side
skupper site status --platform podman
skupper link status --platform podman
skupper connector status --platform podman
podman ps
```

### Verify Network Connectivity

```bash
# From Pi, test connection to OpenShift route
curl -k https://skupper-router-inter-router-rhsi-demo.apps.your-cluster.com

# From OpenShift pod, test DNS resolution
oc run test --image=nicolaka/netshoot --rm -it -- nslookup postgres
```

### Check Skupper Router Logs

```bash
# OpenShift
oc logs -l application=skupper-router -c router -n rhsi-demo --tail=100

# Raspberry Pi
podman logs skupper-router --tail=100
```

### Verify PostgreSQL Connectivity

```bash
# Direct connection on Pi
PGPASSWORD=demopass psql -h 127.0.0.1 -U demouser -d demodb -c "SELECT version();"

# Through skupper from OpenShift
oc exec -n rhsi-demo postgres-client -- \
  bash -c 'PGPASSWORD=demopass psql -h postgres -p 5432 -U demouser -d demodb -c "SELECT version();"'
```

## Getting Help

If issues persist:

1. **Check RHSI version**: Ensure you're using v2.0 or later
2. **Review logs**: Collect logs from both skupper routers
3. **Verify network**: Ensure Pi can reach OpenShift routes
4. **Test incrementally**: Verify PostgreSQL works locally before testing through RHSI

For production support, open a case with Red Hat support referencing:
- RHSI version
- OpenShift version
- Detailed error messages and logs
- Output of diagnostic commands above
