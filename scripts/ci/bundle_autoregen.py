#!/usr/bin/env python3
"""Prepare only generated web bundle conflicts for a rebuild of merged sources."""
import argparse
import json
import os
from pathlib import Path
import subprocess

PANE = 'Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html'
APP = 'Resources/markdown-viewer/webviews-app'


def generated(path):
    return path == PANE or path.startswith(APP + '/')


def git(root, *args, check=True):
    # Report every conflict, even in clones with installed keep-ours drivers.
    return subprocess.run([
        'git', '-C', str(root), '-c', 'core.hooksPath=/dev/null',
        '-c', 'merge.cmux-generated-v1.driver=false',
        '-c', 'merge.xcstrings-v2.driver=false', '-c', 'merge.pbxproj-v1.driver=false',
        '-c', 'rerere.enabled=false', *args,
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


def prepare(root, base):
    original = git(root, 'rev-parse', 'HEAD').stdout.strip()
    result = git(root, 'merge', '--no-ff', '--no-commit', base, check=False)
    conflicts = git(root, 'diff', '--name-only', '--diff-filter=U', '-z').stdout.split('\0')
    conflicts = [path for path in conflicts if path]
    if result.returncode == 0 or not conflicts or any(not generated(path) for path in conflicts):
        # Clean PRs and authored conflicts are the owner's responsibility.
        git(root, 'merge', '--abort', check=False)
        git(root, 'reset', '--hard', original)
        return False
    # Discard all old generated output including modify/delete conflicts.
    # The next build regenerates it entirely from the merged source tree.
    git(root, 'rm', '-r', '-f', '--ignore-unmatch', '--', PANE, APP)
    if git(root, 'diff', '--name-only', '--diff-filter=U').stdout.strip():
        raise RuntimeError('unresolved paths remain after generated output removal')
    return True


def candidates(repository):
    query = '''query($owner:String!,$name:String!,$cursor:String) {
      repository(owner:$owner,name:$name) {
        pullRequests(states:OPEN,baseRefName:"feat-cmux-next",first:100,after:$cursor) {
          pageInfo {hasNextPage endCursor}
          nodes {number headRefName headRepository {nameWithOwner} mergeable
            files(first:100) {pageInfo {hasNextPage} nodes {path}}}
        }
      }
    }'''
    owner, name = repository.split('/')
    cursor = None
    prs = []
    while True:
        args = ['gh', 'api', 'graphql', '-f', 'query=' + query, '-f', 'owner=' + owner, '-f', 'name=' + name]
        if cursor:
            args += ['-f', 'cursor=' + cursor]
        data = json.loads(subprocess.check_output(args, text=True))
        connection = data['data']['repository']['pullRequests']
        for pr in connection['nodes']:
            if (pr.get('headRepository') or {}).get('nameWithOwner') != repository:
                continue
            files = pr['files']
            paths = [file['path'] for file in files['nodes']]
            if files['pageInfo']['hasNextPage']:
                raw_files = subprocess.check_output([
                    'gh', 'api', '--paginate', '--slurp',
                    f"repos/{repository}/pulls/{pr['number']}/files?per_page=100",
                ], text=True)
                paths = [file['filename'] for page in json.loads(raw_files) for file in page]
            # UNKNOWN is checked locally: GitHub recomputes mergeability asynchronously.
            if pr['mergeable'] == 'MERGEABLE':
                continue
            if not any(generated(path) for path in paths):
                continue
            prs.append({'number': pr['number'], 'head_ref': pr['headRefName'], 'merge_base': True})
        if not connection['pageInfo']['hasNextPage']:
            return prs
        cursor = connection['pageInfo']['endCursor']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['discover', 'prepare'])
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--base', default='origin/feat-cmux-next')
    args = parser.parse_args()
    if args.command == 'discover':
        prs = candidates(os.environ['GITHUB_REPOSITORY'])
        print('prs=' + json.dumps(prs, separators=(',', ':')))
    else:
        print('proceed=' + str(prepare(args.root, args.base)).lower())


if __name__ == '__main__':
    main()
