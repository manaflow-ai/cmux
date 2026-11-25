"""Import pinned published-idle-power.sh observations into the common ledger.

Collection needs an already running PID on one exact host. Submit through cmux-ci
with --target-worker and --pin-strict, then use --import on its log or report.json.
This entry never launches an application or silently moves the observation.
"""
import json
from pathlib import Path

from benchlib.bench import Bench, BenchError


class PublishedIdle(Bench):
    name = 'published-idle'
    summary = 'CPU energy, wakeups and footprint of an already running published app and its descendants'
    units = 'mW, %, per_s, MB'
    owner = 'perf'
    hosts = ('fleet',)
    harness = 'scripts/measure/published-idle-power.sh'
    version = '1'
    nightly = False

    def run(self, ctx):
        raise BenchError('published-idle observes a prepared PID: collect with cmux-ci run --class exclusive '
                         '--measurement --script scripts/measure/published-idle-power.sh --ref FULL_SHA '
                         '--target-worker WORKER --pin-strict --arg bundle=APP --arg pid=PID '
                         '--arg label=NAME --timeout 240; then use --import LOG_OR_REPORT_JSON')

    def ingest(self, ctx, path: Path):
        text = Path(path).read_text()
        lines = [line.split('IDLE-RESULT ', 1)[1] for line in text.splitlines() if 'IDLE-RESULT ' in line]
        record = json.loads(lines[-1] if lines else text)
        if record.get('valid') is not True:
            raise BenchError('published-idle: refusing invalid or unvalidated process membership')
        if record.get('process_scope') != 'bundle-owned processes and all observed descendants':
            raise BenchError('published-idle: result has a different process scope')
        ctx.host.update(name=record['host'], role='fleet', os=record['os'], chip=record['chip'])
        ctx.build.update(channel='release', version=record['version'], sha=None)
        ctx.timestamp = record['start']
        labels = {'app': record['label'], 'bundle_id': record['bundle_id']}
        for metric, key, unit in (('cpu_energy', 'mw', 'mW'), ('cpu', 'cpu_pct', '%'),
                                  ('wakeups', 'wakeups_per_s', 'per_s'), ('footprint', 'footprint_mb', 'MB')):
            ctx.row(metric, record['total'][key], unit, labels=labels)
        ctx.notes.append('CPU energy excludes GPU/display; transient processes between endpoint snapshots may be missed. '
                         'Validate zero counters with a known-active control before comparing.')


BENCH = PublishedIdle()
