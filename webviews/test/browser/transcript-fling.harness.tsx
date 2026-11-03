// The chat's transcript as the agent pane lays it out (App.tsx), with the pane's debug API
// (debug.ts) over it as the app installs it, so a test drives the same seed and fling the
// frame pacing bench does (scripts/ci/frame-pacing/bench.sh).
import { useLayoutEffect, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { VirtualTranscript } from "../../src/agent-session/acpmux/App";
import { createAcpmuxDebug, type AcpmuxDebug } from "../../src/agent-session/acpmux/debug";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { received } from "../../src/agent-session/acpmux/incomingFixture";
import { turnView } from "../../src/agent-session/acpmux/conversation/turns";
import { PromptText } from "../../src/agent-session/acpmux/conversation/PromptText";
import { gridScale, MARK_OTHER, transcriptGap } from "../../src/agent-session/acpmux/transcriptGrid";
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
import "../../src/agent-session/acpmux/keys.css";
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

// Real prompt effects, including a short-text guess that wraps long and a long-text guess
// whose display label fits. The row's effect narrows its child after the child has committed.
const promptText = "word ".repeat(16).trim();
const showPrompt = (text: string) => text;
const showLabel = () => "Label";
const promptUpdates = new Map<string, (compact: boolean) => void>();
let promptTrace: string[] = [];
let transcriptRenders = 0;
let stopPromptTrace: (() => void) | undefined;
function PromptMeasureRow({ row }: { row: AcpmuxRow }) {
  const ref = useRef<HTMLDivElement>(null);
  const [compact, setCompact] = useState(false);
  const label = row.id === "prompt-label";
  useLayoutEffect(() => {
    ref.current!.style.width = label ? "200px" : "50px";
    promptTrace.push(`write:${row.id}`);
    promptUpdates.set(row.id, setCompact);
    return () => {
      promptUpdates.delete(row.id);
    };
  }, [row.id, label]);
  return (
    <div ref={ref} className="cv-user__bubble" data-prompt-measure={row.id} style={{ width: 400 }}>
      <PromptText rowId={row.id} text={compact ? "word" : row.text!} show={label ? showLabel : showPrompt} />
    </div>
  );
}
function PromptSentinel() {
  return <div data-prompt-sentinel="">Following row</div>;
}
const promptRegistry = {
  "prompt-measure": Object.assign(PromptMeasureRow, { measure: () => 20 }),
  "prompt-sentinel": Object.assign(PromptSentinel, { measure: () => 20 }),
};
const noActivity = () => {};
const noExpanded = new Set<string>();

export type PromptMeasureApi = {
  mount: () => void;
  compact: (compact: boolean) => { parentRenders: number; immediateReads: number };
  rerender: () => void;
  startTrace: () => void;
  finishTrace: () => { trace: string[]; parentRenders: number };
  snapshot: () => {
    gap: number;
    rows: { id: string; top: number; bottom: number; height: number; clamped: boolean; toggle: string | null }[];
  };
};
declare global {
  interface Window {
    __promptMeasure: PromptMeasureApi;
  }
}

function Transcript() {
  transcriptRenders += 1;
  const [rows, setRows] = useState<AcpmuxRow[]>([]);
  const [older, setOlder] = useState(false);
  const [batch, setBatch] = useState(false);
  const [prompts, setPrompts] = useState(false);
  const [, setRevision] = useState(0);
  window.__promptMeasure = {
    mount() {
      flushSync(() => {
        setPrompts(true);
        setRows([
          ...["prompt-wrap-0", "prompt-wrap-1", "prompt-label"].map((id) => ({
            id,
            kind: "prompt-measure",
            version: 1,
            at: 1,
            text: id === "prompt-label" ? Array.from({ length: 12 }, () => "line").join("\n") : promptText,
          })),
          { id: "prompt-sentinel", kind: "prompt-sentinel", version: 1, at: 2 },
        ]);
      });
    },
    compact(compact) {
      // Only this renderer commits: no setRows, version bump, or parent state change can
      // accidentally stand in for the queue's child-only microtask fallback.
      flushSync(() => promptUpdates.get("prompt-wrap-0")!(compact));
      return {
        parentRenders: transcriptRenders,
        immediateReads: promptTrace.filter((entry) => entry.startsWith("prompt:")).length,
      };
    },
    rerender() {
      flushSync(() => setRevision((value) => value + 1));
    },
    startTrace() {
      stopPromptTrace?.();
      promptTrace = [];
      const style = window.getComputedStyle;
      window.getComputedStyle = function (element, pseudo) {
        if (element.matches(".cv-user__text")) {
          const id = element.closest("[data-row-id]")?.getAttribute("data-row-id");
          if (id?.startsWith("prompt-")) promptTrace.push(`prompt:${id}`);
        }
        return style.call(window, element, pseudo);
      };
      stopPromptTrace = () => {
        window.getComputedStyle = style;
        stopPromptTrace = undefined;
      };
    },
    finishTrace() {
      stopPromptTrace?.();
      return { trace: [...promptTrace], parentRenders: transcriptRenders };
    },
    snapshot() {
      return {
        gap: transcriptGap(MARK_OTHER, MARK_OTHER) * gridScale(),
        rows: [...document.querySelectorAll<HTMLElement>('.acpmux-row[data-row-id^="prompt-"]')].map((row) => {
          const rect = row.getBoundingClientRect();
          return {
            id: row.dataset.rowId!,
            top: rect.top,
            bottom: rect.bottom,
            height: rect.height,
            clamped: row.querySelector(".cv-user__text")?.classList.contains("is-clamped") ?? false,
            toggle: row.querySelector(".cv-user__more")?.getAttribute("aria-expanded") ?? null,
          };
        }),
      };
    },
  };
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
      rows={batch || prompts ? rows : turnView(older ? [olderRow, ...rows] : rows, new Set())}
      registry={prompts ? promptRegistry : batch ? batchRegistry : undefined}
      sessionId="session-1"
      jumpButton
      onToggleActivity={noActivity}
      expanded={noExpanded}
    />
  );
}
createRoot(root).render(<Transcript />);
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
