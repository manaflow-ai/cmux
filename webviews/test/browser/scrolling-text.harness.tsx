// l10n-allow-file: performance fixture content, not shipped UI.
// A long, rich VirtualTranscript used by scrolling-text-perf.test.ts. The fixture deliberately keeps
// hundreds of turns with Markdown, code, tool output, images and edit diffs mounted in the real agent
// transcript so scroll measurements exercise the same virtualization and rails as the app.
import { useState } from "react";
import { createRoot } from "react-dom/client";
import { spans } from "./streaming-text.clock";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import type { AcpmuxActivity, AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { round2 } from "../../src/agent-session/acpmux/perf";

import "../../src/pages/shared/desktop.css";
import "../../src/ui/popupSurface.css";
import "../../src/agent-session/shared/styles.css";
import "../../src/agent-session/acpmux/styles.css";
import "katex/dist/katex.min.css";
import "../../src/agent-session/acpmux/conversation/conversation.css";
import "../../src/agent-session/acpmux/chips/chips.css";
import "../../src/agent-session/acpmux/previewCard/previewCard.css";
import "../../src/agent-session/acpmux/changes/changes.css";
import "../../src/agent-session/acpmux/turnChanges/turnChanges.css";
import "../../src/agent-session/acpmux/summary/summary.css";
import "../../src/agent-session/acpmux/subagents/subagents.css";
import "../../src/agent-session/acpmux/header/header.css";
import "../../src/agent-session/acpmux/composerControls.css";
import "../../src/agent-session/acpmux/composerStates.css";
import "../../src/agent-session/acpmux/composerLocation.css";
import "../../src/agent-session/acpmux/bottomStack.css";
import "../../src/agent-session/acpmux/composerAttachments.css";
import "../../src/agent-session/acpmux/markdownField.css";
import "../../src/agent-session/acpmux/modelPicker.css";
import "../../src/agent-session/acpmux/keys.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import "../../src/agent-session/acpmux/newtab/history.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

const TURN_COUNT = 320;
const STREAM_ID = `t${TURN_COUNT - 1}-answer`;
const STREAM_SOURCE =
  "The streamed answer continues through the same transcript while the reader scrolls. It includes a short " +
  "paragraph, a code sample, and a tool result so the scroll path stays realistic.\n\n" +
  "```ts\nconst retained = virtualTranscript.visibleRange(scrollTop);\nawait retained.draw();\n```\n";
const IMAGE =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='240' height='96' viewBox='0 0 240 96'%3E%3Crect width='240' height='96' fill='%23252a36'/%3E%3Cpath d='M0 74L64 30l44 28 34-20 98 48H0z' fill='%236b89bd'/%3E%3Ccircle cx='184' cy='28' r='12' fill='%23e5b567'/%3E%3C/svg%3E";

const richMarkdown = (turn: number) =>
  `## Transcript turn ${turn}\n\n` +
  "The agent checked the queue and kept the reader's anchor stable while it worked. " +
  "This paragraph is long enough to wrap in the normal pane width.\n\n" +
  "- preserve the scroll anchor\n- render only the visible window\n- keep the rail incremental\n\n" +
  "```ts\n" +
  `export function step${turn}(rows: readonly Row[]): Row[] {\n` +
  "  return rows.filter((row) => row.visible).map((row) => ({ ...row, measured: true }));\n" +
  "}\n```\n\n" +
  "| check | result |\n| --- | --- |\n| frame budget | stable |\n| layout work | bounded |\n";

function toolActivity(turn: number): AcpmuxActivity {
  const tool: NonNullable<AcpmuxActivity["tool"]> = {
    id: `tool-${turn}`,
    title: turn % 7 === 0 ? "Edit transcript renderer" : "Inspect stream and layout",
    kind: turn % 7 === 0 ? "edit" : "execute",
    status: "completed",
    command: turn % 7 === 0 ? "apply_patch webviews/src/agent-session/acpmux/App.tsx" : "bun test transcript",
    output: `turn ${turn}: checked 12 visible rows and retained the measured anchor`,
  };
  if (turn % 7 === 0)
    tool.diffs = [
      {
        path: `src/virtual/row-${turn}.ts`,
        oldText: "return rows.map(render);\n",
        newText: "return visibleRows.map(render);\n",
        line: 42,
      },
    ];
  if (turn % 11 === 0) tool.images = [IMAGE];
  return { kind: "tool", text: "", tool };
}

function fixture(): { rows: AcpmuxRow[]; expanded: Set<string> } {
  const rows: AcpmuxRow[] = [];
  const expanded = new Set<string>();
  for (let turn = 0; turn < TURN_COUNT; turn += 1) {
    const at = turn * 10_000;
    const user = { id: `t${turn}-user`, version: 1, at, kind: "user", text: `Review transcript turn ${turn}` } as AcpmuxRow;
    rows.push(user);
    rows.push({
      id: `t${turn}-activity`,
      version: 1,
      at: at + 1,
      kind: "activity",
      items: [toolActivity(turn)],
    });
    rows.push({
      id: `t${turn}-answer`,
      version: 1,
      at: at + 2,
      kind: "assistant",
      text: richMarkdown(turn),
    });
    rows.push({
      id: `t${turn}-end`,
      version: 1,
      at: at + 3,
      kind: "turnSummary",
      status: "completed",
      durationMs: 4_000,
    } as AcpmuxRow);
    expanded.add(`worked-${user.id}`);
  }
  return { rows, expanded };
}

const { rows: INITIAL_ROWS, expanded: EXPANDED } = fixture();
const rowVersion = (row: AcpmuxRow, text: string, version: number): AcpmuxRow => ({
  ...row,
  text,
  version,
  streaming: true,
});
let updateRows: (rows: AcpmuxRow[], streaming: boolean) => void = () => {};

function Pane() {
  const [state, setState] = useState({ rows: INITIAL_ROWS, streaming: false });
  updateRows = (rows, streaming) => setState({ rows, streaming });
  const [dock, setDock] = useState<HTMLElement | null>(null);
  return (
    <div className="acpmux-shell">
      <div className="acpmux-main" data-dock="float">
        <div className="acpmux-stage">
          <header className="acpmux-header" />
          <VirtualTranscript
            rows={turnView(state.rows, EXPANDED, { working: state.streaming })}
            sessionId="scrolling-text"
            working={state.streaming}
            jumpButton
            dock={dock}
            onToggleActivity={() => {}}
            expanded={EXPANDED}
          />
        </div>
        <div ref={setDock} className="acpmux-dock">
          <form className="acpmux-composer" onSubmit={(event) => event.preventDefault()}>
            <div className="acpmux-composer-strip-placeholder" />
            <div className="acpmux-composer-box" style={{ height: 88 }} />
          </form>
        </div>
      </div>
    </div>
  );
}

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });
createRoot(root).render(<Pane />);

