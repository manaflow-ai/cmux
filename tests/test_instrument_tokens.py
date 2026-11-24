#!/usr/bin/env python3
"""Instrument's token file: the committed copies agree, a moved default is caught, and the gap only shrinks.

Covers scripts/cmux-next/gen-instrument-tokens.py and schemas/instrument/ (instrument.json,
pending-baseline.json, CHANGELOG.md), and the sources it reads today's values from:
schemas/design-scale/design-scale.json, schemas/type-scale/type-scale.json,
schemas/layout-grid/layout-grid.json, schemas/surface-roles/surface-roles.json,
schemas/settings/source/appearance.json, schemas/settings/source/agent-pane-display.json, and the CSS files offToken entries name.
"""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('instrument_tokens', ROOT / 'scripts/cmux-next/gen-instrument-tokens.py')
tokens = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tokens)


class InstrumentTokenTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / tokens.SOURCE).read_text())
        self.baseline = json.loads((ROOT / tokens.BASELINE).read_text())

    def token(self, name, data=None):
        return next(t for t in (data or self.data)['tokens'] if t['name'] == name)

    def test_committed_copies_agree(self):
        tokens.validate(self.data)
        self.assertEqual([], tokens.drift(self.data))
        self.assertEqual([], tokens.ratchet(self.data, self.baseline))
        self.assertEqual([], tokens.changelog_problems(self.data, (ROOT / tokens.CHANGELOG).read_text()))

    def test_sheet_carries_todays_values_not_instruments(self):
        sheet = tokens.css(self.data)
        self.assertIn('--instrument-corner-card: 14px; /* Instrument 12px; waits leo-2 */', sheet)
        self.assertIn('--instrument-prose-measure: 800px;', sheet)
        for t in self.data['tokens']:
            if 'today' in t and tokens._css_value(t) is not None:
                self.assertIn(f'--instrument-{t["name"].replace(".", "-")}: {tokens._css_value(t)};', sheet)

    def test_moved_default_is_drift(self):
        # A PR that moves the card corner in design-scale.json without saying so here.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for t in self.data['tokens']:
                if 'today' in t:
                    dest = root / t['today']['file']
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    if not dest.exists():
                        dest.write_text((ROOT / t['today']['file']).read_text())
            scale_path = root / 'schemas/design-scale/design-scale.json'
            scale = json.loads(scale_path.read_text())
            next(r for r in scale['namedRadii'] if r['name'] == 'card')['px'] = 12
            scale_path.write_text(json.dumps(scale))
            found = tokens.drift(self.data, root)
        self.assertEqual(1, len(found))
        self.assertIn('corner.card', found[0])
        self.assertIn('A default moved', found[0])

    def test_applying_a_value_shrinks_and_must_be_locked(self):
        data = copy.deepcopy(self.data)
        card = self.token('corner.card', data)
        card['today']['value'] = 12
        del card['waits']
        tokens.validate(data)
        problems = tokens.ratchet(data, self.baseline)
        self.assertEqual(['corner.card: now draws Instrument\'s value; lock it in with --update-baseline'], problems)
        shrunk = json.loads(tokens.baseline_text(tokens.pending_names(data)))
        self.assertEqual([], tokens.ratchet(data, shrunk))

    def test_falling_out_of_instrument_fails_the_ratchet(self):
        data = copy.deepcopy(self.data)
        outline = self.token('ink.outline', data)
        outline['today']['value'] = 14
        outline['waits'] = 'skeleton'
        tokens.validate(data)
        self.assertEqual(['ink.outline: newly behind Instrument (not in schemas/instrument/pending-baseline.json); '
                          'the gap may only shrink'], tokens.ratchet(data, self.baseline))

    def test_a_gap_must_say_what_it_waits_on(self):
        del self.token('corner.card')['waits']
        with self.assertRaisesRegex(tokens.TokenError, 'record what it waits on'):
            tokens.validate(self.data)

    def test_applied_token_cannot_claim_to_wait(self):
        self.token('seed.grid')['waits'] = 'skeleton'
        with self.assertRaisesRegex(tokens.TokenError, 'drop waits'):
            tokens.validate(self.data)

    def test_waits_names_a_question(self):
        self.token('corner.card')['waits'] = 'someday'
        with self.assertRaisesRegex(tokens.TokenError, 'not one of the questions'):
            tokens.validate(self.data)

    def test_version_needs_a_changelog_entry(self):
        data = dict(self.data, version='0.2.0')
        self.assertEqual(['schemas/instrument/CHANGELOG.md has no "## 0.2.0" entry'],
                         tokens.changelog_problems(data, (ROOT / tokens.CHANGELOG).read_text()))

    def test_off_token_entries_are_where_they_say(self):
        # Other PRs move these lines, so a stale entry is a warning in --check, never a test red;
        # this checks the mechanism on a file of its own.
        self.assertTrue(self.token('corner.card')['offToken'], 'the transcript cards draw raw corners; the list names them')
        with tempfile.TemporaryDirectory() as tmp:
            sheet = Path(tmp) / 'a.css'
            sheet.write_text('.x {\n  border-radius: 8px;\n}\n')
            data = {'tokens': [{'name': 'corner.card', 'offToken': [
                {'file': 'a.css', 'line': 2, 'value': '8px', 'on': 'x'}]}]}
            self.assertEqual([], tokens.stale_off_token(data, Path(tmp)))
            data['tokens'][0]['offToken'][0]['line'] = 3
            self.assertIn('refresh the entry', tokens.stale_off_token(data, Path(tmp))[0])

    def test_off_token_entry_shape(self):
        self.token('corner.card')['offToken'].append({'file': 'x.css', 'value': '8px'})
        with self.assertRaisesRegex(tokens.TokenError, 'offToken entry'):
            tokens.validate(self.data)

    def test_resolver_paths(self):
        doc = {'a': [{'name': 'x', 'v': 1}, {'name': 'y', 'v': 2}],
               'deep': {'list': [{'key': 'k.with.dots', 'range': {'placeholder': 8}}]}}
        self.assertEqual(2, tokens.resolve(doc, 'a[name=y].v'))
        self.assertEqual([1, 2], tokens.resolve(doc, 'a[*].v'))
        self.assertEqual(8, tokens.resolve(doc, '**[key=k.with.dots].range.placeholder'))
        with self.assertRaises(tokens.TokenError):
            tokens.resolve(doc, 'a[name=z].v')

    def test_px_and_ranges_compare(self):
        self.assertTrue(tokens.same('var(--cmux-button-radius, 8px)', 8))
        self.assertTrue(tokens.same(640, {'min': 560, 'max': 720}))
        self.assertFalse(tokens.same(800, {'min': 560, 'max': 720}))

    def test_rfd_table_names_are_all_here(self):
        rows = '\n'.join(f'| `{t["name"]}` | v | d |' for t in self.data['tokens'] if 'part' not in t)
        rfd = f'<!-- instrument-tokens:begin v0.1 -->\n| Token | Value | Drawn on |\n{rows}\n| `new.token` | 1 | x |\n<!-- instrument-tokens:end -->'
        self.assertEqual(['new.token: in the RFD token table, not in schemas/instrument/instrument.json'],
                         tokens.rfd_problems(self.data, rfd))


if __name__ == '__main__':
    unittest.main()
