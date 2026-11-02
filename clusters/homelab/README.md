# clusters/homelab

Desired state for the k3s cluster. This directory is the only deployment target
in the repository; every CI check scopes to it.

```
bootstrap/root-app.yaml   app-of-apps root, applied by hand once
apps/                     Argo CD Applications, the ApplicationSet and three AppProjects
values/                   Helm values for the chart-backed Applications
config/                   plain manifests: Kyverno policies, Pod Security labels,
                          quotas and LimitRanges, PDBs, PriorityClasses, RBAC,
                          Cilium LB pool, cert-manager issuer, PrometheusRules,
                          probe CronJobs and Grafana dashboards
forgejo-runner/           CI runner StatefulSet and config (no cluster credentials)
buildkit/                 rootless BuildKit for image builds, namespace `ci`
system-upgrade/           system-upgrade-controller and k3s upgrade Plans
tenant-namespaces/        per-tenant namespaces, quotas and LimitRanges (platform-owned)
tenants/website/          the example golden-path tenant: base, guard, observe, dev and prod overlays
```

## Bootstrap

```sh
kubectl apply -f clusters/homelab/bootstrap/root-app.yaml
```

Argo CD then reconciles everything else from the `deploy` branch.

## Argo CD tracks `deploy`, not `main`

Push to `main`. CI validates it and fast-forwards `deploy` only when every
check passes, so a red build leaves last-known-good on the cluster
([ADR 0003](../../docs/adr/0003-promotion-boundary.md)).

## Not managed by Argo CD

Cilium (CNI), kube-vip (API VIP), Sealed Secrets and Argo CD itself are
installed out of band as the bootstrap tier. Handing the CNI or the GitOps
controller to Argo CD risks a self-inflicted outage. `values/argocd-values.yaml`
is kept here as the reference for that install.

## Where the Git server lives

Forgejo (Git, container registry, Actions and the OIDC provider for Argo CD and
Grafana) runs off-cluster on its own VM, so recovering the cluster does not
depend on the cluster. `config/forgejo-availability-check.yaml` probes it from
inside the cluster.
