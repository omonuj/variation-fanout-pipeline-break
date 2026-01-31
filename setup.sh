#!/bin/bash
set -e

# ---------------------- [DO NOT CHANGE ANYTHING BELOW] ---------------------------------- #
echo "Ensuring supervisord is running..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 5

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Waiting for k3s to be ready..."
MAX_WAIT=180
ELAPSED=0
until kubectl get nodes >/dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Error: k3s is not ready after ${MAX_WAIT} seconds"
        exit 1
    fi
    echo "Waiting for k3s... (${ELAPSED}s elapsed)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo "k3s is ready!"
# ---------------------- [DO NOT CHANGE ANYTHING ABOVE] ---------------------------------- #

NAMESPACE="bleater"
PROFILE_DEPLOY="bleater-profile-service"
BLEAT_DEPLOY="bleater-bleat-service"
MTLS_SVC="bleater-profile-service-mtls"
TLS_SECRET="bleater-profile-mtls"
TRUST_CM="bleater-trust-bundle"
AUDIT_SINK="bleater-audit-sink"          # v32: live audit heartbeat sink
AUDIT_SINK_PORT=8127                      # v32: heartbeat ingest port
PAYLOAD_CM="bleater-rotator-payload"
ROTATOR_CRONJOB="bleater-profile-cert-rotator"
CACHE_SYNC="bleater-profile-cache-sync"
KUBE_CRONJOB="node-telemetry-batcher"
# Strategy H (v22+): randomize the names of the kube-system drift Deployments
# from a pool so that hardcoded "stop cluster-trust-syncer / bleater-mesh-validator"
# solutions break when the actual deployed names differ.  Agents must DISCOVER
# the real drift sources from the live cluster (via labels or behaviour), not
# pattern-match against training-data names.
KUBE_SYNCER_POOL=("cluster-trust-syncer" "cluster-config-mirror" "kube-bundle-reconciler" "cluster-cert-aggregator")
MESH_VALIDATOR_POOL=("bleater-mesh-validator" "bleater-mtls-auditor" "bleater-tls-inspector" "bleater-trust-checker")
KUBE_SYNCER="${KUBE_SYNCER_POOL[$((RANDOM % ${#KUBE_SYNCER_POOL[@]}))]}"
MESH_VALIDATOR="${MESH_VALIDATOR_POOL[$((RANDOM % ${#MESH_VALIDATOR_POOL[@]}))]}"
echo "== Scenario: KUBE_SYNCER=${KUBE_SYNCER}, MESH_VALIDATOR=${MESH_VALIDATOR} =="
LOCAL_REAPER="bleater-cert-reaper"
PROFILE_CANARY="bleater-profile-canary"
CANARY_RUNTIME="bleater-profile-canary-runtime"
CERT_DIR="/tmp/bleater-pki"
TLS_PORT=5671

ROLLOUT_TIMEOUT="180s"

echo "Waiting for bleater namespace..."
ELAPSED=0
until kubectl get namespace ${NAMESPACE} >/dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Error: bleater namespace not found after ${MAX_WAIT} seconds"
        exit 1
    fi
    echo "Waiting for namespace... (${ELAPSED}s elapsed)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo "bleater namespace is ready"

echo "Waiting for at least one Kubernetes node to be Ready..."
NODE_WAIT_TIMEOUT=120
NODE_WAIT_INTERVAL=3
NODE_WAIT_ELAPSED=0
until [ "${NODE_WAIT_ELAPSED}" -ge "${NODE_WAIT_TIMEOUT}" ]; do
  READY_NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {c++} END {print c+0}')
  if [ "${READY_NODE_COUNT}" -ge 1 ]; then
    echo "Node readiness OK (${READY_NODE_COUNT} Ready node(s))"
    break
  fi
  echo "Waiting for node readiness... (${NODE_WAIT_ELAPSED}s elapsed)"
  sleep ${NODE_WAIT_INTERVAL}
  NODE_WAIT_ELAPSED=$((NODE_WAIT_ELAPSED + NODE_WAIT_INTERVAL))
done

if [ "${NODE_WAIT_ELAPSED}" -ge "${NODE_WAIT_TIMEOUT}" ]; then
  echo "Node did not become Ready in time; dumping node diagnostics..."
  kubectl get nodes -o wide || true
  kubectl describe nodes || true
  exit 1
fi

echo "Waiting for baseline bleater services (profile + bleat) to exist..."
DEPLOY_WAIT_TIMEOUT=240
DEPLOY_WAIT_INTERVAL=4
DEPLOY_WAIT_ELAPSED=0
until [ "${DEPLOY_WAIT_ELAPSED}" -ge "${DEPLOY_WAIT_TIMEOUT}" ]; do
  PROFILE_OK=$(kubectl get deployment ${PROFILE_DEPLOY} -n ${NAMESPACE} -o name 2>/dev/null || true)
  BLEAT_OK=$(kubectl get deployment ${BLEAT_DEPLOY} -n ${NAMESPACE} -o name 2>/dev/null || true)
  if [ -n "${PROFILE_OK}" ] && [ -n "${BLEAT_OK}" ]; then
    echo "Both baseline services present"
    break
  fi
  echo "Waiting for ${PROFILE_DEPLOY} and ${BLEAT_DEPLOY}... (${DEPLOY_WAIT_ELAPSED}s elapsed)"
  sleep ${DEPLOY_WAIT_INTERVAL}
  DEPLOY_WAIT_ELAPSED=$((DEPLOY_WAIT_ELAPSED + DEPLOY_WAIT_INTERVAL))
done

if [ -z "${PROFILE_OK}" ] || [ -z "${BLEAT_OK}" ]; then
  echo "Error: required baseline services missing"
  kubectl get deployments -n ${NAMESPACE} -o wide || true
  exit 1
fi

# Derive pod labels from the deployments' own selectors. The bleater app names
# its pods with the short form (app=profile-service, app=bleat-service) while
# the deployment objects use the bleater- prefix — pulling the label live keeps
# us aligned with whatever the base image ships.
PROFILE_POD_LABEL=$(kubectl get deployment ${PROFILE_DEPLOY} -n ${NAMESPACE} \
  -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)
BLEAT_POD_LABEL=$(kubectl get deployment ${BLEAT_DEPLOY} -n ${NAMESPACE} \
  -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)
if [ -z "${PROFILE_POD_LABEL}" ] || [ -z "${BLEAT_POD_LABEL}" ]; then
  echo "Error: could not derive pod labels from deployment selectors"
  kubectl get deployment ${PROFILE_DEPLOY} ${BLEAT_DEPLOY} -n ${NAMESPACE} -o yaml || true
  exit 1
fi
echo "Pod labels: profile=${PROFILE_POD_LABEL}, bleat=${BLEAT_POD_LABEL}"