type Phase = "constant" | "fling";
type Frame = { at: number; interval: number };
type LongEntry = { at: number; duration: number; blocking: number; styleAndLayout?: number; scripts?: number };
type ScrollReport = {
  phase: Phase;
  streaming: boolean;
  turns: number;
  rows: number;
  frames: { count: number; p50: number; p95: number; p99: number; max: number; over16_7: number; over33: number };
  longAnimationFrames: { count: number; p50: number; p95: number; p99: number; max: number; entries: LongEntry[] } | null;
  longTasks: { count: number; totalMs: number; p50: number; p95: number; p99: number; max: number; entries: { at: number; duration: number }[] } | null;
  scriptMs: { p50: number; p95: number; p99: number; max: number };
  scrollTop: { start: number; end: number; max: number };
  input: "synthetic-scrollTop+scroll";
};
const frameStats = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (p: number) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1))] ?? 0;
  return { p50: round2(at(0.5)), p95: round2(at(0.95)), p99: round2(at(0.99)), max: round2(sorted.at(-1) ?? 0) };
};
const spanOverlap = (windows: [number, number][], from: number, to: number) =>
  windows.reduce((sum, [start, end]) => sum + Math.max(0, Math.min(end, to) - Math.max(start, from)), 0);
const frameWait = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));

