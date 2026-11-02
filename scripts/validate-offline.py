#!/usr/bin/env python3
"""Run the CI validation jobs locally, offline.

Usage: python3 scripts/validate-offline.py   (from the repository root)

Mirrors .forgejo/workflows/validate.yml without network access or package
installs: yamllint, kubeconform (local schemas only), the Secret boundary, the
PrometheusRule label check, kyverno against raw manifests and every rendered
overlay, kustomize builds, trivy config, and helm template for charts already
in the local Helm cache. Anything that cannot run offline is reported as SKIP
with a reason, never as PASS. Exit code 1 when any check fails.

Environment:
  KUBECONFORM_SCHEMA_DIR  directory of JSON schemas ({{.ResourceKind}}{{.KindSuffix}}.json)
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root = Path.cwd()
cluster = Path('clusters/homelab')
scratch = root / '.validate-tmp'
scratch.mkdir(exist_ok=True)
log = (scratch / 'validate.log').open('w')
failures = []
skipped = []


def skip(name, reason):
    print(f'SKIP  {name} ({reason})', flush=True)
    skipped.append(name)


def run(name, args, ok=(0,)):
    """Run one check. Returns its output, or None when the tool is not installed."""
    if shutil.which(args[0]) is None:
        skip(name, f'{args[0]} not found on PATH')
        return None
    proc = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write(f'\n=== {name} ===\n' + proc.stdout)
    log.flush()
    verdict = 'PASS' if proc.returncode in ok else 'FAIL'
    if name.startswith('kubeconform') and proc.returncode == 0 and re.search(r'Skipped: [1-9]', proc.stdout):
        verdict = 'SKIP (some schemas missing locally)'
        skipped.append(name)
    print(f'{verdict:5} {name} (exit {proc.returncode})', flush=True)
    if proc.returncode not in ok:
        failures.append(name)
    return proc.stdout


def safe(path):
    return not any(part in ('.git', '.validate-tmp') or part.startswith('.env') for part in path.parts)


workflow = Path('.forgejo/workflows/validate.yml').read_text()

all_yaml = [p for p in Path('.').rglob('*') if safe(p) and p.is_file() and p.suffix in ('.yml', '.yaml')]
run('yamllint', ['yamllint', '-c', '.yamllint.yaml', *map(str, all_yaml)])

raw = [p for p in cluster.rglob('*.yaml')
       if safe(p) and 'values' not in p.parts and p.name != 'kustomization.yaml'
       and not ('tenants' in p.parts and 'tests' in p.parts)]

# Same Kubernetes version and CRD exclusions as the workflow; no HTTP fallback.
version = re.search(r'-kubernetes-version ([0-9.]+)', workflow).group(1)
skip_kinds = re.search(r'-skip ([A-Za-z,]+)', workflow).group(1)
schema_dir = os.environ.get('KUBECONFORM_SCHEMA_DIR', str(scratch / 'schemas'))
schema_args = ['-kubernetes-version', version, '-skip', skip_kinds,
               '-schema-location', schema_dir + '/{{.ResourceKind}}{{.KindSuffix}}.json']
run('kubeconform raw manifests',
    ['kubeconform', '-strict', '-summary', '-ignore-missing-schemas', *schema_args, *map(str, raw)])

plaintext = [str(p) for p in raw if re.search(r'^kind:\s*Secret\s*$', p.read_text(), re.M)]
unsealed = [str(p) for p in raw if p.name.startswith('sealed-secret-') and 'encryptedData' not in p.read_text()]
if plaintext or unsealed:
    failures.append('sealed-secret-check')
print(f"{'FAIL' if plaintext or unsealed else 'PASS':5} sealed-secret-check", flush=True)

unlabelled = []
for p in raw:
    for doc in re.split(r'^---\s*$', p.read_text(), flags=re.M):
        if re.search(r'^kind:\s*PrometheusRule\s*$', doc, re.M) and not re.search(
                r'^\s+release:\s+kube-prometheus-stack(?:\s*#.*)?\s*$', doc, re.M):
            unlabelled.append(str(p))
if unlabelled:
    failures.append('prometheusrule-labels')
print(f"{'FAIL' if unlabelled else 'PASS':5} PrometheusRule discovery labels {unlabelled or ''}", flush=True)

policy = str(cluster / 'config/kyverno-policies.yaml')
resources = [p for p in raw if 'tenants' not in p.parts]
run('kyverno raw manifests',
    ['kyverno', 'apply', policy, *[arg for p in resources for arg in ('--resource', str(p))]])

for kfile in sorted(cluster.glob('**/overlays/*/kustomization.yaml')):
    overlay = str(kfile.parent)
    rendered_dir = scratch / ('render-' + kfile.parts[-4] + '-' + kfile.parts[-2])
    rendered_dir.mkdir(exist_ok=True)
    rendered = rendered_dir / 'resources.yaml'
    output = run('kustomize ' + overlay, ['kustomize', 'build', overlay])
    if output is None:
        skip('kyverno, kubeconform and trivy for ' + overlay, 'overlay not rendered')
        continue
    rendered.write_text(output)
    run('kyverno ' + overlay, ['kyverno', 'apply', policy, '--resource', str(rendered), '--audit-warn'])
    run('kubeconform ' + overlay,
        ['kubeconform', '-strict', '-summary', '-ignore-missing-schemas', *schema_args, str(rendered)])
    if 'tenants' in kfile.parts:
        run('trivy config ' + overlay,
            ['trivy', 'config', '--skip-check-update', '--skip-version-check', '--severity', 'HIGH,CRITICAL',
             '--exit-code', '1', '--cache-dir', str(scratch / 'trivy-cache'), str(rendered_dir)])

run('kustomize tenant-namespaces', ['kustomize', 'build', str(cluster / 'tenant-namespaces')])
run('trivy config platform (advisory, as in CI)',
    ['trivy', 'config', '--skip-check-update', '--skip-version-check', '--severity', 'HIGH,CRITICAL',
     '--exit-code', '0', '--cache-dir', str(scratch / 'trivy-cache'), str(cluster)])
skip('trivy image CVEs', 'needs registry access and a DB refresh')

# Reuse the workflow's own chart discovery, stopping before its networked loop.
discovery = workflow.split('          for f in clusters/homelab/apps/*.yaml;', 1)[1].split('          # A parse', 1)[0]
discovery = 'for f in clusters/homelab/apps/*.yaml;' + discovery
discovery = '\n'.join(line[10:] if line.startswith('          ') else line for line in discovery.splitlines())
discovery = discovery.replace('/tmp/charts.txt', str(scratch / 'charts.txt'))
run('helm chart discovery', ['bash', '-ec', discovery])
charts = scratch / 'charts.txt'
if shutil.which('helm') is None or not charts.exists():
    skip('helm template', 'helm not found on PATH' if shutil.which('helm') is None else 'chart discovery failed')
    charts_lines = []
else:
    charts_lines = charts.read_text().splitlines()
    cache = Path(subprocess.run(['helm', 'env', 'HELM_CACHE_HOME'], text=True,
                                stdout=subprocess.PIPE).stdout.strip() or '.') / 'repository'
for line in charts_lines:
    chart, chart_version, _repo, values = line.split('|')
    archives = list(cache.glob(f'{chart}-{chart_version}.tgz'))
    if not archives:
        skip(f'helm {chart}@{chart_version}', 'chart not in the local Helm cache')
        continue
    args = ['helm', 'template', chart, str(archives[0]), '--skip-tests']
    if values:
        args += ['-f', values]
    run(f'helm {chart}@{chart_version}', args)

print(f'Skipped: {len(skipped)}', flush=True)
print('Failures:', failures or 'none', flush=True)
sys.exit(1 if failures else 0)