# Pull a usable image for sidecars and helper workloads. Reuse profile-service's
# image so we know it is locally available in the air-gapped cluster.
SIDECAR_IMAGE=$(kubectl get deployment ${PROFILE_DEPLOY} -n ${NAMESPACE} \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [ -z "${SIDECAR_IMAGE}" ]; then
  SIDECAR_IMAGE=$(kubectl get deployment -n ${NAMESPACE} \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)
fi
if [ -z "${SIDECAR_IMAGE}" ]; then
  echo "Error: could not determine a sidecar image"
  exit 1
fi
echo "Using sidecar image: ${SIDECAR_IMAGE}"

echo "== Generating baseline PKI (bleater-ca + correct profile-mtls cert) and drift PKI (wrong-ca + wrong cert) =="
mkdir -p ${CERT_DIR}
cd ${CERT_DIR}

# Baseline trust anchor: subject CN = "bleater-ca". Identity is disclosed in
# the baseline config. This is the CA the agent must restore.
openssl genrsa -out bleater-ca.key 2048 2>/dev/null
openssl req -new -x509 -days 365 -key bleater-ca.key -out bleater-ca.crt \
  -subj "/CN=bleater-ca/O=Bleater Platform" 2>/dev/null

# Drift CA used by all rotation/reaper sources to inject wrong-CA-signed certs.
openssl genrsa -out wrong-ca.key 2048 2>/dev/null
openssl req -new -x509 -days 365 -key wrong-ca.key -out wrong-ca.crt \
  -subj "/CN=wrong-ca/O=Drift Injection" 2>/dev/null

# Correct profile-mtls cert (signed by bleater-ca, SAN = mTLS headless FQDNs).
cat > profile-mtls-correct.cnf <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = bleater-profile-service-mtls
O = Bleater Platform
[v3_req]
subjectAltName = @san
extendedKeyUsage = serverAuth
[san]
DNS.1 = bleater-profile-service-mtls.bleater.svc.cluster.local
DNS.2 = bleater-profile-service-mtls.bleater.svc
DNS.3 = bleater-profile-service-mtls
EOF

openssl genrsa -out profile-mtls-correct.key 2048 2>/dev/null
openssl req -new -key profile-mtls-correct.key -out profile-mtls-correct.csr \
  -config profile-mtls-correct.cnf 2>/dev/null
openssl x509 -req -in profile-mtls-correct.csr -CA bleater-ca.crt -CAkey bleater-ca.key \
  -CAcreateserial -out profile-mtls-correct.crt -days 365 \
  -extensions v3_req -extfile profile-mtls-correct.cnf 2>/dev/null

# Wrong profile-mtls cert (signed by wrong-ca, SAN = wrong.example.com) — what
# gets installed into the live Secret to inject B1+B2.
cat > profile-mtls-wrong.cnf <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = bleater-profile-service-mtls
O = Bleater Platform
[v3_req]
subjectAltName = @san
extendedKeyUsage = serverAuth
[san]
DNS.1 = wrong.example.com
EOF

openssl genrsa -out profile-mtls-wrong.key 2048 2>/dev/null
openssl req -new -key profile-mtls-wrong.key -out profile-mtls-wrong.csr \
  -config profile-mtls-wrong.cnf 2>/dev/null
openssl x509 -req -in profile-mtls-wrong.csr -CA wrong-ca.crt -CAkey wrong-ca.key \
  -CAcreateserial -out profile-mtls-wrong.crt -days 365 \
  -extensions v3_req -extfile profile-mtls-wrong.cnf 2>/dev/null

CORRECT_CRT_B64=$(base64 -w0 < profile-mtls-correct.crt)
CORRECT_KEY_B64=$(base64 -w0 < profile-mtls-correct.key)
WRONG_CRT_B64=$(base64 -w0 < profile-mtls-wrong.crt)
WRONG_KEY_B64=$(base64 -w0 < profile-mtls-wrong.key)

# Strategy D: webhook server TLS material (CA + serving cert) for the
# MutatingAdmissionWebhook that re-injects wrong cert on every Secret update.
# Self-signed CA → server cert with SAN matching the kube-system Service DNS.
openssl genrsa -out webhook-ca.key 2048 2>/dev/null
openssl req -new -x509 -days 365 -key webhook-ca.key -out webhook-ca.crt \
  -subj "/CN=webhook-ca" 2>/dev/null

cat > webhook-server.cnf <<'EOF'
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = bleater-cert-injector.kube-system.svc
[v3_req]
subjectAltName = @san
extendedKeyUsage = serverAuth
[san]
DNS.1 = bleater-cert-injector.kube-system.svc
DNS.2 = bleater-cert-injector.kube-system.svc.cluster.local
EOF

openssl genrsa -out webhook-server.key 2048 2>/dev/null
openssl req -new -key webhook-server.key -out webhook-server.csr \
  -config webhook-server.cnf 2>/dev/null
openssl x509 -req -in webhook-server.csr -CA webhook-ca.crt -CAkey webhook-ca.key \
  -CAcreateserial -out webhook-server.crt -days 365 \
  -extensions v3_req -extfile webhook-server.cnf 2>/dev/null

WEBHOOK_CA_B64=$(base64 -w0 < webhook-ca.crt)
WEBHOOK_CRT_B64=$(base64 -w0 < webhook-server.crt)
WEBHOOK_KEY_B64=$(base64 -w0 < webhook-server.key)

cd /

echo "== Creating baseline trust ConfigMap (${TRUST_CM}) =="
# Strategy I (v22+): the original platform install carried the label
# `bleater.io/origin=platform-ca` on the trust bundle (documented in the
# baseline config).  The incident-injection block below strips it as part of
# the broader annotation/label scrub, so any restored trust bundle that omits
# the label fails the audit-pipeline gate even if the CA bytes are correct.
TRUST_INDENTED=$(sed 's/^/    /' ${CERT_DIR}/bleater-ca.crt)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${TRUST_CM}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: profile-mtls-mesh
    bleater.io/origin: platform-ca
  annotations:
    bleater.io/rotation-policy: manual
data:
  ca.crt: |
${TRUST_INDENTED}
EOF

echo "== Creating baseline TLS Secret (${TLS_SECRET}) =="
# v24: include the documented bleater.io/key-tier=production label so the
# secret rotation controller treats this as a sanctioned production
# credential.  The incident scrub strips it below, and agents who restore
# without re-adding fail trust_governance.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${TLS_SECRET}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: profile-mtls-mesh
    bleater.io/key-tier: production
type: kubernetes.io/tls
data:
  tls.crt: ${CORRECT_CRT_B64}
  tls.key: ${CORRECT_KEY_B64}
EOF

echo "== Storing drift PKI payload (consumed by rotators) =="
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PAYLOAD_CM}
  namespace: ${NAMESPACE}
data:
  tls.crt.b64: ${WRONG_CRT_B64}
  tls.key.b64: ${WRONG_KEY_B64}
  trust.replacement: |
    # trust bundle reset by ops 2026-05-15
EOF

echo "== Creating headless mTLS service (${MTLS_SVC}) selecting profile-service pods =="
# v24: include the documented bleater.io/audit-tier=enforcing annotation so
# the observability stack tracks endpoint health under the enforcing-tier SLO.
# The incident scrub strips it below, and agents who restore without
# re-adding fail trust_governance.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${MTLS_SVC}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: profile-mtls-mesh
  annotations:
    bleater.io/audit-tier: enforcing
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: ${PROFILE_POD_LABEL}
  ports:
    - name: mtls
      port: ${TLS_PORT}
      targetPort: ${TLS_PORT}
      protocol: TCP
EOF

echo "== Patching ${PROFILE_DEPLOY} with mtls-server sidecar (TLS termination on ${TLS_PORT}) =="
# Strategic merge: containers/volumes are name-keyed, so existing entries are
# preserved and the new sidecar/volumes are added.
kubectl patch deployment ${PROFILE_DEPLOY} -n ${NAMESPACE} --type strategic -p "$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "mtls-server",
            "image": "${SIDECAR_IMAGE}",
            "imagePullPolicy": "IfNotPresent",
            "command": ["sh", "-c", "set -e; mkdir -p /etc/bleater; ln -sf /etc/bleater/trust-cm/ca.crt /etc/bleater/trust.pem; python3 - <<'PY'\nimport socket, ssl, time\nCERT='/etc/bleater/tls/tls.crt'\nKEY='/etc/bleater/tls/tls.key'\ns=socket.socket(socket.AF_INET, socket.SOCK_STREAM)\ns.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\ns.bind(('0.0.0.0', ${TLS_PORT}))\ns.listen(16)\nwhile True:\n  try:\n    conn, _ = s.accept()\n    conn.settimeout(10)\n    try:\n      ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)\n      ctx.load_cert_chain(CERT, KEY)\n      ssock = ctx.wrap_socket(conn, server_side=True)\n      try:\n        ssock.recv(64)\n        try: ssock.send(b'OK\\\\n')\n        except Exception: pass\n      finally:\n        try: ssock.close()\n        except Exception: pass\n    except Exception:\n      try: conn.close()\n      except Exception: pass\n  except Exception:\n    time.sleep(0.5)\nPY"],
            "ports": [{"name": "mtls", "containerPort": ${TLS_PORT}}],
            "readinessProbe": {"tcpSocket": {"port": ${TLS_PORT}}, "initialDelaySeconds": 5, "periodSeconds": 10},
            "volumeMounts": [
              {"name": "profile-mtls-tls", "mountPath": "/etc/bleater/tls", "readOnly": true},
              {"name": "profile-mtls-trust", "mountPath": "/etc/bleater/trust-cm", "readOnly": true}
            ],
            "resources": {"requests": {"cpu": "50m", "memory": "48Mi"}, "limits": {"cpu": "200m", "memory": "96Mi"}}
          }
        ],
        "volumes": [
          {"name": "profile-mtls-tls", "secret": {"secretName": "${TLS_SECRET}"}},
          {"name": "profile-mtls-trust", "configMap": {"name": "${TRUST_CM}"}}
        ]
      }
    }
  }
}
EOF
)"

