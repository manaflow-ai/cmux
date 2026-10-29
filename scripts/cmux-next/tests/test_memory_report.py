#!/usr/bin/env python3
"""memory-report.py (p07-memory task 014): parsing footprint -j, vmmap -summary and heap output,
grouping, the join with debug.memory consumers (task 010's JSON keys), MQ-UNATTRIBUTED rows, the
MQ-CACHE order, a report from saved files with and without debug.memory, and the launched run's
virtual display and failure paths with a fake app.

Run: python3 -I scripts/cmux-next/tests/test_memory_report.py
"""

from __future__ import annotations

import copy
import importlib.util
import io
import json
import os
import signal
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "memory-report.py"
spec = importlib.util.spec_from_file_location("memory_report", SCRIPT)
mr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mr)

M = 1048576

# `swapped` stands for a compressed count footprint reports apart from `dirty`; the key names of a real
# `footprint -j` capture are not checked in yet (the parser adds any swap or compress key).
FOOTPRINT_JSON = {
    "processes": [{
        "pid": 4242, "name": "cmux DEV mem", "footprint": 200 * M, "peak_footprint": 260 * M,
        "categories": {
            "MALLOC_SMALL": {"dirty": 30 * M, "clean": 0, "reclaimable": 0, "regions": 40},
            "MALLOC_LARGE": {"dirty": 10 * M, "clean": 0, "reclaimable": 0, "regions": 12},
            "Memory Tag 253": {"dirty": 58 * M, "swapped": 2 * M, "regions": 90},
            "IOSurface": {"dirty": 40 * M, "regions": 30},
            "IOAccelerator": {"dirty": 20 * M, "regions": 10},
            "CG image": {"dirty": 8 * M, "regions": 4},
            "Stack": {"dirty": 6 * M, "regions": 60},
            "__DATA_DIRTY": {"dirty": 4 * M, "regions": 300},
            "untagged (VM_ALLOCATE)": {"dirty": 7 * M, "regions": 9},
            "TOTAL": {"dirty": 185 * M},
        },
    }],
}

VMMAP = """Process:         cmux DEV mem [4242]
Physical footprint:         200.0M
----

                                VIRTUAL RESIDENT    DIRTY  SWAPPED VOLATILE   NONVOL    EMPTY   REGION
REGION TYPE                        SIZE     SIZE     SIZE     SIZE     SIZE     SIZE     SIZE    COUNT (non-coalesced)
===========                     ======= ========    =====  ======= ========   ======    =====  =======
CG image                          8192K    8192K    8192K       0K       0K       0K       0K        4
IOSurface                          40.0M    40.0M    40.0M       0K       0K       0K       0K       30
MALLOC_LARGE                       12.0M    10.0M    10.0M       0K       0K       0K       0K       12         see MALLOC ZONE table below
MALLOC_SMALL                       64.0M    30.0M    28.0M     2.0M       0K       0K       0K       40         see MALLOC ZONE table below
Memory Tag 253                     80.0M    60.0M    60.0M       0K       0K       0K       0K       90
Stack                              32.0M    6144K    6144K       0K       0K       0K       0K       60
===========                     ======= ========    =====  ======= ========   ======    =====  =======
TOTAL                             236.0M   154.0M   152.0M     2.0M       0K       0K       0K      236

                                          VIRTUAL   RESIDENT      DIRTY    SWAPPED ALLOCATION      BYTES DIRTY+SWAP          REGION
MALLOC ZONE                                  SIZE       SIZE       SIZE       SIZE      COUNT  ALLOCATED  FRAG SIZE  % FRAG   COUNT
===========                               =======  =========  =========  =========  =========  =========  =========  ======  ======
DefaultMallocZone_0x100d0c000               60.0M      30.0M      30.0M         0K     133624      17.3M      12.7M     42%      41
QuartzCore_0x101234000                      16.0M      10.0M      10.0M         0K       2000       9.0M       1.0M     10%      10
PartitionAlloc_0x10a000000                  80.0M      60.0M      60.0M         0K      50000      50.0M      10.0M     17%      90
===========                               =======  =========  =========  =========  =========  =========  =========  ======  ======
TOTAL                                      156.0M     100.0M     100.0M         0K     185624      76.3M      23.7M     24%     141
"""

HEAP = """Process:         cmux DEV mem [4242]
Zone DefaultMallocZone_0x100d0c000: 1000 nodes - 5MB
Zone PartitionAlloc_0x10a000000: 0 nodes - 0K

All zones: 1500 nodes (20MB)
   COUNT      BYTES       AVG   CLASS_NAME                                   TYPE    BINARY
   =====      =====       ===   ==========                                   ====    ======
     500    8388608   16777.2   CmuxNextTabs.TabThumbnailCache               Swift   CmuxNext
     300    2097152    6990.5   Swift._DictionaryStorage<CmuxNextTabs.TabID, CmuxNextTabs.TabImage>  Swift  libswiftCore.dylib
     200    1048576    5242.9   CmuxNextDesign.ChromeLabel                   Swift   CmuxNext
     100      4096K      41.0   non-object
"""


