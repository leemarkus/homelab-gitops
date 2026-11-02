# shellcheck shell=bash
# Shared trivy helpers for readers of .forgejo/trivy-baseline. SOURCED, never
# executed:
#
#   validate.yml `trivy` job  gates the images a PR or push CHANGES
#   a scheduled drift report  scans EVERY image, never gates
#
# Both must count CVEs the same way and read the same baseline, or the report
# and the gate would disagree about what "at baseline" means: one scan
# definition, one baseline parser, one image extractor.
#
# Callers set TRIVY_CACHE_DIR and TRIVY_JSON_DIR / TRIVY_SARIF_DIR (run-scoped;
# see the concurrency note in validate.yml) before calling trivy_count.

TRIVY_BASELINE_FILE=${TRIVY_BASELINE_FILE:-.forgejo/trivy-baseline}
# One `image:` line, as the manifests write it. trivy_gate_set applies the same
# shape to the lines a diff adds, so the two cannot disagree on what an image is.
TRIVY_IMAGE_RE='^[[:space:]]+image: "?[a-zA-Z0-9./_-]+(:[a-zA-Z0-9._-]+)?(@sha256:[a-f0-9]+)?'

# trivy_images_in ROOT — every image reference pinned under
# ROOT/clusters/homelab, sorted and unique. Images are read out of the
# manifests, so a new pin is seen the day it lands and nobody has to remember to
# register it. LC_ALL=C so `comm` in trivy_gate_set agrees on the order.
# A subshell with pipefail, so a failed read is a failed call rather than a
# short list; grep's "no match" (1) is not a failure, its errors (2) are.
trivy_images_in() (
  set -o pipefail
  { grep -rhoE "$TRIVY_IMAGE_RE" "$1/clusters/homelab" --include='*.yaml' || [ $? -eq 1 ]; } \
    | sed 's/.*image: *"*//' | LC_ALL=C sort -u
)

# trivy_baseline_values FILE — the IMAGE=COUNT tokens, comments stripped.
# Non-zero when the file cannot be read; grep's "none" (1) is not an error.
trivy_baseline_values() (
  set -o pipefail
  sed 's/#.*//' "$1" | tr -s ' \t' '\n' | { grep -E '^[^=]+=[0-9]+$' || [ $? -eq 1 ]; }
)

# trivy_baseline_check FILE — refuse a file with a token that is not
# IMAGE=COUNT. A typo must not silently drop an entry: the image it covered
# would then read as NO BASELINE on the gate and as drift on the report, both
# for a reason nobody would think to look for.
trivy_baseline_check() {
  [ -f "$1" ] || { echo "FAIL baseline file $1 is missing"; return 1; }
  _bad=$(sed 's/#.*//' "$1" | tr -s ' \t' '\n' | grep -vE '^$|^[^=]+=[0-9]+$' || true)
  if [ -n "$_bad" ]; then
    echo "FAIL $1 has entries that are not IMAGE=COUNT:"
    # shellcheck disable=SC2086 # one token per line, on purpose
    printf '     %s\n' $_bad
    return 1
  fi
}

# trivy_baseline_for IMAGE FILE — the COUNT of the LAST entry whose prefix
# matches IMAGE; empty when none does.
# Non-zero when FILE cannot be parsed, so "no entry" and "could not read" differ.
trivy_baseline_for() (
  _vals=$(trivy_baseline_values "$2") || exit 1
  _base=""
  for _kv in $_vals; do
    _k=${_kv%%=*}; _v=${_kv##*=}
    case "$1" in "$_k"*) _base=$_v ;; esac
  done
  printf '%s' "$_base"
)

# trivy_skip_reason IMAGE — non-empty when IMAGE is not scanned at all.
trivy_skip_reason() {
  case "$1" in
    *:*) ;;   # a tag, a digest, or both
    *) echo "no tag or digest (kustomize base; the overlay pins it)"; return ;;
  esac
  case "$1" in
    registry.example.com/*) echo "internal registry, this job holds no pull credential by design" ;;
  esac
}

# trivy_lock — the persistent DB cache and the lock that serialises
# it. The runner is `capacity: 2` on a HOST executor, so two jobs are two
# processes in the same container sharing /data; the trivy DB is boltdb and the
# second opener fails on its file lock. That is a red run caused by scheduling,
# so wait for the cache instead — bounded at 30m, well inside the runner's 1h
# job timeout, so a stall fails with a legible message. The fd stays open (and
# the lock held) for the rest of the calling shell.
trivy_lock() {
  mkdir -p "$TRIVY_CACHE_DIR"
  exec 9>/data/trivy-cache.lock
  if ! flock -w 1800 9; then
    echo "FAIL could not acquire the trivy cache lock within 30m — another"
    echo "     trivy run is still scanning. This is a scheduling stall,"
    echo "     not a manifest problem; re-run this job."
    return 1
  fi
}

# trivy_count IMAGE — scan IMAGE once and print its count of fixable
# HIGH/CRITICAL CVEs on stdout (nothing else goes to stdout). Non-zero when the
# scan or the count fails. The JSON report is kept so the same scan also yields
# the SARIF without pulling the image twice; a SARIF failure is not a
# scan failure.
trivy_count() {
  _safe=$(printf '%s' "$1" | tr '/:@' '___')
  trivy image --quiet --scanners vuln --severity HIGH,CRITICAL \
    --ignore-unfixed --format json --output "$TRIVY_JSON_DIR/$_safe.json" "$1" >&2 \
    || return 1
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(sum(len(r.get('Vulnerabilities') or []) for r in d.get('Results',[])))" \
    "$TRIVY_JSON_DIR/$_safe.json" || return 1
  if [ -n "${TRIVY_SARIF_DIR:-}" ]; then
    trivy convert --format sarif --output "$TRIVY_SARIF_DIR/$_safe.sarif" \
      "$TRIVY_JSON_DIR/$_safe.json" >&2 \
      || echo "[i] SARIF conversion failed for $1 — report omitted from the artifact, count unaffected" >&2
  fi
}

# trivy_occurrences [REV] — one "REF PATH" line per `image:` line in the
# manifests, sorted, duplicates KEPT: the working tree with no REV, the tree at
# REV otherwise. `git grep --text` reads blob contents directly, so no
# .gitattributes (`-diff`, textconv, export-ignore) can hide a manifest from it.
# The REF is cut from the END of each match (git grep -o ends the line with
# it) and written FIRST, so a path holding spaces or colons cannot shift it. A
# line that does not come out as a valid reference fails the call (fail closed).
trivy_occurrences() (
  set -o pipefail
  { git grep --text --no-color -oE "$TRIVY_IMAGE_RE" ${1:+"$1"} \
      -- ':(glob)clusters/homelab/**/*.yaml' || [ $? -eq 1 ]; } \
    | sed "${1:+s|^$1:||}" \
    | sed -E 's/^(.*):[[:space:]]+image: *"?([a-zA-Z0-9./_-]+(:[a-zA-Z0-9._-]+)?(@sha256:[a-f0-9]+)?)$/\2 \1/' \
    | awk '$1 !~ /^[a-zA-Z0-9.\/_-]+(:[a-zA-Z0-9._-]+)?(@sha256:[a-f0-9]+)?$/ { bad = 1 } { print } END { exit bad }' \
    | LC_ALL=C sort
)

