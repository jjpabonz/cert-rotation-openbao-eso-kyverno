# Setup

Everything you need before the first act. At the end you have OpenBao in cluster 1 holding certificate v1, and in each
cluster the demo app running with hand-made Secrets that also hold v1 (`demo-tls` with the certificate and key,
`demo-ca` with the CA). There is **no** ExternalSecret and **no** Kyverno policy yet: those come in acts 2 and 3.

## Prerequisites

- Two Kubernetes clusters you already have, with the kubectl contexts `kube1` (cluster 1) and `kube2` (cluster 2), and
  an Ingress controller (with an IngressClass) in both. Cluster 1 will host OpenBao.
- `kubectl`, `helm`, `tofu` (OpenTofu), `mkcert`, `openssl`. The `bao` CLI is recommended (see [Talking to OpenBao](#talking-to-openbao)).

Everything below runs from the root of this repository. Chart versions are not pinned here: add `--version <x>` to each
`helm upgrade` after your rehearsal, so the recording is reproducible.

## 1. Edit the environment-specific values

| File | Value | What to put |
|---|---|---|
| `manifests/eso/clustersecretstore-cluster1.yaml` and `-cluster2.yaml` | `server` | OpenBao address as seen from **both** clusters. It must match the Ingress host in `helm/openbao-values.yaml`: `http://openbao.kube1.example.com` |
| `manifests/demo-app/cluster1/kustomization.yaml` and `cluster2/` | Ingress host and `DEMO_HOST` | Ingress host (`demo.kube1.example.com` in cluster 1, `demo.kube2.example.com` in cluster 2). curl uses the same host, so the name must resolve through DNS from inside each cluster |
| `manifests/demo-app/base/20-ingress.yaml` | `ingressClassName` | Only if your cluster has no default IngressClass: add it under `spec` |
| `tofu/main.tf` | `address`, `kubernetes_host` | OpenBao address (the same as above) and the API server of cluster 2 (`https://kube2.example.com:6443`, a placeholder). The initial root token is set in section 4 |
| `helm/openbao-values.yaml` | `server.ingress.hosts[].host` | The host name OpenBao is published under (a DNS name pointing at your Ingress controller). Add `ingressClassName` or a StorageClass there if your cluster needs them |

## 2. Install OpenBao in cluster 1

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
helm upgrade --install openbao openbao/openbao \
  --kube-context kube1 -n openbao --create-namespace -f helm/openbao-values.yaml
```

OpenBao starts sealed. Initialize it (by default it creates 5 unseal keys, and any 3 unseal it):

```bash
kubectl --context kube1 -n openbao exec openbao-0 -c openbao -- \
  bao operator init
```

Write down the **Unseal Keys** and the **Initial Root Token** from the output, then unseal it with three different keys:

```bash
kubectl --context kube1 -n openbao exec openbao-0 -c openbao -- bao operator unseal <unseal key 1>
kubectl --context kube1 -n openbao exec openbao-0 -c openbao -- bao operator unseal <unseal key 2>
kubectl --context kube1 -n openbao exec openbao-0 -c openbao -- bao operator unseal <unseal key 3>
```

If the OpenBao pod restarts it comes back sealed: run the unseal command again.

### Talking to OpenBao

The acts use the `bao` CLI. From your laptop, point it at the OpenBao Ingress:

```bash
export BAO_ADDR=http://openbao.kube1.example.com
export BAO_TOKEN=<initial root token>
bao status
```

Without a local `bao`, run each command inside the pod instead, for example:
`kubectl --context kube1 -n openbao exec openbao-0 -c openbao -- env BAO_TOKEN=<token> bao status`.
(Passing files with `@file`, as in the acts, only works with a local `bao`.)

## 3. Install External Secrets Operator and Kyverno in both clusters

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  --kube-context kube1 -n external-secrets --create-namespace -f helm/eso-values.yaml --wait
helm upgrade --install kyverno kyverno/kyverno \
  --kube-context kube1 -n kyverno --create-namespace -f helm/kyverno-values.yaml --wait

helm upgrade --install external-secrets external-secrets/external-secrets \
  --kube-context kube2 -n external-secrets --create-namespace -f helm/eso-values.yaml --wait
helm upgrade --install kyverno kyverno/kyverno \
  --kube-context kube2 -n kyverno --create-namespace -f helm/kyverno-values.yaml --wait
```

The Kyverno values (`helm/kyverno-values.yaml`) also give Kyverno's background controller permission to update
Deployments: it is the component that mutates existing resources. If you already run Kyverno, add that rule to your
values (`backgroundController.rbac.clusterRole.extraResources`).

If you already run them, skip this step.

## 4. Give ESO read-only access to OpenBao

OpenTofu configures OpenBao in [`tofu/main.tf`](../tofu/main.tf). It creates:

- the KV v2 engine at `certificates`,
- the policy `external-secrets-policy`, which can only read `certificates/data/*`,
- Kubernetes auth for cluster 1 (`kubernetes`) and cluster 2 (`k8s-remote`),
- the role `external-secrets-role` in each, for the `external-secrets` service account.

Before applying, edit `tofu/main.tf`: check that `address` is the same OpenBao address as `BAO_ADDR` (`http://...`, because this
OpenBao has no TLS), set `token` to the initial root token (do not commit it), and for cluster 2 check `kubernetes_host`
(its API server) and save its CA as `tofu/kube2-ca.crt` (it is the `certificate-authority-data` of its kubeconfig,
base64-decoded). The file is git-ignored.

```bash
cd tofu
tofu init
tofu apply
cd ..
```

Then tell ESO where OpenBao is:

```bash
kubectl --context kube1 apply -f manifests/eso/clustersecretstore-cluster1.yaml
kubectl --context kube2 apply -f manifests/eso/clustersecretstore-cluster2.yaml
kubectl --context kube1 get clustersecretstore openbao   # should be Valid / Ready
kubectl --context kube2 get clustersecretstore openbao   # should be Valid / Ready
```

## 5. Simulate the legacy CA with mkcert

mkcert stands in for the legacy CA. Never run `mkcert -install`: the local CAs are only used to sign certificates, and
`rootCA.pem` becomes `ca.crt`. Three CAs are used, so that a renewal can change the CA. Only v1 is created here, because
the initial state needs it; each act creates the certificate it uploads.

| Set | CA | SAN | Created in |
|---|---|---|---|
| v1 | CA 1 | both app hosts, `v1.demo.local` | Setup: initial state |
| v2 | CA 1 | both app hosts, `v2.demo.local` | Act 1: renewal with the same CA |
| v3 | CA 2 | both app hosts, `v3.demo.local` | Act 2: new CA, curl breaks |
| v4 | CA 3 | both app hosts, `v4.demo.local` | Act 3: renewal with the new CA |
| wrong | CA 3 | `wrong.demo.local` | Act 4: wrong certificate |

mkcert cannot set the subject, so each version is told apart on screen by its serial number and SAN.

```bash
mkdir -p pki/ca1 pki/v1

CAROOT=$PWD/pki/ca1 mkcert -cert-file pki/v1/tls.crt -key-file pki/v1/tls.key \
  demo.kube1.example.com demo.kube2.example.com v1.demo.local
cp pki/ca1/rootCA.pem pki/v1/ca.crt

openssl x509 -in pki/v1/tls.crt -noout -serial
```

## 6. Initial state

Upload v1 to OpenBao. Each upload creates a new KV version; v1 must be version 1:

```bash
bao kv put -mount=certificates demo/tls \
  tls.crt=@pki/v1/tls.crt tls.key=@pki/v1/tls.key ca.crt=@pki/v1/ca.crt
```

In both clusters install the app (namespace, nginx, an Ingress and curl) with kustomize, each cluster with its own host,
and create hand-made Secrets with v1: `demo-tls` (certificate and key, for the Ingress) and `demo-ca` (the CA, only for
curl). The curl pod waits for `demo-ca` and starts as soon as it exists:

```bash
kubectl --context kube1 apply -k manifests/demo-app/cluster1
kubectl --context kube1 -n demo create secret tls demo-tls --cert=pki/v1/tls.crt --key=pki/v1/tls.key
kubectl --context kube1 -n demo create secret generic demo-ca --from-file=ca.crt=pki/v1/ca.crt
kubectl --context kube1 -n demo rollout status deploy/nginx deploy/curl

kubectl --context kube2 apply -k manifests/demo-app/cluster2
kubectl --context kube2 -n demo create secret tls demo-tls --cert=pki/v1/tls.crt --key=pki/v1/tls.key
kubectl --context kube2 -n demo create secret generic demo-ca --from-file=ca.crt=pki/v1/ca.crt
kubectl --context kube2 -n demo rollout status deploy/nginx deploy/curl
```

Check it works: the curl log shows `OK`, the serial number of v1 (compare it with the `openssl` output above) and the
message from that cluster's nginx (`Hi! from Kube 1` and `Hi! from Kube 2`):

```bash
kubectl --context kube1 -n demo logs deploy/curl --tail=3
kubectl --context kube2 -n demo logs deploy/curl --tail=3
```

## Watching the demo

Three panes are enough: one for commands, and one per cluster. In each cluster pane:

```bash
# what the Secret holds: serial number and SAN
kubectl --context kube1 -n demo get secret demo-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -serial -text | grep -E '^serial=|DNS:'
# pods (watch the curl pod being replaced) and the live curl output
kubectl --context kube1 -n demo get pods -w
kubectl --context kube1 -n demo logs -f deploy/curl
```

## Back to the initial state (between takes)

```bash
kubectl --context kube1 -n demo delete externalsecret demo-tls demo-ca --ignore-not-found
kubectl --context kube1 delete mutatingpolicy restart-curl-on-ca-change --ignore-not-found

kubectl --context kube2 -n demo delete externalsecret demo-tls demo-ca --ignore-not-found
kubectl --context kube2 delete mutatingpolicy restart-curl-on-ca-change --ignore-not-found

# restart the KV history so v1 is version 1 again
bao kv metadata delete -mount=certificates demo/tls
bao kv put -mount=certificates demo/tls \
  tls.crt=@pki/v1/tls.crt tls.key=@pki/v1/tls.key ca.crt=@pki/v1/ca.crt

kubectl --context kube1 -n demo create secret tls demo-tls --cert=pki/v1/tls.crt --key=pki/v1/tls.key \
  --dry-run=client -o yaml | kubectl --context kube1 apply -f -
kubectl --context kube1 -n demo create secret generic demo-ca --from-file=ca.crt=pki/v1/ca.crt \
  --dry-run=client -o yaml | kubectl --context kube1 apply -f -
kubectl --context kube1 -n demo rollout restart deploy/curl

kubectl --context kube2 -n demo create secret tls demo-tls --cert=pki/v1/tls.crt --key=pki/v1/tls.key \
  --dry-run=client -o yaml | kubectl --context kube2 apply -f -
kubectl --context kube2 -n demo create secret generic demo-ca --from-file=ca.crt=pki/v1/ca.crt \
  --dry-run=client -o yaml | kubectl --context kube2 apply -f -
kubectl --context kube2 -n demo rollout restart deploy/curl
```