echo "== Patching ${BLEAT_DEPLOY} with mtls-client sidecar (caller side, holds trust bundle + openssl) =="
kubectl patch deployment ${BLEAT_DEPLOY} -n ${NAMESPACE} --type strategic -p "$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "mtls-client",
            "image": "${SIDECAR_IMAGE}",
            "imagePullPolicy": "IfNotPresent",
            "command": ["sh", "-c", "mkdir -p /etc/bleater && ln -sf /etc/bleater/trust-cm/ca.crt /etc/bleater/trust.pem && while true; do sleep 30; done"],
            "volumeMounts": [
              {"name": "profile-mtls-trust", "mountPath": "/etc/bleater/trust-cm", "readOnly": true}
            ],
            "resources": {"requests": {"cpu": "25m", "memory": "32Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}}
          }
        ],
        "volumes": [
          {"name": "profile-mtls-trust", "configMap": {"name": "${TRUST_CM}"}}
        ]
      }
    }
  }
}
EOF
)"

echo "== Waiting for sidecar rollouts =="
kubectl rollout status deployment/${PROFILE_DEPLOY} -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}
kubectl rollout status deployment/${BLEAT_DEPLOY} -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}

# ----------------------------------------------------------------------------- #
# v32: live audit-heartbeat sink. The audit pipeline reconciles per-pod
# heartbeats from every profile-service replica's mTLS audit relay. Setup
# seeds the sink (it just records lines); the AGENT must add a sidecar to
# the profile-service Deployment that emits the heartbeat. See baseline-config
# 'Audit heartbeat' section. mtls_handshake fails if heartbeats stop or never
# arrive during the wait_consistent window — a static config fix is not enough.
# ----------------------------------------------------------------------------- #
echo "== Creating audit-sink Deployment + Service =="
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${AUDIT_SINK}-app
  namespace: ${NAMESPACE}
  labels:
    app: ${AUDIT_SINK}
data:
  sink.py: |
    import socket, threading, time
    LOG = "/tmp/received.log"
    open(LOG, "a").close()
    def handle(conn):
        try:
            data = conn.recv(65536).decode("utf-8", "replace").strip()
            if data:
                with open(LOG, "a") as fh:
                    fh.write("ts=%d %s\\n" % (int(time.time()), data))
            try: conn.sendall(b"200 OK\\n")
            except Exception: pass
        except Exception:
            pass
        finally:
            try: conn.close()
            except Exception: pass
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", ${AUDIT_SINK_PORT})); srv.listen(128)
    print("${AUDIT_SINK} listening on :${AUDIT_SINK_PORT}", flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${AUDIT_SINK}
  namespace: ${NAMESPACE}
  labels:
    app: ${AUDIT_SINK}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${AUDIT_SINK}
  template:
    metadata:
      labels:
        app: ${AUDIT_SINK}
    spec:
      tolerations:
        - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
        - {key: node-role.kubernetes.io/master, operator: Exists, effect: NoSchedule}
      volumes:
        - name: app
          configMap:
            name: ${AUDIT_SINK}-app
      containers:
        - name: sink
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          command: ["python3", "/app/sink.py"]
          ports:
            - containerPort: ${AUDIT_SINK_PORT}
          volumeMounts:
            - {name: app, mountPath: /app}
          readinessProbe:
            tcpSocket: {port: ${AUDIT_SINK_PORT}}
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests: {cpu: "10m", memory: "24Mi"}
            limits: {cpu: "75m", memory: "64Mi"}
---
apiVersion: v1
kind: Service
metadata:
  name: ${AUDIT_SINK}
  namespace: ${NAMESPACE}
  labels:
    app: ${AUDIT_SINK}
spec:
  selector:
    app: ${AUDIT_SINK}
  ports:
    - name: ingest
      port: ${AUDIT_SINK_PORT}
      targetPort: ${AUDIT_SINK_PORT}
      protocol: TCP
EOF
kubectl rollout status deployment/${AUDIT_SINK} -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}

echo "== Creating ${PROFILE_CANARY} (host for cert-watcher sidecar trap) =="
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROFILE_CANARY}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROFILE_CANARY}
  template:
    metadata:
      labels:
        app: ${PROFILE_CANARY}
    spec:
      automountServiceAccountToken: false
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: canary
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "while true; do sleep 30; done"]
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
EOF
kubectl rollout status deployment/${PROFILE_CANARY} -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}

echo "== Writing pre-incident baseline configuration reference =="
cat > /home/ubuntu/profile-mtls-baseline-config.txt <<'BASELINE'
# Pre-incident configuration notes (may be incomplete — verify against live cluster)
# Profile service mTLS layer:
#   bleater-profile-service runs the profile API as before; in addition, each
#   pod hosts an mTLS termination sidecar that listens on port 5671
#   (TLS) for inter-service auth from other bleater services.
# Headless service:
#   bleater-profile-service-mtls (clusterIP: None) selects profile-service pods
#   and exposes the mTLS endpoint on port 5671.
# Trust anchor:
#   The baseline trust anchor is a CA whose subject CN is `bleater-ca`.
#   The trust bundle ConfigMap `bleater-trust-bundle` (key `ca.crt`) holds the
#   PEM-encoded CA cert and is mounted into the profile-service mTLS sidecar
#   AND into the bleater-bleat-service mTLS client sidecar.
#   The trust bundle just needs to hold the baseline CA (Subject CN
#   `bleater-ca`). The platform-identity SANCTION anchors (origin label,
#   rotation-policy, install-id, trust-domain, composite binding, attestation)
#   are NOT declared on this trust bundle — they live on the separate
#   `bleater-audit-policy` ConfigMap (see 'Audit policy' below).
# Cert / key:
#   The mTLS sidecar on profile-service presents a cert from Secret
#   `bleater-profile-mtls` (keys `tls.crt`, `tls.key`); the cert must be signed
#   by the baseline CA and its SAN must include
#   `bleater-profile-service-mtls.bleater.svc.cluster.local`.
#   Install binding: the served leaf must ALSO carry the platform install-id
#   (the value recorded at `/etc/bleater/install-id.txt`) as an additional SAN
#   entry, e.g. `<install-id>.install.bleater.local`. Downstream verifiers use
#   this to bind the served certificate to THIS install generation; a leaf
#   without the install-anchored SAN is treated as unverified for steady-state
#   trust even when the chain and the certificate policy otherwise check out.
#   Signature digest: the platform audit chain mandates that the leaf be SIGNED
#   using SHA-384 (the platform's required signature digest), NOT the tooling
#   default of SHA-256. A leaf signed with SHA-256 is rejected by the digest
#   policy even when its key length, policy OID and SANs are all correct.
#   The Secret carries label `bleater.io/key-tier=production` so the secret
#   rotation controller recognises it as a production-tier credential and
#   refuses to evict its mount during rolling node maintenance; absent label
#   the audit pipeline considers the Secret untrusted.
# Headless service annotation:
#   The mTLS headless service `bleater-profile-service-mtls` carries annotation
#   `bleater.io/audit-tier=enforcing` so the platform observability stack
#   tracks its endpoint health under the enforcing-tier SLO. Without this
#   annotation, the audit pipeline classifies the service as advisory-tier
#   and the trust state is reported as unverified regardless of cert validity.
# Cert policy:
#   The audit pipeline additionally enforces an X.509 policy on the leaf cert
#   served at the mTLS endpoint: the cert must satisfy EVERY property declared
#   in the platform certificate policy file (`/etc/bleater/cert-policy.txt`).
#   The file is a multi-property KEY=VALUE form — at minimum the
#   certificatePolicies OID AND the platform's minimum RSA key bit length.
#   A blessed leaf must satisfy ALL fields the file declares; leaf certs
#   missing the policy OID, or generated with a key smaller than the platform
#   minimum, are rejected by downstream verifiers even when the chain
#   otherwise verifies and the trust anchor is correct.
# Caller side:
#   bleater-bleat-service hosts an mTLS client sidecar that mounts the same
#   trust bundle at /etc/bleater/trust.pem and uses it to verify the
#   profile-service mTLS endpoint when fanning author profile lookups.
# Audit agent:
#   The audit pipeline observes the mesh via a STANDALONE audit agent — a
#   dedicated `bleater-audit-agent` Deployment in the bleater namespace (NOT a
#   sidecar on profile-service). It opens a TCP connection to the
#   `bleater-audit-sink` Service at port 8127 every few seconds and writes a
#   single line of the form:
#       agent=bleater-audit-agent route=mtls-audit count=<N> install=<INSTALL_DIGEST>
#   where `<N>` is a monotonically increasing counter and `<INSTALL_DIGEST>` is
#   the SHA-256 of the EXACT bytes of `/etc/bleater/install-id.txt` (no trailing
#   newline), present on EVERY line. The pipeline reads `/tmp/received.log` on
#   the sink and requires the agent's counter to advance AND the install proof
#   to be present across the verification window. Without a live, install-proofed
#   audit agent the audit subsystem is reported unhealthy.
# Audit policy:
#   The audit pipeline keeps its sanction declaration on a dedicated ConfigMap
#   `bleater-audit-policy` (SEPARATE from the trust bundle). For the audit
#   subsystem to be accepted, that ConfigMap must carry:
#     - label `bleater.io/origin=platform-ca` (else the policy is unauthorised),
#     - annotation `bleater.io/rotation-policy=manual`,
#     - an annotation echoing the install-id (`/etc/bleater/install-id.txt`),
#     - an annotation echoing the trust-domain (`/etc/bleater/trust-domain.txt`),
#     - an annotation = SHA-256 of `<install-id>:<trust-domain>` (install-id
#       first, single colon, no spaces, no trailing newline),
#     - an annotation = SHA-256 of the exact bytes of
#       `/etc/bleater/rollout-attestation.txt` (no trailing newline).
#   (Any annotation key is accepted as long as the value matches.) A
#   non-sanctioned audit-policy ConfigMap is rejected for steady-state trust.
#   Note: a recurring in-cluster audit-reconciler keeps re-stripping this policy
#   — stopping it is not enough; the CAPABILITY (its RBAC) that lets it patch the
#   policy ConfigMap must be revoked, or it can simply be resumed.
# Cluster DNS resolution was operating normally before the incident.
# Platform components observed pre-incident in kube-system:
#   cluster-config-sync (CronJob) — routine config distribution, not bleater-owned
#     (leave untouched unless explicitly implicated in bleater cert drift)
# Bleater components observed pre-incident in bleater namespace:
#   bleater-profile-metrics-cache — profile-layer metrics aggregation sidecar (read-only, no cert access)
BASELINE
chmod 644 /home/ubuntu/profile-mtls-baseline-config.txt
chown ubuntu:ubuntu /home/ubuntu/profile-mtls-baseline-config.txt

