# Secrets in this repository

The private repository stores every Secret the cluster needs as a Bitnami
`SealedSecret` ([ADR 0001](adr/0001-sealed-secrets-over-sops.md)): ciphertext
that only the in-cluster controller can decrypt. **This public copy ships no
SealedSecret and no ciphertext.** The manifests still reference the Secrets by
name, so a fork must create them before the consuming workloads start.

| Namespace / Secret | Consumed by | Contents |
|---|---|---|
| `argocd/forgejo-oidc` | `values/argocd-values.yaml` (`$forgejo-oidc:clientID`, `clientSecret`) | OIDC client for Argo CD SSO |
| `monitoring/grafana-oidc` | `values/kube-prometheus-stack-values.yaml` | OIDC client for Grafana SSO |
| `monitoring/alertmanager-notify` | Alertmanager receivers (`webhook-password`, `telegram-bot-token`) | Paging credentials |
| `monitoring/ntfy-alertmanager-config-page` | `config/ntfy-alertmanager.yaml` | Bridge config for the paging webhook |
| `monitoring/watchdog-heartbeat` | `config/watchdog-heartbeat.yaml` (`push-url`) | External dead-man's-switch URL |
| `cert-manager/cloudflare-api-token` | `config/cluster-issuer.yaml` | DNS-01 token for the wildcard certificate |
| `longhorn-system/minio-credentials` | `values/longhorn-values.yaml` | S3 credentials for Longhorn backups |
| `velero/velero-minio-credentials` | `values/velero-values.yaml` | S3 credentials for Velero |
| `velero/velero-repo-credentials` | Velero repository | Repository encryption password |
| `forgejo-runner/forgejo-runner-token` | `forgejo-runner/statefulset.yaml` | Runner registration token |
| `website-dev/forgejo-registry`, `website-prod/forgejo-registry` | `tenants/website/base/deployment.yaml` | Read-only package pull credential, one per namespace |

Paths are relative to `clusters/homelab/`.

## Sealing a Secret

Pipe plaintext straight into `kubeseal`; never write it to a file or pass it in
argv. Seal against the controller's public certificate, bound to one name and
namespace (the default strict scope):

```sh
# PUSH_URL is already in the environment (for example, read from a password
# manager). The Secret is built inside python3 from os.environ, so the value
# never appears in a command line or on disk.
python3 -c '
import base64, json, os
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "watchdog-heartbeat", "namespace": "monitoring"},
    "data": {"push-url": base64.b64encode(os.environ["PUSH_URL"].encode()).decode()},
}))' \
  | kubeseal --format yaml > clusters/homelab/config/sealed-secret-watchdog-heartbeat.yaml
```

Commit the sealed file in the same change as the manifest that consumes it. CI's
`sealed-secret-check` job rejects any plaintext `kind: Secret` under `clusters/`
and any `sealed-secret-*.yaml` without `encryptedData`.

The controller's private key is the one secret that makes all the others
readable. Escrow it off-cluster; a rebuild that restores manifests without it
restores nothing usable.
