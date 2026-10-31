#!/usr/bin/env python3
"""Decide a whole-tree lint that failed on a pull request's merge commit.

A finding counts against the PR only when it is in a file the PR changed
(HEAD's first parent to HEAD), when it names (--context) another file the PR
changed whose change can cause it, in a path a changed line of a baseline file
names, or when the PR changes the lint's code. A package manifest the lint
reads (--manifests) counts as its code unless every line the PR changes in it
is a comment or sits inside a `dependencies: [...]` list, and names no
target call (`.target(`, `.executableTarget(`, `.testTarget(`, `.macro(`),
`swiftSettings` or `defaultIsolation`; a manifest diff this cannot read counts
as code. A finding anywhere else is
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
parser.add_argument('--context', help='regex, searched over each finding line for every match, whose (?P<path>...) '
                    'group (with --prefix) is another file whose change can cause the finding: a PR that changes '
                    'it owns the finding too')
parser.add_argument('--rules', required=True, help='regex for the repository paths of the lint\'s code')
parser.add_argument('--manifests', help='regex for --rules paths that count only when a changed line can change '
                    'what the lint reads: one outside a dependencies list or comment, or one naming a target or '
                    'swiftSettings')
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

# A manifest line that counts as the lint's code whatever list it sits in. check-concurrency.sh
# reads each target call (`.target(`, `.executableTarget(`, `.testTarget(`, `.macro(`) by balanced
# parentheses and its swiftSettings (uiSwiftSettings, `.defaultIsolation(...)`) inside that call
# (swift_scope.package_targets): a line that opens a call can change which call the lines after it
# belong to. Block comments can hide or expose code.
MANIFEST_ANCHOR = re.compile(r'\.(?:target|executableTarget|testTarget|macro)\s*\(|swiftSettings|defaultIsolation'
                             r'|/\*|\*/')
HUNK = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')


def mask_swift(text):
    """The text with string literals and comments blanked, newlines kept."""
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith('//', i):
            end = text.find('\n', i)
            end = n if end < 0 else end
        elif text.startswith('/*', i):
            end = text.find('*/', i + 2)
            end = n if end < 0 else end + 2
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
        elif text[i] == '"':
            end = i + 1
            while end < n and text[end] not in '"\n':
                end += 2 if text[end] == '\\' else 1
            end = min(end + 1, n)
        else:
            out.append(text[i])
            i += 1
            continue
        out.append(re.sub(r'[^\n]', ' ', text[i:end]))
        i = end
    return ''.join(out)


def dependency_lines(text):
    """1-based numbers of the lines that are only part of a `dependencies: [...]` list,
    and of comment-only and blank lines."""
    masked = mask_swift(text)
    lines = masked.split('\n')
    allowed = {number for number, line in enumerate(lines, 1) if not line.strip()}
    for match in re.finditer(r'\bdependencies\s*:\s*\[', masked):
        depth, end = 0, None
        for index in range(match.end() - 1, len(masked)):
            if masked[index] == '[':
                depth += 1
            elif masked[index] == ']':
                depth -= 1
                if depth == 0:
                    end = index
                    break
        if end is None:
            continue
        first = masked.count('\n', 0, match.start()) + 1
        last = masked.count('\n', 0, end) + 1
        if lines[first - 1][:match.start() - (masked.rfind('\n', 0, match.start()) + 1)].strip():
            first += 1  # the list opens after other code on its line
        if re.sub(r'^\s*,?\s*', '', masked[end + 1:].split('\n', 1)[0]):
            last -= 1  # other code follows the list on its last line
        allowed.update(range(first, last + 1))
    return allowed


def manifest_changes_rules(path):
    """Whether a manifest change can change what the lint reads; True when unreadable."""
    try:
        old = git('show', f'{parents[0]}:{path}')
        new = git('show', f'HEAD:{path}')
        diff = git('diff', '-U0', '--no-renames', '--no-ext-diff', '--no-textconv', parents[0], 'HEAD', '--', path)
    except (subprocess.CalledProcessError, UnicodeDecodeError):
        return True
    removed, added = [], []
    for line in diff.splitlines():
        hunk = HUNK.match(line)
        if hunk:
            old_start, old_count, new_start, new_count = hunk.groups()
            removed += range(int(old_start), int(old_start) + int(1 if old_count is None else old_count))
            added += range(int(new_start), int(new_start) + int(1 if new_count is None else new_count))
    if not removed and not added:
        return True  # a binary, mode-only or otherwise unreadable diff
    for text, numbers in ((old, removed), (new, added)):
        lines = text.split('\n')
        allowed = dependency_lines(text)
        for number in numbers:
            if number not in allowed or number > len(lines) or MANIFEST_ANCHOR.search(lines[number - 1]):
                return True
    return False


rules = re.compile(args.rules)
manifests = re.compile(args.manifests) if args.manifests else None
rule_changes = sorted(path for path in changed if rules.search(path)
                      and not (manifests and manifests.search(path) and not manifest_changes_rules(path)))
if args.baselines:
    baselines = re.compile(args.baselines)
    swift_path = re.compile(r'(?:Packages|ios)/[^\s:]+\.swift')
    for path in sorted(changed):
        if baselines.search(path):
            for line in git('diff', '-U0', '--no-renames', parents[0], 'HEAD', '--', path).splitlines():
                if line[:1] in '+-' and line[:3] not in ('+++', '---'):
                    changed.update(swift_path.findall(line))

finding = re.compile(args.finding)
context = re.compile(args.context) if args.context else None
summary = re.compile(args.summary) if args.summary else None
findings = []  # (path, line)
causes = {}  # finding line -> the other paths whose change can cause it
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
                if context:
                    causes.setdefault(line.strip(), set()).update(
                        args.prefix + cause.group('path') for cause in context.finditer(line))
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

owned = [(path, text) for path, text in findings
         if rule_changes or path in changed or causes.get(text, set()) & changed]
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
