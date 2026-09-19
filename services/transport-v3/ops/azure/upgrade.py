#!/usr/bin/env python3
"""Plan and execute a non-destructive relay-generation handover.

The command never deletes or restarts a generation. It validates overlap,
rechecks replacement readiness, drains old nodes one at a time, and reports
when a retired node has exited cleanly. Deletion is an explicit operator step.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def receipt(path):
    value = json.loads(Path(path).read_text())
    if not isinstance(value.get('nodes'), list) or len(value['nodes']) < 2:
        raise ValueError('receipt needs at least two nodes')
    for node in value['nodes']:
        for key in ('group', 'node', 'region'):
            if not isinstance(node.get(key), str) or not node[key]:
                raise ValueError('receipt node is incomplete')
        if 'CMUX_V3_OK' not in node.get('installation', ''):
            raise ValueError('receipt lacks installation success')
    return value


def validate(old, new):
    old_nodes = {(n['group'], n['node']) for n in old['nodes']}
    new_nodes = {(n['group'], n['node']) for n in new['nodes']}
    if old_nodes & new_nodes:
        raise ValueError('replacement reuses an old node')
    if old.get('image') == new.get('image'):
        raise ValueError('replacement must use a distinct immutable image digest')
    if {n['region'] for n in old['nodes']} != {n['region'] for n in new['nodes']}:
        raise ValueError('replacement must cover the same serving regions')


def run(*args):
    return subprocess.check_output(args, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'drain'])
    parser.add_argument('--subscription', required=True)
    parser.add_argument('--old', type=Path, required=True)
    parser.add_argument('--new', type=Path, required=True)
    parser.add_argument('--wait-seconds', type=int, default=120)
    args = parser.parse_args()
    if args.wait_seconds < 1 or args.wait_seconds > 3600:
        parser.error('--wait-seconds must be 1..3600')
    old, new = receipt(args.old), receipt(args.new)
    validate(old, new)
    if args.action == 'plan':
        print(json.dumps({'old_image': old.get('image'), 'new_image': new.get('image'),
            'regions': sorted({n['region'] for n in new['nodes']}),
            'steps': ['probe replacement', 'drain old region A', 'verify exit',
                      'drain old region B', 'verify exit', 'operator-retire-old-vms']}, indent=2))
        return
    root = Path(__file__).resolve().parent
    for node in old['nodes']:
        command = [str(root / 'manage.py'), 'drain', '--subscription', args.subscription,
                   '--group', node['group'], '--node', node['node'], '--replacement-receipt', str(args.new)]
        subprocess.run(['python3', *command], check=True)
        deadline = time.monotonic() + args.wait_seconds
        while time.monotonic() < deadline:
            state = json.loads(run('az', 'vm', 'run-command', 'invoke', '--subscription', args.subscription,
                '-g', node['group'], '-n', node['node'], '--command-id', 'RunShellScript',
                '--scripts', 'docker inspect --format "{{.State.Status}} {{.State.ExitCode}}" cmux-v3-relay || true',
                '--only-show-errors', '-o', 'json'))
            message = '\n'.join(v.get('message', '') for v in state.get('value', []))
            if 'exited 0' in message:
                print('DRAINED', node['node'], flush=True)
                break
            time.sleep(2)
        else:
            raise RuntimeError(f'old node did not exit cleanly: {node["node"]}')


if __name__ == '__main__':
    main()
