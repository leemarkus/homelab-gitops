# ADR 0003: A `deploy` branch as the promotion boundary

- **Status:** Accepted
- **Date:** 2026-07-27

## Context

`.forgejo/workflows/validate.yml` already ran seven good checks: kubeconform on
every manifest, `kustomize build` plus a schema check on every overlay, a
plaintext-Secret guard, `kyverno apply` proving each resource would still admit
once policies move from Audit to Enforce, trivy against a measured per-image
baseline, and `helm template` on every chart-backed Application. The Kyverno job
had just become blocking.

None of them could prevent anything.

- The history had no merge commits. Every change was a direct push to `main`, so
  the `pull_request` trigger had never fired against real work.
- Every Application tracked `targetRevision: main` with automated sync and
  `selfHeal: true`.

Argo CD and CI saw each commit at the same moment. `kyverno-admission` could only
go red *after* the manifest it rejected had been applied to the only cluster
there is. The reusable lesson: **the checks were never the missing piece; the
ordering was.** An earlier plan for a `kind` cluster inside the runner was ruled
out correctly (the runner is a host executor with no container runtime), and
`kyverno apply` replaced it. That kept the *validation* in "pre-merge validation"
and quietly dropped the *pre*, which was the part that mattered.

## Decision

**Argo CD tracks `deploy`. CI fast-forwards `deploy` to `main` only after all
seven checks pass.**

- Every Application, including the root app, uses `targetRevision: deploy`.
- A `promote` job `needs:` all seven jobs by name and runs only on a push to
  `main`.
- Promotion is fast-forward only, never `--force`. If `deploy` has commits `main`
  lacks, the job fails and asks for a human: a forced push would deploy a
  revision nothing validated.
- A red build leaves `deploy` untouched. Last-known-good stays deployed. Recovery
  is to push a fix; the next green run carries both commits across.

## Alternatives considered

**A pull-request flow with branch protection and required checks.** The
conventional answer, rejected on evidence: the history shows an operator who
pushes directly to `main`. A gate that depends on adopting a habit you
demonstrably do not have stops being used, and that failure is silent. The
`deploy` branch needs no change to day-to-day work.

**Making `kyverno-admission` blocking and stopping there.** Already true, and
insufficient: blocking a job that runs concurrently with the deploy blocks
nothing.

## Consequences

**Gained.** Chart bumps, values edits, policy flips and schema errors all fail
before the cluster sees them, and `main` is still the branch to push to.

**Cost: a new, silent failure mode.** The gate can stay shut: CI goes red, nobody
looks, and the cluster serves an old revision while Git says the change shipped.
A Synced and Healthy Argo CD app no longer proves the cluster is current. So it
is monitored: `clusters/homelab/config/promotion-lag-alerts.yaml` asks the Git
server's compare API hourly and alerts if `deploy` falls more than 6 commits
behind `main`, with a second alert if the check stops running.

**Cost: one write credential in CI.** The promote job pushes with the Actions
secret `PROMOTE_TOKEN`. It grants no cluster access: the runner has no Role, no
ClusterRole and `automountServiceAccountToken: false`, and Argo CD remains the
only thing that talks to the API server. Forgejo token scopes are not
per-repository, so a token minted on the owner's account reaches every repo that
account can write. The job supports a dedicated bot account with write access to
this repo only (`PROMOTE_USER`), which is the right move once a second repo or
person shares the runner. If the secret is missing the job fails loudly rather
than skipping promotion.

**Not covered.** Runtime failure of a platform upgrade (a chart whose pods
crashloop, a CRD migration that wedges a webhook). Admission checks cannot see
it; only running it can. That needs a pre-production cluster, which this
decision deliberately does not pay for yet.

## Cutover

`PROMOTE_TOKEN` must exist first.

```sh
# 1. deploy starts at the revision ALREADY RUNNING, not at the new main.
git push origin origin/main:refs/heads/deploy

# 2. Push main. CI runs; on green, promote fast-forwards deploy to it.
git push origin main

# 3. Only after the first promotion is green and deploy == main:
kubectl -n argocd patch app root-homelab --type merge \
  -p '{"spec":{"source":{"targetRevision":"deploy"}}}'
```

Starting `deploy` behind means the first thing the new machinery does is
validate and promote its own installation. Step 3 waits because, until `deploy`
contains the change, `apps/*.yaml` on that branch still say `main`, and patching
the root app early would revert every child to `main`. Step 3 is needed at all
because the root app does not manage itself.

**Rollback:** patch the root app back to `main`. Nothing here is one-way.