def traits(storage: str | None = None) -> dict:
    """A consumer's `traits` object as task 010 encodes it (MemoryDiagnosticsReport.Traits), with the
    proposed `storage` trait when given."""
    out = {"estimated_usage": "medium", "data_access": "none", "retention": "lossless", "recreate_cost": "cheap",
           "release_cpu_cost": "low", "is_stateful": True, "supports_memory_limit": True}
    if storage:
        out["storage"] = storage
    return out


def consumer(name: str, footprint: int | None, storage: str | None = None) -> dict:
    return {"name": name, "traits": traits(storage), "managed": True, "limit_percent": 100,
            "footprint_bytes": footprint, "volatile_bytes": None, "entries": 40}


# The debug.memory reply as task 010 writes it (MemoryDiagnosticsReport.swift).
DEBUG_MEMORY = {
    "pressure": {"level": "normal", "kernel_level": "normal", "override": None, "since_ms": None},
    "mode": "medium",
    "budget": {"physical_bytes": 16 << 30, "image_cache_bytes": 64 * M},
    "consumers": [consumer("tab-hover-cards", 6 * M), consumer("hibernation-snapshots", 5 * M),
                  consumer("unknown-size", None), consumer("page-host-pool", 50 * M)],
    "processes": [{"kind": "app", "pid": 4242, "phys_footprint_bytes": 200 * M}],
    "tabs": [], "workspaces": [],
    "terminal": {"warm_capacity": 8, "warm_count": 2, "gpu_resident_count": 1,
                 "hidden_nonvolatile_iosurface_bytes": 4 * M, "last_frames": 2},
    "spares": [], "pressure_history": [],
}


def with_storage(document: dict, storages: dict[str, str]) -> dict:
    """`document` with the proposed `traits.storage` on the named consumers."""
    out = copy.deepcopy(document)
    for entry in out["consumers"]:
        if entry["name"] in storages:
            entry["traits"]["storage"] = storages[entry["name"]]
    return out


STORED = with_storage(DEBUG_MEMORY, {"tab-hover-cards": "image", "hibernation-snapshots": "image",
                                     "page-host-pool": "heap"})


class ParseTests(unittest.TestCase):
    def test_sizes(self):
        self.assertEqual(mr.size_bytes("16K"), 16384)
        self.assertEqual(mr.size_bytes("1.5M"), int(1.5 * M))
        self.assertEqual(mr.size_bytes("2G"), 2 * 1024 * M)
        self.assertEqual(mr.size_bytes("123"), 123)
        self.assertIsNone(mr.size_bytes("below"))

    def test_footprint_json_adds_swapped_and_drops_total(self):
        categories, total = mr.footprint_categories(FOOTPRINT_JSON)
        self.assertEqual(total, 200 * M)  # not the peak
        self.assertNotIn("TOTAL", categories)
        self.assertEqual(categories["Memory Tag 253"], 60 * M)  # dirty + swapped, as vmmap's DIRTY + SWAPPED
        self.assertEqual(sum(categories.values()), 185 * M)
        compressed = {"pid": 1, "categories": {"IOSurface": {"dirty": 5, "compressed": 3}, "Stack": {"clean": 9}}}
        self.assertEqual(mr.footprint_categories(compressed), ({"IOSurface": 8}, None))

    def test_footprint_json_from_a_real_capture_counts_compressed_once(self):
        # fixtures/footprint-j-macos.json: `footprint -j` on a fleet Mac (macOS 27.0), chronod with 8 MB compressed.
        # Its `dirty` already holds the swapped bytes (the dirty sum equals the footprint), so nothing is added.
        doc = json.loads((Path(__file__).resolve().parent / "fixtures" / "footprint-j-macos.json").read_text())
        categories, total = mr.footprint_categories(doc)
        self.assertEqual(total, 21_169_040)
        self.assertEqual(sum(categories.values()), 21_136_272)
        self.assertLessEqual(sum(categories.values()), total)

    def test_footprint_json_list_shape(self):
        doc = {"pid": 1, "phys_footprint": 9, "regions": [{"category": "IOSurface", "dirty": 5}, {"name": "Stack", "dirty": 4}]}
        self.assertEqual(mr.footprint_categories(doc), ({"IOSurface": 5, "Stack": 4}, 9))

    def test_footprint_text(self):
        text = ("cmux [4242]: 64-bit    Footprint: 200 MB (16384 bytes per page)\n"
                "    Dirty      Clean  Reclaimable    Regions    Category\n"
                "      ---        ---          ---        ---    ---\n"
                "    40 MB        0 B          0 B         30    IOSurface\n"
                "  6144 KB        0 B          0 B         60    Stack\n"
                "    46 MB        0 B          0 B         90    TOTAL\n")
        categories, total = mr.footprint_text_categories(text)
        self.assertEqual(categories, {"IOSurface": 40 * M, "Stack": 6 * M})
        self.assertEqual(total, 200 * M)

    def test_vmmap_regions_and_zones(self):
        regions, zones = mr.vmmap_tables(VMMAP)
        self.assertEqual(regions["MALLOC_SMALL"], 30 * M)  # dirty + swapped, the trailing words dropped
        self.assertEqual(regions["Memory Tag 253"], 60 * M)
        self.assertNotIn("TOTAL", regions)
        self.assertEqual(zones, {"DefaultMallocZone": 30 * M, "QuartzCore": 10 * M, "PartitionAlloc": 60 * M})
        self.assertEqual(mr.vmmap_footprint(VMMAP), 200 * M)
        self.assertIsNone(mr.vmmap_footprint(""))

    def test_heap_takes_all_zones_table(self):
        classes = mr.heap_classes(HEAP)
        self.assertEqual(classes["CmuxNextTabs.TabThumbnailCache"], 8388608)
        self.assertEqual(classes["non-object"], 4096 * 1024)
        self.assertEqual(len(classes), 4)
        self.assertEqual(mr.heap_zone_nodes(HEAP), {"DefaultMallocZone": 1000, "PartitionAlloc": 0})

    def test_heap_walk_without_partitionalloc_nodes_is_unknown(self):
        _, zones = mr.vmmap_tables(VMMAP)
        walk = mr.heap_walk(HEAP, zones)  # PartitionAlloc is the malloc, and the walk saw none of it
        self.assertFalse(walk["enumerated"])
        self.assertIn("PartitionAlloc", walk["why"])
        self.assertTrue(mr.heap_walk(HEAP, {"DefaultMallocZone": 30 * M})["enumerated"])
        seen = HEAP.replace("PartitionAlloc_0x10a000000: 0 nodes", "PartitionAlloc_0x10a000000: 40 nodes")
        self.assertTrue(mr.heap_walk(seen, zones)["enumerated"])

    def test_groups(self):
        self.assertEqual(mr.group_of("Memory Tag 253"), "PartitionAlloc")
        self.assertEqual(mr.group_of("Memory Tag 255"), "V8")
        self.assertEqual(mr.group_of("PartitionAlloc"), "PartitionAlloc")
        self.assertEqual(mr.group_of("MALLOC_TINY"), "malloc")
        self.assertEqual(mr.group_of("IOSurface"), "IOSurface")
        self.assertEqual(mr.group_of("IOAccelerator (graphics)"), "IOAccelerator")
        self.assertEqual(mr.group_of("CG image"), "CG image")
        self.assertEqual(mr.group_of("Stack Guard"), "stacks")
        self.assertEqual(mr.group_of("__DATA_CONST"), "__DATA")
        self.assertEqual(mr.group_of("__LINKEDIT"), "framework pages")
        self.assertEqual(mr.group_of("untagged (VM_ALLOCATE)"), "VM_ALLOCATE (untagged)")
        self.assertEqual(mr.group_of("SQLite page cache"), "SQLite page cache")


