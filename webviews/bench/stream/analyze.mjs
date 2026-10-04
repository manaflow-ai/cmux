// Summarizes a measure-live.mjs or bench run JSON: wire deltas, frame gaps, reveal, stability.
//   node webviews/bench/stream/analyze.mjs FILE.json [...]
import fs from "node:fs";

const pct = (values, p) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))];
};
const r = (value) => Math.round(value * 100) / 100;
const dist = (values) => ({
  n: values.length,
  p50: r(pct(values, 0.5)),
  p90: r(pct(values, 0.9)),
  p99: r(pct(values, 0.99)),
  max: r(values.length ? Math.max(...values) : 0),
  mean: r(values.length ? values.reduce((a, b) => a + b, 0) / values.length : 0),
});

export function analyze(run) {
  const chunks = run.ws.filter((entry) => entry[2] === "agent_message_chunk" && entry[3] >= 0);
  const thoughts = run.ws.filter((entry) => entry[2] === "agent_thought_chunk");
  const first = chunks[0]?.[0] ?? 0;
  const last = chunks.at(-1)?.[0] ?? 0;
  const gaps = chunks.slice(1).map((entry, index) => entry[0] - chunks[index][0]);
  const chars = chunks.reduce((sum, entry) => sum + entry[3], 0);
  const streamFrames = run.frames.filter((t) => t >= first && t <= last + 200);
  const frameGaps = streamFrames.slice(1).map((t, index) => t - streamFrames[index]);
  const paints = run.paints.filter(([t]) => t >= first && t <= last + 200);
  const changed = paints.filter(([, d]) => d !== 0);
  const longtasks = run.longtasks.filter(([t]) => t >= first - 50 && t <= last + 500);
  const shifts = run.shifts.filter(([t]) => t >= first && t <= last + 500);
  // Bursts: chunks landing in the same 16.7 ms frame.
  const perFrame = new Map();
  for (const [t, , , d] of chunks) {
    const slot = Math.floor((t - first) / 16.67);
    perFrame.set(slot, (perFrame.get(slot) ?? 0) + d);
  }
  const pin = run.pin.map(([, gap]) => gap);
  // Per-frame movement of the streaming edge while pinned: a new line lands as one jump or a glide.
  const pinnedUntil = run.anchor?.[0]?.[0] ?? Infinity;
  const edge = (run.edge ?? []).filter(([t]) => t >= first && t <= Math.min(last, pinnedUntil));
  const edgeMoves = edge
    .slice(1)
    .map(([, y], index) => Math.abs(y - edge[index][1]))
    .filter((d) => d > 0.25);
  const anchor = run.anchor.map(([, drift]) => Math.abs(drift));
  return {
    harness: run.harness,
    engine: run.engine,
    wire: {
      chunks: chunks.length,
      thoughtChunks: thoughts.length,
      chars,
      words: Math.round(chars / 5.7),
      streamSeconds: r((last - first) / 1000),
      charsPerSecond: r(chars / Math.max(0.001, (last - first) / 1000)),
      deltaChars: dist(chunks.map((entry) => entry[3])),
      frameBytes: dist(chunks.map((entry) => entry[1])),
      envelopeOverheadBytes: r(chunks.reduce((s, e) => s + e[1] - e[3], 0) / Math.max(1, chunks.length)),
      interArrivalMs: dist(gaps),
      gapsOver100ms: gaps.filter((g) => g > 100).length,
      gapsUnder2ms: gaps.filter((g) => g < 2).length,
      charsPerActiveFrame: dist([...perFrame.values()]),
    },
    display: {
      frames: streamFrames.length,
      frameGapMs: dist(frameGaps),
      over8_3: frameGaps.filter((g) => g > 8.4).length,
      over16_7: frameGaps.filter((g) => g > 16.8 * 1.25).length,
      over33: frameGaps.filter((g) => g > 33.4).length,
      framesThatChangedText: changed.length,
      shareOfFramesChanged: r(changed.length / Math.max(1, paints.length)),
      charsPerChangedFrame: dist(changed.map(([, d]) => Math.abs(d))),
      longtasks: longtasks.length,
      longtaskMs: dist(longtasks.map(([, d]) => d)),
      layoutShifts: shifts.length,
      cls: r(shifts.reduce((s, [, v]) => s + v, 0)),
      earlierBlockMoves: run.blocks?.moved ?? 0,
      earlierBlockMaxPx: r(run.blocks?.maxMovePx ?? 0),
      lastBlockShrinks: run.blocks?.shrinks ?? 0,
      lastBlockMaxShrinkPx: r(run.blocks?.maxShrinkPx ?? 0),
      edgeMovePx: dist(edgeMoves),
      edgeJumpsOver10px: edgeMoves.filter((d) => d > 10).length,
      pinnedGapPx: dist(pin),
      pinnedFramesOff: pin.filter((gap) => gap > 1).length,
      scrolledAnchorDriftPx: dist(anchor),
      code: run.code,
    },
    cpu: run.cpu,
    react: run.react ? { commits: run.react.length, commitMs: dist(run.react) } : undefined,
    parse: run.parse,
    perf: run.perf
      ? {
          commits: run.perf.commits ?? run.perf.renders,
          layout: run.perf.layout,
          react: run.perf.react,
        }
      : undefined,
  };
}

if (import.meta.url === `file://${process.argv[1]}`)
  for (const file of process.argv.slice(2)) {
    const run = JSON.parse(fs.readFileSync(file, "utf8"));
    console.log(JSON.stringify(analyze(run), null, 1));
  }