echo "== Writing on-call incident notes =="
cat > /home/ubuntu/incident-notes-2026-05-15.txt <<'NOTES'
# bleater-incidents channel — pasted from on-call handoff (2026-05-15)
[10:42] bleat API still returning 200 but bleats not landing in follower timelines
[10:51] checked profile-service mTLS sidecar logs — TLS handshake failures from bleat-service caller
[10:55] rotated the cert manually with kubectl patch, looked clean for ~2 min, went sideways again on its own
[11:02] trust bundle keeps drifting back to the wrong shape after we fix it
[11:04] tried scaling down the cert-reaper to 0 — it bounced right back, something is keeping it alive
[11:14] platform: "this isn't just one thing in this namespace, check broadly"
[11:21] tried looking at the profile canary too — we did some ops on it last week, not sure if anything stuck around
[11:30] handing off — something in here keeps reapplying the broken state
NOTES
chmod 644 /home/ubuntu/incident-notes-2026-05-15.txt
chown ubuntu:ubuntu /home/ubuntu/incident-notes-2026-05-15.txt

# Same incident shape every rollout. Score variance comes from agent
# investigation/fix behavior, not random setup branches.
echo "== Injecting B1+B2: replace mTLS cert with wrong-CA + wrong-SAN cert =="
kubectl patch secret ${TLS_SECRET} -n ${NAMESPACE} --type merge -p \
  "{\"data\":{\"tls.crt\":\"${WRONG_CRT_B64}\",\"tls.key\":\"${WRONG_KEY_B64}\"}}"

echo "== Injecting B3: strip CA from trust bundle ConfigMap =="
kubectl patch configmap ${TRUST_CM} -n ${NAMESPACE} --type merge -p \
  '{"data":{"ca.crt":"# trust bundle reset by ops 2026-05-15\n"}}'

# v22: also strip the bleater.io/origin label as part of the same scrub.
# Documented in baseline-config as a required label; agents who only restore
# the cert bytes without re-adding the label fail trust_governance.
kubectl label configmap ${TRUST_CM} -n ${NAMESPACE} bleater.io/origin- --overwrite \
  >/dev/null 2>&1 || true

# v24: strip three more baseline-documented metadata marks.  Agents who only
# read task.yaml (which doesn't mention any of these) and skim baseline-config
# will miss at least one and fail governance.
kubectl annotate configmap ${TRUST_CM} -n ${NAMESPACE} \
  bleater.io/rotation-policy- --overwrite >/dev/null 2>&1 || true
kubectl label secret ${TLS_SECRET} -n ${NAMESPACE} \
  bleater.io/key-tier- --overwrite >/dev/null 2>&1 || true
kubectl annotate service ${MTLS_SVC} -n ${NAMESPACE} \
  bleater.io/audit-tier- --overwrite >/dev/null 2>&1 || true

# v25: install-checksum requirement.  The platform install records a checksum
# at /etc/bleater/install-id.txt; the trust bundle ConfigMap must carry an
# annotation echoing the file contents (v27: any annotation key with matching
# value) for the audit pipeline to recognise it as belonging to this install.
mkdir -p /etc/bleater
INSTALL_CHECKSUM=$(openssl rand -hex 8)
echo "${INSTALL_CHECKSUM}" > /etc/bleater/install-id.txt
chmod 644 /etc/bleater/install-id.txt
chown root:root /etc/bleater/install-id.txt 2>/dev/null || true
cp /etc/bleater/install-id.txt /opt/grader-install-id.txt
chmod 600 /opt/grader-install-id.txt
chown root:root /opt/grader-install-id.txt 2>/dev/null || true

# v45: platform trust-domain anchor — a second buried install-scoped value the
# trust bundle must also echo through its metadata (sibling of the install-id).
# Disclosed in baseline-config 'Trust anchor'. Root-mirrored for the grader.
TRUST_DOMAIN=$(openssl rand -hex 8)
echo "${TRUST_DOMAIN}" > /etc/bleater/trust-domain.txt
chmod 644 /etc/bleater/trust-domain.txt
chown root:root /etc/bleater/trust-domain.txt 2>/dev/null || true
echo "${TRUST_DOMAIN}" > /opt/grader-trust-domain.txt
chmod 600 /opt/grader-trust-domain.txt
chown root:root /opt/grader-trust-domain.txt 2>/dev/null || true
kubectl annotate configmap ${TRUST_CM} -n ${NAMESPACE} \
  bleater.io/install-checksum- --overwrite >/dev/null 2>&1 || true

# v31: rollout-attestation requirement (compound multi-step gate).  Every
# blessed rotation must stamp the SHA-256 DIGEST of the platform's
# rollout-attestation token on the trust bundle as an annotation. Multi-step:
# read the file, sha256 the exact bytes, set the annotation. Independent of
# install-id (different file, different value, different intent: install-id
# binds the bundle to THIS install; rollout-attestation binds it to THIS
# rotation event).
ROLLOUT_ATTESTATION="1.3.6.1.4.1.99999.$(( (RANDOM % 9000) + 1000 )).$(( (RANDOM % 9000) + 1000 ))"
printf '%s' "${ROLLOUT_ATTESTATION}" > /etc/bleater/rollout-attestation.txt
chmod 644 /etc/bleater/rollout-attestation.txt
chown root:root /etc/bleater/rollout-attestation.txt 2>/dev/null || true
printf '%s' "${ROLLOUT_ATTESTATION}" > /opt/grader-attestation.txt
chmod 600 /opt/grader-attestation.txt
chown root:root /opt/grader-attestation.txt 2>/dev/null || true

