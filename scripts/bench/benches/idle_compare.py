"""Idle energy of cmux NEXT, Claude Code desktop and Terminal.app on one fleet Mac, same conditions.

Wraps scripts/measure/idle-energy-compare.sh: fresh signed-out profiles, a calibration window, then at least
3 interleaved rounds of equal idle windows per app with baseline counters read at each window's start.
"""
import json
from pathlib import Path

from benchlib.bench import Bench, BenchError


class IdleCompare(Bench):
    name = 'idle-compare'
    summary = 'Idle CPU energy, CPU % and wakeups of cmux NEXT vs Claude Code desktop vs Terminal.app, interleaved'
    units = 'mW, %, per_s'
    owner = 'perf'
    hosts = ('fleet',)
    harness = 'scripts/measure/idle-energy-compare.sh'
    version = '1'
    nightly = False

    def run(self, ctx):
        args = [f'{key}={ctx.arg(key)}' for key in ('rounds', 'seconds', 'settle', 'calibrate', 'apps', 'next_dmg', 'claude_dmg')
                if ctx.arg(key)]
        res = ctx.fleet_step(self.harness, args=args, artifact='artifacts/idle-energy-compare.tgz', display=True, timeout=3600)
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx, path: Path):
        lines = [line.split('IDLE-COMPARE-RESULT ', 1)[1] for line in Path(path).read_text().splitlines()
                 if 'IDLE-COMPARE-RESULT ' in line]
        if not lines:
            raise BenchError('idle-compare: no IDLE-COMPARE-RESULT line')
        record = json.loads(lines[-1])
        ctx.host.update(name=record['host'], role='fleet', os=record['os'], chip=record['chip'])
        ctx.timestamp = record['start']
        for row in record['ranking']:
            if not row.get('n_valid'):
                ctx.notes.append(f"{row['app']}: no valid window")
                continue
            labels = {'app': row['app'], 'version': record['apps'].get(row['app'], {}).get('version') or ''}
            for metric, key, unit in (('cpu_energy', 'mw', 'mW'), ('cpu', 'cpu_pct', '%'), ('wakeups', 'wakeups_per_s', 'per_s')):
                ctx.row(metric, row[key], unit, n=row['n_valid'], labels=labels)
        ctx.notes.append('Per-process CPU energy (no GPU/display); windows with a missing baseline counter are dropped, not zero-filled.')


BENCH = IdleCompare()
