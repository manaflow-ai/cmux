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
        evidence = cold.analyze([(0, bytes(base)), (.02, bytes(blank)), (.03, bytes(end))], .01, 10, item, .01)
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


if __name__ == '__main__':
    unittest.main()