# v28/v30: cert-policy gate for mtls_handshake.  Same hidden-filesystem
# pattern as install-id but for the leaf cert content. v30 makes this a
# COMPOUND multi-property requirement: the file now declares BOTH the
# certificatePolicies OID AND the platform's required minimum RSA key bit
# length, so a blessed leaf must satisfy both.  Parsing the multi-line format,
# pulling the OID into the openssl ext config, AND wiring the bit length into
# `openssl genrsa` are independent failure points — agents who hardcode the
# old single-line single-OID assumption miss the bit length entirely.
POLICY_OID="1.3.6.1.4.1.99999.$((RANDOM % 900 + 100)).$((RANDOM % 90 + 10))"
POLICY_BITS=4096
cat > /etc/bleater/cert-policy.txt <<POLICY
# Bleater profile mTLS leaf cert policy
# Every rotated leaf must satisfy ALL fields below.
OID=${POLICY_OID}
RSA_KEY_BITS=${POLICY_BITS}
POLICY
chmod 644 /etc/bleater/cert-policy.txt
chown root:root /etc/bleater/cert-policy.txt 2>/dev/null || true
cp /etc/bleater/cert-policy.txt /opt/grader-cert-policy.txt
chmod 600 /opt/grader-cert-policy.txt
chown root:root /opt/grader-cert-policy.txt 2>/dev/null || true
echo "== Cert policy this run: OID=${POLICY_OID} RSA_KEY_BITS=${POLICY_BITS} =="

# Strategy C: strip last-applied-configuration annotations so agents cannot
# reconstruct known-good state from annotation history — they must use the
# baseline file and live cluster knowledge.
kubectl annotate secret ${TLS_SECRET} -n ${NAMESPACE} \
  kubectl.kubernetes.io/last-applied-configuration- --overwrite 2>/dev/null || true
kubectl annotate configmap ${TRUST_CM} -n ${NAMESPACE} \
  kubectl.kubernetes.io/last-applied-configuration- --overwrite 2>/dev/null || true
kubectl annotate service ${MTLS_SVC} -n ${NAMESPACE} \
  kubectl.kubernetes.io/last-applied-configuration- --overwrite 2>/dev/null || true

echo "== Injecting B4: cert rotator CronJob (re-injects wrong cert every 2 minutes) =="
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ROTATOR_CRONJOB}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROTATOR_CRONJOB}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${ROTATOR_CRONJOB}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${ROTATOR_CRONJOB}
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${ROTATOR_CRONJOB}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${ROTATOR_CRONJOB}
  namespace: ${NAMESPACE}
  annotations:
    bleater.io/purpose: "profile mTLS cert health check"
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          serviceAccountName: ${ROTATOR_CRONJOB}
          restartPolicy: Never
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
            - key: node-role.kubernetes.io/master
              operator: Exists
              effect: NoSchedule
          containers:
            - name: rotator
              image: "${SIDECAR_IMAGE}"
              imagePullPolicy: IfNotPresent
              env:
                - name: WRONG_CRT_B64
                  valueFrom:
                    configMapKeyRef:
                      name: ${PAYLOAD_CM}
                      key: tls.crt.b64
                - name: WRONG_KEY_B64
                  valueFrom:
                    configMapKeyRef:
                      name: ${PAYLOAD_CM}
                      key: tls.key.b64
              command:
                - sh
                - -c
                - |
                  kubectl patch secret ${TLS_SECRET} -n ${NAMESPACE} --type merge \
                    -p "{\"data\":{\"tls.crt\":\"\${WRONG_CRT_B64}\",\"tls.key\":\"\${WRONG_KEY_B64}\"}}"
EOF

echo "== Injecting B5: ${KUBE_SYNCER} in kube-system (re-strips trust bundle every 5s) =="
# kube-system controller agents must discover by auditing all .allowed_namespaces.
# Same cross-namespace trap pattern as the original ring task, applied to the
# trust bundle target instead of pod labels.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${KUBE_SYNCER}
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${KUBE_SYNCER}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${KUBE_SYNCER}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${KUBE_SYNCER}
    namespace: kube-system
roleRef:
  kind: Role
  name: ${KUBE_SYNCER}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${KUBE_SYNCER}
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${KUBE_SYNCER}
  template:
    metadata:
      labels:
        app: ${KUBE_SYNCER}
    spec:
      serviceAccountName: ${KUBE_SYNCER}
      automountServiceAccountToken: true
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: syncer
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              python3 - <<'PY'
              import json, os, ssl, time
              import urllib.error, urllib.request

              namespace = "bleater"
              host = os.environ["KUBERNETES_SERVICE_HOST"]
              port = os.environ["KUBERNETES_SERVICE_PORT"]
              api = f"https://{host}:{port}"
              token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
              ca_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

              with open(token_path, "r", encoding="utf-8") as fh:
                  token = fh.read().strip()
              ctx = ssl.create_default_context(cafile=ca_path)

              def patch(path, body, content_type="application/merge-patch+json"):
                  data = json.dumps(body).encode("utf-8")
                  req = urllib.request.Request(
                      api + path, data=data, method="PATCH",
                      headers={"Authorization": f"Bearer {token}",
                               "Content-Type": content_type},
                  )
                  try:
                      with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                          return r.status
                  except urllib.error.HTTPError as e:
                      return e.code
                  except Exception:
                      return 0

              replacement = "# trust bundle reset by ops 2026-05-15\n"
              while True:
                  patch(
                      f"/api/v1/namespaces/{namespace}/configmaps/bleater-trust-bundle",
                      {"data": {"ca.crt": replacement}},
                  )
                  time.sleep(5)
              PY
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
EOF
kubectl rollout status deployment/${KUBE_SYNCER} -n kube-system --timeout=${ROLLOUT_TIMEOUT}

echo "== Injecting ${MESH_VALIDATOR} in kube-system (Secret rotator, 20s loop) =="
# Second kube-system drift surface. Innocuous name ("mesh validator" sounds like
# observability infrastructure, not a fault). Targets the Secret specifically —
# without stopping this one the cert keeps flipping back within the grader's
# stability window even after the bleater-local reaper is killed.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${MESH_VALIDATOR}
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${MESH_VALIDATOR}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${MESH_VALIDATOR}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${MESH_VALIDATOR}
    namespace: kube-system
roleRef:
  kind: Role
  name: ${MESH_VALIDATOR}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${MESH_VALIDATOR}
  namespace: kube-system
  labels:
    app.kubernetes.io/part-of: bleater-platform
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${MESH_VALIDATOR}
  template:
    metadata:
      labels:
        app: ${MESH_VALIDATOR}
    spec:
      serviceAccountName: ${MESH_VALIDATOR}
      automountServiceAccountToken: true
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: validator
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              python3 - <<'PY'
              import json, os, ssl, time
              import urllib.error, urllib.request

              namespace = "bleater"
              host = os.environ["KUBERNETES_SERVICE_HOST"]
              port = os.environ["KUBERNETES_SERVICE_PORT"]
              api = f"https://{host}:{port}"
              token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
              ca_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

              with open(token_path, "r", encoding="utf-8") as fh:
                  token = fh.read().strip()
              ctx = ssl.create_default_context(cafile=ca_path)

              def get(path):
                  req = urllib.request.Request(
                      api + path,
                      headers={"Authorization": f"Bearer {token}"},
                  )
                  try:
                      with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                          return json.loads(r.read())
                  except Exception:
                      return None

              def patch(path, body, content_type="application/merge-patch+json"):
                  data = json.dumps(body).encode("utf-8")
                  req = urllib.request.Request(
                      api + path, data=data, method="PATCH",
                      headers={"Authorization": f"Bearer {token}",
                               "Content-Type": content_type},
                  )
                  try:
                      with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                          return r.status
                  except urllib.error.HTTPError as e:
                      return e.code
                  except Exception:
                      return 0

              while True:
                  payload = get(f"/api/v1/namespaces/{namespace}/configmaps/bleater-rotator-payload")
                  if payload:
                      data = payload.get("data", {})
                      crt = data.get("tls.crt.b64", "")
                      key = data.get("tls.key.b64", "")
                      if crt and key:
                          patch(
                              f"/api/v1/namespaces/{namespace}/secrets/bleater-profile-mtls",
                              {"data": {"tls.crt": crt, "tls.key": key}},
                          )
                  time.sleep(20)
              PY
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
EOF
kubectl rollout status deployment/${MESH_VALIDATOR} -n kube-system --timeout=${ROLLOUT_TIMEOUT}

echo "== Injecting kube-system CronJob ${KUBE_CRONJOB} (Secret rotator, every minute) =="
# Drift in CronJob form (not Deployment) and in kube-system rather than bleater.
# Agents who audit kube-system with kubectl get pods/deploy/sts but skip
# kubectl get cronjob -A miss this entirely. Resembles a legitimate platform
# reconciliation cronjob in name and labels.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${KUBE_CRONJOB}
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${KUBE_CRONJOB}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${KUBE_CRONJOB}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${KUBE_CRONJOB}
    namespace: kube-system
