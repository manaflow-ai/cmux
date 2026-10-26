#!/usr/bin/env python3
"""memory-report.py (p07-memory task 014): parsing footprint -j, vmmap -summary and heap output,
grouping, the join with debug.memory consumers, MQ-UNATTRIBUTED rows, the MQ-CACHE order, and a
report from saved files with and without debug.memory.

Run: python3 -I scripts/cmux-next/tests/test_memory_report.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "memory-report.py"
spec = importlib.util.spec_from_file_location("memory_report", SCRIPT)
mr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mr)

M = 1048576

FOOTPRINT_JSON = {
    "processes": [{
        "pid": 4242, "name": "cmux DEV mem", "footprint": 200 * M, "peak_footprint": 260 * M,
        "categories": {
            "MALLOC_SMALL": {"dirty": 30 * M, "clean": 0, "reclaimable": 0, "regions": 40},
            "MALLOC_LARGE": {"dirty": 10 * M, "clean": 0, "reclaimable": 0, "regions": 12},
            "Memory Tag 253": {"dirty": 60 * M, "dirty_compressed": 1, "regions": 90},
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

All zones: 1500 nodes (20MB)
   COUNT      BYTES       AVG   CLASS_NAME                                   TYPE    BINARY
   =====      =====       ===   ==========                                   ====    ======
     500    8388608   16777.2   CmuxNextTabs.TabThumbnailCache               Swift   CmuxNext
     300    2097152    6990.5   Swift._DictionaryStorage<CmuxNextTabs.TabID, CmuxNextTabs.TabImage>  Swift  libswiftCore.dylib
     200    1048576    5242.9   CmuxNextDesign.ChromeLabel                   Swift   CmuxNext
     100      4096K      41.0   non-object
"""

DEBUG_MEMORY = {
    "pressure": "normal", "mode": "medium",
    "consumers": [
        {"name": "TabThumbnailCache", "footprint_bytes": 6 * M, "volatile_bytes": 0, "entries": 40},
        {"name": "HibernationSnapshots", "footprint_bytes": 5 * M},
        {"name": "Unknown size", "footprint_bytes": None},
        {"name": "PageHostPool", "footprint_bytes": 50 * M, "storage": "heap"},
    ],
    "terminal": {"iosurface_bytes": 30 * M, "hidden_nonvolatile_iosurface_bytes": 4 * M},
}


class ParseTests(unittest.TestCase):
    def test_sizes(self):
        self.assertEqual(mr.size_bytes("16K"), 16384)
        self.assertEqual(mr.size_bytes("1.5M"), int(1.5 * M))
        self.assertEqual(mr.size_bytes("2G"), 2 * 1024 * M)
        self.assertEqual(mr.size_bytes("123"), 123)
        self.assertIsNone(mr.size_bytes("below"))

    def test_footprint_json_takes_dirty_and_drops_total(self):
        categories, total = mr.footprint_categories(FOOTPRINT_JSON)
        self.assertEqual(total, 200 * M)  # not the peak
        self.assertNotIn("TOTAL", categories)
        self.assertEqual(categories["Memory Tag 253"], 60 * M)  # `dirty`, not `dirty_compressed`
        self.assertEqual(sum(categories.values()), 185 * M)

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
        categories, self.total = mr.footprint_categories(FOOTPRINT_JSON)
        _, self.zones = mr.vmmap_tables(VMMAP)
        self.categories = categories

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

    def test_consumers_explain_their_storage(self):
        phase = mr.analyze("home", self.categories, self.zones, self.total, DEBUG_MEMORY)
        rows = self.rows(phase)
        self.assertEqual(phase["debug_memory"]["consumers"], 4)  # nil bytes is unknown, not 0
        # The largest consumer goes first; image consumers fill CG image, then spill into malloc.
        self.assertEqual(rows["CG image"]["consumers"], [{"name": "TabThumbnailCache", "bytes": 6 * M},
                                                         {"name": "HibernationSnapshots", "bytes": 2 * M}])
        self.assertEqual(rows["PartitionAlloc"]["consumers"], [{"name": "PageHostPool", "bytes": 50 * M},
                                                               {"name": "HibernationSnapshots", "bytes": 3 * M}])
        # The terminal's IOSurface bytes (the largest of its nested counts) explain IOSurface.
        self.assertEqual(rows["IOSurface"]["explained_bytes"], 30 * M)
        queued = {r["group"]: r for r in phase["mq_unattributed"]}
        self.assertEqual(queued["IOSurface"]["unexplained_bytes"], 10 * M)
        self.assertNotIn("CG image", queued)  # all 8 MB explained
        explained = sum(r["explained_bytes"] for r in phase["groups"])
        self.assertEqual(phase["unattributed_bytes"], 200 * M - explained)

    def test_consumer_larger_than_its_regions_is_noted(self):
        doc = {"consumers": [{"name": "Huge", "footprintBytes": 500 * M, "storage": "gpu"}]}
        phase = mr.analyze("x", {"IOAccelerator": 20 * M}, {}, 20 * M, doc)
        self.assertEqual(phase["unattributed_bytes"], 0)
        self.assertEqual(phase["consumer_bytes_beyond_regions"], [{"name": "Huge", "bytes": 480 * M}])


