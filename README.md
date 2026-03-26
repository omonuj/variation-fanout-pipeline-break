# Bleater — Profile ↔ Bleat mTLS Trust Erosion

An agentic-AI evaluation task (Apex/Horizon format). An autonomous agent is dropped into a
running Kubernetes (k3s) cluster where the inter-service **mTLS trust mesh** between two
microservices has degraded, and must diagnose and durably repair it — while active,
self-healing drift controllers keep reintroducing the broken state.

## The scenario

**Bleater** is a fictional distributed, microservices-based social-media platform running in the
`bleater` namespace. A recently rolled-out inter-service mTLS layer between
`bleater-profile-service` and `bleater-bleat-service` is broken: both services are `Running` and
reachable on their application ports, but `bleater-bleat-service` can no longer authenticate to
the `bleater-profile-service` mTLS endpoint.

The visible symptom is subtle: posts to the bleat API succeed (HTTP 200), but the bleat never
enriches author-profile data and is silently dropped from the downstream timeline pipeline. The
mTLS client sidecar logs repeated `x509: certificate signed by unknown authority` /
`tls: bad certificate` errors.

### The faults the agent must untangle

The break is deliberately **not** a single misconfiguration. A durable fix requires finding and
stopping every source of drift, not just patching symptoms:

- **Corrupted cert / CA trust bundle** — the TLS secret and the trust-bundle ConfigMap hold the
  wrong material. Manual `kubectl patch` looks clean for a minute, then degrades again.
- **Self-healing drift controllers** — multiple in-cluster controllers reapply the broken trust
  state. Some live **outside** the `bleater` namespace (in `kube-system`). They rotate names
  between deployments, so they must be identified by *what they do*, not by matching a known-name
  list. A controller merely scaled to zero is not fixed — it can be resumed.
- **CoreDNS tampering** — the mTLS service FQDN may be redirected to a non-existent namespace or
  black-holed; more than one interfering rewrite rule may be present.
- **Stale service-discovery artifacts** — leftover EndpointSlice objects advertise endpoints not
  backed by any real profile-service pod, polluting the endpoint set even after the Service looks
  correct.
- **A leftover canary workload** — a recent ops touch on a profile-service canary left extra
  moving parts behind.

The environment is air-gapped: `/home/ubuntu/profile-mtls-baseline-config.txt` (last known-good
conventions, trust anchor identity, cert/CA locations) and
`/home/ubuntu/incident-notes-2026-05-15.txt` (what the previous operator tried — signal, not
instruction) are the primary sources of truth.

## How it's graded

`grade()` produces two **equally weighted, functional, structurally independent** subscores. Each
is verified against live cluster state, not metadata matching:

| Subscore | Weight | What it verifies |
| --- | --- | --- |
| `mtls_handshake` | 0.50 | The live TLS cert path is healthy **and stays healthy**: trust-anchor CN, cert policy (OID + RSA bits), correct SAN (headless FQDN of the profile-service mTLS endpoint), and a verified `s_client` handshake held consistently across a sustained observation window (8 passes). A live drift controller re-corrupting the cert mid-window resets the streak — so patching without stopping drift fails here. |
| `trust_governance` | 0.50 | The audit/governance pipeline is genuinely live and cannot be re-corrupted: a standalone `bleater-audit-agent` Deployment emits a monotonic install-proofed heartbeat to `bleater-audit-sink`, policy sanctions live on a **separate** `bleater-audit-policy` ConfigMap, and the audit-reconciler's scrub **capability** (Role/RoleBinding) is *revoked*, not merely its CronJob deleted. |

**Why the subscores decorrelate.** They share **zero** read resources and **zero** required agent
action. The handshake reads the cert / Secret / trust-bundle CA / profile pods / DNS; governance
reads only governance-owned resources (its own policy ConfigMap, the audit agent/sink, the
reconciler's RBAC). This makes the `(1,0)` and `(0,1)` quadrants genuinely reachable — an agent can
restore the handshake without wiring governance, or vice versa — which is what keeps the two
subscores from moving in lockstep and satisfies the QC spec's Functional-Subscore-Variance and
No-Dead-Weights constraints. (The header comment in [grader.py](grader.py) records the full v29→v51
tuning history behind this design.)

## Repo layout

| File | Purpose |
| --- | --- |
| [task.yaml](task.yaml) | Task definition: agent-facing prompt, observed symptoms, expected outcome, metadata. |
| [Dockerfile](Dockerfile) | Base image + env; grants the agent user scoped `kube-system` access needed to stop the out-of-namespace drift controller. |
| [setup.sh](setup.sh) | Provisions the cluster and injects every fault (corrupted certs, drift controllers, CoreDNS rewrites, stale EndpointSlices, canary leftovers). |
| [solution.sh](solution.sh) | Reference solution — the durable fix (answer key). |
| [grader.py](grader.py) | Automated grader producing the two functional subscores above. |
| [data/ubuntu-user-rbac.yaml](data/ubuntu-user-rbac.yaml) | RBAC granted to the agent user. |

## Task metadata

- **Difficulty:** hard
- **Category:** platform-eng
- **Tags:** kubernetes, mtls, x509, secrets, configmap, sidecar

## A note on what's not here

Generated run artifacts (`.rollouts/`, `.validation/`, `__pycache__/`) and internal authoring
tooling (`.claude/`, `.horizon/`) are intentionally `.gitignore`d — they capture eval methodology
and difficulty-tuning internals, not the task definition itself.
