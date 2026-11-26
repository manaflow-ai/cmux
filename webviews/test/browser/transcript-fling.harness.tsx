// The chat's transcript as the agent pane lays it out (App.tsx), with the pane's debug API
// (debug.ts) over it as the app installs it, so a test drives the same seed and fling the
// frame pacing bench does (scripts/ci/frame-pacing/bench.sh).
import { useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { createAcpmuxDebug, type AcpmuxDebug } from "../../src/agent-session/acpmux/debug";
import * as acpmuxPerfModule from "../../src/agent-session/acpmux/perf";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { received } from "../../src/agent-session/acpmux/incomingFixture";
import { turnView, turnViewFrom, type TurnView } from "../../src/agent-session/acpmux/conversation/turns";
// The pane's styles, as its dev entry loads them (acpmux/dev.tsx).
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
import "../../src/agent-session/acpmux/composerAttachments.css";
import "../../src/agent-session/acpmux/markdownField.css";
import "../../src/agent-session/acpmux/modelPicker.css";
import "../../src/agent-session/acpmux/newtab/screen.css";
import "../../src/agent-session/acpmux/newtab/history.css";
import "../../src/agent-session/acpmux/threadMinimap/threadMinimap.css";

const root = document.getElementById("root")!;
document.documentElement.style.height = document.body.style.height = "100%";
document.body.style.margin = "0";
Object.assign(root.style, { height: "100%", display: "flex", flexDirection: "column" });

let current: AcpmuxRow[] = [];
let show: (rows: AcpmuxRow[]) => void = () => {};
const olderRow: AcpmuxRow = {
  id: "prefetched-older",
  kind: "user",
  text: "Prefetched question",
  version: 1,
  at: 1,
};
// Mounting rich content can write layout from a child effect (code cards do this). Observe the
// ordering in the real virtualizer, without adding a measurement seam to product code.
let measureTrace: string[] = [];
function BatchMeasureRow({ row }: { row: AcpmuxRow }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    ref.current!.style.height = `${Number(row.text)}px`;
    measureTrace.push(`write:${row.id}`);
  }, [row.id, row.version, row.text]);
  return (
    <div ref={ref} data-batch-height={row.text}>
      Measured content
    </div>
  );
}
const batchRegistry = { "batch-measure": Object.assign(BatchMeasureRow, { measure: () => 4 }) };

/// What the shaping cost: updates shaped, what each reused, and the chat's length.
type ShapedCount = { updates: number; reused: number[]; source: number };

/// One empty fold set, shared by every render. `turnViewFrom` reuses the view it is given only
/// while the folds are the same object, so a fresh `Set` per render would make each update look
/// like the reader had just folded something and reshape the whole chat: the very cost `app`
/// shaping exists to avoid.
const NO_FOLDS: ReadonlySet<string> = new Set<string>();

/// The rows the transcript draws, shaped as `mode` says. `app` keeps the last view in `drawn` and
/// builds the next one on it, so a streamed chunk reshapes the rows that changed instead of all of
/// them; it records what each update reused so a test can show the shaping stayed incremental.
function shapeRows(
  mode: Shaping,
  drawn: { current: TurnView | undefined },
  shaped: { current: ShapedCount },
  source: readonly AcpmuxRow[],
  expanded: ReadonlySet<string>,
): AcpmuxRow[] {
  if (mode === "scratch") return turnView(source, expanded);
  const view = turnViewFrom(source, expanded, {}, drawn.current);
  drawn.current = view;
  const count = shaped.current;
  count.updates += 1;
  count.source = source.length;
  count.reused.push(view.reusedRows ?? 0);
  return view.rows;
}

/// How the harness shapes the rows it hands the transcript.
/// - `scratch` (the default, and what every caller got before): `turnView` over the whole chat on
///   every render, starting from nothing. A streamed chunk then reshapes every row the chat holds.
/// - `app`: `turnViewFrom` given the view it drew last, which is what the pane itself does
///   (App.tsx `shapeFrom`, which passes `last?.turns`), so an update costs the rows that changed
///   and the unchanged ones stay the same objects.
/// A bench or test that measures a streaming chat has to ask for `app`: on `scratch` it measures
/// the harness reshaping 100k rows a chunk, not what the app pays (#44389 read that cost and said
/// so). The default is left alone so every existing caller reads what it read before.
type Shaping = "scratch" | "app";

