"""Offline shape checks for renovate.json, plus two policy regressions.

Run: python3 tests/prometheus/test_renovate.py [path/to/renovate.json]
This checks the literal matching subset the rules rely on, not Renovate's full
engine.
"""
import json
from pathlib import Path
import sys

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('renovate.json')
config = json.loads(path.read_text())
assert isinstance(config, dict)
assert isinstance(config['extends'], list)
assert isinstance(config['packageRules'], list)
for rule in config['packageRules']:
    assert isinstance(rule, dict)
    assert any(key.startswith('match') for key in rule)
    for key in ('matchDatasources', 'matchPackageNames', 'matchManagers', 'matchUpdateTypes'):
        if key in rule:
            assert isinstance(rule[key], list) and rule[key]
            assert all(isinstance(item, str) for item in rule[key])
    for key in ('enabled', 'automerge', 'separateMultipleMinor'):
        if key in rule:
            assert type(rule[key]) is bool

# deploy is CI-managed: Renovate must only ever target main.
assert config['baseBranches'] == ['main']

# k3s is upgraded by system-upgrade-controller Plans, never by Renovate. Exactly
# one rule disables it, for every datasource and update type.
k3s = [rule for rule in config['packageRules']
       if any('k3s' in name for name in rule.get('matchPackageNames', []))]
assert len(k3s) == 1, k3s
rule = k3s[0]
assert rule['enabled'] is False
assert 'matchUpdateTypes' not in rule and 'matchDatasources' not in rule

# No rule turns auto-merge on anywhere.
assert not any(rule.get('automerge') is True for rule in config['packageRules'])
print('PASS: Renovate JSON shape; main-only base; k3s disabled; no auto-merge')