async function run({ phase, streaming }: { phase: Phase; streaming: boolean }): Promise<ScrollReport> {
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) throw new Error("transcript scroller did not mount");
  const max = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
  scroller.scrollTop = phase === "constant" ? 0 : Math.min(max, Math.max(0, max * 0.12));
  await frameWait();
  const spanAt = spans.length;
  const frames: Frame[] = [];
  const loaf: LongEntry[] = [];
  const loafSupported = PerformanceObserver.supportedEntryTypes?.includes("long-animation-frame") ?? false;
  const loafObserver = loafSupported
    ? new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as (PerformanceEntry & {
          blockingDuration?: number;
          renderStart?: number;
          styleAndLayoutStart?: number;
          scripts?: { duration?: number }[];
        })[])
          loaf.push({
            at: round2(entry.startTime),
            duration: round2(entry.duration),
            blocking: round2(entry.blockingDuration ?? 0),
            styleAndLayout:
              entry.renderStart !== undefined && entry.styleAndLayoutStart !== undefined
                ? round2(entry.styleAndLayoutStart - entry.renderStart)
                : undefined,
            scripts: entry.scripts?.reduce((sum, script) => sum + (script.duration ?? 0), 0),
          });
      })
    : undefined;
  loafObserver?.observe({ type: "long-animation-frame", buffered: false });
  const longTasks: { at: number; duration: number }[] = [];
  const longTaskObserver = PerformanceObserver.supportedEntryTypes?.includes("longtask")
    ? new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) longTasks.push({ at: entry.startTime, duration: entry.duration });
      })
    : undefined;
  longTaskObserver?.observe({ type: "longtask", buffered: false });
  let streamTimer: ReturnType<typeof setTimeout> | undefined;
  let streamText = INITIAL_ROWS.find((row) => row.id === STREAM_ID)?.text ?? "";
  let streamVersion = 1;
  let running = true;
  if (streaming) {
    const append = () => {
      if (!running) return;
      streamText += STREAM_SOURCE.slice(streamText.length % STREAM_SOURCE.length, (streamText.length % STREAM_SOURCE.length) + 18);
      streamVersion += 1;
      const next = INITIAL_ROWS.map((row) => (row.id === STREAM_ID ? rowVersion(row, streamText, streamVersion) : row));
      updateRows(next, true);
      streamTimer = setTimeout(append, 48);
    };
    streamTimer = setTimeout(append, 48);
  }
  let previous = performance.now();
  const startTop = scroller.scrollTop;
  let frame = 0;
  const sample = (time: number) => {
    frames.push({ at: time, interval: time - previous });
    previous = time;
  };
  try {
    await new Promise<void>((resolve) => {
      const tick = (time: number) => {
        sample(time);
        const progress = (frame + 1) / 180;
        const delta = phase === "constant" ? Math.max(1, max * 0.8 / 180) : Math.max(2, max * 0.16 * 0.42 ** frame);
        const next = Math.min(max, scroller.scrollTop + delta);
        scroller.dispatchEvent(new WheelEvent("wheel", { bubbles: true, deltaY: delta, deltaMode: 0 }));
        scroller.scrollTop = next;
        scroller.dispatchEvent(new Event("scroll", { bubbles: true }));
        frame += 1;
        if (frame >= 180 || progress >= 1) resolve();
        else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    // Keep the final frame and any streamed render in the report, then stop all observers/timers.
    await frameWait();
  } finally {
    running = false;
    if (streamTimer !== undefined) clearTimeout(streamTimer);
    if (streaming) updateRows(INITIAL_ROWS, false);
    loafObserver?.takeRecords();
    longTaskObserver?.takeRecords();
    loafObserver?.disconnect();
    longTaskObserver?.disconnect();
  }
  const intervals = frames.slice(1).map((entry) => entry.interval);
  const measuredSpans = spans.slice(spanAt);
  const script = frames.slice(1).map((entry, index) => {
    const from = frames[index]!.at;
    return spanOverlap(measuredSpans, from, entry.at);
  });
  const loafValues = loaf.map((entry) => entry.duration);
  return {
    phase,
    streaming,
    turns: TURN_COUNT,
    rows: INITIAL_ROWS.length,
    frames: { count: intervals.length, ...frameStats(intervals), over16_7: intervals.filter((ms) => ms > 16.7).length, over33: intervals.filter((ms) => ms > 33).length },
    longAnimationFrames: loafSupported
      ? { count: loaf.length, ...frameStats(loafValues), entries: loaf.slice(0, 40) }
      : null,
    longTasks: longTaskObserver
      ? {
          count: longTasks.length,
          totalMs: round2(longTasks.reduce((sum, entry) => sum + entry.duration, 0)),
          ...frameStats(longTasks.map((entry) => entry.duration)),
          entries: longTasks.slice(0, 40),
        }
      : null,
    scriptMs: frameStats(script),
    scrollTop: { start: round2(startTop), end: round2(scroller.scrollTop), max: round2(max) },
    input: "synthetic-scrollTop+scroll",
  };
}

(window as unknown as { __scrollPerf: { run: typeof run } }).__scrollPerf = { run };
