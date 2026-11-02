#!/usr/bin/env bash
# Offline checks for .forgejo/scripts/trivy-lib.sh: which images the
# changed-image gate selects, and how the baseline file is parsed. No trivy,
# no network — the scan itself is exercised by CI, not here.
#
# Run from the repo root: bash tests/trivy/test_gate.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LIB="$ROOT/.forgejo/scripts/trivy-lib.sh"
pass=0
check() {  # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
    printf 'FAIL %s\n--- expected\n%s\n--- actual\n%s\n' "$1" "$2" "$3"; exit 1; fi
}

# 1. The committed baseline parses, and every image the manifests pin today
#    has an entry (otherwise the next diff touching it fails NO BASELINE, and
#    a drift report shows it as NOBASE).
(
  cd "$ROOT"
  # shellcheck source=../../.forgejo/scripts/trivy-lib.sh
  . "$LIB"
  trivy_baseline_check "$TRIVY_BASELINE_FILE" >/dev/null
  missing=""
  while IFS= read -r img; do
    [ -n "$(trivy_skip_reason "$img")" ] && continue
    [ -n "$(trivy_baseline_for "$img" "$TRIVY_BASELINE_FILE")" ] || missing="$missing $img"
  done < <(trivy_images_in .)
  [ -z "$missing" ] || { echo "FAIL images with no baseline:$missing"; exit 1; }
)
pass=$((pass + 1))

# 2. A scratch repo, so gate_set can be driven through real git diffs.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"
git init -q . && git config user.email t@t && git config user.name t
mkdir -p clusters/homelab/a .forgejo
cat > clusters/homelab/a/d.yaml <<'Y'
spec:
  containers:
    - name: one
      image: alpine:3.22
    - name: two
      image: "moby/buildkit:v0.31.2-rootless@sha256:aaaa"
    - name: three
      image: debian:bookworm-slim@sha256:bbbb
Y
printf '# c\nalpine=0 moby/buildkit=200\ndebian=8\n' > .forgejo/trivy-baseline
git add -A && git commit -qm base
BASE=$(git rev-parse HEAD)
# shellcheck source=../../.forgejo/scripts/trivy-lib.sh
. "$LIB"

check "baseline_for last-match" "200" "$(trivy_baseline_for moby/buildkit:v1 .forgejo/trivy-baseline)"
check "baseline_for none" "" "$(trivy_baseline_for nginx:1 .forgejo/trivy-baseline)"
check "images_in strips quotes, sorts" \
  "$(printf 'alpine:3.22\ndebian:bookworm-slim@sha256:bbbb\nmoby/buildkit:v0.31.2-rootless@sha256:aaaa')" \
  "$(trivy_images_in .)"

# No change at all -> nothing gated, even though nothing was scanned.
check "no diff gates nothing" "" "$(trivy_gate_set "$BASE")"

# A doc-only / unrelated change -> nothing gated.
echo x > README.md; git add -A; git commit -qm doc
check "unrelated change gates nothing" "" "$(trivy_gate_set "$BASE")"

# Digest change -> exactly that image gated.
sed -i.bak 's/sha256:aaaa/sha256:cccc/' clusters/homelab/a/d.yaml && rm clusters/homelab/a/d.yaml.bak
check "digest change gated" \
  "$(printf 'moby/buildkit:v0.31.2-rootless@sha256:cccc\tadded or changed in this diff')" \
  "$(trivy_gate_set "$BASE")"
git checkout -q -- clusters/homelab

# Tag change + new image -> both gated; the untouched ones are not.
sed -i.bak 's/alpine:3.22/alpine:3.23/' clusters/homelab/a/d.yaml && rm clusters/homelab/a/d.yaml.bak
printf '      image: nginx:1.27\n' >> clusters/homelab/a/d.yaml
check "tag change + new image gated" \
  "$(printf 'alpine:3.23\tadded or changed in this diff\nnginx:1.27\tadded or changed in this diff')" \
  "$(trivy_gate_set "$BASE")"
git checkout -q -- clusters/homelab

# Baseline entry changed, ref unchanged -> that image gated (ratchet PR proves itself).
printf '# c\nalpine=0 moby/buildkit=150\ndebian=8\n' > .forgejo/trivy-baseline
check "baseline change gated" \
  "$(printf 'moby/buildkit:v0.31.2-rootless@sha256:aaaa\tbaseline changed in this diff (200 -> 150)')" \
  "$(trivy_gate_set "$BASE")"
git checkout -q -- .forgejo

# A workload moved to a reference ANOTHER workload already uses -> gated
# (the repo-wide reference set does not change, the workload does).
sed -i.bak 's#debian:bookworm-slim@sha256:bbbb#alpine:3.22#' clusters/homelab/a/d.yaml && rm clusters/homelab/a/d.yaml.bak
check "move to an existing ref gated" \
  "$(printf 'alpine:3.22\tadded or changed in this diff')" \
  "$(trivy_gate_set "$BASE")"
git checkout -q -- clusters/homelab

# A new workload (new file) using an existing reference -> gated.
mkdir -p clusters/homelab/b
printf 'spec:\n  containers:\n    - name: x\n      image: debian:bookworm-slim@sha256:bbbb\n' > clusters/homelab/b/e.yaml
git add clusters/homelab/b/e.yaml
check "new workload on existing ref gated" \
  "$(printf 'debian:bookworm-slim@sha256:bbbb\tadded or changed in this diff')" \
  "$(trivy_gate_set "$BASE")"
