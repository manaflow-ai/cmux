#!/usr/bin/env python3
"""Exercise grid validation and generated artifact drift without an app build."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('layout_grid', ROOT / 'scripts/cmux-next/gen-layout-grid.py')
grid = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(grid)


class LayoutGridTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / grid.SOURCE).read_text())

    def metric(self, name):
        return next(item for item in self.data['metrics'] if item['name'] == name)

    def test_committed_copies_and_idempotence(self):
        grid.validate(self.data)
        css = (ROOT / grid.CSS_FILE).read_text()
        self.assertEqual(css, grid.css(css, self.data))
        self.assertEqual([], grid.swift_drift(self.data, (ROOT / grid.SWIFT_FILE).read_text()))

    def test_off_grid_edge_rejected(self):
        self.metric('cards-padding')['pt'] = 13
        with self.assertRaisesRegex(ValueError, '4 pt grid'):
            grid.validate(self.data)

    def test_derived_center_must_match_its_edges(self):
        self.metric('composer-lead-center')['pt'] = 24
        with self.assertRaisesRegex(ValueError, 'formula result'):
            grid.validate(self.data)

    def test_half_steps_are_named(self):
        self.metric('gap').update(pt=2, kind='halfStep')
        with self.assertRaisesRegex(ValueError, 'only named half-steps'):
            grid.validate(self.data)

    def test_optical_offsets_are_bounded_and_emitted(self):
        self.data['opticalOffsets'] = {'play': {'x': 0.5, 'y': -1}}
        grid.validate(self.data)
        self.assertIn('--grid-optical-play-y: calc(-1px * var(--cmux-interface-scale, 1))', grid.css_block(self.data))
        self.data['opticalOffsets']['play']['x'] = 1.1
        with self.assertRaisesRegex(ValueError, 'at most 1 pt'):
            grid.validate(self.data)

    def test_swift_drift_is_reported_not_written(self):
        swift = (ROOT / grid.SWIFT_FILE).read_text()
        changed = swift.replace('composerText: CGFloat = 44', 'composerText: CGFloat = 48')
        self.assertEqual(['composerText is 48.0, expected 44'], grid.swift_drift(self.data, changed))
        self.assertEqual(swift, (ROOT / grid.SWIFT_FILE).read_text())

    def test_cycles_and_duplicate_names_are_rejected(self):
        self.metric('base')['formula'] = {'base': 1}
        with self.assertRaisesRegex(ValueError, 'cyclic'):
            grid.validate(self.data)
        self.data['metrics'].append(copy.deepcopy(self.metric('base')))
        with self.assertRaisesRegex(ValueError, 'named once'):
            grid.validate(self.data)


class SettledSpacingTests(unittest.TestCase):
    """Leo's settled spacings stay where he settled them (ask-08a8b942a0)."""

    def setUp(self):
        self.data = json.loads((ROOT / grid.SOURCE).read_text())
        self.settled = json.loads((ROOT / grid.SETTLED).read_text())
        self.files = {}

    def read(self, path):
        return self.files[path] if path in self.files else grid.read_file(path)

    def drift(self):
        return grid.settled_drift(self.data, self.settled, self.read)

    def pin(self, name):
        return next(pin for pin in self.settled['pins'] if pin['id'] == name)

    def test_committed_pins_hold(self):
        self.assertEqual([], self.drift())

    def test_moved_grid_metric_names_leos_words(self):
        next(m for m in self.data['metrics'] if m['name'] == 'gap-turn')['pt'] = 24
        [finding] = self.drift()
        self.assertIn('gap-turn is 24; Leo settled turn-gap = 32', finding)
        self.assertIn('center it', finding)

    def test_moved_file_value_is_reported(self):
        path = self.pin('rest-gap')['source']['file']
        self.files[path] = grid.read_file(path).replace('REST_GAP = 56;', 'REST_GAP = 16;')
        [finding] = self.drift()
        self.assertIn('rest-gap is 16; Leo settled rest-gap = 56', finding)

    def test_source_keeps_its_comment(self):
        path = self.pin('rest-gap')['source']['file']
        self.files[path] = grid.read_file(path).replace('settled-spacing: rest-gap', 'rest gap')
        self.assertIn('lost its "settled-spacing: rest-gap" comment', self.drift()[0])
        metric = next(m for m in self.data['metrics'] if m['name'] == 'gap-turn')
        metric['description'] = 'Gap between transcript turns'
        self.assertTrue(any('lost "(settled-spacing: turn-gap)"' in f for f in self.drift()))

    def test_a_pin_needs_words_and_one_match(self):
        del self.pin('turn-gap')['words']
        self.assertIn("pin 'turn-gap' lacks words", self.drift()[0])
        self.pin('rest-gap')['source']['pattern'] = r'const (\d+)'
        self.assertTrue(any('matches 0 times' in f for f in self.drift()))


if __name__ == '__main__':
    unittest.main()
