#!/usr/bin/env python3
# bleater-profile-mtls-trust-erosion grader v2 — Subscore Independence fix.
#
# v29 reviewer (Nihit Raj): trust_governance AND-gated 10+ heterogeneous checks
# spanning unrelated resource types AND drift-controller state. Because the
# drift controllers ALSO break the handshake's wait_consistent window, both
# subscores moved in 100% lockstep ([0,0] or [1,1] only).
#
# v30 attempt made trust_governance pure METADATA matching (labels, annotations,
# install-id / CA-fingerprint / attestation anchors). That removed the lockstep
# but left mtls_handshake deadweight-1 and trust_governance non-functional
# (failing Functional-Tests-as-Subscores) — rollouts went to avg 0.90.
#
# v32 fix — TWO cohesive FUNCTIONAL subscores, de-bundled and independent:
#   - mtls_handshake   — the live TLS cert path: trust-anchor CN + cert-policy
#                        (OID + RSA bits) + a verified s_client handshake held
#                        over the window. Fails on cert/CA corruption.
#   - trust_governance — the audit/governance pipeline is LIVE: every Ready
#                        profile-service replica emits a monotonic per-pod
#                        heartbeat to bleater-audit-sink (the agent must wire the
#                        audit relay sidecar). The relay runs over plain TCP,
#                        independent of cert validity, so it does NOT move in
#                        lockstep with the cert path. No metadata bundling.
#
# Independence: fixing the cert (handshake) does not wire the relay (governance)
# and vice-versa — the [1,0] and [0,1] quadrants are both reachable.
import hashlib
import json
import subprocess
import time
from apex_arena._types import GradingResult

NAMESPACE = "bleater"
PROFILE_DEPLOY = "bleater-profile-service"
BLEAT_DEPLOY = "bleater-bleat-service"
MTLS_SVC = "bleater-profile-service-mtls"
TLS_SECRET = "bleater-profile-mtls"
TLS_PORT = 5671
TRUST_PATH = "/etc/bleater/trust.pem"
CLIENT_CONTAINER = "mtls-client"
SERVER_CONTAINER = "mtls-server"
TRUST_CM = "bleater-trust-bundle"

# v32: live audit-heartbeat sink — every profile-service replica must emit a
# monotonically increasing per-pod heartbeat to the sink during the
# verification window. mtls_handshake fails if the heartbeat never arrives or
# stops advancing.
AUDIT_SINK = "bleater-audit-sink"
AUDIT_SINK_PORT = 8127
HEARTBEAT_MARKER = "route=mtls-audit"
# v51: governance reads ONLY these (none touched by mtls_handshake) — full
# structural decouple. The audit relay runs as a standalone Deployment (NOT a
# profile-service sidecar) and the sanction policy lives in its own ConfigMap
# (NOT the trust bundle the handshake reads).
AUDIT_POLICY_CM = "bleater-audit-policy"
AUDIT_AGENT_TAG = "agent=bleater-audit-agent"

# v28/v30: cert-policy gate for mtls_handshake.  Setup writes the platform's
# required leaf-cert policy to /etc/bleater/cert-policy.txt (agent-readable)
# and mirrors it to /opt/grader-cert-policy.txt (root-only for the grader).
# v30 multi-property KEY=VALUE form: at minimum OID and RSA_KEY_BITS — the
# blessed leaf must satisfy both.
CERT_POLICY_PATH = "/opt/grader-cert-policy.txt"