class JoinTests(unittest.TestCase):
    def setUp(self):
        self.categories, self.total = mr.footprint_categories(FOOTPRINT_JSON)
        _, self.zones = mr.vmmap_tables(VMMAP)

    def rows(self, phase):
        return {row["group"]: row for row in phase["groups"]}

    def test_malloc_splits_by_zone_without_partitionalloc(self):
        groups, _ = mr.groups_from(self.categories, self.zones)
        # 40 MB of MALLOC_* by the non-PartitionAlloc zones' dirty bytes (30 : 10); PartitionAlloc keeps its tag.
        self.assertEqual(groups["DefaultMallocZone"], 30 * M)
        self.assertEqual(groups["malloc zones (other)"], 10 * M)
        self.assertEqual(groups["PartitionAlloc"], 60 * M)
        self.assertEqual(sum(groups.values()), 185 * M)

    def test_without_debug_memory_only_fixed_owners_explain(self):
        phase = mr.analyze("home", self.categories, self.zones, self.total, None, "unknown method debug.memory")
        rows = self.rows(phase)
        self.assertFalse(phase["debug_memory"]["available"])
        self.assertEqual(rows["stacks"]["explained_bytes"], 6 * M)
        self.assertEqual(rows["__DATA"]["owner"], "binaries (dyld images)")
        self.assertEqual(rows["IOSurface"]["explained_bytes"], 0)
        # 15 MB outside the categories plus everything without a fixed owner.
        self.assertEqual(rows["outside footprint categories"]["bytes"], 15 * M)
        self.assertEqual(phase["unattributed_bytes"], 200 * M - 10 * M)
        self.assertEqual(phase["unattributed_pct"], 95.0)
        queued = {row["group"] for row in phase["mq_unattributed"]}
        self.assertEqual(queued, {"PartitionAlloc", "IOSurface", "DefaultMallocZone", "IOAccelerator", "malloc zones (other)",
                                  "CG image", "VM_ALLOCATE (untagged)", "outside footprint categories"})

    def test_task_010_reply_explains_only_the_terminal_surfaces(self):
        # Task 010's consumers say nothing about where their storage lives: they explain no group.
        phase = mr.analyze("home", self.categories, self.zones, self.total, DEBUG_MEMORY)
        rows = self.rows(phase)
        self.assertEqual(phase["debug_memory"]["consumers"], 4)  # null bytes is unknown, not 0
        self.assertEqual(phase["consumers_without_storage"], ["tab-hover-cards", "hibernation-snapshots", "page-host-pool"])
        self.assertEqual(rows["CG image"]["explained_bytes"], 0)
        self.assertEqual(rows["PartitionAlloc"]["explained_bytes"], 0)
        # Only the hidden non-volatile IOSurfaces are reported: the visible ones stay unexplained.
        self.assertEqual(rows["IOSurface"]["consumers"], [{"name": "terminal hidden non-volatile IOSurfaces", "bytes": 4 * M}])
        queued = {r["group"]: r for r in phase["mq_unattributed"]}
        self.assertEqual(queued["IOSurface"]["unexplained_bytes"], 36 * M)
        self.assertEqual(phase["unattributed_bytes"], 200 * M - 10 * M - 4 * M)

    def test_consumers_claim_only_their_allocator(self):
        phase = mr.analyze("home", self.categories, self.zones, self.total, STORED)
        rows = self.rows(phase)
        # Image storage fills CG image only; what does not fit is listed, never spilled into malloc.
        self.assertEqual(rows["CG image"]["consumers"], [{"name": "tab-hover-cards", "bytes": 6 * M},
                                                         {"name": "hibernation-snapshots", "bytes": 2 * M}])
        self.assertEqual(phase["consumer_bytes_beyond_regions"], [{"name": "hibernation-snapshots", "bytes": 3 * M}])
        # PartitionAlloc is the malloc (its zone is in vmmap's table): heap storage is there, nowhere else.
        self.assertEqual(rows["PartitionAlloc"]["consumers"], [{"name": "page-host-pool", "bytes": 50 * M}])
        for group in ("DefaultMallocZone", "malloc zones (other)", "VM_ALLOCATE (untagged)"):
            self.assertEqual(rows[group]["explained_bytes"], 0, group)
        explained = sum(r["explained_bytes"] for r in phase["groups"])
        self.assertEqual(phase["unattributed_bytes"], 200 * M - explained)

    def test_heap_storage_goes_to_the_default_zone_without_partitionalloc(self):
        zones = {"DefaultMallocZone": 30 * M}
        phase = mr.analyze("home", {"MALLOC_SMALL": 40 * M, "untagged (VM_ALLOCATE)": 7 * M}, zones, 47 * M, STORED)
        rows = self.rows(phase)
        self.assertEqual(rows["DefaultMallocZone"]["consumers"], [{"name": "page-host-pool", "bytes": 40 * M}])
        self.assertEqual(rows["VM_ALLOCATE (untagged)"]["explained_bytes"], 0)
        self.assertIn({"name": "page-host-pool", "bytes": 10 * M}, phase["consumer_bytes_beyond_regions"])

    def test_consumer_larger_than_its_regions_is_noted(self):
        doc = {"consumers": [consumer("huge", 500 * M, "gpu")]}
        phase = mr.analyze("x", {"IOAccelerator": 20 * M}, {}, 20 * M, doc)
        self.assertEqual(phase["unattributed_bytes"], 0)
        self.assertEqual(phase["consumer_bytes_beyond_regions"], [{"name": "huge", "bytes": 480 * M}])

    def test_categories_above_the_footprint_are_noted(self):
        phase = mr.analyze("x", {"IOSurface": 30 * M}, {}, 20 * M, None)
        self.assertEqual(len(phase["notes"]), 1)
        self.assertIn("twice", phase["notes"][0])


class CacheOrderTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.files = {
            "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabThumbnailCache.swift": "final class TabThumbnailCache {}\nstruct TabImage {}\n",
            "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/ChromeLabel.swift": "final class ChromeLabel {}\n",
            "Packages/macOS/CmuxNext/Sources/CmuxNextHome/Quiet.swift": "struct QuietCache {}\n",
            "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabHoverCard.swift":
                'final class HoverThumbs {}\nstatic let memoryConsumerName = "tab-hover-cards"\n',
            "Packages/macOS/CmuxNext/Sources/CmuxNextHome/Sized.swift": 'let name = "unknown-size"\n',
        }
        for path, text in self.files.items():
            os.makedirs(os.path.join(self.root, os.path.dirname(path)), exist_ok=True)
            Path(self.root, path).write_text(text)
        self.heap = mr.heap_walk(HEAP, {"DefaultMallocZone": 30 * M})

    def names(self, rows):
        return [r["file"].rsplit("/", 1)[1] for r in rows]

    def test_consumer_bytes_then_heap_bytes(self):
        rows = mr.mq_cache_order(list(self.files), DEBUG_MEMORY, self.heap, self.root)
        self.assertEqual(self.names(rows), ["TabThumbnailCache.swift", "TabHoverCard.swift", "ChromeLabel.swift",
                                            "Quiet.swift", "Sized.swift"])
        by = {name: row for name, row in zip(self.names(rows), rows)}
        self.assertEqual((by["TabHoverCard.swift"]["bytes"], by["TabHoverCard.swift"]["source"]), (6 * M, "debug.memory"))
        self.assertEqual((by["TabThumbnailCache.swift"]["bytes"], by["TabThumbnailCache.swift"]["source"]),
                         (8388608 + 2097152, "heap"))
        self.assertEqual(by["Quiet.swift"]["bytes"], 0)  # the walk saw the malloc and no object of the file's types
        self.assertEqual((by["Sized.swift"]["bytes"], by["Sized.swift"]["source"]), (None, "debug.memory"))  # null bytes

    def test_heap_bytes_are_unknown_when_the_walk_missed_the_malloc(self):
        _, zones = mr.vmmap_tables(VMMAP)
        rows = mr.mq_cache_order(list(self.files), None, mr.heap_walk(HEAP, zones), self.root)
        self.assertTrue(all(r["bytes"] is None for r in rows))
        self.assertEqual([r["rank"] for r in rows], [1, 2, 3, 4, 5])
        self.assertTrue(all(r["bytes"] is None for r in mr.mq_cache_order(list(self.files), None, None, self.root)))


