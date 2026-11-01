// Which moments of an attached video the agent sees (Leo, 2026-11-01: "i feel like cmux-next should
// give u better tools to deal with this kind of thing"). Four frames at even times missed what
// happened between them, so the host now also answers small gray probes of the video
// (`video.info`'s `probes`, AgentPaneVideoInfo.swift), this file picks the times from them, and the
// host decodes those frames large enough to read on-screen text (`video.frames`). The pick is plain
// logic, so it lives here and is tested on Linux. AVFoundation's decoding stays in the host.
//
// The pick: the opening frame, then each scene change (a probe that differs from the one before it
// in more than CUT of its cells), the largest first, never two closer than a share of the video;
// then the largest gaps left, filled at their middles, so a video with no cuts gets even spacing.

/// A probe: the video at `atMs` drawn as a small grid of gray cells (one byte each).
export type VideoProbe = { atMs: number; cells: Uint8Array };

/// A picked time, and whether a scene starts there.
export type FramePick = { atMs: number; scene: boolean };

/// The most frames a video gives the agent.
export const MAX_FRAMES = 16;
/// A cell counts as changed when its gray moved more than this (of 255).
const CELL_STEP = 24;
/// A probe starts a scene when more than this share of its cells changed.
const CUT = 0.3;

/// How many frames a video of `durationMs` gives: one a second up to 8, then one per two seconds
/// up to MAX_FRAMES (a 16 s clip: 8; a minute: 16; a 3 s clip: 3).
export function frameCount(durationMs: number): number {
  const seconds = durationMs / 1000;
  if (!Number.isFinite(seconds) || seconds <= 0) return 0;
  return Math.min(MAX_FRAMES, Math.max(Math.min(8, Math.ceil(seconds)), Math.round(seconds / 2)));
}

/// The share of cells that changed from `a` to `b` (0 for probes of different sizes).
export function change(a: Uint8Array, b: Uint8Array): number {
  if (!a.length || a.length !== b.length) return 0;
  let changed = 0;
  for (let index = 0; index < a.length; index++) if (Math.abs(a[index]! - b[index]!) > CELL_STEP) changed += 1;
  return changed / a.length;
}

/// `count` even times over `durationMs`: the middle of each of `count` equal parts.
export function evenTimes(durationMs: number, count: number): number[] {
  if (!(durationMs > 0) || count <= 0) return [];
  return Array.from({ length: count }, (_, index) => Math.round((durationMs * (index + 0.5)) / count));
}

/// The times to show a video of `durationMs` at, in order, from its `probes` (any order); even
/// times when there are fewer than two probes.
export function pickFrameTimes(
  durationMs: number,
  probes: readonly VideoProbe[],
  count = frameCount(durationMs),
): FramePick[] {
  const want = Math.min(count, MAX_FRAMES);
  if (!(durationMs > 0) || want <= 0) return [];
  const sorted = probes
    .filter((probe) => probe.atMs >= 0 && probe.atMs <= durationMs && probe.cells.length > 0)
    .sort((a, b) => a.atMs - b.atMs);
  if (sorted.length < 2) return evenTimes(durationMs, want).map((atMs) => ({ atMs, scene: false }));
  const minGap = durationMs / (want * 2);
  const picks: FramePick[] = [{ atMs: sorted[0]!.atMs, scene: false }];
  const far = (atMs: number) => picks.every((pick) => Math.abs(pick.atMs - atMs) >= minGap);
  const cuts = sorted
    .slice(1)
    .map((probe, index) => ({ atMs: probe.atMs, score: change(sorted[index]!.cells, probe.cells) }))
    .filter((cut) => cut.score > CUT);
  // The largest cut next (scores within a tenth tie), of ties the farthest from what is picked, so
  // a video that flickers throughout is still seen throughout.
  const nearest = (atMs: number) => Math.min(...picks.map((pick) => Math.abs(pick.atMs - atMs)));
  while (picks.length < want) {
    let best: { atMs: number; score: number } | undefined;
    for (const cut of cuts) {
      if (!far(cut.atMs)) continue;
      const tier = Math.round(cut.score * 10) - Math.round((best?.score ?? -1) * 10);
      if (!best || tier > 0 || (tier === 0 && nearest(cut.atMs) > nearest(best.atMs))) best = cut;
    }
    if (!best) break;
    picks.push({ atMs: best.atMs, scene: true });
  }
  // The largest gaps left (the video's ends included) get a frame at their middles.
  while (picks.length < want) {
    const times = [0, ...picks.map((pick) => pick.atMs).sort((a, b) => a - b), durationMs];
    let widest = 0;
    for (let index = 1; index < times.length; index++)
      if (times[index]! - times[index - 1]! > times[widest + 1]! - times[widest]!) widest = index - 1;
    const atMs = Math.round((times[widest]! + times[widest + 1]!) / 2);
    if (picks.some((pick) => pick.atMs === atMs)) break;
    picks.push({ atMs, scene: false });
  }
  return picks.sort((a, b) => a.atMs - b.atMs);
}

/// The most base64 the frames of one video carry in a prompt: 16 frames of a 1280 px screen
/// recording (about 200 KB each) fit, and three such videos still fit the prompt's 12 MiB
/// (promptBudget.ts), which drops whole videos' frames past it.
export const FRAME_BYTES = 4 * 1024 * 1024;

/// `frames` within `budget` base64 characters: while over, the frame closest in time to its
/// neighbours goes (never the first), so what is left stays spread over the video.
export function fitFrames<Frame extends { atMs: number; data: string }>(
  frames: readonly Frame[],
  budget = FRAME_BYTES,
): Frame[] {
  const kept = [...frames].sort((a, b) => a.atMs - b.atMs);
  let total = kept.reduce((sum, frame) => sum + frame.data.length, 0);
  while (total > budget && kept.length > 1) {
    let drop = 1;
    let tightest = Infinity;
    for (let index = 1; index < kept.length; index++) {
      const before = kept[index]!.atMs - kept[index - 1]!.atMs;
      const after = index + 1 < kept.length ? kept[index + 1]!.atMs - kept[index]!.atMs : before;
      if (before + after < tightest) {
        tightest = before + after;
        drop = index;
      }
    }
    total -= kept[drop]!.data.length;
    kept.splice(drop, 1);
  }
  return total > budget ? [] : kept;
}

/// The probes of a `video.info` answer, checked: each `{atMs, cells}` with `cells` base64 of one
/// byte per cell, all of one size. Undefined for an answer without them (an older host).
export function parseProbes(value: unknown): VideoProbe[] | undefined {
  const raw = (value as { probes?: unknown } | null | undefined)?.probes;
  if (!Array.isArray(raw)) return undefined;
  const probes = raw.flatMap((probe: unknown): VideoProbe[] => {
    const { atMs, cells } = (probe ?? {}) as { atMs?: unknown; cells?: unknown };
    if (typeof atMs !== "number" || !Number.isFinite(atMs) || atMs < 0 || typeof cells !== "string") return [];
    try {
      const bytes = Uint8Array.from(atob(cells), (char) => char.charCodeAt(0));
      return bytes.length > 0 && bytes.length <= 4096 ? [{ atMs, cells: bytes }] : [];
    } catch {
      return [];
    }
  });
  const size = probes[0]?.cells.length;
  return probes.filter((probe) => probe.cells.length === size).slice(0, 256);
}
