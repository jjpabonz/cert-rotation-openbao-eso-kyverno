# Act 2: External Secrets Operator without Kyverno

**Goal:** show that ESO removes the copying: OpenBao becomes the only place a person touches. Then show what ESO does
**not** solve: a workload that only reads the certificate when it starts.

**Starting point:** [Act 1](act-1-without-eso.md) done (OpenBao has v2; cluster 1 has v2, cluster 2 has v1).

## 1. Create the ExternalSecret in both clusters

```bash
kubectl --context kube1 apply -f manifests/eso/externalsecret.yaml
kubectl --context kube2 apply -f manifests/eso/externalsecret.yaml
kubectl --context kube1 -n demo get externalsecret
kubectl --context kube2 -n demo get externalsecret
```

Two ExternalSecrets read `certificates/demo/tls` from OpenBao every 15 seconds and merge it into the existing Secrets
(`creationPolicy: Merge`): `demo-tls` gets the certificate and key (used by the Ingress) and `demo-ca` gets the CA
(used by curl).

**Expected:** `STATUS: SecretSynced`. Cluster 2 catches up from v1 to v2 without anyone touching it. Check both
Secrets with the command from [setup](00-setup.md#watching-the-demo): serial and `v2.demo.local` in both clusters.

## 2. The next renewal: a person uploads only to OpenBao (v2 to v3, new CA)

The legacy CA now issues the certificate with a different CA (CA 2):

```bash
mkdir -p pki/ca2 pki/v3
CAROOT=$PWD/pki/ca2 mkcert -cert-file pki/v3/tls.crt -key-file pki/v3/tls.key \
  demo.kube1.example.com demo.kube2.example.com v3.demo.local
cp pki/ca2/rootCA.pem pki/v3/ca.crt
openssl x509 -in pki/v3/tls.crt -noout -serial
```

Upload it only to OpenBao:

```bash
bao kv put -mount=certificates demo/tls \
  tls.crt=@pki/v3/tls.crt tls.key=@pki/v3/tls.key ca.crt=@pki/v3/ca.crt
```

Within about 15 seconds, in **both** clusters:

- the Secret `demo-tls` holds v3 (`v3.demo.local`) and `demo-ca` holds CA 2, with no `kubectl` against the clusters;
- the Ingress controller serves v3 on its own.

## 3. The part ESO cannot fix: curl fails

```bash
kubectl --context kube1 -n demo logs deploy/curl --tail=5
kubectl --context kube2 -n demo logs deploy/curl --tail=5
```

**Expected:** `FAIL ... certificate verify failed` (or similar) in both clusters. v3 was issued by a new CA (CA 2),
but curl loaded the CA from the Secret **when it started**, and an environment variable never changes in a running pod.
The certificate is fine, the Secret is fine, the application is still broken until somebody restarts it.

> **Do not restart curl by hand.** Act 3 needs it exactly like this: still holding the old CA and failing.

## Next

[Act 3](act-3-eso-and-kyverno.md) removes that last manual step.
