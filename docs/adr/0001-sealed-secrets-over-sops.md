# ADR 0001: Sealed Secrets is the one secrets path

- **Status:** Accepted
- **Date:** 2026-07-26

## Context

The lab had three half-strategies at once: the Sealed Secrets controller was
deployed with no sealed resources, SOPS lived on in the previous cluster's flow,
and the Cloudflare API token and the DNS-01 `ClusterIssuer` had been applied by
hand and committed nowhere. Three paths meant no path. An audit of resources not
tracked in Git found six that would not survive a rebuild, five of them secrets.

By the time of this decision the mechanism had settled itself in practice:

- The controller was deployed and its private key escrowed off-cluster.
- Five hand-applied secrets had been adopted in place: annotate the live Secret
  `sealedsecrets.bitnami.com/managed=true`, seal from the live object, no restart
  and no content change.
- A storage credential rotation had run end to end through it (seal, verify,
  apply), with the new value read from the environment and never written to disk
  or passed in argv.
- Every SealedSecret carried an Argo CD tracking id, so the whole secret set was
  declared and would survive a rebuild.

## Decision

**Sealed Secrets is the only secrets-at-rest mechanism in this repository.**
SOPS with KSOPS is dropped.

1. Every Secret a rebuild needs is a `SealedSecret` in this repo.
2. Adopt, don't recreate: seal from the live Secret with plaintext piped through
   `kubeseal`, never rendered to disk.
3. The controller key is escrowed off-cluster. It is the highest-value secret in
   the lab: without it every SealedSecret is unreadable.
4. A new secret is sealed in the same commit as the manifest that consumes it.

CI enforces the boundary: the `sealed-secret-check` job fails on any plaintext
`kind: Secret` under `clusters/` and on any `sealed-secret-*` file without
`encryptedData`.

## Why not SOPS + KSOPS

- Its one real advantage, decrypting anywhere rather than only in-cluster, matters
  for multi-cluster or multi-operator setups. This is one cluster and one operator.
- KSOPS needs an Argo CD repo-server plugin or custom image: another component to
  maintain on a path that had already failed twice.
- The age key would be a second key to escrow, with the same catastrophic-loss
  property and no reduction in blast radius.
- Migrating working SealedSecrets would churn exactly the objects where churn is
  most expensive.

## Consequences

- Secrets decrypt only inside this cluster. If the controller key and its escrow
  copy are both lost, every value must be re-created from its upstream source, so
  verifying the escrow belongs on the quarterly checklist.
- Break-glass reads go through the cluster API. Node or API access equals secret
  access, as before.
- One residual is outside what any secrets system fixes: k3s reads its etcd
  snapshot S3 credential from a plaintext config file on each control-plane node.
  Treat node access as bucket access.
