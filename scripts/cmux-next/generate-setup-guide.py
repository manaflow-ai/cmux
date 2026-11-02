#!/usr/bin/env python3
"""Derive the offline native guide and docs from setup::TASKS. Rust parity tests own the wire."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'cmux-tui/crates/cmux-tui/src/cli/setup.rs'
APP = ROOT / 'Packages/macOS/CmuxNext/Sources/CmuxNextApp'


def guides():
    source = SOURCE.read_text()
    tasks = source.split('const TASKS: &[Task] = &[', 1)[1].split('\nfn list()', 1)[0]
    result = []
    literal = r'"(?:[^"\\]|\\.)*"'
    for task in tasks.split('    Task {')[1:]:
        identifier = re.search(r'id: (' + literal + ')', task)
        guide = re.search(r'guide: Some\(HumanGuide \{\s*title: (' + literal + r'),\s*steps: &\[([\s\S]*?)\],\s*\}\)', task)
        if guide:
            result.append({'id': json.loads(identifier[1]), 'title': json.loads(guide[1]),
                           'steps': [json.loads(s) for s in re.findall(literal, guide[2])]})
        elif 'guide: None,' not in task:
            raise ValueError('Every task must declare its guide explicitly')
    if not result:
        raise ValueError('No human guides found')
    return result


def outputs():
    entries = guides()
    md = ['# Set up cmux', '', '<!-- Generated from setup::TASKS by scripts/cmux-next/generate-setup-guide.py. -->', '']
    for entry in entries:
        md += ['## ' + entry['title'], '']
        md += [f'{i + 1}. {value}' for i, value in enumerate(entry['steps'])]
        md += ['']
    return {ROOT / 'docs/setup-guide.md': '\n'.join(md),
            APP / 'Resources/setup-guide.json': json.dumps(entries, indent=2, ensure_ascii=False) + '\n'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for path, content in outputs().items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f'{path.relative_to(ROOT)} differs; run {Path(__file__).relative_to(ROOT)}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)


if __name__ == '__main__':
    main()