roleRef:
  kind: Role
  name: ${KUBE_CRONJOB}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${KUBE_CRONJOB}
  namespace: kube-system
  labels:
    app.kubernetes.io/part-of: bleater-platform
  annotations:
    bleater.io/purpose: "platform config reconciliation"
  finalizers:
    - bleater.io/telemetry-batcher-protection
spec:
  schedule: "*/1 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          serviceAccountName: ${KUBE_CRONJOB}
          restartPolicy: Never
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
            - key: node-role.kubernetes.io/master
              operator: Exists
              effect: NoSchedule
          containers:
            - name: syncer
              image: "${SIDECAR_IMAGE}"
              imagePullPolicy: IfNotPresent
              command:
                - sh
                - -c
                - |
                  python3 - <<'PY'
                  import json, os, ssl
                  import urllib.error, urllib.request

                  namespace = "bleater"
                  host = os.environ["KUBERNETES_SERVICE_HOST"]
                  port = os.environ["KUBERNETES_SERVICE_PORT"]
                  api = f"https://{host}:{port}"
                  token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
                  ca_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
                  with open(token_path, "r", encoding="utf-8") as fh:
                      token = fh.read().strip()
                  ctx = ssl.create_default_context(cafile=ca_path)
                  def get(path):
                      req = urllib.request.Request(api+path, headers={"Authorization": f"Bearer {token}"})
                      try:
                          with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                              return json.loads(r.read())
                      except Exception:
                          return None
                  def patch(path, body):
                      data = json.dumps(body).encode("utf-8")
                      req = urllib.request.Request(
                          api+path, data=data, method="PATCH",
                          headers={"Authorization": f"Bearer {token}",
                                   "Content-Type": "application/merge-patch+json"},
                      )
                      try:
                          with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                              return r.status
                      except urllib.error.HTTPError as e:
                          return e.code
                      except Exception:
                          return 0
                  payload = get(f"/api/v1/namespaces/{namespace}/configmaps/bleater-rotator-payload")
                  if payload:
                      data = payload.get("data", {})
                      crt = data.get("tls.crt.b64", "")
                      key = data.get("tls.key.b64", "")
                      if crt and key:
                          patch(
                              f"/api/v1/namespaces/{namespace}/secrets/bleater-profile-mtls",
                              {"data": {"tls.crt": crt, "tls.key": key}},
                          )
                  PY
EOF

echo "== Injecting ${LOCAL_REAPER} (additional bleater-local rotator, 7s loop) =="
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${LOCAL_REAPER}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${LOCAL_REAPER}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${LOCAL_REAPER}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${LOCAL_REAPER}
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${LOCAL_REAPER}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${LOCAL_REAPER}
  namespace: ${NAMESPACE}
  finalizers:
    - bleater.io/cert-reaper-protection
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${LOCAL_REAPER}
  template:
    metadata:
      labels:
        app: ${LOCAL_REAPER}
    spec:
      serviceAccountName: ${LOCAL_REAPER}
      automountServiceAccountToken: true
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: reaper
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              python3 - <<'PY'
              import json, os, ssl, time
              import urllib.error, urllib.request

              namespace = "bleater"
              host = os.environ["KUBERNETES_SERVICE_HOST"]
              port = os.environ["KUBERNETES_SERVICE_PORT"]
              api = f"https://{host}:{port}"
              token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
              ca_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

              with open(token_path, "r", encoding="utf-8") as fh:
                  token = fh.read().strip()
              ctx = ssl.create_default_context(cafile=ca_path)

              def get(path):
                  req = urllib.request.Request(
                      api + path,
                      headers={"Authorization": f"Bearer {token}"},
                  )
                  try:
                      with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                          return json.loads(r.read())
                  except Exception:
                      return None

              def patch(path, body, content_type="application/merge-patch+json"):
                  data = json.dumps(body).encode("utf-8")
                  req = urllib.request.Request(
                      api + path, data=data, method="PATCH",
                      headers={"Authorization": f"Bearer {token}",
                               "Content-Type": content_type},
                  )
                  try:
                      with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                          return r.status
                  except urllib.error.HTTPError as e:
                      return e.code
                  except Exception:
                      return 0

              while True:
                  payload = get(f"/api/v1/namespaces/{namespace}/configmaps/bleater-rotator-payload")
                  if payload:
                      data = payload.get("data", {})
                      crt = data.get("tls.crt.b64", "")
                      key = data.get("tls.key.b64", "")
                      if crt and key:
                          patch(
                              f"/api/v1/namespaces/{namespace}/secrets/bleater-profile-mtls",
                              {"data": {"tls.crt": crt, "tls.key": key}},
                          )
                  time.sleep(7)
              PY
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
EOF
kubectl rollout status deployment/${LOCAL_REAPER} -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}

echo "== Embedding cert-watcher sidecar inside ${PROFILE_CANARY} (delete-vs-patch trap) =="
# Same trap pattern as the original task's metrics-collector sidecar.
# Agents who fix the canary deployment via patch preserve this sidecar — it
# keeps re-injecting the wrong cert into the Secret. Agents who delete and
# recreate ${PROFILE_CANARY} from baseline remove it naturally.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${CANARY_RUNTIME}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${CANARY_RUNTIME}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${CANARY_RUNTIME}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${CANARY_RUNTIME}
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${CANARY_RUNTIME}
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl delete deployment ${PROFILE_CANARY} -n ${NAMESPACE} --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROFILE_CANARY}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PROFILE_CANARY}
  template:
    metadata:
      labels:
        app: ${PROFILE_CANARY}
    spec:
      serviceAccountName: ${CANARY_RUNTIME}
      automountServiceAccountToken: true
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: canary
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "while true; do sleep 30; done"]
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
        - name: cert-watcher
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              python3 - <<'PY'
              import json, os, ssl, time
              import urllib.error, urllib.request

              namespace = "bleater"
              host = os.environ["KUBERNETES_SERVICE_HOST"]
              port = os.environ["KUBERNETES_SERVICE_PORT"]
              api = f"https://{host}:{port}"
              token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
              ca_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

              with open(token_path, "r", encoding="utf-8") as fh:
                  token = fh.read().strip()
              ctx = ssl.create_default_context(cafile=ca_path)

              def get(path):
                  req = urllib.request.Request(
                      api + path,
                      headers={"Authorization": f"Bearer {token}"},
                  )
                  try:
                      with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                          return json.loads(r.read())
                  except Exception:
                      return None

              def patch(path, body, content_type="application/merge-patch+json"):
                  data = json.dumps(body).encode("utf-8")
                  req = urllib.request.Request(
                      api + path, data=data, method="PATCH",
                      headers={"Authorization": f"Bearer {token}",
                               "Content-Type": content_type},
                  )
                  try:
                      with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                          return r.status
                  except urllib.error.HTTPError as e:
                      return e.code
                  except Exception:
                      return 0

              while True:
                  payload = get(f"/api/v1/namespaces/{namespace}/configmaps/bleater-rotator-payload")
                  if payload:
                      data = payload.get("data", {})
                      crt = data.get("tls.crt.b64", "")
                      key = data.get("tls.key.b64", "")
                      if crt and key:
                          patch(
                              f"/api/v1/namespaces/{namespace}/secrets/bleater-profile-mtls",
                              {"data": {"tls.crt": crt, "tls.key": key}},
                          )
                  time.sleep(11)
              PY
          resources:
            requests:
              cpu: "25m"
              memory: "32Mi"
            limits:
              cpu: "100m"
              memory: "64Mi"
EOF
kubectl rollout status deployment/${PROFILE_CANARY} -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}