class OfflineMainTests(unittest.TestCase):
    def run_main(self, *extra, footprint=FOOTPRINT_JSON):
        folder = tempfile.mkdtemp()
        fp = Path(folder, "fp.json")
        fp.write_text(json.dumps(footprint))
        vm = Path(folder, "vmmap.txt")
        vm.write_text(VMMAP)
        out = Path(folder, "report.json")
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = mr.main(["--footprint-file", str(fp), "--vmmap-file", str(vm), "--label", "home",
                            "--no-cache-queue", "--out", str(out), *extra])
        return code, buffer.getvalue(), json.loads(out.read_text())

    def test_report_without_debug_memory(self):
        code, text, report = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("MEMORY-REPORT phase=home footprint_mb=200.0", text)
        self.assertIn("debug_memory=no", text)
        self.assertIn("MQ-UNATTRIBUTED phase=home group='PartitionAlloc'", text)
        self.assertEqual(report["phases"][0]["phys_footprint_bytes"], 200 * M)

    def test_without_a_footprint_total_takes_vmmap_footprint_as_live(self):
        bare = copy.deepcopy(FOOTPRINT_JSON)
        del bare["processes"][0]["footprint"]
        del bare["processes"][0]["peak_footprint"]
        _, _, report = self.run_main(footprint=bare)
        _, _, live = self.run_main()
        self.assertEqual(report["phases"][0]["phys_footprint_bytes"], 200 * M)
        self.assertEqual(report["phases"][0]["unattributed_pct"], live["phases"][0]["unattributed_pct"])

    def test_report_with_debug_memory_and_heap(self):
        folder = tempfile.mkdtemp()
        dm = Path(folder, "dm.json")
        dm.write_text(json.dumps(DEBUG_MEMORY))
        heap = Path(folder, "heap.txt")
        heap.write_text(HEAP)
        code, text, report = self.run_main("--debug-memory-file", str(dm), "--heap-file", str(heap))
        self.assertEqual(code, 0)
        self.assertIn("debug_memory=yes", text)
        self.assertIn("report no traits.storage", text)
        self.assertTrue(report["phases"][0]["debug_memory"]["available"])
        self.assertEqual(report["phases"][0]["heap"]["enumerated"], False)

    def test_no_categories_fails(self):
        folder = tempfile.mkdtemp()
        empty = Path(folder, "empty.json")
        empty.write_text("{}")
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = mr.main(["--footprint-file", str(empty), "--no-cache-queue", "--out", str(Path(folder, "r.json"))])
        self.assertEqual(code, 1)