def _read_cert_policy():
    """Parse multi-property KEY=VALUE cert-policy file. Falls back to
    legacy single-line single-OID form so older fixtures keep working."""
    try:
        with open(CERT_POLICY_PATH, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except Exception:
        return None, None
    oid = None
    bits = None
    if "=" in raw or "\n" in raw:
        for line in raw.splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if "=" in s:
                k, v = s.split("=", 1)
                k = k.strip().upper()
                v = v.strip()
                if k in ("OID", "POLICY_OID", "CERT_POLICY", "CERTIFICATE_POLICY"):
                    oid = v
                elif k in ("RSA_KEY_BITS", "RSA_BITS", "KEY_BITS", "MIN_KEY_BITS"):
                    try:
                        bits = int(v)
                    except ValueError:
                        pass
            elif oid is None:
                oid = s
    else:
        oid = raw.strip()
    if oid == "":
        oid = None
    return oid, bits


POLICY_OID_REQ, POLICY_BITS_REQ = _read_cert_policy()


def _read_attestation_digest():
    """v31: SHA-256 of the rollout-attestation token (exact bytes, no
    trailing newline) — the value the trust bundle must echo through any
    annotation."""
    try:
        with open("/opt/grader-attestation.txt", "r", encoding="utf-8") as fh:
            tok = fh.read().strip()
        if not tok:
            return None
        return hashlib.sha256(tok.encode("utf-8")).hexdigest()
    except Exception:
        return None


ROLLOUT_ATT_DIGEST = _read_attestation_digest()

# Strategy H (v22+): setup.sh randomly assigns the names of the kube-system
# drift Deployments from a pool, so agents cannot hardcode against names from
# prior runs or task documentation.  The chosen names land in this root-only
# scenario file; if the file is absent (e.g. pre-v22 setup) we fall back to
# the v17–v21 default names.
SCENARIO_PATH = "/opt/grader-scenario.json"

def _load_scenario():
    defaults = {
        "kube_syncer": "cluster-trust-syncer",
        "mesh_validator": "bleater-mesh-validator",
    }
    try:
        with open(SCENARIO_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return {
            "kube_syncer": data.get("kube_syncer", defaults["kube_syncer"]),
            "mesh_validator": data.get("mesh_validator", defaults["mesh_validator"]),
        }
    except Exception:
        return defaults

_scn = _load_scenario()
KUBE_SYNCER = _scn["kube_syncer"]
MESH_VALIDATOR = _scn["mesh_validator"]

PROFILE_CANARY = "bleater-profile-canary"
CANARY_RUNTIME = "bleater-profile-canary-runtime"
ROTATOR_CRONJOB = "bleater-profile-cert-rotator"
KUBE_CRONJOB = "node-telemetry-batcher"
LOCAL_REAPER = "bleater-cert-reaper"
CACHE_SYNC = "bleater-profile-cache-sync"
GOV_CRONJOB = "bleater-audit-reconciler"  # governance audit-drift (kube-system)


def run_kubectl(cmd: str, timeout: int = 30):
    try:
        result = subprocess.run(
            f"kubectl {cmd}",
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "timed out"
    except Exception as e:
        return -1, "", str(e)


def kubectl_json(cmd: str):
    code, out, err = run_kubectl(cmd)
    if code != 0:
        return None, err or "kubectl failed"
    try:
        return json.loads(out), ""
    except json.JSONDecodeError:
        return None, "failed to parse json"


def wait_consistent(fn, passes=3, gap=8, timeout=150, interval=10):
    """Require `passes` consecutive successes spaced `gap` seconds apart.
    Mirrors the helper from fanout-ring-restoration so behavior under flake is
    identical."""
    deadline = time.time() + timeout
    streak = 0
    last_detail = "condition not met"
    while time.time() < deadline:
        ok, detail = fn()
        last_detail = detail
        if ok:
            streak += 1
            if streak >= passes:
                return True, detail
            time.sleep(gap)
        else:
            streak = 0
            time.sleep(interval)
    return False, last_detail


def list_pods(label_selector: str):
    pods, err = kubectl_json(
        f"get pods -n {NAMESPACE} -l {label_selector} -o json"
    )
    if not pods:
        return [], err or "no pods returned"
    names = [
        item.get("metadata", {}).get("name", "")
        for item in (pods.get("items") or [])
    ]
    return [n for n in names if n], ""


def deployment_pod_label(deploy_name: str):
    """Pull the `app` label the deployment selector uses to find its pods.

    The bleater base image names its pods with the short form
    (app=profile-service, app=bleat-service) while the deployment objects use
    the bleater- prefix. Reading the live selector keeps us aligned regardless
    of how the base image labels things across versions."""
    dep, _ = kubectl_json(f"get deployment {deploy_name} -n {NAMESPACE} -o json")
    if not dep:
        return None
    return (
        dep.get("spec", {})
        .get("selector", {})
        .get("matchLabels", {})
        .get("app")
    )


def container_ready(pod_name: str, container_name: str):
    pod, err = kubectl_json(f"get pod {pod_name} -n {NAMESPACE} -o json")
    if not pod:
        return False, f"could not get pod {pod_name}: {err}"
    if pod.get("metadata", {}).get("deletionTimestamp"):
        return False, f"{pod_name} terminating"
    phase = pod.get("status", {}).get("phase", "")
    if phase != "Running":
        return False, f"{pod_name} phase={phase}"
    statuses = pod.get("status", {}).get("containerStatuses") or []
    target = next((s for s in statuses if s.get("name") == container_name), None)
    if target is None:
        return False, f"{pod_name} missing container {container_name}"
    if not target.get("ready"):
        return False, f"{pod_name}/{container_name} not ready"
    return True, "ready"


def _audit_sink_pod():
    pods, _ = kubectl_json(f"get pods -n {NAMESPACE} -l app={AUDIT_SINK} -o json")
    for p in (pods or {}).get("items", []) or []:
        ok = False
        for c in (p.get("status", {}).get("conditions", []) or []):
            if c.get("type") == "Ready" and c.get("status") == "True":
                ok = True
                break
        if ok:
            return p.get("metadata", {}).get("name", "")
    return ""


def _audit_sink_log():
    sp = _audit_sink_pod()
    if not sp:
        return None, f"{AUDIT_SINK} pod not Ready"
    code, out, err = run_kubectl(
        f"exec {sp} -n {NAMESPACE} -- cat /tmp/received.log", timeout=20
    )
    if code != 0:
        return None, err or "could not read sink log"
    return out, ""


import re as _re_hb
_HB_COUNT_RE = _re_hb.compile(r"count=(\d+)")


def _install_digest():
    """v33: SHA-256 of the exact bytes of /opt/grader-install-id.txt
    (no trailing newline) — the value the agent's relay must embed in
    every heartbeat line as `install=<digest>`."""
    try:
        with open("/opt/grader-install-id.txt", "rb") as fh:
            tok = fh.read().rstrip(b"\n")
        if not tok:
            return None
        return hashlib.sha256(tok).hexdigest()
    except Exception:
        return None


INSTALL_DIGEST = _install_digest()


def _heartbeat_count_for(pod, lines):
    """v33: Highest count= value observed for this pod tagged with
    route=mtls-audit AND carrying the install=<INSTALL_DIGEST> proof on the
    same line. Lines without the install proof are ignored — they count as
    audit-silent for this pod."""
    best = None
    for ln in lines:
        if f"pod={pod}" not in ln or HEARTBEAT_MARKER not in ln:
            continue
        if INSTALL_DIGEST is not None and f"install={INSTALL_DIGEST}" not in ln:
            continue
        m = _HB_COUNT_RE.search(ln)
        if m:
            v = int(m.group(1))
            best = v if best is None else max(best, v)
    return best


def check_mtls_handshake():
    """Verify the bleater-bleat-service mTLS client sidecar can complete a
    verified TLS handshake against the bleater-profile-service mTLS endpoint
    AND that the trust anchor in the live trust bundle matches the baseline
    identity (Subject CN = bleater-ca, per /home/ubuntu/profile-mtls-baseline-config.txt).

    Single cohesive functional outcome — verified profile↔bleat mTLS through
    the headless mTLS service with the baseline trust anchor. Sequential
    causal layers underneath:
       - trust bundle CA Subject CN matches the documented baseline identity
         (`bleater-ca`) — catches agents who regenerate a CA with a different
         CN; orthogonal to governance (this is a cert-content property, not a
         drift-controller state)
       - bleat-service pods Running with mtls-client sidecar Ready
       - profile-service pods Running with mtls-server sidecar Ready
       - cert chain in the served cert verifies against /etc/bleater/trust.pem
         (catches B1 wrong-CA cert, B3 stripped trust bundle)
       - hostname verification against the mTLS headless FQDN succeeds
         (catches B2 wrong-SAN)
       - state holds for `passes=5, gap=15s` so flips driven by drift sources
         cause the streak to reset
    """

    fqdn = f"{MTLS_SVC}.{NAMESPACE}.svc.cluster.local"

    def _trust_anchor_cn_ok():
        """Pull the trust bundle CA out of the live ConfigMap, decode it via
        openssl, and confirm the Subject CN equals the documented baseline
        identity. Loose substring match handles openssl's output variants
        ("subject= /CN=..." vs "subject=CN = ...")."""
        cmd = (
            f"get configmap bleater-trust-bundle -n {NAMESPACE} "
            f"-o jsonpath='{{.data.ca\\.crt}}'"
        )
        code, ca_pem, err = run_kubectl(cmd, timeout=15)
        if code != 0 or not ca_pem.strip():
            return False, f"trust bundle ca.crt empty or unreadable: {err}"

        # Pipe the PEM through openssl x509 -subject. Use shell here since we
        # are intentionally building a pipeline of two commands.
        import subprocess as _sub
        try:
            r = _sub.run(
                "openssl x509 -noout -subject",
                shell=True, input=ca_pem, text=True,
                capture_output=True, timeout=10,
            )
        except Exception as e:
            return False, f"openssl invocation failed: {e}"
        if r.returncode != 0:
            return False, "trust bundle ca.crt is not a valid PEM cert"
        subject = (r.stdout or "").strip().lower()
        if "cn=bleater-ca" not in subject.replace(" ", ""):
            return False, (
                f"trust anchor CN does not match baseline 'bleater-ca' "
                f"(got: {subject})"
            )
        return True, "trust anchor CN ok"

    def _cert_satisfies_policy():
        """v30: check the leaf cert in bleater-profile-mtls Secret satisfies
        EVERY property declared in /etc/bleater/cert-policy.txt — currently
        the certificatePolicies OID AND the platform minimum RSA key bit
        length. Both are independent failure points; agents who parse the file
        as a single-line OID (the v28 shape) miss the bit-length requirement
        entirely."""
        if POLICY_OID_REQ is None and POLICY_BITS_REQ is None:
            return True, "no policy configured (skipping)"
        code, b64, _ = run_kubectl(
            f"get secret {TLS_SECRET} -n {NAMESPACE} "
            f"-o jsonpath='{{.data.tls\\.crt}}'",
            timeout=10,
        )
        if code != 0 or not (b64 or "").strip():
            return False, "could not fetch leaf cert from Secret"
        import subprocess as _sub
        try:
            r = _sub.run(
                f"echo '{b64}' | base64 -d | openssl x509 -noout -text 2>&1",
                shell=True, capture_output=True, text=True, timeout=15,
            )
        except Exception as e:
            return False, f"openssl invocation failed: {e}"
        if r.returncode != 0:
            return False, "leaf cert parse failed"
        text = r.stdout or ""
        if POLICY_OID_REQ and POLICY_OID_REQ not in text:
            return False, (
                f"leaf cert missing required policy OID {POLICY_OID_REQ} "
                f"in certificatePolicies (see /etc/bleater/cert-policy.txt)"
            )
        if POLICY_BITS_REQ is not None:
            import re as _re
            m = _re.search(r"(?:RSA )?Public-Key:\s*\((\d+)\s*bit\)", text)
            if not m:
                return False, "leaf cert public-key bit length unparseable"
            got = int(m.group(1))
            if got < POLICY_BITS_REQ:
                return False, (
                    f"leaf cert RSA key is {got}-bit; platform certificate "
                    f"policy requires >= {POLICY_BITS_REQ}-bit "
                    f"(see /etc/bleater/cert-policy.txt)"
                )
        # v45: install-anchor in the leaf cert. Per baseline-config 'Cert / key',
        # the served leaf must also carry the platform install-id (the value in
        # /etc/bleater/install-id.txt) as an additional SAN entry, binding the
        # cert to THIS install. This is a buried, no-observable-consequence
        # requirement: the TLS handshake itself works with or without it, so an
        # agent that regenerates a policy-clean cert but does not read the
        # baseline carefully omits it. Cohesive with "the leaf satisfies platform
        # certificate policy".
        try:
            with open("/opt/grader-install-id.txt", "r", encoding="utf-8") as fh:
                inst = fh.read().strip()
        except Exception:
            inst = ""
        if inst and inst not in text:
            return False, (
                f"leaf cert is not install-anchored: it does not carry the "
                f"platform install-id ({inst[:8]}...) from "
                f"/etc/bleater/install-id.txt as a SAN entry — downstream "
                f"verifiers cannot bind the served cert to this install "
                f"(see baseline-config 'Cert / key')"
            )
        # v46: platform signature-digest policy (conflicting-default trap). The
        # audit chain mandates SHA-384 leaf signatures, NOT the openssl default
        # SHA-256 — disclosed in baseline-config 'Cert / key'. An agent that
        # regenerates a policy-clean leaf with default settings satisfies the
        # OID/bits/SAN but signs with SHA-256 and fails here. No observable
        # handshake consequence, so no self-correction.
        sig_line = ""
        for ln in text.splitlines():
            if "signature algorithm" in ln.lower():
                sig_line = ln.lower()
                break
        if sig_line and "sha384" not in sig_line.replace("-", ""):
            return False, (
                "leaf cert signed with the wrong digest: the platform "
                "certificate policy mandates SHA-384 leaf signatures (not the "
                "default SHA-256) — see baseline-config 'Cert / key'"
            )
        return True, "leaf cert satisfies policy (OID + bits + install-anchor + sig-digest)"

    def _handshake_ok():
        ok, d = _trust_anchor_cn_ok()
        if not ok:
            return False, d
        ok, d = _cert_satisfies_policy()
        if not ok:
            return False, d

        # v42: mTLS endpoint membership (parent fanout-ring ghost-EndpointSlice
        # pattern). Every endpoint serving the mTLS headless service must be
        # backed by a real profile-service pod (i.e. carry a targetRef). A
        # stale/manual EndpointSlice injects a ghost endpoint with no pod
        # backing, which pollutes resolution of the mTLS FQDN; it must be found
        # and removed. Disclosed in task.yaml ("stale ... EndpointSlice objects
        # may persist ... and still pollute the mTLS endpoint set"). Auto-managed
        # EndpointSlices always carry a targetRef, so this never false-fails on
        # legitimate endpoints. Independent of trust_governance.
        eps, ep_err = kubectl_json(
            f"get endpointslice -n {NAMESPACE} "
            f"-l kubernetes.io/service-name={MTLS_SVC} -o json"
        )
        if eps is None:
            return False, f"could not read mTLS EndpointSlices: {ep_err}"
        for item in (eps.get("items", []) or []):
            for ep in (item.get("endpoints", []) or []):
                if not ep.get("targetRef"):
                    addrs = ep.get("addresses", []) or []
                    return False, (
                        f"mTLS service has a ghost endpoint {addrs} with no "
                        f"profile-service pod backing — a stale/manual "
                        f"EndpointSlice is polluting the mTLS endpoint set; it "
                        f"must be removed (see task.yaml service-discovery note)"
                    )

        bleat_label = deployment_pod_label(BLEAT_DEPLOY)
        profile_label = deployment_pod_label(PROFILE_DEPLOY)
        if not bleat_label or not profile_label:
            return False, (
                f"could not derive pod labels (bleat={bleat_label}, "
                f"profile={profile_label})"
            )

        callers, err = list_pods(f"app={bleat_label}")
        if not callers:
            return False, f"no caller pods (app={bleat_label}): {err}"

        # Caller readiness — the mtls-client sidecar must be live so we have
        # somewhere to exec from.
        for pod in callers:
            ok, d = container_ready(pod, CLIENT_CONTAINER)
            if not ok:
                return False, d

        # Server readiness — we need at least one profile-service pod with the
        # mtls-server sidecar Ready. Without it the connect would TCP-fail.
        servers, _ = list_pods(f"app={profile_label}")
        if not servers:
            return False, f"no server pods (app={profile_label})"
        ready_servers = 0
        for pod in servers:
            ok, _ = container_ready(pod, SERVER_CONTAINER)
            if ok:
                ready_servers += 1
        if ready_servers < 1:
            return False, "no profile-service pods have mtls-server sidecar Ready"

        # Run the handshake from every caller against the headless mTLS FQDN.
        # `echo Q` sends s_client's explicit quit so it exits cleanly after
        # the handshake. -verify_hostname forces SAN verification.
        for caller in callers:
            cmd = (
                f"exec {caller} -n {NAMESPACE} -c {CLIENT_CONTAINER} -- sh -c "
                f"\"echo Q | openssl s_client -connect {fqdn}:{TLS_PORT} "
                f"-CAfile {TRUST_PATH} -servername {fqdn} "
                f"-verify_hostname {fqdn} -verify_return_error 2>&1\""
            )
            code, out, _ = run_kubectl(cmd, timeout=20)
            if code != 0:
                snippet = ""
                for line in out.splitlines():
                    l = line.strip()
                    if any(
                        kw in l
                        for kw in (
                            "verify error",
                            "Verify return code",
                            "unknown ca",
                            "certificate verify failed",
                            "alert",
                            "Hostname mismatch",
                        )
                    ):
                        snippet = l
                        break
                return False, f"tls handshake failed {caller}->{fqdn}: {snippet or 'exit '+str(code)}"
            if "Verify return code: 0 (ok)" not in out:
                return False, f"chain not verified {caller}->{fqdn}"

        # v40: stability boundary (parent fanout-ring `workload_isolation`
        # pattern) — a verified mTLS path that stays verified. The cert-drift
        # workloads must be GONE, not merely scaled to zero / suspended. A
        # dormant drift Deployment/CronJob is a latent threat: an HPA, a node
        # reboot, an operator reconcile, or a manual scale can resume it and
        # re-corrupt the cert/trust bundle, so the fix is not "stable on its
        # own" (task prompt) until they are deleted. This is a causal layer of
        # the SAME functional outcome, disclosed in task.yaml ("a recurring fix
        # that holds only while a workload is scaled to zero is not truly
        # stable ... removed rather than merely paused"). Scale-to-zero passes
        # the live handshake (dormant drift doesn't corrupt) but fails here.
        for kind, name, ns in (
            ("deployment", KUBE_SYNCER, "kube-system"),
            ("deployment", MESH_VALIDATOR, "kube-system"),
            ("deployment", LOCAL_REAPER, NAMESPACE),
            ("deployment", CACHE_SYNC, NAMESPACE),
            ("cronjob", ROTATOR_CRONJOB, NAMESPACE),
            ("cronjob", KUBE_CRONJOB, "kube-system"),
        ):
            obj, _ = kubectl_json(f"get {kind} {name} -n {ns} -o json")
            # A workload that is mid-deletion (deletionTimestamp set) counts as
            # gone — the agent DID delete it; GC/finalizer lag is not a failure.
            # Only a workload that still exists WITHOUT a deletionTimestamp (i.e.
            # left scaled-to-zero or suspended) is the "still exists" violation.
            if obj is not None and not obj.get("metadata", {}).get("deletionTimestamp"):
                ns_tag = f"@{ns}" if ns != NAMESPACE else ""
                return False, (
                    f"cert-drift {kind} {name}{ns_tag} still exists — scaling to "
                    f"zero / suspending is insufficient: a dormant drift workload "
                    f"can be resumed and re-corrupt the cert, so the mTLS path is "
                    f"not stable on its own. It must be deleted."
                )

        return True, "tls handshake verified profile<-bleat"

    # v31: passes=8, gap=20s → 160s stable window. The kube-system
    # node-telemetry-batcher CronJob runs every 60s, so it fires 2-3 times in
    # window for agents who didn't find and stop EVERY drift source — even one
    # missed drift source (deployment that re-blanks ca.crt, sidecar that
    # re-patches Secret, etc.) breaks the handshake mid-window and resets the
    # streak. Decoupled from trust_governance per v30; the longer window is
    # how drift sensitivity is restored.
    return wait_consistent(_handshake_ok, passes=8, gap=20, timeout=320, interval=10)


def check_trust_governance():
    """v51: the audit/compliance subsystem is sanctioned, live, and cannot be
    re-corrupted — FULLY STRUCTURALLY DECOUPLED from mtls_handshake. This reads
    ONLY governance-owned resources; the handshake reads the cert/Secret/trust-
    bundle-ca/profile-pods/DNS. There is ZERO shared read, so the two subscores
    are independent by construction (not just "in steady state").

    Governance-only resources / layers:
       - capability boundary (variance driver): the audit-reconciler's
         Role/RoleBinding (its scrub capability) must be REVOKED, not just the
         cronjob removed. biggie reliably forgets this no-feedback cleanup (~80%).
       - policy sanctions on the SEPARATE bleater-audit-policy ConfigMap (origin
         label, rotation-policy, install-id, trust-domain, composite binding,
         attestation) — NOT the trust bundle the handshake reads.
       - live anchor: a STANDALONE bleater-audit-agent Deployment (NOT a
         profile-service sidecar) emits a monotonic install-proofed heartbeat to
         bleater-audit-sink, tagged agent=bleater-audit-agent.

    All disclosed in /home/ubuntu/profile-mtls-baseline-config.txt ('Audit
    policy' / 'Audit agent'). The (1,0) and (0,1) quadrants are reachable because
    the subscores share no resource and no agent action.
    """

    _seen_hb = {}

    def _governance_ok():
        # === Audit-pipeline capability boundary (behavioral trap, governance-only) ===
        # The audit-reconciler's ability to scrub the audit-policy ConfigMap comes
        # from its Role+RoleBinding in the bleater namespace (configmaps patch).
        # Removing the cronjob alone leaves that CAPABILITY orphaned — any actor
        # or a recreated cronjob bound to it can resume scrubbing the audit policy,
        # so trust governance is not stable until the RBAC is revoked. This is the
        # variance driver: biggie reliably removes the workload but forgets to
        # revoke the leftover RBAC (a no-feedback cleanup step). Reads only the
        # reconciler's own RBAC — nothing the handshake touches.
        gov_role, _ = kubectl_json(f"get role {GOV_CRONJOB} -n {NAMESPACE} -o json")
        gov_rb, _ = kubectl_json(f"get rolebinding {GOV_CRONJOB} -n {NAMESPACE} -o json")
        if gov_role is not None or gov_rb is not None:
            which = "Role" if gov_role is not None else "RoleBinding"
            return False, (
                f"the {GOV_CRONJOB} scrub capability is still granted: its "
                f"{which} in {NAMESPACE} (which permits patching the audit-policy "
                f"ConfigMap) was not revoked. Removing the cronjob is "
                f"insufficient — the orphaned RBAC lets any bound actor resume "
                f"re-stripping the audit policy, so trust governance is not "
                f"stable on its own. The capability must be revoked."
            )

        # === Audit-policy sanction stack (bleater-audit-policy ConfigMap) ===
        # A SEPARATE object from the handshake's trust bundle — governance reads
        # the audit pipeline's OWN policy declaration, nothing the cert path
        # touches. Each anchor is disclosed in baseline-config 'Audit policy'.
        apc, _ = kubectl_json(f"get configmap {AUDIT_POLICY_CM} -n {NAMESPACE} -o json")
        if not apc:
            return False, (
                f"audit-policy ConfigMap {AUDIT_POLICY_CM} is missing — the audit "
                f"pipeline has no sanctioned policy declaration (see baseline-config "
                f"'Audit policy')"
            )
        labels = apc.get("metadata", {}).get("labels", {}) or {}
        annotations = apc.get("metadata", {}).get("annotations", {}) or {}
        if labels.get("bleater.io/origin") != "platform-ca":
            return False, (
                "audit policy missing label bleater.io/origin=platform-ca — the "
                "audit pipeline treats an unlabelled policy as unauthorised "
                "(see baseline-config 'Audit policy')"
            )
        if annotations.get("bleater.io/rotation-policy") != "manual":
            return False, (
                "audit policy missing annotation bleater.io/rotation-policy=manual "
                "(see baseline-config 'Audit policy')"
            )
        try:
            with open("/opt/grader-install-id.txt", "r") as fh:
                expected_id = fh.read().strip()
        except Exception:
            expected_id = ""
        if expected_id and expected_id not in list(annotations.values()):
            return False, (
                "audit policy does not echo the platform install id "
                "(/etc/bleater/install-id.txt) through any annotation (see "
                "baseline-config 'Audit policy')"
            )
        try:
            with open("/opt/grader-trust-domain.txt", "r") as fh:
                expected_td = fh.read().strip()
        except Exception:
            expected_td = ""
        if expected_td and expected_td not in list(annotations.values()):
            return False, (
                "audit policy does not echo the platform trust-domain "
                "(/etc/bleater/trust-domain.txt) through any annotation (see "
                "baseline-config 'Audit policy')"
            )
        if expected_id and expected_td:
            expected_bind = hashlib.sha256(
                f"{expected_id}:{expected_td}".encode("utf-8")
            ).hexdigest()
            if expected_bind not in list(annotations.values()):
                return False, (
                    "audit policy missing the composite install-binding (SHA-256 "
                    "of '<install-id>:<trust-domain>', install-id first, single "
                    "colon) in any annotation — see baseline-config 'Audit policy'"
                )
        if ROLLOUT_ATT_DIGEST is not None and ROLLOUT_ATT_DIGEST not in list(annotations.values()):
            return False, (
                "audit policy does not anchor the rollout-attestation digest "
                "(SHA-256 of /etc/bleater/rollout-attestation.txt) in any "
                "annotation — see baseline-config 'Audit policy'"
            )

        # === Live anchor: standalone audit-agent heartbeat ===
        # The audit relay runs as its OWN Deployment (bleater-audit-agent), NOT a
        # sidecar on the profile-service pods — so governance reads the audit-sink
        # only, never the handshake's pods. The agent emits an install-proofed,
        # monotonic heartbeat tagged `agent=bleater-audit-agent`.
        log, lerr = _audit_sink_log()
        if log is None:
            return False, f"audit-sink unreachable for heartbeat verification: {lerr}"
        best = None
        for ln in log.splitlines():
            if AUDIT_AGENT_TAG not in ln or HEARTBEAT_MARKER not in ln:
                continue
            if INSTALL_DIGEST is not None and f"install={INSTALL_DIGEST}" not in ln:
                continue
            m = _HB_COUNT_RE.search(ln)
            if m:
                v = int(m.group(1))
                best = v if best is None else max(best, v)
        if best is None:
            # Distinguish "no agent heartbeats" from "present but missing proof".
            raw_present = any(
                AUDIT_AGENT_TAG in ln and HEARTBEAT_MARKER in ln
                for ln in log.splitlines()
            )
            if raw_present and INSTALL_DIGEST is not None:
                return False, (
                    "the bleater-audit-agent emits heartbeats but they do NOT "
                    "carry the required install=<sha256 of "
                    "/etc/bleater/install-id.txt> proof — see baseline-config "
                    "'Audit agent'"
                )
            return False, (
                f"the bleater-audit-agent is not emitting install-proofed "
                f"{HEARTBEAT_MARKER} heartbeats (tagged {AUDIT_AGENT_TAG}) to "
                f"{AUDIT_SINK}:{AUDIT_SINK_PORT} — deploy/repair the standalone "
                f"audit agent (see baseline-config 'Audit agent')"
            )
        prev = _seen_hb.get("agent")
        if prev is not None and best <= prev:
            return False, (
                "audit-agent heartbeat count did not advance since last check — "
                "the agent stalled or restarted its counter; the pipeline rejects "
                "non-monotonic streams"
            )
        _seen_hb["agent"] = best

        return True, (
            "audit subsystem live: policy sanctioned + agent heartbeat monotonic "
            "+ scrub capability revoked"
        )

    return wait_consistent(_governance_ok, passes=5, gap=8, timeout=200, interval=10)


def grade(transcript: str) -> GradingResult:
    handshake_ok, handshake_detail = check_mtls_handshake()
    governance_ok, governance_detail = check_trust_governance()

    handshake_score = 1.0 if handshake_ok else 0.0
    governance_score = 1.0 if governance_ok else 0.0

    score = 0.50 * handshake_score + 0.50 * governance_score

    feedback = f"handshake: {handshake_detail}; governance: {governance_detail}"

    return GradingResult(
        score=score,
        subscores={
            "mtls_handshake": handshake_score,
            "trust_governance": governance_score,
        },
        weights={
            "mtls_handshake": 0.50,
            "trust_governance": 0.50,
        },
        feedback=feedback,
    )
