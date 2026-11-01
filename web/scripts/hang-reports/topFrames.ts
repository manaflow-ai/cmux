/**
 * Pure grouping for `scripts/hang-reports-top-frames.ts`. No I/O.
 *
 * Signature rule. A frame is "ours" when its image is not `other`, not in
 * ``APPLE_IMAGES``, not an Apple system dylib (`lib*.dylib`), and not an
 * Apple GPU driver (`AGXMetal*`).
 * The client keeps an image's name only when the image is ours or Apple's,
 * so any kept name outside the Apple list is treated as ours (an Apple
 * framework missing from the list shows up as ours; add it to the list).
 * A hang's signature is its first five frames that are ours, innermost first;
 * a hang with no frame of ours uses its first five frames.
 *
 * Durations. Only MetricKit hangs carry a measured duration. A watchdog
 * `hang` is reported when the main thread has been stuck for 2 s, so its
 * duration is a lower bound near 2000 ms: those are counted as
 * `watchdogHangs` ("watchdog >=2s") and never enter p50/p95. Watchdog
 * stalls are counted in `kinds` and `sources` only.
 *
 * Ranking. Groups are ranked by distinct installs, then by hang count, so
 * one Mac that hangs often does not outrank a hang many people hit.
 */

export type StoredFrame = {
  readonly image: string;
  readonly uuid?: string | null;
  readonly offset?: number | null;
};

export type StoredBucket = { readonly lowMs: number; readonly highMs: number; readonly count: number };

export type StoredHang = {
  readonly source: string;
  readonly kind: string;
  readonly durationMs: number;
  readonly frames: readonly StoredFrame[];
};

export type StoredInterval = {
  readonly category: string;
  readonly name: string;
  readonly count: number;
  readonly buckets?: readonly StoredBucket[];
  readonly hitchMsPerS?: number | null;
};

/** One `hang_reports` row as the script reads it. */
export type StoredReport = {
  readonly installId: string;
  readonly appVersion: string | null;
  readonly appBuild: string | null;
  readonly channel: string | null;
  readonly payload: {
    readonly hangs?: readonly StoredHang[];
    readonly stallHistogram?: readonly StoredBucket[];
    readonly intervals?: readonly StoredInterval[];
  };
};

export type HangGroup = {
  readonly signature: string;
  readonly frames: readonly StoredFrame[];
  readonly count: number;
  readonly installs: number;
  /** Nearest-rank p50 of MetricKit hang durations, or null when the group has none. */
  readonly p50DurationMs: number | null;
  /** Nearest-rank p95 of MetricKit hang durations, or null when the group has none. */
  readonly p95DurationMs: number | null;
  /** MetricKit hangs in the group (the hangs that have a measured duration). */
  readonly metrickitHangs: number;
  /** Watchdog hangs: stuck for at least 2 s, duration not measured. */
  readonly watchdogHangs: number;
  readonly kinds: Readonly<Record<string, number>>;
  readonly sources: Readonly<Record<string, number>>;
  readonly appBuilds: Readonly<Record<string, number>>;
};

export type MergedInterval = {
  readonly category: string;
  readonly name: string;
  readonly count: number;
  readonly buckets: readonly StoredBucket[];
  /** Count-weighted mean over reports that carried a value, else null. */
  readonly hitchMsPerS: number | null;
};

export const SIGNATURE_FRAMES = 5;

export const APPLE_IMAGES: ReadonlySet<string> = new Set([
  "AppKit", "AppleSystemInfo", "ApplicationServices", "AttributeGraph", "AudioToolbox", "CFNetwork",
  "Carbon", "CloudKit", "Combine", "ContactsFoundation", "CoreAnimation", "CoreAutoLayout",
  "CoreData", "CoreDisplay", "CoreFoundation", "CoreGraphics", "CoreImage", "CoreML", "CoreMedia",
  "CoreServices", "CoreServicesInternal", "CoreSVG", "CoreSymbolication", "CoreText", "CoreUI",
  "CoreVideo", "DesktopServicesPriv", "FileProvider", "Foundation", "FrontBoardServices",
  "GLEngine", "HIServices", "HIToolbox", "IOAccelerator", "IOKit", "IOSurface", "ImageIO",
  "JavaScriptCore", "LaunchServices", "LinkPresentation", "Metal", "MetalKit",
  "MetalPerformanceShaders", "MetalTools", "MetricKit", "Network", "OpenGL", "QuartzCore",
  "QuickLookUI", "RenderBox", "RunningBoardServices", "Security", "SkyLight", "SwiftUI",
  "SwiftUICore", "SystemConfiguration", "TextInput", "UIFoundation", "UniformTypeIdentifiers",
  "ViewBridge", "WebCore", "WebKit", "dyld", "dyld_sim",
]);

