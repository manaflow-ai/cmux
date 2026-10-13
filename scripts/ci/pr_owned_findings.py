#!/usr/bin/env python3
"""Decide a whole-tree lint that failed on a pull request's merge commit.

A finding counts against the PR only when it is in a file the PR changed
(HEAD's first parent to HEAD), in a path a changed line of a baseline file
names, or when the PR changes the lint's code. A finding anywhere else is
already on the base branch: it is reported as a warning, and the gate passes.
Base pushes keep the whole-tree verdict.

Exits 1 when the PR owns a finding, when HEAD is not a merge commit, or when
the lint did not finish cleanly (a traceback, no finding this can read, or a
summary count that differs from the findings read): then the lint's own
failure stands.
"""
import argparse
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument('--finding', required=True, help='regex for a finding line; its (?P<path>...) group is the file')
parser.add_argument('--prefix', default='', help='prepended to each finding path to make it repository-relative')
parser.add_argument('--rules', required=True, help='regex for the repository paths of the lint\'s code')
parser.add_argument('--baselines', help='regex for baseline files; a changed line owns the Swift paths it names')
parser.add_argument('--summary', help='regex whose (?P<count>...) group is the number of findings the lint reports')
parser.add_argument('--fixed', help='file listing paths the lint rewrote; each is a finding too')
parser.add_argument('logs', nargs='+', help='the lint output')
args = parser.parse_args()


def git(*command):
    return subprocess.run(['git', *command], check=True, text=True, capture_output=True).stdout


parents = git('rev-list', '--parents', '-n', '1', 'HEAD').split()[1:]
if len(parents) != 2:
    print('::error::HEAD is not a pull request merge commit; every finding counts.')
    sys.exit(1)
changed = set(git('diff', '--name-only', '--no-renames', parents[0], 'HEAD').splitlines())

rules = re.compile(args.rules)
rule_changes = sorted(path for path in changed if rules.search(path))
if args.baselines:
    baselines = re.compile(args.baselines)
    swift_path = re.compile(r'(?:Packages|ios)/[^\s:]+\.swift')
    for path in sorted(changed):
        if baselines.search(path):
            for line in git('diff', '-U0', '--no-renames', parents[0], 'HEAD', '--', path).splitlines():
                if line[:1] in '+-' and line[:3] not in ('+++', '---'):
                    changed.update(swift_path.findall(line))

finding = re.compile(args.finding)
summary = re.compile(args.summary) if args.summary else None
findings = []  # (path, line)
reported = []
for log in args.logs:
    with open(log, encoding='utf-8', errors='replace') as handle:
        for line in handle:
            if line.startswith('Traceback (most recent call last)'):
                print('::error::The lint crashed; its failure stands for every file it did not reach.')
                sys.exit(1)
            match = finding.search(line)
            if match:
                findings.append((args.prefix + match.group('path'), line.strip()))
            match = summary.search(line) if summary else None
            if match:
                reported.append(int(match.group('count')))
if summary and sum(reported) != len(findings):
    print(f'::error::The lint reported {sum(reported) if reported else "no"} finding(s) and this gate read '
          f'{len(findings)}; the failure stands.')
    sys.exit(1)
if args.fixed:
    with open(args.fixed, encoding='utf-8') as handle:
        findings += [(path, f'{path}: the namespace lint rewrites it')
                     for path in handle.read().splitlines() if path]

if not findings:
    print('::error::The lint failed without a finding this gate can read; the failure stands.')
    sys.exit(1)

owned = [(path, text) for path, text in findings if rule_changes or path in changed]
for path, text in owned:
    print(f'::error file={path}::{text}')
if owned:
    if rule_changes:
        print(f'This PR changes the lint ({", ".join(rule_changes)}), so every finding counts.')
    print(f'{len(owned)} finding(s) in this PR.')
    sys.exit(1)
for path, text in findings:
    print(f'::warning file={path},title=On the base branch, not in this PR::{text}')
print(f'{len(findings)} finding(s), all in files this PR does not change: they are on the base branch. '
      'Fix them forward there; this PR passes.')