class CacheOrderTests(unittest.TestCase):
    def test_files_sort_by_heap_bytes_of_their_types(self):
        root = tempfile.mkdtemp()
        files = {
            "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabThumbnailCache.swift": "final class TabThumbnailCache {}\nstruct TabImage {}\n",
            "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/ChromeLabel.swift": "final class ChromeLabel {}\n",
            "Packages/macOS/CmuxNext/Sources/CmuxNextHome/Quiet.swift": "struct QuietCache {}\n",
        }
        for path, text in files.items():
            os.makedirs(os.path.join(root, os.path.dirname(path)), exist_ok=True)
            Path(root, path).write_text(text)
        rows = mr.mq_cache_order(list(files), mr.heap_classes(HEAP), root)
        self.assertEqual([r["file"].rsplit("/", 1)[1] for r in rows], ["TabThumbnailCache.swift", "ChromeLabel.swift", "Quiet.swift"])
        self.assertEqual(rows[0]["bytes"], 8388608 + 2097152)
        self.assertEqual(rows[2]["bytes"], 0)
        unknown = mr.mq_cache_order(list(files), None, root)
        self.assertTrue(all(r["bytes"] is None for r in unknown))
        self.assertEqual([r["rank"] for r in unknown], [1, 2, 3])


class OfflineMainTests(unittest.TestCase):
    def run_main(self, *extra):
        folder = tempfile.mkdtemp()
        fp = Path(folder, "fp.json")
        fp.write_text(json.dumps(FOOTPRINT_JSON))
        vm = Path(folder, "vmmap.txt")
        vm.write_text(VMMAP)
        out = Path(folder, "report.json")
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = mr.main(["--footprint-file", str(fp), "--vmmap-file", str(vm), "--label", "home",
                            "--no-cache-queue", "--out", str(out), *extra])
        return code, buffer.getvalue(), json.loads(out.read_text()), folder

    def test_report_without_debug_memory(self):
        code, text, report, _ = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("MEMORY-REPORT phase=home footprint_mb=200.0", text)
        self.assertIn("debug_memory=no", text)
        self.assertIn("MQ-UNATTRIBUTED phase=home group='PartitionAlloc'", text)
        self.assertEqual(report["phases"][0]["phys_footprint_bytes"], 200 * M)

    def test_report_with_debug_memory_and_heap(self):
        folder = tempfile.mkdtemp()
        dm = Path(folder, "dm.json")
        dm.write_text(json.dumps(DEBUG_MEMORY))
        heap = Path(folder, "heap.txt")
        heap.write_text(HEAP)
        code, text, report, _ = self.run_main("--debug-memory-file", str(dm), "--heap-file", str(heap))
        self.assertEqual(code, 0)
        self.assertIn("debug_memory=yes", text)
        self.assertTrue(report["phases"][0]["debug_memory"]["available"])

    def test_no_categories_fails(self):
        folder = tempfile.mkdtemp()
        empty = Path(folder, "empty.json")
        empty.write_text("{}")
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = mr.main(["--footprint-file", str(empty), "--no-cache-queue", "--out", str(Path(folder, "r.json"))])
        self.assertEqual(code, 1)


if __name__ == "__main__":
    sys.exit(unittest.main())
