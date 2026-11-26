# What App-Specific Tag 14 holds in the cmux NEXT app process

The ram-baseline goal (hq `goals/ram-baseline.md`) found most of the app process's footprint in one vmmap class,
**App-Specific Tag 14**: 225 MB dirty of 322 MB on a host with a stale session (11-16, cmux-austin-mini-1), and
131.6 MB dirty of 222.7 MB on a clean one (11-17, cmux9s-Mac-mini). This page says what that class is and what it
holds, from `footprint -v` on a clean mini, against the 2026-11-08 base 08edac86344 with the same harness.

## What the tag is

vmmap prints a Mach VM tag in 240-255 (`VM_MEMORY_APPLICATION_SPECIFIC_1` to `_16`) as "App-Specific Tag N", with
N = tag - 239. Tag 14 is VM tag 253. Chromium's `partition_alloc::PageTag` gives PartitionAlloc 253 (`kBlinkGC` 252,
`kChromium` 254, `kV8` 255), so Tag 14 is every page PartitionAlloc maps, in every partition.

## Why it is not only Chromium's memory

On macOS, PartitionAlloc's allocator shim makes itself the process's default malloc zone. cmux makes that possible
in-process: `CmuxNextMallocZone/early_zone.c` installs the delegating zone (`DelegatingDefaultZoneForPartitionAlloc`)
that PartitionAlloc's constructor swaps out, and after the swap `malloc_default_zone()` follows zones[0], so
CoreFoundation's, Swift's, Objective-C's and the Rust FFI's `malloc` all go to PartitionAlloc too. So Tag 14 is the
app process's whole malloc heap from the moment CEF's framework loads, cmux's and Chromium's browser process together.
What vmmap calls `DefaultMallocZone` (34.7 MB on 11-16) is only what was allocated before the swap, and the blocks
that still live there.

Two consequences for measuring it:

- `heap` does not see Tag 14: PartitionAlloc's zone answers no introspection enumeration, so `heap --sortBySize` lists
  the system zones only. A class-by-class split of Tag 14 needs Chromium's own accounting (memory-infra's
  `malloc` and `partition_alloc/partitions/*` dumps for the browser process), not the macOS heap tools.
- A cut in "Chromium's browser heap" may be a cut in cmux's own Swift allocations, and the other way round.

## The reading

PENDING: perf-idle-ab.sh vm=1, base 08edac86344, head d182b24308ad, rounds=3, chats=0, kinds=app.
