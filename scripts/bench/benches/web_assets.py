"""Exact byte copies in a published web artifact; not a startup benchmark.

Run with --host anywhere --arg root=EXTRACTED_BUNDLES, or import the JSON
produced by scripts/measure/web-asset-duplicates.sh on the managed fleet.
"""
import json
from pathlib import Path
import subprocess
import sys
from benchlib.bench import REPO_ROOT, Bench, BenchError


class WebAssets(Bench):
    name = 'web-assets'
    summary = 'Stored asset and decoded font duplication, with a normalized archive experiment'
    units = 'bytes, count'
    owner = 'web performance'
    hosts = ('anywhere',)
    harness = 'scripts/measure/web-asset-duplicates.sh'
    version = '1'

    def run(self, ctx):
        root = ctx.arg('root')
        if not root:
            raise BenchError('web-assets: pass --arg root=EXTRACTED_BUNDLES or --import RESULT.json')
        output = ctx.workdir / 'web-assets.json'
        subprocess.run([sys.executable, str(REPO_ROOT / 'scripts/measure/web-asset-duplicates.py'),
                        str(Path(root).resolve()), '--output', str(output)], check=True, timeout=90)
        self.ingest(ctx, output)

    def ingest(self, ctx, path):
        data = json.loads(path.read_text())
        if data.get('schema') != 1:
            raise BenchError('web-assets: expected schema 1')
        manifest = data.get('manifest') or {}
        ctx.notes.append('Artifact identity: ' + json.dumps(manifest, sort_keys=True))
        if manifest.get('commit'):
            ctx.build = {'channel': 'sha', 'sha': manifest['commit']}
        labels = {}
        for key in ('storedBytes', 'redundantBytes', 'externalFontBytes',
                    'externalFontRedundantBytes', 'inlineFontBytes',
                    'inlineFontRedundantBytes', 'allFontRedundantBytes'):
            ctx.row(key, data[key], 'bytes', labels=labels)
        for key in ('files', 'uniquePayloads', 'externalFontFiles', 'inlineFontOccurrences', 'uniqueInlineFonts'):
            ctx.row(key, data[key], 'count', labels=labels, better='none')
        ctx.row('archiveExperimentDelta', data['archiveExperiment']['deltaBytes'], 'bytes', labels=labels, better='none')
        ctx.notes.append('Decoded font bytes are not transfer/startup bytes. Archive experiment omits paths and is not installable.')


BENCH = WebAssets()
