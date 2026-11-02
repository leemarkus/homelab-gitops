#!/usr/bin/env python3
"""Run from the repo root; requires PyYAML and promtool, never downloads tools."""
import os
import shutil
from pathlib import Path
import subprocess
import tempfile

import yaml

if shutil.which('promtool') is None:
    raise SystemExit('SKIP: promtool not found on PATH; these suites need it')

root = Path(__file__).resolve().parents[2]
scratch = root / '.validate-tmp'
scratch.mkdir(exist_ok=True)
os.environ['TMPDIR'] = str(scratch)

# (PrometheusRule manifest, promtool test file, rules filename the test names).
# Each suite runs against the ACTUAL rule spec extracted from the manifest.
SUITES = [
    ('clusters/homelab/config/etcd-disk-alerts.yaml', 'etcd-disk.test.yaml', 'etcd-rules.yaml'),
    ('clusters/homelab/config/job-failure-alerts.yaml', 'job-failure.test.yaml', 'job-failure-rules.yaml'),
]

# Keep extracted rules beside the rewritten test file. Cleanup also runs on
# parse failures, missing executables and nonzero promtool exits.
with tempfile.TemporaryDirectory(prefix='prometheus-', dir=scratch) as work:
    work = Path(work)
    for manifest_path, test_name, rules_name in SUITES:
        docs = [d for d in yaml.safe_load_all((root / manifest_path).read_text()) if d]
        manifest = next(d for d in docs if d.get('kind') == 'PrometheusRule')
        rules = work / rules_name
        rules.write_text(yaml.safe_dump(manifest['spec']))
        suite = yaml.safe_load((root / 'tests/prometheus' / test_name).read_text())
        suite['rule_files'] = [str(rules)]
        tests = work / test_name
        tests.write_text(yaml.safe_dump(suite))
        subprocess.run(['promtool', 'check', 'rules', str(rules)], check=True)
        subprocess.run(['promtool', 'test', 'rules', str(tests)], check=True)
