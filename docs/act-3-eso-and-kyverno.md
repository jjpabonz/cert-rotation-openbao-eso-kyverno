# Act 3: External Secrets Operator + Kyverno

**Goal:** close the loop. When ESO updates the Secret, Kyverno restarts only the workload that needs it (curl). The
Ingress controller and nginx are left alone.

**Starting point:** [Act 2](act-2-eso-without-kyverno.md) done: both Secrets hold v3, the Ingress serves v3, and curl
is failing because it still holds CA 1 (`demo-ca` already holds CA 2). Apply the policy and upload v4 a couple of seconds
apart: you will see two curl pods in `Terminating` at the same time (one restart per trigger).

## 1. Create the next renewal (v4, yet another CA)

Create v4 with a third CA (CA 3). A new CA is needed because the policy watches the CA Secret, and ESO only updates
`demo-ca` when the CA changes:

```bash
mkdir -p pki/ca3 pki/v4
CAROOT=$PWD/pki/ca3 mkcert -cert-file pki/v4/tls.crt -key-file pki/v4/tls.key \
  demo.kube1.example.com demo.kube2.example.com v4.demo.local
cp pki/ca3/rootCA.pem pki/v4/ca.crt
openssl x509 -in pki/v4/tls.crt -noout -serial
```

Do not upload it yet.

## 2. Show the Kyverno policy and apply it in both clusters

Open the pods and log panes first (`kubectl ... get pods -w`, `kubectl ... logs -f deploy/curl`). Show the policy:

```bash
cat manifests/kyverno/mutatingpolicy.yaml
```

What it does: when the Secret `demo-ca` in namespace `demo` is **updated**, it writes the Secret's `resourceVersion` as
an annotation in the pod template of `deploy/curl`. A changed pod template makes Kubernetes roll the Deployment: a
normal rolling restart of that one workload. Then apply it:

```bash
kubectl --context kube1 apply -f manifests/kyverno/mutatingpolicy.yaml
kubectl --context kube2 apply -f manifests/kyverno/mutatingpolicy.yaml
kubectl --context kube1 get mutatingpolicy
```

Kyverno also evaluates the policy against the `demo-ca` Secret that already exists, so the annotation is written (and curl
restarts) as soon as the policy is applied, even before anything changes. Do not wait for it: go straight to the next
step.

## 3. A person uploads v4 to OpenBao, a couple of seconds later

```bash
bao kv put -mount=certificates demo/tls \
  tls.crt=@pki/v4/tls.crt tls.key=@pki/v4/tls.key ca.crt=@pki/v4/ca.crt
```

**Expected, in both clusters, within about a minute, with no `kubectl` and no restart by a person:**

1. The policy has already restarted curl once (applying it counts as a trigger), so the pod from that restart is still
   starting or being replaced.
2. ESO updates `demo-tls` to v4 (`v4.demo.local`) and `demo-ca` to CA 3.
3. Kyverno sees the update of `demo-ca` and annotates `deploy/curl` again: a second restart, so **two curl pods are in
   `Terminating` at the same time**. nginx does not restart.
4. The last curl pod loads CA 3 from `demo-ca` and logs `OK` with the v4 serial.

Useful checks:

```bash
kubectl --context kube1 -n demo get deploy curl -o jsonpath='{.spec.template.metadata.annotations}'; echo
kubectl --context kube1 -n demo get pods        # nginx age unchanged, curl pod new
```

## Takeaway

A person did one thing, in one place: upload to OpenBao. Everything else (sync, reload, restart) followed.

Optional: [Act 4](act-4-rollback.md) shows the same path working in reverse when someone uploads the wrong
certificate.
