import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tab_switch_cold as cold
import tab_switch_judge as judge


class UnchangedRegionsTests(unittest.TestCase):
    def test_transient_flash_counts_even_when_final_frame_matches(self):
        base = bytes([64] * 64)
        flash = bytes([224] * 64)
        result = cold.unchanged([(0, base), (.01, base), (.02, flash), (.03, base)], .01, 8, [(0, 0, 8, 8)])
        self.assertEqual(result['changed_frames'], 1)
        self.assertEqual(result['changed_ms'], [10.0])
        self.assertEqual(result['max_changed_share'], 1)

    def test_expected_content_change_does_not_count_as_border_repaint(self):
        base = bytes([64] * 100)
        content = bytearray(base)
        for y in range(2, 8):
            for x in range(2, 8):
                content[y * 10 + x] = 224
        regions = cold.border_regions((0, 0, 10, 10))
        result = cold.unchanged([(0, base), (.02, bytes(content))], .01, 10, regions)
        self.assertEqual(result['changed_frames'], 0)
        self.assertEqual(sum((r[2]-r[0])*(r[3]-r[1]) for r in regions), 64)

    def test_blank_source_frame_fails_while_borders_remain_unchanged(self):
        base = bytearray([64] * 100)
        for y in range(2, 8):
            for x in range(2, 8):
                base[y*10+x] = 48 if x < 5 else 192
        blank = bytearray(base)
        for y in range(2, 8):
            for x in range(2, 8):
                blank[y*10+x] = 0
        item = {'source_content': (2, 2, 8, 8), 'unchanged_regions': cold.border_regions((0, 0, 10, 10))}
        end = bytearray(base)
        end[44] = 112
        evidence = cold.analyze([(0, bytes(base)), (.02, bytes(blank)), (.03, bytes(end))], .01, 10, item, .01, bytes(end))
        self.assertEqual(evidence['changed_frames'], 0)
        self.assertEqual(evidence['source_blank_frames'], 1)
        failures = judge.budget_fails({'cold_evidence': evidence, 'to_content_ms': 0, 'display_frame_ms': 16}, 'move')
        self.assertTrue(any('blank source-content' in failure for failure in failures))

    def test_missing_baseline_is_unmeasurable(self):
        with self.assertRaises(ValueError):
            cold.unchanged([(.02, bytes(64))], .01, 8, [(0, 0, 8, 8)])

    def test_unchanged_region_failure_reaches_gate(self):
        evidence = {'changed_frames': 1, 'source_blank_frames': 0}
        failures = judge.budget_fails({'cold_evidence': evidence, 'to_content_ms': 0, 'display_frame_ms': 16}, 'activate')
        self.assertTrue(any('unchanged source regions' in failure for failure in failures))


    def test_flash_on_small_edge_is_not_diluted_by_large_sidebar(self):
        base = bytes([64] * 10000)
        changed = bytearray(base)
        changed[0] = 224
        result = cold.unchanged([(0, base), (.02, bytes(changed))], .01, 100,
                                [(0, 0, 1, 1), (1, 0, 100, 100)], .01)
        self.assertEqual(result['changed_frames'], 1)
        self.assertEqual(result['per_region_max_changed_share'], [1, 0])

    def test_inset_bands_ignore_native_focus_ring_changes(self):
        base = bytes([64] * 400)
        changed = bytearray(base)
        changed[:20] = bytes([224] * 20)
        result = cold.unchanged([(0, base), (.02, bytes(changed))], .01, 20,
                                cold.border_regions((0, 0, 20, 20), inset=4))
        self.assertEqual(result['changed_frames'], 0)

    def test_outside_frame_region_is_unmeasurable(self):
        with self.assertRaisesRegex(ValueError, 'outside'):
            cold.unchanged([(0, bytes(64)), (.02, bytes(64))], .01, 8, [(0, 0, 9, 8)])

    def test_blank_baseline_endpoint_and_unchanged_endpoint_are_unmeasurable(self):
        textured = bytes([48, 192] * 32)
        blank = bytes([0] * 64)
        item = {'source_content': (0, 0, 8, 8), 'unchanged_regions': [(0, 0, 1, 1)]}
        for before, end, reason in ((blank, textured, 'baseline'),
                                    (textured, blank, 'endpoint is blank'),
                                    (textured, textured, 'never changed')):
            with self.subTest(reason=reason), self.assertRaisesRegex(ValueError, reason):
                cold.analyze([(0, before), (.02, end)], .01, 8, item, .01)

    def test_missing_posttrigger_frame_is_unmeasurable(self):
        with self.assertRaises(ValueError):
            cold.unchanged([(0, bytes(64))], .01, 8, [(0, 0, 8, 8)])

    def test_cold_cases_are_opt_in(self):
        import tab_switch_matrix as matrix
        self.assertTrue(set(cold.SCENARIOS).isdisjoint(matrix.MATRIX_SCENARIOS))
        self.assertTrue(set(cold.SCENARIOS).issubset(matrix.AVAILABLE_SCENARIOS))
        self.assertTrue(set(cold.SCENARIOS).isdisjoint(judge.ALL_SCENARIOS))

    def test_unmeasurable_cold_case_does_not_drop_next_case(self):
        import types
        import tab_switch_frames as frames
        h = object.__new__(frames.Harness)
        h.rec = types.SimpleNamespace(w=8, frame_ms=16, scale=1)
        h.args = types.SimpleNamespace(tolerance=.01)
        h.foreign_over = lambda _: []
        h.add_settle = lambda *args: None
        h.keep_sheet = lambda *args, **kwargs: None
        h.judge = lambda *args, **kwargs: {'to_content_ms': 1}
        samples = [(0, bytes(64)), (.02, bytes(64))]
        pending = [{'label': 'cold', 'kind': 'settled', 'cold_evidence': True,
                    'source_content': (0, 0, 8, 8), 'unchanged_regions': [(0, 0, 1, 1)],
                    'cold_setup': 'test', 'cold_tab': 'test'},
                   {'label': 'next', 'kind': 'settled'}]
        flips = {f'{label}:{key}': value for label in ('cold', 'next')
                 for key, value in (('leave', 0), ('mark', .01), ('end', .03))}
        results = h.settle_block(pending, samples, flips)
        self.assertIn('unmeasurable', results[0][1]['error'])
        self.assertEqual(results[1][1]['to_content_ms'], 1)


