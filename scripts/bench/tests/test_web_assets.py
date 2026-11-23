"""Falsifying fixtures for stored vs decoded duplication and registered bench import."""
import base64
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zlib

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))
from benches.web_assets import BENCH
from benchlib.bench import Context

spec = importlib.util.spec_from_file_location('web_duplicates', BENCH_DIR.parent / 'measure/web-asset-duplicates.py')
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


class WebAssetsTest(unittest.TestCase):
    def test_copies_fonts_and_import(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'a').mkdir()
            (root / 'a/same.css').write_bytes(b'abc')
            (root / 'same.css').write_bytes(b'different')
            (root / 'copy.css').write_bytes(b'abc')
            font = b'wOF2fixture'
            css = b'data:font/woff2;base64,' + base64.b64encode(font)
            (root / 'font.js').write_bytes(css)
            packer = zlib.compressobj(wbits=-15)
            (root / 'font.deflate').write_bytes(packer.compress(css) + packer.flush())
            (root / 'font.woff2').write_bytes(font)
            (root / '.manifest.json').write_text(json.dumps({'key': 'a'*64, 'commit': 'b'*40}))
            result = measure.measure(root)
            self.assertEqual(result['files'], 6)
            self.assertEqual(result['redundantBytes'], 3)
            self.assertEqual(result['inlineFontOccurrences'], 2)
            self.assertEqual(result['inlineFontRedundantBytes'], len(font))
            self.assertEqual(result['allFontRedundantBytes'], 2*len(font))
            self.assertEqual(result, measure.measure(root))
            with tempfile.TemporaryDirectory() as output:
                path = Path(output) / 'result.json'
                path.write_text(json.dumps(result))
                ctx = Context(bench=BENCH, build={'channel': 'sha', 'sha': 'b'*40}, host_role='anywhere', workdir=Path(output))
                BENCH.ingest(ctx, path)
                rows = {row['metric']: row for row in ctx.rows}
                self.assertEqual(rows['redundantBytes']['value'], 3)
                self.assertEqual(rows['inlineFontRedundantBytes']['value'], len(font))
                self.assertEqual(rows['files']['labels'], {})
                self.assertEqual(rows['files']['build']['sha'], 'b'*40)
                self.assertIn('not installable', ctx.notes[-1])
                result['manifest'] = {'key': 'c'*64, 'commit': 'd'*40}
                path.write_text(json.dumps(result))
                other = Context(bench=BENCH, build={'channel': 'local'}, host_role='anywhere', workdir=Path(output))
                BENCH.ingest(other, path)
                self.assertEqual([(r['bench'], r['metric'], r['labels']) for r in ctx.rows],
                                 [(r['bench'], r['metric'], r['labels']) for r in other.rows])
                self.assertEqual(other.rows[0]['build']['sha'], 'd'*40)

    def test_empty_and_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(ValueError, 'no asset files'):
                measure.measure(root)
            (root / 'link').symlink_to(root)
            with self.assertRaisesRegex(ValueError, 'symlink'):
                measure.measure(root)

    def test_registry(self):
        from benchlib.registry import load_all
        self.assertEqual(load_all()['web-assets'].name, BENCH.name)


if __name__ == '__main__':
    unittest.main()
