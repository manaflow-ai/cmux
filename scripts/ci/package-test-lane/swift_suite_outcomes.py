from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
from urllib.parse import urlencode
from urllib.request import urlopen


SCRIPT = 'scripts/ci/package-test-lane.sh'
DIGEST = re.compile(r'[a-f0-9]{64}')
SHA = re.compile(r'[a-f0-9]{40}')
MAX_AGE = 24 * 3600
MAX_PAGES = 4


def write_json(path, value):
    pending = path.with_name(path.name + '.tmp')
    pending.write_text(json.dumps(value, sort_keys=True) + '\n')
    pending.chmod(0o600)
    pending.replace(path)


def probe(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=True)
    if not result.stdout.strip():
        raise ValueError('toolchain probe returned no identity')
    return result.stdout.strip()


def fingerprint(arguments, environment):
    context = environment.get('CMUX_CI_SUITE_FAILURE_CONTEXT', '')
    ref = environment.get('CMUX_CI_SUITE_FAILURE_REF', '')
    if not DIGEST.fullmatch(context) or not SHA.fullmatch(ref):
        return None
    toolchain = [platform.system(), platform.machine(), platform.version(), probe(['swift', '--version'])]
    if platform.system() == 'Darwin':
        toolchain.extend((probe(['xcodebuild', '-version']), probe(['xcrun', '--show-sdk-build-version'])))
    helpers = {}
    for path in (Path(__file__), Path(arguments.lane_script), Path(arguments.lane_script).with_name('require_swift_test_execution.py')):
        helpers[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    inputs = dict(version=1, context=context, ref=ref, package=arguments.package,
                  filters=arguments.filter, configuration=arguments.configuration,
                  toolchain=toolchain, helpers=helpers,
                  environment={name: environment.get(name, '') for name in (
                      'DEVELOPER_DIR', 'SDKROOT', 'CMUX_CI_CPU_BUDGET',
                      'CMUX_SWIFT_TEST_SUITE_JOBS', 'SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH')})
    key = hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return dict(key=key, context=context, ref=ref,
                repo=environment.get('CMUX_CI_SUITE_FAILURE_REPO', ''),
                output=environment.get('CMUX_CI_SUITE_FAILURE_FILE', ''), blocked=False)


def timestamp(value):
    if not isinstance(value, str) or value.startswith('0001-'):
        return None
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    return parsed.timestamp() if parsed.tzinfo is not None else None


def valid_receipt(receipt, job):
    if not isinstance(receipt, dict) or not DIGEST.fullmatch(receipt.get('key', '')):
        return False
    code = receipt.get('exit_code')
    if type(code) is not int or code != job.get('exit_code'):
        return False
    phase = receipt.get('phase')
    if phase == 'passed':
        return code == 0 and job.get('state') == 'done' and not receipt.get('reused_from')
    if phase in ('compile', 'assertion'):
        return code == 1 and job.get('state') == 'failed'
    return phase == 'discovery' and code in (1, 2) and job.get('state') == 'failed'


def prior_failure(base, state, now):
    deadline = time.monotonic() + 8
    cursor = None
    cursors = set()
    candidates = []
    for page_number in range(MAX_PAGES):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        query = dict(limit=200, ref=state['ref'], kind='ci-step', state='failed,done',
                     fields='id,kind,script,ref,state,exit_code,updated_at,suite_request_context,suite_result')
        if cursor:
            query['cursor'] = cursor
        with urlopen(base.rstrip('/') + '/v1/jobs/history?' + urlencode(query), timeout=min(3, remaining)) as response:
            page = json.load(response)
        if not isinstance(page.get('jobs'), list) or not isinstance(page.get('has_more'), bool):
            return None
        for job in page['jobs']:
            if not isinstance(job, dict):
                return None
            if job.get('ref') != state['ref'] or job.get('script') != SCRIPT or job.get('kind') != 'ci-step':
                continue
            receipt = job.get('suite_result') or {}
            if not isinstance(receipt, dict):
                return None
            context = job.get('suite_request_context') or receipt.get('context')
            if context != state['context'] or receipt.get('reused_from'):
                continue
            valid = valid_receipt(receipt, job)
            if valid and receipt['key'] != state['key']:
                continue
            stamp = timestamp(receipt.get('reported_at')) if valid else timestamp(job.get('updated_at'))
            if stamp is None or stamp > now + 30:
                return None
            candidates.append((stamp, job, receipt if valid else None))
        if not page['has_more']:
            break
        cursor = page.get('next_cursor')
        if not cursor or cursor in cursors:
            return None
        cursors.add(cursor)
    else:
        return None
    if not candidates:
        return None
    newest_at = max(entry[0] for entry in candidates)
    newest = [entry for entry in candidates if entry[0] == newest_at]
    if len(newest) != 1:
        return None
    stamp, job, receipt = newest[0]
    if now - stamp > MAX_AGE or receipt is None or job.get('state') != 'failed':
        return None
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', job.get('id', '')):
        return None
    return dict(key=state['key'], phase=receipt['phase'], exit_code=receipt['exit_code'], reused_from=job['id'])


def check(arguments):
    output = os.environ.get('CMUX_CI_SUITE_FAILURE_FILE')
    if not output:
        return 0
    Path(output).unlink(missing_ok=True)
    state = fingerprint(arguments, os.environ)
    if state is None or not state['repo'] or not state['output']:
        return 0
    write_json(arguments.state, state)
    if os.environ.get('CMUX_SWIFT_RETRY_FAILED') == '1':
        print('Swift suite failure reuse: explicit retest; executing the requested suites.')
        return 0
    base = os.environ.get('CMUX_CI_CONTROLLER')
    if not base:
        return 0
    failure = prior_failure(base, state, time.time())
    if failure is None:
        return 0
    write_json(Path(state['output']), failure)
    print(f"Swift suite failure reuse: original job {failure['reused_from']} failed in {failure['phase']}; "
          'identical inputs and toolchain remain RED. Use --env CMUX_SWIFT_RETRY_FAILED=1 for an explicit retest.')
    return failure['exit_code']


def eligible_failure(phase, status, output):
    if phase == 'passed':
        return status == 0
    if phase == 'compile':
        return status == 1 and re.search(r'(?m)^.*\.swift:\d+:\d+: error:', output) is not None
    if phase == 'discovery':
        return status in (1, 2) and ('no Swift tests discovered' in output or 'no discovered test matches' in output)
    if phase == 'assertion' and status == 1:
        return (re.search(r'Test run with [1-9][0-9]* tests?(?: in [0-9]+ suites?)? failed after', output) is not None or
                (re.search(r"Test Suite ['\"](?:All tests|Selected tests)['\"] failed at", output) is not None and
                 re.search(r'Executed [1-9][0-9]* tests?, with [1-9][0-9]* failures?', output) is not None))
    return False


def record(arguments):
    if not arguments.state.exists() or not arguments.state.stat().st_size:
        return 0
    state = json.loads(arguments.state.read_text())
    output = ''
    if arguments.log:
        with arguments.log.open('rb') as log:
            log.seek(max(0, arguments.log.stat().st_size - (2 << 20)))
            output = log.read(2 << 20).decode(errors='replace')
    if not eligible_failure(arguments.phase, arguments.status, output):
        state['blocked'] = True
        write_json(arguments.state, state)
        Path(state['output']).unlink(missing_ok=True)
        return 0
    if not state['blocked']:
        write_json(Path(state['output']), dict(key=state['key'], phase=arguments.phase, exit_code=arguments.status))
    return 0


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    checking = commands.add_parser('check')
    checking.add_argument('--state', type=Path, required=True)
    checking.add_argument('--package', required=True)
    checking.add_argument('--lane-script', required=True)
    checking.add_argument('--filter', action='append', default=[])
    checking.add_argument('--configuration', action='append', default=[])
    recording = commands.add_parser('record')
    recording.add_argument('--state', type=Path, required=True)
    recording.add_argument('--phase', choices=('compile', 'discovery', 'assertion', 'passed'), required=True)
    recording.add_argument('--status', type=int, required=True)
    recording.add_argument('--log', type=Path)
    arguments = parser.parse_args()
    try:
        return check(arguments) if arguments.command == 'check' else record(arguments)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        print(f'Swift suite failure reuse unavailable ({type(error).__name__}); normal test execution remains required.', file=sys.stderr)
        return 0


if __name__ == '__main__':
    raise SystemExit(main())