# trivy_gate_set BASE_REV — the images a diff from BASE_REV to the working tree
# must gate, one "IMAGE<TAB>WHY" per line:
#
#   * every image reference that occurs in some manifest file MORE times than it
#     did at BASE_REV: a tag or digest bump, a brand-new image (which then fails
#     NO BASELINE if nobody registered it), and also a workload moved to, or
#     added with, a reference another workload already uses. Comparing the
#     repo-wide SET of references misses that last case, because the set does
#     not change. Re-indenting or re-quoting an
#     `image:` line changes nothing here. Moving a file to a new path does gate
#     the images in it: that fails safe, and it is rare.
#     ACCEPTED RESIDUAL: the unit is the
#     reference per file, not the container. Two containers in ONE file that
#     swap references, or a container moved onto a reference whose only other
#     user in that file is removed, leave every count unchanged and gate
#     nothing. Every reference involved is already pinned in that same file,
#     so no image new to it reaches the cluster, and the weekly report covers
#     drift on them. Closing this needs container-aware YAML parsing.
#   * every other pinned reference whose baseline value changed in this diff, so
#     a ratchet-down PR proves its new number and a raise is measured, not typed.
#
# Images whose occurrences AND baseline are untouched are not returned: CVE
# drift on them is upstream publishing, not this diff, and belongs to the
# drift report, not to the promotion gate.
#
# FAIL CLOSED. Callers invoke this inside `if`, where bash ignores errexit, so
# `set -e` would not stop a half-failed selection. Every step is therefore
# checked explicitly, pipelines run under pipefail, and the result is printed
# only after every step succeeded. Any failure returns non-zero with nothing on
# stdout, and the caller then gates every image.
trivy_gate_set() (
  set -o pipefail
  _gs_tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$_gs_tmp"' EXIT
  git rev-parse -q --verify "$1^{commit}" >/dev/null || exit 1

  trivy_occurrences > "$_gs_tmp/occ-head" || exit 1
  trivy_occurrences "$1" > "$_gs_tmp/occ-base" || exit 1
  # comm on sorted input with duplicates is a multiset difference: a line that
  # occurs n times in head and m < n times at base is reported n - m times.
  LC_ALL=C comm -23 "$_gs_tmp/occ-head" "$_gs_tmp/occ-base" \
    | awk '{ print $1 }' | LC_ALL=C sort -u > "$_gs_tmp/added" || exit 1
  awk '{ printf "%s\tadded or changed in this diff\n", $0 }' "$_gs_tmp/added" > "$_gs_tmp/out" || exit 1

  # Absent at the base (the commit that introduced it) is a skip; failing to
  # look, or failing to read a file that is there, is a failure.
  _gs_bl=$(git ls-tree --name-only "$1" -- "$TRIVY_BASELINE_FILE") || exit 1
  if [ -n "$_gs_bl" ]; then
    git show "$1:$TRIVY_BASELINE_FILE" > "$_gs_tmp/base-baseline" || exit 1
    trivy_images_in . > "$_gs_tmp/head" || exit 1
    LC_ALL=C comm -23 "$_gs_tmp/head" "$_gs_tmp/added" > "$_gs_tmp/rest" || exit 1
    while IFS= read -r _img; do
      _now=$(trivy_baseline_for "$_img" "$TRIVY_BASELINE_FILE") || exit 1
      _was=$(trivy_baseline_for "$_img" "$_gs_tmp/base-baseline") || exit 1
      [ "$_now" = "$_was" ] && continue
      printf '%s\tbaseline changed in this diff (%s -> %s)\n' "$_img" "${_was:-none}" "${_now:-none}" \
        >> "$_gs_tmp/out" || exit 1
    done < "$_gs_tmp/rest"
  else
    echo "[i] $1 has no $TRIVY_BASELINE_FILE — the baseline-change rule has nothing to compare against" >&2
  fi
  cat "$_gs_tmp/out"
)
