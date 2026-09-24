#!/usr/bin/env python3
"""Fail before dependency setup when the required E2E recording cannot capture."""

import argparse
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout-seconds', type=float, default=10)
    args = parser.parse_args()
    if not math.isfinite(args.timeout_seconds) or args.timeout_seconds <= 0:
        parser.error('--timeout-seconds must be finite and positive')
    deadline = time.monotonic() + args.timeout_seconds

    def run(command):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, args.timeout_seconds)
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            # The capture command has sudo/launchctl children. Stop its process
            # group so a hung child cannot keep the probe's output pipes open.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=1)
            process.stdout.close()
            process.stderr.close()
            raise
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

    try:
        user = run(['stat', '-f', '%Su', '/dev/console']).stdout.strip()
        if not user or user in ('root', 'loginwindow'):
            raise RuntimeError('No logged-in GUI user is available for screen recording')
        uid = run(['id', '-u', user]).stdout.strip()
        if not uid.isdecimal():
            raise RuntimeError('Cannot identify the logged-in GUI user')
        with tempfile.TemporaryDirectory(prefix='cmux-capture-preflight-',
                                         dir=os.environ.get('RUNNER_TEMP')) as temporary:
            # Match the recorder's output-directory access; do not broaden
            # runner permissions to turn an unavailable capture into a pass.
            os.chmod(temporary, 0o755)
            image = Path(temporary) / 'probe.jpg'
            run(['sudo', '-n', 'launchctl', 'asuser', uid, 'sudo', '-n', '-H', '-u', user,
                 '/usr/sbin/screencapture', '-x', '-t', 'jpg', '-D', '1', str(image)])
            if not image.is_file() or image.stat().st_size == 0:
                raise RuntimeError('Screen capture produced no image')
        print('Screen capture preflight passed; required test recording still runs separately.')
        return 0
    except subprocess.TimeoutExpired:
        detail = f'Screen capture preflight exceeded {args.timeout_seconds:g} seconds'
    except subprocess.CalledProcessError as error:
        detail = f'{error.cmd[0]} exited {error.returncode}: {(error.stderr or "").strip()[:2000]}'
    except (OSError, RuntimeError) as error:
        detail = str(error)
    print('::error::Screen capture unavailable before E2E dependency setup. ' + detail,
          file=sys.stderr)
    print('Check the runner GUI display and screen-recording permission; no tests ran.',
          file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
