# Act 1: Without External Secrets Operator

**Goal:** show the problem. The legacy CA issues a new certificate, a person uploads it to OpenBao, and nothing else
happens. Every cluster keeps serving the old certificate until somebody copies the new one by hand, cluster by cluster.

**Starting point:** [setup](00-setup.md) finished. Both clusters have the hand-made Secrets `demo-tls` and `demo-ca` with v1, no
ExternalSecret, no Kyverno policy.

## 1. The legacy CA issues the renewed certificate (v2) and a person uploads it to OpenBao

Same CA as v1, new certificate:

```bash
mkdir -p pki/v2
CAROOT=$PWD/pki/ca1 mkcert -cert-file pki/v2/tls.crt -key-file pki/v2/tls.key \
  demo.kube1.example.com demo.kube2.example.com v2.demo.local
cp pki/ca1/rootCA.pem pki/v2/ca.crt
openssl x509 -in pki/v2/tls.crt -noout -serial
```

Upload it:

```bash
bao kv put -mount=certificates demo/tls \
  tls.crt=@pki/v2/tls.crt tls.key=@pki/v2/tls.key ca.crt=@pki/v2/ca.crt
```

OpenBao now holds v2 (KV version 2).

## 2. Check what the clusters are serving

```bash
kubectl --context kube1 -n demo get secret demo-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -serial -text | grep -E '^serial=|DNS:'
kubectl --context kube1 -n demo logs deploy/curl --tail=2

kubectl --context kube2 -n demo get secret demo-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -serial -text | grep -E '^serial=|DNS:'
kubectl --context kube2 -n demo logs deploy/curl --tail=2
```

**Expected:** both Secrets still hold v1 (`v1.demo.local`), and curl keeps logging `OK` with the v1 serial. OpenBao is
the source of truth, but nothing moves the new certificate into the clusters.

## 3. The manual way, in cluster 1 only

Somebody has to copy the certificate and the CA by hand:

```bash
kubectl --context kube1 -n demo create secret tls demo-tls --cert=pki/v2/tls.crt --key=pki/v2/tls.key \
  --dry-run=client -o yaml | kubectl --context kube1 apply -f -
kubectl --context kube1 -n demo create secret generic demo-ca --from-file=ca.crt=pki/v2/ca.crt \
  --dry-run=client -o yaml | kubectl --context kube1 apply -f -
```

**Expected:** after a few seconds cluster 1 serves v2 (`v2.demo.local`, the Ingress controller reloads it without a
restart) and curl keeps logging `OK`, because v2 comes from the same CA. Cluster 2 still serves v1: the clusters have
**drifted**, and with ten clusters and ten systems this is a manual job per system.

## Next

The state is now "cluster 1 has v2, cluster 2 has v1", which is a perfectly good starting point for
[Act 2](act-2-eso-without-kyverno.md). Do not reset between acts 1 and 2 unless you want a clean take.