echo "== Strategy A: Injecting ${CACHE_SYNC} (hidden cert re-patcher, 45s loop) =="
# This deployment lives in the bleater namespace but is NOT in the grader.
# It patches bleater-profile-mtls every 45s with the wrong cert, so even after
# agents fix the Secret it will revert — forcing them to find and stop it before
# the mtls_handshake window can stabilise. The name looks like a metrics/cache
# component to avoid easy identification.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${CACHE_SYNC}
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${CACHE_SYNC}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${CACHE_SYNC}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${CACHE_SYNC}
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: ${CACHE_SYNC}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CACHE_SYNC}
  namespace: ${NAMESPACE}
  labels:
    app: ${CACHE_SYNC}
    component: cache
  finalizers:
    - bleater.io/cache-sync-protection
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${CACHE_SYNC}
  template:
    metadata:
      labels:
        app: ${CACHE_SYNC}
        component: cache
    spec:
      serviceAccountName: ${CACHE_SYNC}
      containers:
        - name: cache-sync
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          env:
            - name: WRONG_CRT_B64
              valueFrom:
                configMapKeyRef:
                  name: ${PAYLOAD_CM}
                  key: tls.crt.b64
            - name: WRONG_KEY_B64
              valueFrom:
                configMapKeyRef:
                  name: ${PAYLOAD_CM}
                  key: tls.key.b64
          command:
            - python3
            - -c
            - |
              import json, os, ssl, time
              import urllib.error, urllib.request

              namespace = "bleater"
              host = os.environ["KUBERNETES_SERVICE_HOST"]
              port = os.environ["KUBERNETES_SERVICE_PORT"]
              api = f"https://{host}:{port}"
              token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
              ca_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
              wrong_crt = os.environ["WRONG_CRT_B64"]
              wrong_key = os.environ["WRONG_KEY_B64"]

              with open(token_path, "r", encoding="utf-8") as fh:
                  token = fh.read().strip()
              ctx = ssl.create_default_context(cafile=ca_path)

              def patch_secret():
                  body = {"data": {"tls.crt": wrong_crt, "tls.key": wrong_key}}
                  data = json.dumps(body).encode("utf-8")
                  req = urllib.request.Request(
                      api + f"/api/v1/namespaces/{namespace}/secrets/bleater-profile-mtls",
                      data=data, method="PATCH",
                      headers={"Authorization": f"Bearer {token}",
                               "Content-Type": "application/merge-patch+json"},
                  )
                  try:
                      with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
                          return r.status
                  except Exception:
                      return 0

              while True:
                  patch_secret()
                  time.sleep(45)
          resources:
            requests:
              cpu: "20m"
              memory: "28Mi"
            limits:
              cpu: "80m"
              memory: "56Mi"
EOF
kubectl rollout status deployment/${CACHE_SYNC} -n ${NAMESPACE} --timeout=${ROLLOUT_TIMEOUT}

echo "== Strategy D: MutatingAdmissionWebhook that re-injects wrong cert on every Secret update =="
# Agents systematically audit Deployments/CronJobs/Secrets/ConfigMaps across all
# accessible namespaces, but do NOT audit admission webhook configurations.
# This webhook intercepts every UPDATE/CREATE on the bleater-profile-mtls
# Secret and overwrites tls.crt/tls.key with the wrong-CA payload, so even after
# an agent stops every visible drift source and patches the Secret correctly,
# the webhook silently re-mutates it back to the broken cert until the agent
# discovers and deletes the MutatingWebhookConfiguration.
#
# objectSelector scopes the webhook to ONLY the bleater-profile-mtls Secret so
# we don't accidentally break other Secret operations cluster-wide.  The Secret
# is labelled below.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bleater-cert-injector
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: bleater-cert-injector-tls
  namespace: kube-system
type: kubernetes.io/tls
data:
  tls.crt: ${WEBHOOK_CRT_B64}
  tls.key: ${WEBHOOK_KEY_B64}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bleater-cert-injector
  namespace: kube-system
  labels:
    app: bleater-cert-injector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bleater-cert-injector
  template:
    metadata:
      labels:
        app: bleater-cert-injector
    spec:
      serviceAccountName: bleater-cert-injector
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: webhook
          image: "${SIDECAR_IMAGE}"
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8443
          env:
            - name: WRONG_CRT_B64
              value: "${WRONG_CRT_B64}"
            - name: WRONG_KEY_B64
              value: "${WRONG_KEY_B64}"
          volumeMounts:
            - name: tls
              mountPath: /etc/webhook-tls
              readOnly: true
          command:
            - sh
            - -c
            - |
              python3 - <<'PY'
              import base64, json, os, ssl
              from http.server import BaseHTTPRequestHandler, HTTPServer

              CRT = os.environ["WRONG_CRT_B64"]
              KEY = os.environ["WRONG_KEY_B64"]

              class H(BaseHTTPRequestHandler):
                  def log_message(self, *a, **k):
                      pass
                  def do_POST(self):
                      n = int(self.headers.get("Content-Length", 0))
                      body = json.loads(self.rfile.read(n))
                      req = body.get("request", {}) or {}
                      uid = req.get("uid")
                      obj = req.get("object", {}) or {}
                      name = obj.get("metadata", {}).get("name", "")
                      if name == "bleater-profile-mtls":
                          patch = [
                              {"op": "replace", "path": "/data/tls.crt", "value": CRT},
                              {"op": "replace", "path": "/data/tls.key", "value": KEY},
                          ]
                          resp = {
                              "apiVersion": "admission.k8s.io/v1",
                              "kind": "AdmissionReview",
                              "response": {
                                  "uid": uid,
                                  "allowed": True,
                                  "patchType": "JSONPatch",
                                  "patch": base64.b64encode(json.dumps(patch).encode()).decode(),
                              },
                          }
                      else:
                          resp = {
                              "apiVersion": "admission.k8s.io/v1",
                              "kind": "AdmissionReview",
                              "response": {"uid": uid, "allowed": True},
                          }
                      data = json.dumps(resp).encode()
                      self.send_response(200)
                      self.send_header("Content-Type", "application/json")
                      self.send_header("Content-Length", str(len(data)))
                      self.end_headers()
                      self.wfile.write(data)

              httpd = HTTPServer(("0.0.0.0", 8443), H)
              ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
              ctx.load_cert_chain("/etc/webhook-tls/tls.crt", "/etc/webhook-tls/tls.key")
              httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
              httpd.serve_forever()
              PY
          resources:
            requests:
              cpu: "20m"
              memory: "32Mi"
            limits:
              cpu: "80m"
              memory: "64Mi"
      volumes:
        - name: tls
          secret:
            secretName: bleater-cert-injector-tls
---
apiVersion: v1
kind: Service
metadata:
  name: bleater-cert-injector
  namespace: kube-system
spec:
  selector:
    app: bleater-cert-injector
  ports:
    - port: 443
      targetPort: 8443
EOF

kubectl rollout status deployment/bleater-cert-injector -n kube-system --timeout=${ROLLOUT_TIMEOUT}

# Label the bleater-profile-mtls Secret so the webhook's objectSelector matches
# only this one Secret (and not other Secrets the agent or the cluster touches).
kubectl label secret ${TLS_SECRET} -n ${NAMESPACE} \
  bleater.io/mtls-target=true --overwrite >/dev/null 2>&1 || true

