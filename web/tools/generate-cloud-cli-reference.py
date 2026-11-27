#!/usr/bin/env python3
"""Refresh the public NEXT command snapshot from its action catalog.

Run from a checkout whose Git history contains the NEXT revision:
  python3 web/tools/generate-cloud-cli-reference.py --ref origin/feat-cmux-next
Use --check to verify a snapshot against its recorded source commit.
The website's main branch does not contain the NEXT catalog itself.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = 'plans/cmux-next/action-surfaces.json'
OUTPUT = ROOT / 'web/app/[locale]/(landing)/docs/cloud/cli/actions.json'
PAGE = OUTPUT.with_name('page.tsx')


def snapshot(ref):
    sha = subprocess.check_output(['git', 'rev-parse', '--verify', f'{ref}^{{commit}}'], cwd=ROOT, text=True).strip()
    data = json.loads(subprocess.check_output(['git', 'show', f'{sha}:{CATALOG}'], cwd=ROOT, text=True))
    actions = sorted(
        ({'command': 'cmux ' + action['cli_name'], 'id': action['id']}
         for action in data['actions']
         if action['cli'] == 'offered' and action['cli_name'].startswith('cloud ')),
        key=lambda action: action['command'],
    )
    if not actions or len({a['command'] for a in actions}) != len(actions):
        raise ValueError('Expected a nonempty catalog of unique offered Cloud commands')
    lines = ['{', f'  "sourceCommit": "{sha}",', f'  "sourcePath": "{CATALOG}",', '  "actions": [']
    lines.extend('    ' + json.dumps(a) + (',' if i < len(actions) - 1 else '') for i, a in enumerate(actions))
    return '\n'.join([*lines, '  ]', '}', ''])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', help='NEXT revision to read; defaults to the recorded source commit')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    ref = args.ref or json.loads(OUTPUT.read_text())['sourceCommit']
    generated = snapshot(ref)
    actions = json.loads(generated)['actions']
    # Inline rows keep commands discoverable by the site's static search index.
    rows = '\n'.join('          <tr><td><code>' + a['command'] + '</code></td><td><code>' + a['id'] + '</code></td></tr>' for a in actions)
    page, replacements = re.subn(r'(?s)(          \{/\* GENERATED_CLOUD_ACTIONS_START \*/\})(.*?)(          \{/\* GENERATED_CLOUD_ACTIONS_END \*/\})', lambda m: m[1] + '\n' + rows + '\n' + m[3], PAGE.read_text())
    if replacements != 1:
        parser.exit(1, 'Expected exactly one generated Cloud table in page.tsx.\n')
    if args.check:
        if PAGE.read_text() != page:
            parser.exit(1, 'Cloud CLI table differs; regenerate it with --ref.\n')
        if OUTPUT.read_text() != generated:
            parser.exit(1, 'Cloud CLI snapshot differs; regenerate it with --ref.\n')
    else:
        OUTPUT.write_text(generated)
        PAGE.write_text(page)
