#!/usr/bin/env python3
"""Benchmark isolated real event-log writers before/after, including behavior checks.

The baseline must include the injectable write operation (the red regression
commit). Only the standalone writer/spy/harness are compiled, never the app.
"""
import argparse
import json
import pathlib
import platform
import statistics
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True)
    parser.add_argument('--samples', type=int, default=7)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.samples <= 100:
        parser.error('--samples must be between 1 and 100')
    root = pathlib.Path(__file__).resolve().parents[1]
    baseline = subprocess.check_output(['git', 'rev-parse', '--verify', f'{args.baseline}^{{commit}}'], cwd=root, text=True).strip()
    writer = 'Sources/CmuxEventLogWriter.swift'
    report = {
        'baseline': baseline,
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        'platform': platform.platform(),
        'swift': subprocess.check_output(['swiftc', '--version'], text=True).strip(),
        'scope': 'Warm runtime; fresh synthetic files; kernel-buffered FileHandle writes; no fsync.',
        'variants': {},
    }
    with tempfile.TemporaryDirectory(prefix='cmux-event-log-benchmark-') as directory:
        temp = pathlib.Path(directory)
        for variant in ('before', 'after'):
            source = temp / f'{variant}.swift'
            source.write_bytes(subprocess.check_output(['git', 'show', f'{baseline}:{writer}'], cwd=root)
                               if variant == 'before' else (root / writer).read_bytes())
            executable = temp / variant
            subprocess.run([
                'swiftc', '-swift-version', '6', '-DDEBUG', '-O', '-warnings-as-errors', str(source),
                str(root / 'cmuxTests/CmuxEventLogWriteSpy.swift'),
                str(root / 'scripts/benchmarks/EventLogWriteBenchmark.swift'), '-o', str(executable)
            ], check=True, cwd=root)
            output = subprocess.check_output([str(executable), str(args.samples)], text=True)
            rows = [json.loads(line) for line in output.splitlines()]
            report['variants'][variant] = rows
            for row in rows:
                observations = row['samples']
                latency = statistics.median(item['flush_ms'] for item in observations)
                print(f"{variant}: lines={row['submitted_lines']} crossing={row['crossing_16_mib']} "
                      f"writes={observations[0]['write_calls']} median_ms={latency:.3f} "
                      f"drops={observations[0]['dropped_lines']} behavior={row['behavior_checks']}", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
