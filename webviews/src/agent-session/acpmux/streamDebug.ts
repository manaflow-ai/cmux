// `debug.agent_pane action=stream` (R104): streams a scripted reply into a long transcript, at a
// chosen delta size and cadence, and reports how the frames went. Deltas arrive on a timer, not
// on frames, as a socket's do. Measures dropped and long frames, how often the view left the
// bottom while it should follow it, and how far the content grew in one frame (a burst reads as
// a jump).
import type { AcpmuxRow } from "./model";
import { acpmuxPerf, frameStats, median, percentile, round2 } from "./perf";
import { syntheticRows } from "./synthetic";

export type StreamOptions = {
  rows?: number;
  seconds?: number;
  chunk_chars?: number;
  chunk_ms?: number;
  nominal_ms?: number;
};

const SAMPLE = [
  "Here is what I found after reading the transcript code and the pacing module. ",
  "The reply streams in small deltas, and each one used to re-render the whole message.\n\n",
  "- The model keeps one row per message segment.\n- Tool calls split a message into segments.\n",
  "- The height estimate re-lexes the row's Markdown.\n\n",
  "```ts\nfunction reveal(text: string, now: number) {\n  return text.slice(0, shown(now));\n}\n```\n\n",
  "A longer paragraph follows so the reply wraps over several lines in a normal pane width, ",
  "which is where a burst of text makes the transcript jump instead of flow.\n\n",
].join("");

const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));

export async function runStream(
  replaceRows: (rows: AcpmuxRow[]) => void,
  options: StreamOptions = {},
): Promise<Record<string, unknown>> {
  acpmuxPerf.enable();
  const base = syntheticRows(Math.max(3, Math.floor(options.rows ?? 2000)));
  const seconds = Math.max(0.5, options.seconds ?? 6);
  const chunkChars = Math.max(1, Math.floor(options.chunk_chars ?? 24));
  const chunkMs = Math.max(1, options.chunk_ms ?? 12);
  replaceRows(base);
  const warmup: number[] = [];
  for (let index = 0; index < 30; index += 1) warmup.push(await frame());
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return { error: "no transcript" };
  scroller.scrollTop = scroller.scrollHeight;
  await frame();
  const nominal =
    options.nominal_ms && options.nominal_ms > 0
      ? options.nominal_ms
      : Math.max(1, median(warmup.slice(1).map((time, index) => time - warmup[index]!)));
  acpmuxPerf.resetFrames();
  const at = (base.at(-1)?.at ?? 0) + 1_000;
  let text = "";
  let version = 0;
  let source = 0;
  const push = (streaming: boolean) => {
    version += 1;
    replaceRows([...base, { id: "debug-stream", version, at, kind: "assistant", text, streaming }]);
  };
  const feeder = setInterval(() => {
    text += SAMPLE.repeat(2).slice(source % SAMPLE.length, (source % SAMPLE.length) + chunkChars);
    source += chunkChars;
    push(true);
  }, chunkMs);
  const timestamps: number[] = [];
  const growth: number[] = [];
  let detached = 0;
  const gaps: number[] = [];
  // The reply's visible characters per frame: text that lands in bursts shows on few frames in
  // big steps; flowing text shows on most frames in small steps.
  const steps: number[] = [];
  let shown = 0;
  let lastHeight = scroller.scrollHeight;
  const end = performance.now() + seconds * 1000;
  let ended = false;
  let tail = 0;
  while (tail < 30) {
    const now = await frame();
    timestamps.push(now);
    acpmuxPerf.markFrame(now, false);
    const height = scroller.scrollHeight;
    growth.push(Math.max(0, height - lastHeight));
    lastHeight = height;
    const gap = height - scroller.clientHeight - scroller.scrollTop;
    gaps.push(gap);
    if (gap > 2) detached += 1;
    const visible = document.querySelector('[data-row-id="debug-stream"]')?.textContent?.length ?? shown;
    steps.push(Math.max(0, visible - shown));
    shown = Math.max(shown, visible);
    if (!ended && now >= end) {
      ended = true;
      clearInterval(feeder);
      push(false);
    }
    if (ended) tail += 1;
  }
  const sorted = [...growth].sort((a, b) => a - b);
  const stats = acpmuxPerf.stats(false) as Record<string, unknown>;
  return {
    rows: base.length + 1,
    chars: text.length,
    deltas: version - 1,
    ...frameStats(timestamps, nominal),
    detached_frames: detached,
    growth_px: {
      p50: round2(percentile(sorted, 0.5)),
      p95: round2(percentile(sorted, 0.95)),
      max: round2(sorted.at(-1) ?? 0),
    },
    growing_frames: growth.filter((value) => value > 0).length,
    gap_px: { p50: round2(median(gaps)), max: round2(Math.max(0, ...gaps)) },
    text_frames: steps.filter((value) => value > 0).length,
    text_step: (() => {
      const moving = steps.filter((value) => value > 0).sort((a, b) => a - b);
      return { p50: percentile(moving, 0.5), p95: percentile(moving, 0.95), max: moving.at(-1) ?? 0 };
    })(),
    // Per frame: geometry and React time (acpmuxPerf), and time outside both.
    layout_ms: stats.layout,
    react_ms: stats.react,
    other_ms: stats.other,
  };
}