# Apply the MutatingWebhookConfiguration AFTER the webhook pod is ready and the
# Secret is labelled.  failurePolicy=Fail ensures every Secret UPDATE matching
# the selector goes through the webhook (or fails closed) — the trap can't be
# silently bypassed by the webhook crashing.  objectSelector keeps the blast
# radius to exactly one Secret.
kubectl apply -f - <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: bleater-cert-injector
webhooks:
  - name: cert-injector.bleater.io
    clientConfig:
      service:
        name: bleater-cert-injector
        namespace: kube-system
        path: "/mutate"
        port: 443
      caBundle: ${WEBHOOK_CA_B64}
    rules:
      - operations: ["CREATE", "UPDATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["secrets"]
        scope: "Namespaced"
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: ${NAMESPACE}
    objectSelector:
      matchLabels:
        bleater.io/mtls-target: "true"
    failurePolicy: Fail
    sideEffects: None
    admissionReviewVersions: ["v1"]
    timeoutSeconds: 5
    reinvocationPolicy: IfNeeded
EOF

# Grant ubuntu-user permission to delete admission webhook configurations so
# solution.sh (and any agent who discovers the webhook) can clean it up.
# Without this, the task would be unsolvable.
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ubuntu-webhook-cleaner
rules:
  - apiGroups: ["admissionregistration.k8s.io"]
    resources: ["mutatingwebhookconfigurations", "validatingwebhookconfigurations"]
    verbs: ["get", "list", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ubuntu-webhook-cleaner-binding
subjects:
  - kind: ServiceAccount
    name: ubuntu-user
    namespace: default
roleRef:
  kind: ClusterRole
  name: ubuntu-webhook-cleaner
  apiGroup: rbac.authorization.k8s.io
EOF

echo "== Strategy B: Injecting HPA pinner on ${LOCAL_REAPER} (keeps replicas=1) =="
# The HPA enforces minReplicas=1 at the k8s control-plane level.  Agents who
# try kubectl scale --replicas=0 will have the HPA immediately restore it.
# Grader already checks replicas>0 on cert-reaper, so agents must delete both
# the deployment AND this HPA to fully stop the re-injection loop.
kubectl apply -f - <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${LOCAL_REAPER}-pinner
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${LOCAL_REAPER}
  minReplicas: 1
  maxReplicas: 1
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 80
EOF

echo "== Granting ubuntu-user limited kube-system access =="
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ubuntu-ns-manager
  namespace: kube-system
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "patch", "update"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch", "update", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]
    verbs: ["patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-ns-manager-binding
  namespace: kube-system
subjects:
  - kind: ServiceAccount
    name: ubuntu-user
    namespace: default
roleRef:
  kind: Role
  name: ubuntu-ns-manager
  apiGroup: rbac.authorization.k8s.io
EOF

if [ -f /home/ubuntu/.allowed_namespaces ]; then
  cat >> /home/ubuntu/.allowed_namespaces <<'APPEND'

# Additionally, limited read/write access to kube-system has been granted
# for operational use (configmaps, deployments).
APPEND
fi

mkdir -p /opt

# Strategy H (v22+): the grader reads the actual kube-system drift Deployment
# names from this root-only scenario file (KUBE_SYNCER and MESH_VALIDATOR were
# picked from a pool at the top of this script).  Agents who hardcode the
# v17–v21 names from training data or prior cycles will target the wrong
# resources and leave the real drift sources running.
cat > /opt/grader-scenario.json <<EOF
{"kube_syncer":"${KUBE_SYNCER}","mesh_validator":"${MESH_VALIDATOR}"}
EOF
chmod 600 /opt/grader-scenario.json
chown root:root /opt/grader-scenario.json 2>/dev/null || true

# === Audit policy ConfigMap (governance surface, SEPARATE from the trust bundle) ===
# The platform's mTLS audit-policy declaration. It starts UN-sanctioned (carries
# none of the platform-identity anchors), so downstream verifiers reject it until
# the operator re-declares the sanction anchors on it (see baseline-config 'Audit
# policy'). It is a distinct object from bleater-trust-bundle; the cert path never
# reads it, so governance and the handshake share nothing.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleater-audit-policy
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: profile-mtls-mesh
data:
  policy: "platform mTLS audit policy declaration"
EOF

# === Governance audit-drift: a non-sanctioned audit-reconciler CronJob ===
# Re-applies advisory-tier trust config and can strip the trust bundle's
# sanction metadata if resumed. Lives in kube-system, finalizer-protected. Like
# the other recurring drift, scaling/suspending it is insufficient — a dormant
# reconciler can be resumed to re-corrupt the audit/governance state, so it must
# be DELETED for trust governance to be stable on its own. Independent of the
# cert path: it touches audit/governance metadata, not the cert or DNS.
GOV_CRONJOB="bleater-audit-reconciler"
# The reconciler's SCRUB CAPABILITY is granted by a Role+RoleBinding in the
# bleater namespace (it can patch the trust-bundle ConfigMap). Removing the
# cronjob alone leaves this capability orphaned — any actor (or a recreated
# cronjob) bound to it can resume scrubbing the bundle's sanction metadata. The
# capability (RBAC) must be revoked for trust governance to be stable. This is a
# DIFFERENT cleanup axis from the cert cronjob (which is graded on existence),
# so the two subscores do not move together.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${GOV_CRONJOB}
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${GOV_CRONJOB}
  namespace: ${NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${GOV_CRONJOB}
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: ${GOV_CRONJOB}
    namespace: kube-system
roleRef:
  kind: Role
  name: ${GOV_CRONJOB}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${GOV_CRONJOB}
  namespace: kube-system
  labels:
    app.kubernetes.io/part-of: bleater-platform
  annotations:
    bleater.io/purpose: "advisory-tier audit reconciliation"
  finalizers:
    - bleater.io/audit-reconciler-protection
spec:
  schedule: "*/2 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          tolerations:
            - {key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}
            - {key: node-role.kubernetes.io/master, operator: Exists, effect: NoSchedule}
          containers:
            - name: reconciler
              image: "${SIDECAR_IMAGE}"
              imagePullPolicy: IfNotPresent
              command: ["sh","-c","echo audit-reconcile tick; sleep 5"]
EOF

# === Stale manual EndpointSlice polluting the mTLS service endpoint set ===
# An out-of-band ops change left a manual EndpointSlice attached to the mTLS
# headless service, advertising a ghost endpoint (no pod backing). It pollutes
# resolution of the mTLS FQDN and survives one-time service fixes — the agent
# must find and delete it. Scoped to the mTLS service only (independent of the
# audit-sink / trust-governance path).
kubectl apply -f - <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${MTLS_SVC}-stale
  namespace: ${NAMESPACE}
  labels:
    kubernetes.io/service-name: ${MTLS_SVC}
    endpointslice.kubernetes.io/managed-by: ops-manual
addressType: IPv4
ports:
  - name: mtls
    protocol: TCP
    port: ${TLS_PORT}
endpoints:
  - addresses:
      - 10.244.251.251
    hostname: mtls-ghost
    conditions:
      ready: true
EOF

# === DNS-level interference for the mTLS endpoint (CoreDNS) ===
# The bleat->profile mTLS handshake resolves
# bleater-profile-service-mtls.bleater.svc.cluster.local through cluster DNS.
# Two CoreDNS rewrite faults are injected with the SAME incident shape every
# run (variance must come from agent investigation depth, not random setup):
#   Fault 1 (obvious): a `rewrite name` that redirects the mTLS FQDN to a
#                      non-existent namespace (bleater-env) -> NXDOMAIN.
#   Fault 2 (hidden):  a `rewrite stop name exact` variant that black-holes the
#                      same FQDN. An agent who only strips the obvious
#                      `rewrite name` line leaves this intact and the handshake
#                      keeps failing.
# Both faults are scoped to the mTLS FQDN ONLY, so the audit-sink resolution
# path (trust_governance) is unaffected and stays independent of the handshake.
echo "Injecting CoreDNS interference for mTLS endpoint resolution..."
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' > /tmp/_mcf
awk '/kubernetes cluster.local/{print "    rewrite name regex (.*\\.)?bleater-profile-service-mtls\\.bleater\\.svc\\.cluster\\.local bleater-profile-service-mtls.bleater-env.svc.cluster.local"}1' /tmp/_mcf > /tmp/_mcf2
awk '/kubernetes cluster.local/{print "    rewrite stop name exact bleater-profile-service-mtls.bleater.svc.cluster.local mtls-blackhole.kube-system.svc.cluster.local"}1' /tmp/_mcf2 > /tmp/_mcf3
PATCHED_MCF=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" < /tmp/_mcf3)
kubectl patch configmap coredns -n kube-system --type merge -p "{\"data\":{\"Corefile\":${PATCHED_MCF}}}"
rm -f /tmp/_mcf /tmp/_mcf2 /tmp/_mcf3
kubectl rollout restart deployment/coredns -n kube-system >/dev/null 2>&1 || true
kubectl rollout status deployment/coredns -n kube-system --timeout=60s >/dev/null 2>&1 || true
sleep 8

# Hygiene: clear events so agents cannot infer injected faults from event history.
kubectl delete events --all -A >/dev/null 2>&1 || true

# Hide grader.py from agent (grader runs as root post-eval)
find / -maxdepth 4 -name "grader.py" -not -path "/proc/*" -not -path "/sys/*" -exec chmod 000 {} \; 2>/dev/null || true

# Hide setup
chmod 000 /opt/setup.sh 2>/dev/null || true
rm -f /opt/setup.sh 2>/dev/null || true
chmod 000 /home/ubuntu/setup.sh 2>/dev/null || true
rm -f /home/ubuntu/setup.sh 2>/dev/null || true
find / -maxdepth 3 -name "setup.sh" -not -path "/proc/*" -not -path "/sys/*" -exec chmod 000 {} \; 2>/dev/null || true
find / -maxdepth 3 -name "setup.sh" -not -path "/proc/*" -not -path "/sys/*" -exec rm -f {} \; 2>/dev/null || true

# Wipe the PKI scratch dir so wrong-ca + correct-ca material isn't readable.
rm -rf ${CERT_DIR} 2>/dev/null || true

echo "Setup complete."