const APPLE_DYLIB = /^lib[A-Za-z0-9_+.-]*\.dylib$/;

/** Whether a frame's image counts as ours under the module's signature rule. */
export function isOurImage(image: string): boolean {
  if (image === "other") return false;
  if (APPLE_IMAGES.has(image)) return false;
  return !APPLE_DYLIB.test(image) && !image.startsWith("AGXMetal");
}

/** A compact, stable text form of one frame. */
export function frameLabel(frame: StoredFrame): string {
  if (frame.image === "other" || frame.offset == null) return frame.image;
  return `${frame.image}+0x${frame.offset.toString(16)}`;
}

/** The frames that identify a hang. */
export function signatureFrames(frames: readonly StoredFrame[]): readonly StoredFrame[] {
  const ours = frames.filter((frame) => isOurImage(frame.image));
  return (ours.length > 0 ? ours : frames).slice(0, SIGNATURE_FRAMES);
}

/** Nearest-rank percentile of a list of numbers (0 for an empty list). */
export function percentile(values: readonly number[], fraction: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.max(1, Math.ceil(fraction * sorted.length));
  return sorted[Math.min(rank, sorted.length) - 1]!;
}

type GroupAccumulator = {
  frames: readonly StoredFrame[];
  count: number;
  metrickitDurations: number[];
  watchdogHangs: number;
  installs: Set<string>;
  kinds: Map<string, number>;
  sources: Map<string, number>;
  appBuilds: Map<string, number>;
};

function bump(map: Map<string, number>, key: string, by = 1): void {
  map.set(key, (map.get(key) ?? 0) + by);
}

/** Group every hang of every report by signature, ranked by distinct installs, then hang count. */
export function groupHangs(reports: readonly StoredReport[]): HangGroup[] {
  const groups = new Map<string, GroupAccumulator>();
  for (const report of reports) {
    for (const hang of report.payload.hangs ?? []) {
      const frames = signatureFrames(hang.frames);
      const signature = frames.length > 0 ? frames.map(frameLabel).join(" | ") : "(no frames)";
      let group = groups.get(signature);
      if (!group) {
        group = { frames, count: 0, metrickitDurations: [], watchdogHangs: 0, installs: new Set(), kinds: new Map(), sources: new Map(), appBuilds: new Map() };
        groups.set(signature, group);
      }
      group.count += 1;
      if (hang.source === "metrickit") group.metrickitDurations.push(hang.durationMs);
      else if (hang.source === "watchdog" && hang.kind === "hang") group.watchdogHangs += 1;
      group.installs.add(report.installId);
      bump(group.kinds, hang.kind);
      bump(group.sources, hang.source);
      bump(group.appBuilds, report.appBuild ?? "unknown");
    }
  }
  return [...groups.entries()]
    .map(([signature, group]) => ({
      signature,
      frames: group.frames,
      count: group.count,
      installs: group.installs.size,
      p50DurationMs: group.metrickitDurations.length > 0 ? percentile(group.metrickitDurations, 0.5) : null,
      p95DurationMs: group.metrickitDurations.length > 0 ? percentile(group.metrickitDurations, 0.95) : null,
      metrickitHangs: group.metrickitDurations.length,
      watchdogHangs: group.watchdogHangs,
      kinds: Object.fromEntries(group.kinds),
      sources: Object.fromEntries(group.sources),
      appBuilds: Object.fromEntries(group.appBuilds),
    }))
    .sort((a, b) => b.installs - a.installs || b.count - a.count || a.signature.localeCompare(b.signature));
}

