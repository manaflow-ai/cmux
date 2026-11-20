#!/usr/bin/env python3
"""Tests for scripts/ci/actions_cache_report.py (no network).

The log excerpts are cut from real cmux job logs (2026-10-29): an owned-mini
`cmux-tui.yml / macOS lint and tests` job whose setup-go restore failed over
a read-only module cache, a Linux rust-cache hit, a fast-gates miss and save, and
an R2 restore receipt.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/actions_cache_report.py"
SPEC = importlib.util.spec_from_file_location("actions_cache_report", SCRIPT)
cache = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["actions_cache_report"] = cache
SPEC.loader.exec_module(cache)

T = "2026-10-29T19:38:12.6004360Z "

MAC_JOB = "\n".join(T + line for line in (
    "##[group]Run actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae",
    "with:",
    "  path: /tmp/cmux-zig-tarballs",
    "  key: cmux-zig-tarball-macOS-ARM64-8ea6cb6236edac01d7b7444bea624e4db0e16d531d111ebc132110499a10cef7",
    "##[endgroup]",
    "Cache not found for input keys: cmux-zig-tarball-macOS-ARM64-8ea6cb6236edac01d7b7444bea624e4db0e16d531d111ebc132110499a10cef7",
    "##[group]Run actions/setup-go@4a3601121dd01d1626a1e23e37211e3254c1c06c",
    "with:",
    "  go-version-file: cmux-tui/crates/cmux-tailnet/go-version",
    "  cache: true",
    "##[endgroup]",
    "Cache hit for: setup-go-macOS-arm64-go-1.27.1-66176040da63a34f4bd5aecf2b4a7d5b5a9e39cedfd3e09ad0aae1d7ba0f290e",
    "Received 620097537 of 620097537 (100.0%), 5.4 MBs/sec",
    "Cache Size: ~591 MB (620097537 B)",
    "../../go/pkg/mod/github.com/creack/pty@v1.1.24/go.mod: Can't unlink already-existing object: Permission denied",
    "##[warning]Failed to restore: \"/usr/bin/tar\" failed with error: The process '/usr/bin/tar' failed with exit code 1",
    "Cache is not found",
    "##[group]Run Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6",
    "with:",
    "  shared-key: cmux-tui-macos",
    "  prefix-key: v0-rust",
    "##[endgroup]",
    "##[group]Cache Configuration",
    "Restore Key:",
    "    v0-rust-cmux-tui-macos-Darwin-arm64-ae76135b",
    "Cache Key:",
    "    v0-rust-cmux-tui-macos-Darwin-arm64-ae76135b-45f6b09c",
    "##[endgroup]",
    "No cache found.",
    "##[group]Run cargo clippy --workspace --all-targets --locked -- -D warnings",
    "Post job cleanup.",
    "Failed to save: Unable to reserve cache with key setup-go-macOS-arm64-go-1.27.1-66176040da63a34f4bd5aecf2b4a7d5b5a9e39cedfd3e09ad0aae1d7ba0f290e, another job may be creating this cache.",
))

LINUX_JOB = "\n".join(T + line for line in (
    "##[group]Run Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6",
    "with:",
    "  shared-key: cmux-tui-linux",
    "##[endgroup]",
    "Cache Key:",
    "    v0-rust-cmux-tui-linux-Linux-x64-b69e319b-9562e0cd",
    "Cache Size: ~533 MB (559047057 B)",
    "Cache restored successfully",
    'Restored from cache key "v0-rust-cmux-tui-linux-Linux-x64-b69e319b-9562e0cd" full match: true.',
    "##[group]Run actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae",
    "with:",
    "  key: zig-packages-1c7dacaa43f6f0691a3f9e302b263eb3657a341c7d3201403a0b223cce251d13",
    "  restore-keys: zig-packages-",
    "##[endgroup]",
    "Cache restored from key: zig-packages-0000aaaa43f6f0691a3f9e302b263eb3657a341c7d3201403a0b223cce251d13",
    "##[group]Run actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae",
    "with:",
    "  key: cmux-lint-tools-Linux-X64-1155f2ce39b8713694924e2cf4e3400c0f081911b92418dc4ba8bbb9414026bf",
    "##[endgroup]",
    "Cache not found for input keys: cmux-lint-tools-Linux-X64-1155f2ce39b8713694924e2cf4e3400c0f081911b92418dc4ba8bbb9414026bf",
    "Post job cleanup.",
    "Cache saved with key: cmux-lint-tools-Linux-X64-1155f2ce39b8713694924e2cf4e3400c0f081911b92418dc4ba8bbb9414026bf",
    "##[group]Run ./.github/actions/cache-restore",
    "with:",
    "  key: cmux-next-web-bundles-v1-3412dd828f664bdbd4e9c00aec3b738e88d44b416f1364705771ad4ca337d0be",
    "##[endgroup]",
    "##[group]Run python3 \"$GITHUB_ACTION_PATH/../../../scripts/ci/cache_restore_receipt.py\"",
    'CMUX_CACHE_RESTORE {"action_route": "r2", "key": "cmux-next-web-bundles-v1-3412dd828f664bdbd4e9c00aec3b738e88d44b416f1364705771ad4ca337d0be", "result": "exact"}',
    'CMUX_CACHE_RESTORE {"action_route": "github-cache", "key": "ghostty-zig-packages-v1-Linux-zig0.16.0-22e766fa", "result": "exact"}',
))


def kinds(events):
    return [(event.label, event.kind) for event in events]


class KeyPrefixTests(unittest.TestCase):
    def test_the_prefix_stops_at_the_first_content_hash(self):
        self.assertEqual(cache.key_prefix("v0-rust-cmux-tui-macos-Darwin-arm64-ae76135b-45f6b09c"),
                         "v0-rust-cmux-tui-macos-Darwin-arm64")
        self.assertEqual(cache.key_prefix("setup-go-macOS-arm64-go-1.27.1-66176040da63a34f"),
                         "setup-go-macOS-arm64-go-1.27.1")

    def test_a_key_with_no_hash_is_its_own_prefix(self):
        self.assertEqual(cache.key_prefix("cmux-tui-macos"), "cmux-tui-macos")


class ParseTests(unittest.TestCase):
    def test_a_restore_that_downloads_then_fails_to_untar_is_failed_not_a_hit(self):
        events = kinds(cache.parse_job_log(MAC_JOB))
        self.assertIn(("setup-go-macOS-arm64-go-1.27.1", "failed"), events)
        self.assertNotIn(("setup-go-macOS-arm64-go-1.27.1", "exact"), events)
        self.assertNotIn(("setup-go-macOS-arm64-go-1.27.1", "miss"), events)

    def test_misses_take_their_label_from_the_key_input_or_rust_caches_cache_key(self):
        events = kinds(cache.parse_job_log(MAC_JOB))
        self.assertIn(("cmux-zig-tarball-macOS-ARM64", "miss"), events)
        self.assertIn(("v0-rust-cmux-tui-macos-Darwin-arm64", "miss"), events)

    def test_a_refused_save_is_a_collision_on_its_cache(self):
        self.assertIn(("setup-go-macOS-arm64-go-1.27.1", "collision"), kinds(cache.parse_job_log(MAC_JOB)))

    def test_hits_prefix_hits_misses_saves_and_receipts(self):
        events = kinds(cache.parse_job_log(LINUX_JOB))
        self.assertEqual(events, [
            ("v0-rust-cmux-tui-linux-Linux-x64", "exact"),
            ("zig-packages", "prefix"),
            ("cmux-lint-tools-Linux-X64", "miss"),
            ("cmux-lint-tools-Linux-X64", "saved"),
            ("cmux-next-web-bundles-v1 (r2)", "exact"),
        ])

    def test_a_github_route_receipt_is_not_counted_twice(self):
        labels = [label for label, _ in kinds(cache.parse_job_log(LINUX_JOB))]
        self.assertNotIn("ghostty-zig-packages-v1-Linux-zig0.16.0 (github)", labels)
        self.assertFalse(any(label.startswith("ghostty-zig") for label in labels))

    def test_a_github_route_receipt_counts_when_actions_cache_printed_no_result(self):
        log = "\n".join(T + line for line in (
            "##[group]Run ./.github/actions/cache-restore",
            "##[group]Run actions/cache/restore@27d5ce7f107fe9357f9df03efb73ab90386fccae",
            "with:",
            "  key: ghostty-zig-packages-v1-Linux-zig0.16.0-22e766fa",
            "##[endgroup]",
            "##[warning]Cache service responded with 503",
            "##[group]Run python3 \"$GITHUB_ACTION_PATH/../../../scripts/ci/cache_restore_receipt.py\"",
            'CMUX_CACHE_RESTORE {"action_route": "github-cache", "key": "ghostty-zig-packages-v1-Linux-zig0.16.0-22e766fa", "result": "miss_or_unavailable"}',
        ))
        self.assertEqual(kinds(cache.parse_job_log(log)), [("ghostty-zig-packages-v1-Linux-zig0.16.0", "miss")])

    def test_a_github_route_receipt_after_a_printed_result_is_not_counted(self):
        log = "\n".join(T + line for line in (
            "##[group]Run actions/cache/restore@27d5ce7f107fe9357f9df03efb73ab90386fccae",
            "with:",
            "  key: ghostty-zig-packages-v1-Linux-zig0.16.0-22e766fa",
            "##[endgroup]",
            "Cache hit for: ghostty-zig-packages-v1-Linux-zig0.16.0-22e766fa",
            "##[group]Run python3 \"$GITHUB_ACTION_PATH/../../../scripts/ci/cache_restore_receipt.py\"",
            'CMUX_CACHE_RESTORE {"action_route": "github-cache", "key": "ghostty-zig-packages-v1-Linux-zig0.16.0-22e766fa", "result": "exact"}',
        ))
        self.assertEqual(kinds(cache.parse_job_log(log)), [("ghostty-zig-packages-v1-Linux-zig0.16.0", "exact")])

    def test_cache_phrases_in_a_build_or_local_action_step_are_not_restores(self):
        log = "\n".join(T + line for line in (
            "##[group]Run ./scripts/build@main",
            "##[endgroup]",
            "Failed to restore terminal state",
            "Cache not found for input keys: whatever-1",
            "##[group]Run make test",
            "Cache hit for: some-test-fixture",
            "##[group]Run someone/other-action@v1",
            "  key: other-key-deadbeef",
            "Cache hit for: other-key-deadbeef",
        ))
        self.assertEqual(kinds(cache.parse_job_log(log)), [])

    def test_save_lines_count_only_in_a_cache_action_or_post_job_cleanup(self):
        log = "\n".join(T + line for line in (
            "##[group]Run make build",
            "Cache saved with key: forged-key-deadbeef",
            "Failed to save: Unable to reserve cache with key forged-key-deadbeef, another job may be creating this cache.",
            "##[group]Run actions/cache/save@27d5ce7f107fe9357f9df03efb73ab90386fccae",
            "Cache saved with key: real-key-deadbeef",
            "##[group]Run make test",
            "Post job cleanup.",
            "Cache saved with key: post-key-deadbeef",
        ))
        self.assertEqual(kinds(cache.parse_job_log(log)), [("real-key", "saved"), ("post-key", "saved")])

    def test_a_receipt_printed_outside_the_receipt_step_is_not_counted(self):
        log = "\n".join(T + line for line in (
            "##[group]Run make test",
            'CMUX_CACHE_RESTORE {"action_route": "r2", "key": "forged-key-deadbeef", "result": "exact"}',
        ))
        self.assertEqual(kinds(cache.parse_job_log(log)), [])

    def test_an_actions_cache_exact_hit_is_counted_once(self):
        log = "\n".join(T + line for line in (
            "##[group]Run actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae",
            "with:",
            "  key: bun-web-lint-Linux-X64-0f1e2d3c4b5a69788796a5b4c3d2e1f0",
            "##[endgroup]",
            "Cache restored successfully",
            "Cache restored from key: bun-web-lint-Linux-X64-0f1e2d3c4b5a69788796a5b4c3d2e1f0",
            "##[group]Run bun run lint",
            "Post job cleanup.",
            "Cache hit occurred on the primary key bun-web-lint-Linux-X64-0f1e2d3c4b5a69788796a5b4c3d2e1f0, not saving cache.",
        ))
        self.assertEqual(kinds(cache.parse_job_log(log)), [("bun-web-lint-Linux-X64", "exact")])


class AggregateTests(unittest.TestCase):
    def test_rows_are_per_workflow_and_cache_worst_hit_rate_first(self):
        rows = cache.aggregate_restores([
            ("cmux-tui.yml", 1, cache.parse_job_log(MAC_JOB)),
            ("cmux-tui.yml", 2, cache.parse_job_log(MAC_JOB)),
            ("cmux-tui.yml", 3, cache.parse_job_log(LINUX_JOB)),
        ])
        first = rows[0]
        self.assertEqual(first.hit_rate, 0.0)
        go = next(row for row in rows if row.label == "setup-go-macOS-arm64-go-1.27.1")
        self.assertEqual((go.restores, go.failed, go.collision, len(go.jobs)), (2, 2, 2, 2))
        linux = next(row for row in rows if row.label == "v0-rust-cmux-tui-linux-Linux-x64")
        self.assertEqual(linux.hit_rate, 1.0)
        self.assertLess(rows.index(go), rows.index(linux))

    def test_a_cache_with_only_saves_has_no_hit_rate(self):
        rows = cache.aggregate_restores([("w", 1, [cache.CacheEvent("k", "saved")])])
        self.assertIsNone(rows[0].hit_rate)


class SelectionTests(unittest.TestCase):
    def test_only_finished_jobs_with_a_cache_or_restore_step_are_sampled(self):
        step = {"name": "Cache cargo build", "conclusion": "success"}
        self.assertTrue(cache.is_cache_job({"conclusion": "success", "steps": [step]}))
        self.assertTrue(cache.is_cache_job({"conclusion": "failure",
                                            "steps": [{"name": "Restore web bundles", "conclusion": "success"}]}))
        self.assertFalse(cache.is_cache_job({"conclusion": "cancelled", "steps": [step]}))
        self.assertFalse(cache.is_cache_job({"conclusion": "success",
                                             "steps": [{"name": "Cache cargo build", "conclusion": "skipped"}]}))
        self.assertFalse(cache.is_cache_job({"conclusion": "success", "steps": [{"name": "Build", "conclusion": "success"}]}))

    def test_timed_out_jobs_and_cache_enabled_setup_actions_are_sampled(self):
        step = {"name": "Cache cargo build", "conclusion": "success"}
        self.assertTrue(cache.is_cache_job({"conclusion": "timed_out", "steps": [step]}))
        for name in ("Set up Node", "Run actions/setup-node@v4", "Set up Go", "Run actions/setup-go@abc"):
            self.assertTrue(cache.is_cache_job({"conclusion": "success", "steps": [{"name": name, "conclusion": "success"}]}), name)

    def test_setup_only_jobs_rank_below_jobs_with_a_cache_step(self):
        setup = {"name": "Set up Node", "conclusion": "success"}
        named = {"name": "Restore web bundles", "conclusion": "success"}
        self.assertEqual(cache.is_cache_job({"conclusion": "success", "steps": [setup]}), cache.SETUP_ONLY_JOB)
        self.assertEqual(cache.is_cache_job({"conclusion": "success", "steps": [setup, named]}), cache.CACHE_STEP_JOB)
        candidates = [("a.yml", "setup", 1), ("a.yml", "setup", 2), ("b.yml", "cache", 3), ("c.yml", "cache", 4)]
        self.assertEqual(cache.choose_log_jobs(candidates, 3, deferred={1, 2}),
                         [("b.yml", "cache", 3), ("c.yml", "cache", 4), ("a.yml", "setup", 1)])

    def test_the_sample_spreads_across_jobs_before_going_deep(self):
        candidates = [("a.yml", "x", 1), ("a.yml", "x", 2), ("a.yml", "x", 3), ("b.yml", "y", 4)]
        self.assertEqual(cache.choose_log_jobs(candidates, 2), [("a.yml", "x", 1), ("b.yml", "y", 4)])
        self.assertEqual(len(cache.choose_log_jobs(candidates, 10)), 4)
        self.assertEqual(cache.choose_log_jobs(candidates, 0), [])


class StoreTests(unittest.TestCase):
    ENTRIES = [
        {"key": "v0-rust-cmux-tui-macos-Darwin-arm64-ae76135b-45f6b09c", "ref": "refs/heads/feat-cmux-next",
         "size_in_bytes": 870_000_000, "last_accessed_at": "2026-10-29T19:58:00Z"},
        {"key": "v0-rust-cmux-tui-macos-Darwin-arm64-b2523b1e-45f6b09c", "ref": "refs/heads/scratch/x",
         "size_in_bytes": 870_000_000, "last_accessed_at": "2026-10-29T20:00:00Z"},
        {"key": "ghostty-zig-packages-v1-macOS-zig0.16.0-22e766fa43e4", "ref": "refs/heads/feat-cmux-next",
         "size_in_bytes": 140_000_000, "last_accessed_at": "2026-10-29T20:05:00Z"},
    ]

    def test_prefixes_sum_their_entries_and_split_out_unshared_refs(self):
        store = cache.summarize_store(self.ENTRIES, {"active_caches_size_in_bytes": 1_880_000_000,
                                                    "active_caches_count": 0})
        self.assertEqual(store.entries, 3)  # a count of 0 beside a real size falls back to the listing
        self.assertEqual(store.unshared_size, 870_000_000)
        top = store.prefixes[0]
        self.assertEqual((top.prefix, top.entries, top.size, top.unshared_size, len(top.refs)),
                         ("v0-rust-cmux-tui-macos-Darwin-arm64", 2, 1_740_000_000, 870_000_000, 2))
        self.assertEqual(top.last_used, "2026-10-29T20:00:00Z")

    def test_the_section_names_both_stores_and_renders_the_tables(self):
        store = cache.summarize_store(self.ENTRIES, None)
        rows = cache.aggregate_restores([("cmux-tui.yml", 1, cache.parse_job_log(MAC_JOB))])
        text = "\n".join(cache.render_section(store, rows, sampled_logs=1, notes=["a note"]))
        self.assertIn("### Actions cache", text)
        self.assertIn("**GitHub store:**", text)
        self.assertIn("Blacksmith's own store", text)
        self.assertIn("| `v0-rust-cmux-tui-macos-Darwin-arm64` | 2 |", text)
        self.assertIn("| cmux-tui.yml | `setup-go-macOS-arm64-go-1.27.1` | 1 | 1 | 0 | 0 | 0 | 1 | 0% | 1 |", text)
        self.assertIn("_a note_", text)

    def test_a_partial_listing_says_its_other_ref_share_is_a_lower_bound(self):
        store = cache.summarize_store(self.ENTRIES, {"active_caches_size_in_bytes": 9_000_000_000,
                                                    "active_caches_count": 700})
        text = "\n".join(cache.render_section(store, [], sampled_logs=0))
        self.assertIn("3 of 700 entries listed", text)
        self.assertIn("lower bound", text)

    def test_labels_from_logs_cannot_break_the_code_span_or_the_row(self):
        rows = [cache.RestoreRow("w.yml", "evil`**x**\nnext|row", exact=1)]
        text = "\n".join(cache.render_section(None, rows, sampled_logs=1))
        row = next(line for line in text.splitlines() if line.startswith("| w.yml"))
        self.assertIn("`evil'**x** next\\|row`", row)

    def test_notes_are_one_line_with_no_markdown_of_their_own(self):
        text = "\n".join(cache.render_section(None, [], sampled_logs=0,
                                               notes=["GET x failed\n# heading | `code` [link](http://e) <b>*"]))
        note = next(line for line in text.splitlines() if line.startswith("_GET"))
        self.assertEqual(note, "_GET x failed \\# heading \\| 'code' \\[link\\](http://e) \\<b\\>\\*_")

    def test_the_failed_legend_covers_lookup_errors(self):
        text = "\n".join(cache.render_section(None, [], sampled_logs=0))
        self.assertIn("Failed to restore", text)
        self.assertNotIn("the entry downloaded but did not restore", text)

    def test_an_unread_store_still_renders_the_restores(self):
        text = "\n".join(cache.render_section(None, [], sampled_logs=0))
        self.assertNotIn("**GitHub store:**", text)
        self.assertIn("_No cache restores in the sampled logs._", text)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
