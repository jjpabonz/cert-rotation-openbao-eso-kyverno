# Certificate rotation with an internal CA: OpenBao + External Secrets + Kyverno

Demo resources for a talk on certificate rotation without ACME. A certificate issued by hand from a legacy CA is uploaded **once** to OpenBao.
External Secrets Operator (ESO) copies it as a Secret into every cluster, the Ingress controller reloads the
certificate on its own, and Kyverno restarts only the workload that needs it (curl, which reads its CA at startup).

```
 "legacy" CA (mkcert) ──(human step)──► OpenBao (cluster 1, KV v2: certificates/demo/tls)
                                              │  ESO polls every 15 s
                      ┌───────────────────────┴───────────────────────┐
                  cluster 1                                       cluster 2
        ESO → Secrets demo-tls, demo-ca                 ESO → Secrets demo-tls, demo-ca
        ├─ Ingress ◄── demo-tls (reloads itself)        ├─ Ingress ◄── demo-tls (reloads itself)
        ├─ nginx (backend)                              ├─ nginx (backend)
        └─ curl ◄── demo-ca, restarted by Kyverno       └─ curl ◄── demo-ca, restarted by Kyverno
```

## How to follow this repository

This repository is written for people, not for automation: there are no scripts and no Makefile. Every step is a
command in a Markdown file, one file per act of the video.

| Step | Guide | What it shows |
|---|---|---|
| Before recording | [docs/00-setup.md](docs/00-setup.md) | Install OpenBao, ESO and Kyverno, configure OpenBao with OpenTofu, create the first certificate, initial state, reset between takes |
| Act 1 | [docs/act-1-without-eso.md](docs/act-1-without-eso.md) | The problem: a new certificate in OpenBao reaches nobody; manual copies drift |
| Act 2 | [docs/act-2-eso-without-kyverno.md](docs/act-2-eso-without-kyverno.md) | ESO syncs every cluster, but curl keeps the old CA and fails |
| Act 3 | [docs/act-3-eso-and-kyverno.md](docs/act-3-eso-and-kyverno.md) | Kyverno restarts curl after the Secret changes: fully hands-off |
| Act 4 (optional) | [docs/act-4-rollback.md](docs/act-4-rollback.md) | A wrong certificate, and a rollback from OpenBao |

## Repository layout

| Path | Contents |
|---|---|
| `helm/` | Helm values for OpenBao, ESO and Kyverno |
| `tofu/` | OpenTofu that configures OpenBao: KV engine, policy and Kubernetes auth for both clusters (setup) |
| `manifests/demo-app/` | Namespace `demo`, nginx, an Ingress with TLS, curl. `base/` plus one kustomize overlay per cluster, installed with `kubectl apply -k manifests/demo-app/cluster1` (or `cluster2`) |
| `manifests/eso/` | `ClusterSecretStore` pointing to OpenBao (setup) and `ExternalSecret` (act 2) |
| `manifests/kyverno/` | `MutatingPolicy` (act 3) |
| `docs/` | The guides above |
| `pki/` | Created by you in the setup and the acts (git-ignored): the mkcert CAs and certificates |

The app hosts (`demo.kube1.example.com` in cluster 1, `demo.kube2.example.com` in cluster 2) are set in `manifests/demo-app/cluster1` and `cluster2`.
The OpenBao address in `manifests/eso/clustersecretstore-cluster*.yaml` and `helm/openbao-values.yaml` is a placeholder host (`openbao.kube1.example.com`). The
setup guide explains both.

## Design decisions

- **curl reads the CA from an environment variable**, which never changes in a running pod. A normal volume mount would
  update itself and remove the reason for Kyverno in the demo.
- **The Ingress controller does not need Kyverno**, as long as it reloads the certificate from the Secret on its own.
  That depends on your controller: check it in a rehearsal.
- **Each cluster calls its own Ingress host**, so the applications need no connectivity between clusters. Only ESO
  needs to reach OpenBao, and in cluster 2 that is across clusters.
- **ESO logs in with its own service account** (Kubernetes auth, no long-lived token), and its access is read-only
  (policy `external-secrets-policy`, only `certificates/data/*`).
- **Kyverno's RBAC** grants `update` on Deployments cluster-wide, because the permission is a ClusterRole rule. The
  policy itself only touches `deployment/curl` in namespace `demo`.
- **OpenBao is the only entry point for operators.** Nobody needs `kubectl` access to any cluster to renew, or to
  roll back, a certificate.

## Things to check in a rehearsal

These points depend on your environment and on the versions you install. Rehearse before recording, and pay special
attention to:

1. **The `MutatingPolicy`** (`manifests/kyverno/mutatingpolicy.yaml`): field names and the CEL expression follow the
   Kyverno documentation and depend on its version. If Kyverno rejects the policy, the message names the failing field. The annotation uses the Secret's `request.object.metadata.resourceVersion`, which changes on every
   update; check that it really triggers the rollout. Applying the policy also restarts curl (Kyverno evaluates the
   existing `demo-ca` Secret): if you apply the policy and upload the next version a few seconds apart, both restarts
   overlap and two pods are in `Terminating` at the same time. `MutatingPolicy` needs a recent Kyverno (the chart
   installed in the setup).
2. **curl output:** the Deployment prints the serial number, the SAN and the nginx message using `-w '%{certs}'` (curl
   7.88 or later). If the serial number and SAN do not show in the log, read them from the Secret with the `openssl` command in the setup guide.
3. **`creationPolicy: Merge`** on the ExternalSecret, so ESO updates the hand-made Secret instead of trying to create
   it. Check that the Secrets move to v2 in act 2.
4. **Rollback:** that `bao kv rollback` produces a new version that ESO syncs and that Kyverno reacts to like any
   other upload.
5. **OpenBao via Helm:** the pod name `openbao-0` and the Ingress values (`server.ingress`) depend on the chart version. If OpenBao is not
   reachable or its volume stays pending (no default StorageClass), adjust `helm/openbao-values.yaml`.
6. **Ingress controller:** that it reloads the certificate from the Secret without restarting, and which
   `ingressClassName` your infrastructure needs.
7. That ESO does not update the Secret when the value did not change, which avoids pointless curl restarts.
8. **Versions:** the Helm charts install at their latest version. Pin them with `--version` after the rehearsal.

## For a real environment

This OpenBao listens on plain HTTP and is set up with the root token. In production: TLS, auto-unseal, Raft storage in
high availability, and a scoped token (not the root token) for OpenTofu.

All host names (`*.example.com`) are placeholders: replace them with your own, and make sure the names resolve from
inside both clusters.
