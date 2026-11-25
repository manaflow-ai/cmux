#!/usr/bin/env python3
"""Fail a pull request that adds a namespace type the safe rewrite fixes.

Run after scripts/ci/package-conventions-gate.sh --pr on a pull request's merge
commit: the gate's `lint-ios-package-conventions.sh --namespace-fix` pass leaves
its rewrites in the working tree. A rewrite that removes a line the pull request
added (HEAD's first parent to HEAD) is a namespace type this pull request
introduced, and it fails even while CMUX_NEXT_STYLE_GUARDS=warn keeps the rest of
the conventions lint advisory. Namespace types already on the base branch stay
warnings: the base autofix rewrites those.

Leo wants the class fixed, not the instance: the same base red came back three
times on 2026-11-21 (#48696, #48875) because warn-only let each one merge.

Exits 1 and names each type when the pull request owns one, else 0.
"""
import subprocess
import sys

ROOTS = ('ios', 'Packages')


def git(*args):
    return subprocess.run(('git', *args), check=True, capture_output=True, text=True).stdout


def changed_lines(diff, sign):
    """Lines a unified diff removes ('-') or adds ('+'), stripped, by file."""
    lines, path = {}, None
    for line in diff.splitlines():
        if line.startswith('+++ ') or line.startswith('--- '):
            if line.startswith('+++ '):
                name = line[4:]
                path = name[2:] if name.startswith('b/') else None
            continue
        if path and line.startswith(sign):
            text = line[1:].strip()
            if text:
                lines.setdefault(path, set()).add(text)
    return lines


def owned(rewrite_diff, pr_diff):
    removed = changed_lines(rewrite_diff, '-')
    added = changed_lines(pr_diff, '+')
    return sorted((path, text) for path, texts in removed.items() for text in texts & added.get(path, set()))


def main():
    rewrite = git('diff', '-U0', '--', *ROOTS)
    if not rewrite.strip():
        return 0
    files = git('diff', '--name-only', '--', *ROOTS).split()
    pr = git('diff', '-U0', 'HEAD^1', 'HEAD', '--', *files)
    found = owned(rewrite, pr)
    if not found:
        print('namespace types: the safe rewrite touched only lines already on the base branch (warning only)')
        return 0
    for path, text in found:
        print(f'::error file={path},title=namespace type added::{text} is an all-static namespace type; '
              'run ./scripts/lint-ios-package-conventions.sh --namespace-fix and commit the result')
    print('This pull request adds namespace types, which fail even while the rest of the conventions lint only '
          'warns. Fix: ./scripts/lint-ios-package-conventions.sh --namespace-fix. To merge anyway, add the '
          'namespace-lint-override label and re-run this job.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
