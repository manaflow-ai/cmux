// `debug.agent_pane action=stream` with `surface` (DEBUG; golden.py `ui_surface_stream`): an agent UI surface
// card streaming into a long chat, in the live pane, the counterpart of
// webviews/bench/ui-surface-stream-frames.bench.ts (plans/cmux-next/agent-ui-surfaces-DESIGN.md, "Streaming and
// frames"). Seeds `rows` synthetic rows and a running turn's prompt, then updates one tool row `updates` times at
// `hz` (on wall-clock timers, as a socket's updates come): `surface: "cmux-catalog-cards"` puts the shared
// golden's growing surface on the call (uiSurfaceStreamFixture.ts, read with `readUiSurface` on every update as direct.ts reads `_meta.acpmux.uiSurface`); `surface: "none"` is the
// baseline, the same row at the same cadence with no surface. Reports the page's animation-frame intervals from the
// first update to 200 ms after the last (p50/p95/max, frames over 16.7 ms), long tasks where the engine reports
// them, and whether the Labs flag was on and the card drew.
import { agentUiSurfacesOn } from "./agentUiSurfaces";
import type { AcpmuxRow } from "./model";
import { acpmuxPerf, frameStats, intervalsOf, median, round2 } from "./perf";
import type { StreamOptions } from "./streamDebug";
import { syntheticRows } from "./synthetic";
import { readUiSurface } from "./uiSurface/model";
import {
  UI_SURFACE_STREAM_CALL,
  UI_SURFACE_STREAM_FIXTURE,
  UI_SURFACE_STREAM_HZ,
  UI_SURFACE_STREAM_TITLE,
  UI_SURFACE_STREAM_UPDATES,
  uiSurfaceStreamAt,
} from "./uiSurfaceStreamFixture";
import type { SeedSnapshotFields } from "./waitingSteersFixture";

/// The turn is running, so its tool row draws live, not folded into a finished turn's "Worked for".
const WORKING: SeedSnapshotFields = { isWorking: true, summary: { steering: false, backgroundsWork: false } };
const TOOL_ROW = "debug-ui-surface-stream";
/// Frames after the last update that still count (the bench's window).
const TAIL_MS = 200;

const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));

/// Long tasks (> 50 ms) from now until `stop`; null where the engine has no `longtask` entries (WebKit).
function longTasks(): { stop(): { count: number; max_ms: number } | null } {
  const tasks: number[] = [];
  let observer: PerformanceObserver | undefined;
  try {
    if (PerformanceObserver.supportedEntryTypes?.includes("longtask")) {
      observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) tasks.push(entry.duration);
      });
      observer.observe({ type: "longtask" });
    }
  } catch {
    observer = undefined;
  }
  return {
    stop() {
      if (!observer) return null;
      observer.disconnect();
      return { count: tasks.length, max_ms: round2(Math.max(0, ...tasks)) };
    },
  };
}

export async function runSurfaceStream(
  replaceRows: (rows: AcpmuxRow[], fields?: SeedSnapshotFields) => void,
  options: StreamOptions,
): Promise<Record<string, unknown>> {
  const withSurface = options.surface === UI_SURFACE_STREAM_FIXTURE;
  if (!withSurface && options.surface !== "none")
    return { error: `unknown surface ${String(options.surface)}; use ${UI_SURFACE_STREAM_FIXTURE} or none` };
  acpmuxPerf.enable();
  const base = syntheticRows(Math.max(3, Math.floor(options.rows ?? 1500)));
  const updates = Math.max(2, Math.floor(options.updates ?? UI_SURFACE_STREAM_UPDATES));
  const gap = 1000 / Math.max(1, options.hz ?? UI_SURFACE_STREAM_HZ);
  const at = (base.at(-1)?.at ?? 0) + 1_000;
  const prompt: AcpmuxRow = {
    id: "debug-ui-surface-prompt",
    version: 1,
    at,
    kind: "user",
    text: "Show the release status.",
  };
  const seeded = [...base, prompt];
  replaceRows(seeded, WORKING);
  const warmup: number[] = [];
  for (let index = 0; index < 30; index += 1) warmup.push(await frame());
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return { error: "no transcript" };
  scroller.scrollTop = scroller.scrollHeight;
  await frame();
  const nominal = Math.max(1, median(intervalsOf(warmup.slice(1))));

  const push = (index: number) => {
    const last = index === updates - 1;
    const surface = withSurface ? readUiSurface(uiSurfaceStreamAt(index, updates)) : undefined;
    const tool = {
      id: UI_SURFACE_STREAM_CALL,
      title: UI_SURFACE_STREAM_TITLE,
      kind: "other",
      status: last ? "completed" : "in_progress",
      ...(surface ? { uiSurface: surface } : {}),
    };
    const row: AcpmuxRow = {
      id: TOOL_ROW,
      version: index + 1,
      at: at + 500,
      kind: "activity",
      items: [{ kind: "tool", text: UI_SURFACE_STREAM_TITLE, tool }],
    };
    replaceRows([...seeded, row], WORKING);
  };

  acpmuxPerf.resetFrames();
  const tasks = longTasks();
  const timestamps: number[] = [];
  let sent = 0;
  let lastSentAt = 0;
  const start = performance.now();
  // Paced on the wall clock from `start`, so a late timer does not slow the stream (the bench's pacing).
  const feed = () => {
    push(sent);
    sent += 1;
    if (sent < updates) setTimeout(feed, Math.max(0, start + sent * gap - performance.now()));
    else lastSentAt = performance.now();
  };
  feed();
  for (;;) {
    const now = await frame();
    timestamps.push(now);
    acpmuxPerf.markFrame(now, false);
    if (lastSentAt && now >= lastSentAt + TAIL_MS) break;
    // A stream whose timers stopped (a page the host paused) ends instead of waiting for ever.
    if (now - start > updates * gap * 20 + 5_000) break;
  }
  const long = tasks.stop();
  const intervals = intervalsOf(timestamps);
  const stats = acpmuxPerf.stats(false) as Record<string, unknown>;
  return {
    arm: withSurface ? "with" : "without",
    fixture: withSurface ? UI_SURFACE_STREAM_FIXTURE : null,
    rows: seeded.length + 1,
    updates: sent,
    hz: round2(1000 / gap),
    stream_ms: round2((lastSentAt || performance.now()) - start),
    // The Labs flag as the page has it, and whether the card drew: a `with` arm without both measured nothing.
    flag_on: agentUiSurfacesOn(),
    card_drawn: document.querySelector(".uis-card") !== null,
    ...frameStats(timestamps, nominal),
    over_16_7: intervals.filter((value) => value > 16.7).length,
    long_tasks: long,
    layout_ms: stats.layout,
    react_ms: stats.react,
    other_ms: stats.other,
    ...(options.trace ? { intervals_ms: intervals.map(round2) } : {}),
  };
}