function Transcript() {
  const [rows, setRows] = useState<AcpmuxRow[]>([]);
  const [older, setOlder] = useState(false);
  const [batch, setBatch] = useState(false);
  const [shaping, setShaping] = useState<Shaping>("scratch");
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(NO_FOLDS);
  /// The thread minimap, on as the pane has it. A bench turns it off to tell whether a frame's cost
  /// is the transcript's or the rail's, which reading either component cannot settle.
  const [minimap, setMinimap] = useState(true);
  /// The view drawn last, as the pane keeps it (`lastTurns`), so the next one builds on it.
  const drawn = useRef<TurnView | undefined>(undefined);
  /// What the shaping cost, for a test to read: how many updates were shaped and how many rows each
  /// reused from the view before it (`TurnView.reusedRows`).
  const shaped = useRef<ShapedCount>({
    updates: 0,
    reused: [],
    source: 0,
  });
  (window as unknown as { __shaping: (mode: Shaping) => void }).__shaping = (mode) => {
    drawn.current = undefined;
    shaped.current = { updates: 0, reused: [], source: 0 };
    setShaping(mode);
  };
  (window as unknown as { __expandWorked: (open: boolean) => void }).__expandWorked = (open) =>
    setExpanded(open ? new Set(["worked-worked-resize-user"]) : NO_FOLDS);
  (window as unknown as { __shapingStats: () => unknown }).__shapingStats = () => ({ ...shaped.current });
  (window as unknown as { __minimap: (shown: boolean) => void }).__minimap = setMinimap;
  (window as unknown as { __batchMeasure: (version: number) => string[] }).__batchMeasure = (version) => {
    measureTrace = [];
    const read = Element.prototype.getBoundingClientRect;
    Element.prototype.getBoundingClientRect = function (this: Element) {
      const id = this.getAttribute("data-row-id");
      if (id?.startsWith("batch-")) measureTrace.push(`${this.isConnected ? "read" : "stale"}:${id}`);
      return read.call(this);
    };
    try {
      flushSync(() => {
        setBatch(true);
        setRows(
          Array.from({ length: version === 1 ? 12 : 11 }, (_, index) => ({
            id: `batch-${index + (version === 1 ? 0 : 1)}`,
            kind: "batch-measure",
            version,
            at: index,
            text: String(12 + index + version * 3),
          })),
        );
      });
      return [...measureTrace];
    } finally {
      Element.prototype.getBoundingClientRect = read;
    }
  };
  (window as unknown as { __showOlder: (shown: boolean) => void }).__showOlder = setOlder;
  show = setRows;
  return (
    <VirtualTranscript
      rows={batch ? rows : shapeRows(shaping, drawn, shaped, older ? [olderRow, ...rows] : rows, expanded)}
      registry={batch ? batchRegistry : undefined}
      sessionId="session-1"
      jumpButton
      showMinimap={minimap}
      onToggleActivity={() => {}}
      expanded={new Set()}
    />
  );
}
createRoot(root).render(<Transcript />);
// The pane's own measuring object, for a bench to enable and read. A dev server serves perf.ts at
// its source URL, so a bench used to `import("/src/agent-session/acpmux/perf.ts")`; a build has no
// such route (the module is inside a chunk), and that import failed with "Failed to fetch
// dynamically imported module", which is why a production run printed no numbers. The page hands it
// over instead, the same object the pane itself uses.
(window as unknown as { __acpmuxPerf: typeof acpmuxPerfModule }).__acpmuxPerf = acpmuxPerfModule;
(window as unknown as { __debug: AcpmuxDebug }).__debug = createAcpmuxDebug({
  replaceRows(rows) {
    current = rows;
    show(rows);
  },
  rowCount: () => current.length,
});

// Synthetic reproduction of a received card collapsing while the last reply keeps streaming.
let foldStreamVersion = 0;
Object.assign(window, {
  __seedFoldStream() {
    if (current.length !== 9000) throw new Error("seed the unchanged 3000-turn fixture first");
    const at = current.length - 9;
    current = [...current];
    current[at] = received("gap-incoming", current[at]!.at, {
      id: "synthetic-gap-message",
      thread: "synthetic-gap-thread",
      sender: "cli",
      name: "synthetic-render-probe",
      body: Array.from(
        { length: 32 },
        (_, index) => `Synthetic received line ${index}: row boxes remain adjacent.`,
      ).join("\n\n"),
    });
    show(current);
  },
  __stepFoldStream() {
    foldStreamVersion += 1;
    const at = current.length - 2;
    current = [...current];
    current[at] = {
      ...current[at]!,
      version: foldStreamVersion + 1,
      streaming: true,
      text:
        `Streaming synthetic reply ${foldStreamVersion}. ` +
        "The received card can collapse while this reply changes. ".repeat(4),
    };
    show(current);
  },
});