class AtlasTests(unittest.TestCase):
    """Task 039: the atlas verdict from GPU bytes at 1..K terminals before and after the glyph sheet."""

    BASE = 30 * M  # the window's drawables: about the same at every count, since the panes tile it
    SURFACE = 2 * M  # buffers each surface holds whatever its size

    def series(self, atlas_per_surface, atlas_shared, counts=(1, 2, 3, 4)):
        return [(k, self.BASE + k * (self.SURFACE + atlas_per_surface) + atlas_shared) for k in counts]

    def test_per_surface_copies(self):
        # Three frame copies per surface: 3 x 256 KiB at the start, 3 x 4 MiB grown.
        summary = mr.atlas_summary(self.series(3 * M // 4, 0), self.series(12 * M, 0, counts=(4, 3, 2, 1)))
        self.assertEqual(summary["verdict"], "per_surface")
        self.assertEqual(summary["atlas_bytes_per_extra_terminal"], 12 * M - 3 * M // 4)
        self.assertEqual(summary["atlas_growth_one_terminal_bytes"], 12 * M - 3 * M // 4)
        self.assertEqual(summary["per_surface_share"], 1.0)
        self.assertEqual(summary["terminals"], 4)

    def test_one_shared_texture(self):
        summary = mr.atlas_summary(self.series(0, M // 4), self.series(0, 4 * M))
        self.assertEqual(summary["verdict"], "shared")
        self.assertEqual(summary["atlas_bytes_per_extra_terminal"], 0)
        self.assertEqual(summary["atlas_growth_one_terminal_bytes"], 4 * M - M // 4)

    def test_noise_does_not_turn_shared_into_per_surface(self):
        grown = [(k, b + (M // 2 if k % 2 else -M // 2)) for k, b in self.series(0, 4 * M)]
        self.assertEqual(mr.atlas_summary(self.series(0, M // 4), grown)["verdict"], "shared")

    def test_no_growth_is_unmeasured(self):
        summary = mr.atlas_summary(self.series(0, M // 4), self.series(0, M // 4))
        self.assertEqual(summary["verdict"], "unmeasured")
        self.assertIn("did not grow", summary["why"])
        # The recorded field stays unknown (a 0 would read as shared); the raw slope change has its own field.
        self.assertIsNone(summary["atlas_bytes_per_extra_terminal"])
        self.assertEqual(summary["gpu_slope_change_bytes"], 0)
        text = io.StringIO()
        with redirect_stdout(text):
            mr.print_atlas(summary)
        self.assertIn("atlas_bytes_per_extra_terminal=unknown", text.getvalue())

    def test_one_doubling_of_a_shared_texture_reads_shared(self):
        # The smallest real shared growth: 512 x 512 -> 1024 x 1024 R8, 768 KiB on one terminal only.
        summary = mr.atlas_summary(self.series(0, M // 4), self.series(0, M))
        self.assertEqual(summary["atlas_growth_one_terminal_bytes"], 3 * M // 4)
        self.assertEqual(summary["verdict"], "shared")
        self.assertEqual(summary["atlas_bytes_per_extra_terminal"], 0)

    def test_sheet_grows_the_atlas_to_2048_at_either_scale(self):
        # 1x is the STRESS virtual display (vdisplay.m hiDPI = 0); 2x a Retina screen.
        for scale in (1.0, 2.0):
            area = mr.atlas_glyph_count(scale) * mr.ATLAS_GLYPH_PIXELS_1X * scale * scale
            self.assertGreater(area, 1024 * 1024 * 1.5, scale)  # well past a 1024 x 1024 atlas
            self.assertLess(area, 2048 * 2048 * 0.75, scale)  # well inside 2048 x 2048
        self.assertGreater(mr.atlas_glyph_count(1.0), 6000)
        self.assertEqual(mr.atlas_glyph_count(0.1), 0x9FFF - 0x4E00 + 1)  # never past the CJK block

    def test_backing_scale(self):
        self.assertEqual(mr.backing_scale(lambda method: {"windows": [{"scale": 1.0}, {"scale": 2.0}]}), 2.0)
        self.assertIsNone(mr.backing_scale(lambda method: {"error": "unknown method"}))
        self.assertIsNone(mr.backing_scale(lambda method: {"windows": [{"scale": 0}]}))

    def test_one_count_is_unmeasured(self):
        summary = mr.atlas_summary([(1, 10 * M)], [(1, 20 * M)])
        self.assertEqual(summary["verdict"], "unmeasured")
        self.assertIsNone(summary["atlas_bytes_per_extra_terminal"])

    def test_glyph_pages(self):
        count = mr.atlas_glyph_count(1.0)
        pages = mr.glyph_pages(count)
        lines = [line for page in pages for line in page.splitlines()]
        glyphs = "".join(lines)
        self.assertEqual(len(glyphs), count)
        self.assertEqual(len(set(glyphs)), count)  # each glyph once: every one is a new atlas entry
        self.assertTrue(all(len(line) <= mr.ATLAS_LINE_GLYPHS for line in lines))
        self.assertTrue(all(len(page.splitlines()) <= mr.ATLAS_PAGE_LINES for page in pages))
        self.assertTrue(all(0x4E00 <= ord(c) <= 0x9FFF for c in glyphs))  # CJK Unified Ideographs, two cells each

    def test_gpu_bytes_sums_the_gpu_groups(self):
        self.assertEqual(mr.gpu_bytes({"IOSurface": 3 * M, "IOAccelerator (graphics)": 2 * M,
                                       "owned physical footprint (unmapped)": M, "Stack": 9 * M,
                                       "MALLOC_SMALL": 5 * M}), 6 * M)


class FakeAtlasBuilder:
    """The Stress surface measure_atlas uses, over a fake app whose GPU bytes follow its pane count and
    whether the glyph sheet reached every terminal."""

    def __init__(self, per_surface_copy, scale=1.0, refuse_close=False):
        self.per_surface_copy, self.scale, self.refuse_close = per_surface_copy, scale, refuse_close
        self.pane_ids, self.sent, self.actions, self.refusals, self.splits = [], set(), [], [], []
        self.window_sized = False
        self.sheet = ""

    def rpc(self, method, params=None, timeout=60):
        assert method == "debug.pane_chrome"
        return {"windows": [{"scale": self.scale}]}

    def size_window(self):
        self.window_sized = True

    def new_workspace(self):
        self.pane_ids = ["p0"]
        return "w1"

    def show(self, workspace):
        pass

    def workspace(self, workspace_id):
        return {"id": workspace_id}

    def panes(self, workspace):
        return [{"id": p} for p in self.pane_ids]

    def record_first(self, workspace, pane):
        pass

    def split(self, workspace, pane, verb):
        assert pane in self.pane_ids
        self.splits.append((pane, verb))
        self.pane_ids.append(f"p{len(self.pane_ids)}")
        return self.pane_ids[-1]

    def tabs(self, workspace_id, pane_id):
        return [{"id": f"t-{pane_id}", "kind": "terminal"}]

    def send(self, tab_id, text):
        self.sent.add(tab_id)
        self.sheet = text

    def action(self, name, args=None, target=None, focus=True, timeout=120, settle=0.0):
        self.actions.append((name, target))
        if name == "closePane":
            if self.refuse_close:
                self.refusals.append("closePane: refused")
            else:
                self.pane_ids.remove(target.split(":", 1)[1])

    def gpu(self, raw_stem):
        atlas = 4 * M if len(self.sent) == 4 else M // 4
        copies = len(self.pane_ids) * 3 * atlas if self.per_surface_copy else atlas
        return 30 * M + len(self.pane_ids) * 2 * M + copies


def fake_wait(predicate, seconds, step=0.25):
    return predicate()


class MeasureAtlasTests(unittest.TestCase):
    """measure_atlas over the fake builder: the steps, the sheet in every terminal, the verdict."""

    def setUp(self):
        self.saved_sleep = mr.time.sleep
        mr.time.sleep = lambda seconds: None
        self.stem = str(Path(tempfile.mkdtemp(), "report with space-atlas"))

    def tearDown(self):
        mr.time.sleep = self.saved_sleep

    def test_per_surface_fake_reads_per_surface(self):
        builder = FakeAtlasBuilder(True)
        summary = mr.measure_atlas(builder, self.stem, 4, 0, builder.gpu, fake_wait)
        self.assertTrue(builder.window_sized)
        # Two columns: p0 | p1, then p2 under p0 and p3 under p1 (a 2 x 2 grid).
        self.assertEqual(builder.splits, [("p0", "splitRight"), ("p0", "splitDown"), ("p1", "splitDown")])
        self.assertEqual((summary["backing_scale"], summary["glyphs"]), (1.0, mr.atlas_glyph_count(1.0)))
        self.assertEqual(summary["verdict"], "per_surface")
        self.assertEqual(summary["atlas_bytes_per_extra_terminal"], 3 * (4 * M - M // 4))
        self.assertEqual([p["terminals"] for p in summary["start"]], [1, 2, 3, 4])
        self.assertEqual([p["terminals"] for p in summary["grown"]], [4, 3, 2, 1])
        self.assertEqual(builder.sent, {"t-p0", "t-p1", "t-p2", "t-p3"})  # every terminal drew the sheet
        self.assertIn("'" + self.stem + "-glyphs'/page-*.txt", builder.sheet)  # quoted for the shell
        pages = sorted(Path(self.stem + "-glyphs").glob("page-*.txt"))
        self.assertEqual("".join(p.read_text() for p in pages).replace("\n", ""),
                         "".join(mr.glyph_pages(mr.atlas_glyph_count(1.0))).replace("\n", ""))
        self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w1"))

    def test_shared_fake_reads_shared(self):
        builder = FakeAtlasBuilder(False)
        summary = mr.measure_atlas(builder, self.stem, 4, 0, builder.gpu, fake_wait)
        self.assertEqual(summary["verdict"], "shared")
        self.assertEqual(summary["atlas_bytes_per_extra_terminal"], 0)

    def test_missing_sample_raises_and_closes_the_workspace(self):
        builder = FakeAtlasBuilder(True)
        with self.assertRaises(RuntimeError):
            mr.measure_atlas(builder, self.stem, 2, 0, lambda raw: None, fake_wait)
        # A failed phase leaves no workspace for the phases after it.
        self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w1"))

    def test_refused_close_raises_instead_of_a_wrong_count(self):
        builder = FakeAtlasBuilder(True, refuse_close=True)
        with self.assertRaises(RuntimeError) as caught:
            mr.measure_atlas(builder, self.stem, 3, 0, builder.gpu, fake_wait)
        self.assertIn("closePane left pane p2 open", str(caught.exception))
        self.assertIn("closePane: refused", str(caught.exception))
        self.assertEqual(builder.actions[-1], ("closeWorkspace", "workspace:w1"))

    def test_no_scale_raises(self):
        builder = FakeAtlasBuilder(True, scale=None)
        with self.assertRaises(RuntimeError):
            mr.measure_atlas(builder, self.stem, 2, 0, builder.gpu, fake_wait)


class FakeDisplay:
    def __init__(self):
        self.terminated = False

    def terminate(self):
        self.terminated = True


class FakeApp:
    """activation-perf.App's surface: launch, stop, rpc, process.pid, socket."""

    fail_launch = False

    def __init__(self, bundle, out, hang_ms):
        self.out, self.socket, self.stopped = out, None, False
        self.process = types.SimpleNamespace(pid=4242)
        FakeApp.last = self

    def launch(self):
        Path(self.out, "app.log").write_text("launched\n")
        if FakeApp.fail_launch:
            raise SystemExit("activation-perf: the app's debug socket never answered (a Debug build is required)")

    def stop(self):
        self.stopped = True

    def rpc(self, method, params=None, timeout=60):
        return {"error": "fake"}


class FakeStress:
    def __init__(self, rpc):
        self.closed = False

    def build(self):
        raise KeyError("workspace_id")  # an rpc error reply the builder indexes

    def close(self):
        self.closed = True


class LaunchedRunTests(unittest.TestCase):
    """run_launched with a fake perf-stress-session module and app: the display, the logs and the
    phases measured before a failure all reach the report."""

    def setUp(self):
        self.displays = []
        module = types.ModuleType("perf_stress_session")
        module.StressShapeError = type("StressShapeError", (RuntimeError,), {})

        def start_vdisplay(hz, out, hold):
            self.displays.append((hz, out, hold, FakeDisplay()))
            return self.displays[-1][3]

        module.start_vdisplay = start_vdisplay
        module.load_activation_app = lambda: FakeApp
        module.Stress = FakeStress
        module.wait = fake_wait
        self.saved_module = sys.modules.get("perf_stress_session")
        sys.modules["perf_stress_session"] = module
        self.saved_measure = mr.measure
        mr.measure = lambda label, pid, socket_path, heap, stem: (
            dict(mr.analyze(label, {"IOSurface": 10 * M}, {}, 10 * M, None), source="fake"), None, None)
        self.saved_signals = {n: signal.getsignal(n) for n in (signal.SIGTERM, signal.SIGHUP)}
        FakeApp.fail_launch = False

    def tearDown(self):
        mr.measure = self.saved_measure
        if self.saved_module is None:
            sys.modules.pop("perf_stress_session", None)
        else:
            sys.modules["perf_stress_session"] = self.saved_module
        for number, handler in self.saved_signals.items():
            signal.signal(number, handler)

    def run_main(self, *extra):
        folder = tempfile.mkdtemp()
        out = Path(folder, "report.json")
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = mr.main(["--app", "/x/cmux DEV mem.app", "--settle", "0", "--no-cache-queue", "--out", str(out), *extra])
        return code, buffer.getvalue(), json.loads(out.read_text()), folder

    def test_stress_failure_keeps_home_and_the_logs(self):
        code, text, report, folder = self.run_main("--phases", "home,stress")
        self.assertEqual(code, 1)
        self.assertEqual([p["label"] for p in report["phases"]], ["home", "stress"])
        self.assertIn("MEMORY-REPORT phase=home footprint_mb=10.0", text)
        self.assertIn("KeyError", report["phases"][1]["skipped"])
        # The STRESS display came up at 120 Hz in the report folder and went down with the run.
        self.assertEqual([(hz, out) for hz, out, _, _ in self.displays], [(120.0, folder)])
        self.assertTrue(self.displays[0][3].terminated)
        self.assertTrue(FakeApp.last.stopped)
        self.assertEqual(Path(folder, "app.log").read_text(), "launched\n")  # kept beside report.json
        self.assertEqual(report["app_log"], str(Path(folder, "app.log")))

    def test_home_only_starts_no_display_unless_asked(self):
        code, _, report, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertEqual(self.displays, [])
        self.run_main("--vdisplay", "60")
        self.assertEqual(self.displays[0][0], 60.0)
        self.run_main("--phases", "home,stress", "--vdisplay", "0")
        self.assertEqual(len(self.displays), 1)

    def test_atlas_failure_is_reported_and_fails_the_run(self):
        # FakeStress has no window steps: the atlas phase fails, says why, and home stays measured.
        code, text, report, _ = self.run_main("--phases", "home,atlas")
        self.assertEqual(code, 1)
        self.assertIn("AttributeError", report["atlas"]["error"])
        self.assertIn("ATLAS error: AttributeError", text)
        self.assertEqual([p["label"] for p in report["phases"]], ["home"])
        self.assertEqual(self.displays[0][0], 120.0)  # the atlas window needs the STRESS display too
        self.assertTrue(self.displays[0][3].terminated)

    def test_atlas_and_stress_need_separate_launches(self):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            mr.main(["--app", "/x/a.app", "--phases", "home,atlas,stress"])

    def test_atlas_needs_two_terminals(self):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            mr.main(["--app", "/x/a.app", "--phases", "atlas", "--atlas-terminals", "1"])

    def test_launch_failure_writes_the_report(self):
        FakeApp.fail_launch = True
        code, text, report, folder = self.run_main("--phases", "home,stress")
        self.assertEqual(code, 1)
        self.assertEqual([p["label"] for p in report["phases"]], ["home", "stress"])
        self.assertIn("debug socket never answered", report["phases"][0]["skipped"])
        self.assertIn("MEMORY-REPORT phase=home skipped", text)
        self.assertTrue(Path(folder, "app.log").exists())
        self.assertTrue(self.displays[0][3].terminated)


if __name__ == "__main__":
    sys.exit(unittest.main())