/** Sum histogram buckets with the same bounds, ordered by bounds. */
export function mergeBuckets(histograms: readonly (readonly StoredBucket[] | undefined)[]): StoredBucket[] {
  const merged = new Map<string, StoredBucket>();
  for (const histogram of histograms) {
    for (const bucket of histogram ?? []) {
      const key = `${bucket.lowMs}:${bucket.highMs}`;
      const current = merged.get(key);
      merged.set(key, { lowMs: bucket.lowMs, highMs: bucket.highMs, count: (current?.count ?? 0) + bucket.count });
    }
  }
  return [...merged.values()].sort((a, b) => a.lowMs - b.lowMs || a.highMs - b.highMs);
}

/** The watchdog stall histogram summed across reports. */
export function mergeStallHistograms(reports: readonly StoredReport[]): StoredBucket[] {
  return mergeBuckets(reports.map((report) => report.payload.stallHistogram));
}

/** Release interval histograms merged by category and name. */
export function mergeIntervals(reports: readonly StoredReport[]): MergedInterval[] {
  const byKey = new Map<string, { category: string; name: string; count: number; histograms: (readonly StoredBucket[] | undefined)[]; hitchWeighted: number; hitchWeight: number }>();
  for (const report of reports) {
    for (const interval of report.payload.intervals ?? []) {
      const key = `${interval.category}\u0000${interval.name}`;
      let entry = byKey.get(key);
      if (!entry) {
        entry = { category: interval.category, name: interval.name, count: 0, histograms: [], hitchWeighted: 0, hitchWeight: 0 };
        byKey.set(key, entry);
      }
      entry.count += interval.count;
      entry.histograms.push(interval.buckets);
      if (interval.hitchMsPerS != null) {
        const weight = Math.max(1, interval.count);
        entry.hitchWeighted += interval.hitchMsPerS * weight;
        entry.hitchWeight += weight;
      }
    }
  }
  return [...byKey.values()]
    .map((entry) => ({
      category: entry.category,
      name: entry.name,
      count: entry.count,
      buckets: mergeBuckets(entry.histograms),
      hitchMsPerS: entry.hitchWeight > 0 ? entry.hitchWeighted / entry.hitchWeight : null,
    }))
    .sort((a, b) => a.category.localeCompare(b.category) || a.name.localeCompare(b.name));
}

/** Compare dotted numeric versions ("0.70.0-nightly.1" reads as 0.70.0). */
export function compareVersions(a: string, b: string): number {
  const parts = (value: string) => value.split("-")[0]!.split(".").map((part) => Number.parseInt(part, 10) || 0);
  const left = parts(a);
  const right = parts(b);
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

/** Parse `dwarfdump --uuid` output into uppercase UUID to (arch, binary path). */
export function parseDwarfdumpUuids(output: string): Map<string, { readonly arch: string; readonly path: string }> {
  const result = new Map<string, { readonly arch: string; readonly path: string }>();
  for (const line of output.split("\n")) {
    const match = /^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\) (.+)$/.exec(line.trim());
    if (match) result.set(match[1]!.toUpperCase(), { arch: match[2]!, path: match[3]! });
  }
  return result;
}

/** Load address `atos` is given; offsets are relative to the image's `__TEXT` start. */
export const ATOS_LOAD_ADDRESS = 0x1_0000_0000;

/** `atos` arguments that symbolicate `offsets` in one dSYM binary. */
export function atosArguments(binaryPath: string, arch: string, offsets: readonly number[]): string[] {
  return [
    "-o", binaryPath,
    "-arch", arch,
    "-l", `0x${ATOS_LOAD_ADDRESS.toString(16)}`,
    ...offsets.map((offset) => `0x${(ATOS_LOAD_ADDRESS + offset).toString(16)}`),
  ];
}

/** Our frames with a UUID and offset, grouped by uppercase UUID, offsets de-duplicated. */
export function symbolicationRequests(groups: readonly HangGroup[]): Map<string, number[]> {
  const byUuid = new Map<string, Set<number>>();
  for (const group of groups) {
    for (const frame of group.frames) {
      if (!isOurImage(frame.image) || frame.uuid == null || frame.offset == null) continue;
      const uuid = frame.uuid.toUpperCase();
      const offsets = byUuid.get(uuid) ?? new Set<number>();
      offsets.add(frame.offset);
      byUuid.set(uuid, offsets);
    }
  }
  return new Map([...byUuid.entries()].map(([uuid, offsets]) => [uuid, [...offsets].sort((a, b) => a - b)]));
}
