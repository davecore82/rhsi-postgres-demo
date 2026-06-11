# AMQP Protocol and How RHSI Uses It

## What is AMQP?

**AMQP (Advanced Message Queuing Protocol)** is an open standard application layer protocol for message-oriented middleware. According to [Wikipedia](https://en.wikipedia.org/wiki/Advanced_Message_Queuing_Protocol), AMQP is a binary protocol designed to efficiently support a wide variety of messaging applications and communication patterns.

### Key Characteristics

- **Protocol Layer**: Application layer (Layer 7)
- **Standard**: OASIS and ISO/IEC International Standard (approved 2014)
- **Version**: AMQP 1.0 is the current specification
- **Security**: Built-in support for TLS encryption and SASL authentication
- **Reliability**: Message delivery guarantees (at-most-once, at-least-once, exactly-once)
- **Industry Adoption**: Used by finance, healthcare, transportation, and cloud platforms like Azure Service Bus

**Sources:**
- [What is AMQP - A1 Digital](https://www.a1.digital/knowledge-hub/what-is-amqp-the-protocol-explained/)
- [AMQP Overview - Akamai](https://www.akamai.com/glossary/what-is-an-advanced-message-queuing-protocol-amqp)

## Why Does RHSI/Skupper Use AMQP?

RHSI uses AMQP as the **transport layer** for its Virtual Application Network (VAN). Here's why this is clever:

### 1. **AMQP is Designed for Routing**

Traditional messaging protocols like HTTP are request/response. AMQP is designed for **routing messages between nodes** in a network - exactly what RHSI needs to do when connecting services across clusters.

From the [Skupper Google Groups discussion](https://groups.google.com/g/skupper/c/DLZ34YrfQsQ), AMQP provides:
- Dynamic routing capabilities
- Multi-hop message forwarding
- Built-in flow control
- Connection pooling and multiplexing

### 2. **Protocol Encapsulation**

RHSI doesn't replace your application protocols (PostgreSQL, HTTP, etc.). Instead, it **encapsulates** them inside AMQP for transport across the network.

As explained in [Skupper.io developer blog](https://developers.redhat.com/blog/2020/01/01/skupper-io-let-your-services-communicate-across-kubernetes-clusters):

```
Application Layer:    PostgreSQL wire protocol (port 5432)
                              ↓
Encapsulation:        Wrapped in AMQP messages
                              ↓
Transport:            AMQP router → TLS → AMQP router
                              ↓
Decapsulation:        Unwrapped from AMQP messages
                              ↓
Application Layer:    PostgreSQL wire protocol (port 5432)
```

### 3. **Firewall-Friendly**

AMQP over TLS uses standard HTTPS ports (443), making it firewall-friendly. Network admins see normal HTTPS traffic, not custom protocols requiring special firewall rules.

## How RHSI Encapsulates TCP (Like PostgreSQL)

Let's trace exactly what happens when your OpenShift application queries the PostgreSQL database on the Raspberry Pi:

### Step 1: Application Sends SQL Query

```
OpenShift Pod → TCP socket to postgres:5432
```

Your application thinks it's connecting to a local PostgreSQL server. It has no idea RHSI is involved.

### Step 2: Service Routes to skupper-router

```
Service: postgres → Endpoint: skupper-router-pod:1024
```

Kubernetes routes the connection to the skupper-router pod instead of a real database.

### Step 3: TCP Adaptation Layer (Encapsulation)

According to the [skupper-proxy GitHub](https://github.com/skupperproject/skupper-proxy), the skupper-router has a TCP adaptation layer that:

1. **Receives TCP stream** on port 1024
2. **Chunks the TCP stream** into manageable segments
3. **Wraps each segment in AMQP messages** with:
   - Routing key: `postgres` (matches listener/connector)
   - Sequence numbers for ordering
   - Flow control tokens
4. **Sends AMQP messages** through the router

Example (conceptual):
```
TCP Stream:   [SQL query bytes: SELECT * FROM demo_data]
               ↓
AMQP Message: {
                routing-key: "postgres",
                sequence: 1,
                payload: [encrypted TCP segment],
                delivery-tag: 12345
              }
```

### Step 4: AMQP Routing Across the Internet

The AMQP router forwards messages:

```
OpenShift skupper-router → TLS/AMQP → External Host skupper-router
```

Key points:
- **Multiple hops supported**: AMQP routers can forward messages through intermediate nodes
- **Routing key matching**: Messages with routing-key `postgres` are forwarded to nodes that have a connector for `postgres`
- **Flow control**: AMQP prevents overwhelming slow receivers
- **Reliable delivery**: Messages are acknowledged to prevent loss

From the [Skupper router GitHub](https://github.com/skupperproject/skupper-router):
> An application-layer router for Skupper networks that provides dynamic routing and flow control

### Step 5: Decapsulation on External Host

The external host's skupper-router:

1. **Receives AMQP messages** with routing-key `postgres`
2. **Checks connector configuration**: routing-key=postgres, host=127.0.0.1, port=5432
3. **Extracts TCP segments** from AMQP payload
4. **Reassembles TCP stream** in correct order
5. **Forwards to localhost:5432** (PostgreSQL)

### Step 6: PostgreSQL Processes Query

```
PostgreSQL ← TCP socket on 127.0.0.1:5432 ← skupper-router
```

PostgreSQL receives the query on localhost and has no idea it came from across the internet via AMQP.

### Step 7: Response Flows Back

The same process happens in reverse:
```
PostgreSQL response → skupper-router → AMQP encapsulation → 
TLS/Internet → OpenShift skupper-router → TCP decapsulation → 
Application receives result
```

## Why Not Just Use a VPN or Direct TCP Tunnel?

Good question! Here's why AMQP is better for this use case:

### VPN Approach
```
❌ Requires site-to-site VPN setup
❌ Network admin involvement
❌ Exposes entire networks to each other
❌ Complex routing tables
❌ Difficult to manage at scale
```

### Direct TCP Tunnel (like SSH tunnel)
```
❌ Point-to-point only (no routing)
❌ No dynamic discovery
❌ Manual port management
❌ No built-in load balancing
❌ Connection failures require manual restart
```

### AMQP Approach (RHSI)
```
✓ Dynamic routing (service mesh)
✓ Service discovery via routing keys
✓ Multi-hop support
✓ Built-in flow control
✓ Connection pooling
✓ Automatic failover
✓ No network admin involvement
✓ Works through firewalls (HTTPS/443)
```

## AMQP Router Architecture

The skupper-router creates a **mesh network** of AMQP routers:

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│  OpenShift  │◄───────►│  AWS EKS    │◄───────►│  On-Prem    │
│   Cluster   │  AMQP   │   Cluster   │  AMQP   │  Data Center│
│             │  Link   │             │  Link   │             │
└─────────────┘         └─────────────┘         └─────────────┘
       ▲                       ▲                       ▲
       │                       │                       │
       │         AMQP Messages with routing-key       │
       │                       │                       │
       └───────────────────────┴───────────────────────┘
```

Services can be in **any location** and AMQP routing finds the best path.

## AMQP vs Application Protocol

**Important distinction:**

- **Application protocol**: PostgreSQL wire protocol, HTTP, gRPC, etc.
  - What your application speaks
  - Completely preserved and transparent
  
- **Transport protocol**: AMQP
  - How RHSI moves data between locations
  - Invisible to your application

As noted in the [Skupper Google Groups](https://groups.google.com/g/skupper/c/DLZ34YrfQsQ):
> "The skupper routers won't 'know' that the traffic is AMQP - meaning the encapsulation is transparent to the application layer protocol being carried."

Your PostgreSQL client and server continue speaking PostgreSQL wire protocol. AMQP is just the delivery mechanism.

## AMQP Security

AMQP provides security at multiple layers:

### 1. Transport Security (TLS)
```
skupper-router ←──TLS 1.3──→ skupper-router
```
All AMQP traffic is encrypted in transit using TLS.

### 2. Authentication (SASL)
```
Connection Request → SASL Authentication → Certificate Validation
```
RHSI uses mutual TLS authentication - both sides verify certificates.

### 3. Authorization (Routing Keys)
```
Message routing-key: postgres
Router policy: Only forward "postgres" to authorized connectors
```
Routing keys provide a form of access control.

## Performance Characteristics

### Overhead

- **AMQP header**: ~50-100 bytes per message
- **TCP segmentation**: Chunks large streams
- **Latency**: ~2-5ms added latency (for encapsulation/decapsulation)
- **Throughput**: Near line-rate for bulk transfers

From your actual test results:
```
FLOW_LOG: octets=2561 latency=4944 processLatency=3613
```
- **Total latency**: 4.9ms (includes network + processing)
- **Processing latency**: 3.6ms (AMQP encapsulation/routing)
- **Network latency**: ~1.3ms (actual transmission)

This is **acceptable** for most database workloads, especially compared to:
- Cross-region database queries: 50-200ms
- VPN overhead: 10-50ms
- Internet routing: varies widely

### Connection Pooling

AMQP routers maintain **persistent connections** and **multiplex** many application flows over a single AMQP link:

```
100 PostgreSQL connections → 1 AMQP link → 100 PostgreSQL connections
```

This reduces:
- TLS handshake overhead
- NAT table entries
- Firewall state tracking
- Memory per connection

## Troubleshooting AMQP Issues

### Check AMQP Connection Status

```bash
# OpenShift
oc logs -l application=skupper-router -c router -n rhsi-v2-demo | grep AMQP

# External Host
podman logs skupper-router | grep AMQP
```

### Look for AMQP Errors

Common errors:
```
amqp:connection:framing-error - TLS handshake failed
amqp:unauthorized-access - Certificate validation failed  
delivery-failed - No route to destination
```

### Verify Routing Keys Match

```bash
# Listener (OpenShift)
skupper listener status -n rhsi-v2-demo
# Should show: routing-key=postgres

# Connector (External)
skupper connector status --platform podman
# Should show: routing-key=postgres
```

If routing keys don't match, AMQP router won't know where to forward messages.

## Summary

**AMQP in RHSI provides:**

1. ✓ **Dynamic routing** - Messages find their destination automatically
2. ✓ **Protocol encapsulation** - Carry any TCP protocol transparently
3. ✓ **Firewall-friendly** - Uses standard HTTPS/443
4. ✓ **Security** - TLS encryption + certificate authentication
5. ✓ **Reliability** - Message delivery guarantees and flow control
6. ✓ **Scalability** - Connection pooling and multiplexing
7. ✓ **Multi-hop** - Route through intermediate nodes

**Your PostgreSQL connection:**
```
App (PostgreSQL protocol) → TCP → AMQP encapsulation → 
TLS/Internet → AMQP decapsulation → TCP → PostgreSQL (PostgreSQL protocol)
```

The application sees: `postgres:5432` (local service)

The network sees: `HTTPS/443` (normal web traffic)

The reality: AMQP-routed secure tunnel transparently carrying PostgreSQL wire protocol across the internet.

## Further Reading

- [Advanced Message Queuing Protocol - Wikipedia](https://en.wikipedia.org/wiki/Advanced_Message_Queuing_Protocol)
- [Skupper.io: Let your services communicate across Kubernetes clusters](https://developers.redhat.com/blog/2020/01/01/skupper-io-let-your-services-communicate-across-kubernetes-clusters)
- [Why does Skupper use AMQP? - Google Groups](https://groups.google.com/g/skupper/c/DLZ34YrfQsQ)
- [Skupper Router GitHub](https://github.com/skupperproject/skupper-router)
- [Red Hat MRG AMQP Documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_mrg/3/html/messaging_programming_reference/amqp___advanced_message_queuing_protocol)