git rm -qf clusters/homelab/b/e.yaml

# Re-indenting and re-quoting an image: line changes no reference -> nothing.
sed -i.bak -e 's#      image: alpine:3.22#        image: "alpine:3.22"#' clusters/homelab/a/d.yaml && rm clusters/homelab/a/d.yaml.bak
check "reformat gates nothing" "" "$(trivy_gate_set "$BASE")"
git checkout -q -- clusters/homelab

# A .gitattributes that hides YAML from diffs (-diff) must not hide a re-pin.
printf '*.yaml -diff\n' > .gitattributes && git add .gitattributes
sed -i.bak 's/sha256:aaaa/sha256:cccc/' clusters/homelab/a/d.yaml && rm clusters/homelab/a/d.yaml.bak
check "-diff attribute cannot hide a re-pin" \
  "$(printf 'moby/buildkit:v0.31.2-rootless@sha256:cccc\tadded or changed in this diff')" \
  "$(trivy_gate_set "$BASE")"
git rm -qf .gitattributes
git checkout -q -- clusters/homelab

# A manifest path with a space (and a colon) cannot shift the reference.
mkdir -p "clusters/homelab/my app"
printf 'spec:\n  containers:\n    - name: x\n      image: nginx:1.27\n' > "clusters/homelab/my app/a:b.yaml"
git add "clusters/homelab/my app"
check "odd path keeps its reference" \
  "$(printf 'nginx:1.27\tadded or changed in this diff')" \
  "$(trivy_gate_set "$BASE")"
git rm -qrf "clusters/homelab/my app"

# Image removed -> nothing gated.
sed -i.bak '/debian/d' clusters/homelab/a/d.yaml && rm clusters/homelab/a/d.yaml.bak
check "removal gates nothing" "" "$(trivy_gate_set "$BASE")"
git checkout -q -- clusters/homelab

# Base with no baseline file (the commit that introduced it) -> ref rule only.
git rm -q .forgejo/trivy-baseline && git commit -qm nobase && NOBASE=$(git rev-parse HEAD)
git checkout -q "$BASE" -- .forgejo/trivy-baseline
check "base without baseline file" "" "$(trivy_gate_set "$NOBASE" 2>/dev/null)"

# FAILURE INJECTION, invoked the way validate.yml does: inside `if`, where
# bash ignores errexit. Any failing step must return non-zero with NOTHING on
# stdout, so the caller falls back to gating every image.
gate_must_fail() {  # NAME — gate_set against $BASE must fail closed
  local out
  if out=$(trivy_gate_set "$BASE" 2>/dev/null); then
    echo "FAIL $1: gate_set succeeded"; exit 1; fi
  [ -z "$out" ] || { echo "FAIL $1: partial output: $out"; exit 1; }
  pass=$((pass + 1))
}
sed -i.bak 's/sha256:aaaa/sha256:cccc/' clusters/homelab/a/d.yaml && rm clusters/homelab/a/d.yaml.bak
printf '# c\nalpine=0 moby/buildkit=150\ndebian=8\n' > .forgejo/trivy-baseline
git() { [ "$1" = grep ] && return 128; command git "$@"; }
gate_must_fail "git grep fails"
git() { [ "$1" = ls-tree ] && return 128; command git "$@"; }
gate_must_fail "baseline lookup at base fails"
git() { [ "$1" = show ] && return 128; command git "$@"; }
gate_must_fail "baseline read at base fails"
comm() { return 1; }
unset -f git
gate_must_fail "comm fails"
unset -f comm
sort() { return 2; }
gate_must_fail "sort fails"
unset -f sort
# shellcheck disable=SC2329 # stub shadowing a command the library calls
grep() { [ "$1" = -rhoE ] && return 2; command grep "$@"; }
gate_must_fail "image extraction errors"
unset -f grep
# shellcheck disable=SC2329 # stub shadowing a command the library calls
tr() { return 1; }
gate_must_fail "baseline parsing fails"
unset -f tr
check "unstubbed again" \
  "$(printf 'moby/buildkit:v0.31.2-rootless@sha256:cccc\tadded or changed in this diff')" \
  "$(trivy_gate_set "$BASE")"
git checkout -q -- clusters/homelab .forgejo

# Unreadable base -> non-zero, so the caller gates everything.
if trivy_gate_set deadbeef >/dev/null 2>&1; then echo "FAIL bad base should fail"; exit 1; fi
pass=$((pass + 1))

# Malformed baseline token is refused.
printf 'alpine=0 buildkit200\n' > "$T/bad"
if trivy_baseline_check "$T/bad" >/dev/null; then echo "FAIL malformed baseline accepted"; exit 1; fi
pass=$((pass + 1))

# Skip rules.
check "skip untagged" "no tag or digest (kustomize base; the overlay pins it)" "$(trivy_skip_reason hq)"
check "skip internal" "internal registry, this job holds no pull credential by design" \
  "$(trivy_skip_reason registry.example.com/apps/hq:1)"
check "no skip" "" "$(trivy_skip_reason alpine:3.22)"

echo "ok — $pass checks"
