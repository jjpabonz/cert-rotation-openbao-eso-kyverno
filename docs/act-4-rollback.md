# Act 4 (optional): A wrong certificate and a rollback

**Goal:** show that the same pipeline that delivers a good certificate also delivers a bad one, and that undoing it is
one command in OpenBao, again without touching Kubernetes.

**Starting point:** [Act 3](act-3-eso-and-kyverno.md) done. OpenBao KV history: version 1 = v1, 2 = v2, 3 = v3,
4 = v4. If you did not follow the acts exactly, check with `bao kv metadata get -mount=certificates demo/tls`.

## 1. Someone uploads the wrong certificate

Create a certificate signed by the right CA (CA 3) but only valid for `wrong.demo.local`:

```bash
mkdir -p pki/wrong
CAROOT=$PWD/pki/ca3 mkcert -cert-file pki/wrong/tls.crt -key-file pki/wrong/tls.key wrong.demo.local
cp pki/ca3/rootCA.pem pki/wrong/ca.crt
```

Upload it:

```bash
bao kv put -mount=certificates demo/tls \
  tls.crt=@pki/wrong/tls.crt tls.key=@pki/wrong/tls.key ca.crt=@pki/wrong/ca.crt
```

**Expected, in both clusters:** ESO syncs it (version 5) and curl logs a hostname-mismatch
failure (`FAIL ... no alternative certificate subject name matches target host name '<the cluster's demo host>'`).

## 2. Roll back in OpenBao

```bash
bao kv rollback -mount=certificates -version=4 demo/tls
```

This writes the content of version 4 as a new version (6). **Expected:** ESO syncs v4 again,
and curl logs `OK` with the v4 serial in both clusters. Kyverno does not restart curl in either step: the CA never
changed, so `demo-ca` was not updated. Only a CA change needs a restart.

Nobody needed access to either cluster for the incident or for the fix.