class ColdEvidenceBindingTests(unittest.TestCase):
    def fixtures(self):
        base = bytearray([40] * 10000)
        for y in range(20, 60):
            base[y*100+10:y*100+90] = bytes([100] * 80)
        end = bytearray(base)
        for y in range(40, 80):
            end[y*100+30:y*100+70] = bytes([146] * 40)
        item = {'source_content': (10, 20, 90, 100),
                'unchanged_regions': cold.border_regions((10, 20, 90, 100), inset=4) + [(10, 0, 90, 20)]}
        return bytes(base), bytes(end), item

    def test_wrong_partial_blank_endpoint_cannot_be_its_own_reference(self):
        base, expected, item = self.fixtures()
        wrong = bytearray(expected)
        for y in range(40, 80):
            wrong[y*100+30:y*100+70] = bytes(40)
        with self.assertRaisesRegex(ValueError, 'independently verified'):
            cold.analyze([(0, base), (.016, bytes(wrong)), (.032, bytes(wrong))], 0, 100, item, .002, expected)

    def test_missing_reference_is_inconclusive(self):
        base, expected, item = self.fixtures()
        with self.assertRaisesRegex(ValueError, 'reference required'):
            cold.analyze([(0, base), (.016, expected)], 0, 100, item, .002)

    def test_tab_strip_flash_reaches_failure_gate(self):
        base, expected, item = self.fixtures()
        flash = bytearray(expected)
        for y in range(20):
            flash[y*100+10:y*100+90] = bytes(80)
        samples = [(0, base), (.016, bytes(flash)), (.032, expected)]
        switch = judge.judge_switch(samples, 0, 100, item['source_content'], 1000/60, reference=expected)
        switch['cold_evidence'] = cold.analyze(samples, 0, 100, item, .002, expected)
        self.assertTrue(any('changed frames' in f for f in judge.budget_fails(switch, 'strip-flash')))

    def test_correct_reference_and_static_chrome_pass(self):
        base, expected, item = self.fixtures()
        samples = [(0, base), (.016, expected), (.032, expected)]
        switch = judge.judge_switch(samples, 0, 100, item['source_content'], 1000/60, reference=expected)
        switch['cold_evidence'] = cold.analyze(samples, 0, 100, item, .002, expected)
        self.assertEqual(judge.budget_fails(switch, 'good'), [])

    def test_reference_requires_independent_stable_interval(self):
        base, expected, item = self.fixtures()
        item.update(reference_start='ref-start', reference_end='ref-end')
        flips = {'ref-start': 1, 'ref-end': 1.4}
        self.assertEqual(cold.recorded_reference([(1.1, expected), (1.3, expected)], flips, item, 100, .002), expected)
        with self.assertRaisesRegex(ValueError, 'did not settle'):
            cold.recorded_reference([(1.1, base), (1.3, expected)], flips, item, 100, .002)
        with self.assertRaisesRegex(ValueError, 'missing'):
            cold.recorded_reference([(1.1, expected), (1.3, expected)], {}, item, 100, .002)
        with self.assertRaisesRegex(ValueError, 'color was not painted'):
            cold.recorded_reference([(1.1, base), (1.3, base)], flips, item, 100, .002)

    def geometry_data(self):
        rect = lambda x, y, w, h: dict(x=x, y=y, width=w, height=h)
        windows = {'windows': [dict(id=1, kind='main', visible=True, frame=rect(0, 100, 100, 100)),
                               dict(id=2, kind='main', visible=True, frame=rect(100, 100, 100, 100))]}
        surfaces = {'windows': [{'window': '1', 'panes': [{'pane': 'other'}]},
                                {'window': '2', 'panes': [{'pane': 'source'}]}]}
        def pane(key):
            return dict(pane=key, cell=[5, 0, 95, 100], border=[10, 20, 80, 70],
                        strip=[5, 0, 95, 20], strip_empty=[70, 0, 30, 20])
        chrome = {'windows': [dict(id='record-other', panes=[pane('other')], sidebar=[0, 0, 5, 100]),
                              dict(id='record-source', panes=[pane('source')], sidebar=[0, 0, 5, 100])]}
        return windows, surfaces, chrome

    def test_recorded_second_window_and_source_pane_not_first_match(self):
        args = self.geometry_data()
        result = cold.geometry(*args, 'source', [100, 0, 100, 100], [0, 0, 200, 200], 1)
        self.assertEqual((result['native_window'], result['window'], result['pane']), ('2', 'record-source', 'source'))

    def test_wrong_recorded_window_rejects_source_pane(self):
        with self.assertRaisesRegex(ValueError, 'not in the recorded'):
            cold.geometry(*self.geometry_data(), 'source', [0, 0, 100, 100], [0, 0, 200, 200], 1)

    def test_missing_or_ambiguous_native_window_rejected(self):
        windows, surfaces, chrome = self.geometry_data()
        for bounds in ([500, 0, 100, 100], [100, 0, 100, 100]):
            if bounds[0] == 100:
                windows['windows'].append(dict(windows['windows'][1], id=3))
            with self.assertRaisesRegex(ValueError, 'unique native-window'):
                cold.geometry(windows, surfaces, chrome, 'source', bounds, [0, 0, 200, 200], 1)

    def test_geometry_uses_pane_key_and_rejects_old_id_shape(self):
        windows, surfaces, chrome = self.geometry_data()
        chrome['windows'][1]['panes'][0]['id'] = chrome['windows'][1]['panes'][0].pop('pane')
        with self.assertRaisesRegex(ValueError, 'chrome is missing'):
            cold.geometry(windows, surfaces, chrome, 'source', [100, 0, 100, 100], [0, 0, 200, 200], 1)

    def test_static_strip_is_intersection_of_pre_and_post_empty_space(self):
        before = cold.geometry(*self.geometry_data(), 'source', [100, 0, 100, 100], [0, 0, 200, 200], 1)
        after = dict(before, empty_strip=(50, 0, 100, 20))
        regions, names = cold.stable_regions(before, after, 1)
        self.assertEqual(regions[names.index('static-tab-strip')], (70, 0, 100, 20))
        with self.assertRaisesRegex(ValueError, 'geometry changed'):
            cold.stable_regions(before, dict(after, pane='wrong'), 1)
        with self.assertRaisesRegex(ValueError, 'no measurable'):
            cold.stable_regions(before, dict(after, empty_strip=(0, 0, 20, 20)), 1)

    def test_unloaded_requires_positive_diagnostic_control(self):
        receipt = cold.unloaded({'hibernation': {'page_phases': {'shown': 'visible'}}}, 'shown', 'cold')
        self.assertFalse(receipt['cold_cached'])
        for report in ({}, {'hibernation': {'page_phases': {}}},
                       {'hibernation': {'page_phases': {'shown': 'visible', 'cold': 'mountedHidden'}}}):
            with self.assertRaises(ValueError):
                cold.unloaded(report, 'shown', 'cold')


if __name__ == '__main__':
    unittest.main()
