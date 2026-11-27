// l10n-allow-file: a built-in sample chat drawn offscreen once to warm the page's code, never shown.
// The spare page's rehearsal (trading systems' "warm up before market open"): the prewarmed New Tab page
// premounts its chat view with no rows, so the row, markdown, fold and layout code first runs, unoptimized,
// on the person's first open. Once the page has painted and is idle, this folds a small sample chat through
// the real reducer (AcpmuxDirectClient.replay), draws it once offscreen, inert and unseen, then unmounts it.
// The first real open then runs code V8 has already parsed, compiled and gathered type feedback for.
// Off: `window.__cmuxSpareRehearse = "off"` (the bench's A/B, REHEARSE=off).
import { useEffect, useState } from "react";
import { AcpmuxDirectClient, type EventRecord } from "./direct";
import type { AcpmuxRow } from "./model";
import { turnView } from "./conversation/turns";
import { NO_FOLD_TOGGLES } from "./conversation/viewFolds";
import { VirtualTranscript } from "./VirtualTranscript";

const SESSION = "rehearsal:spare";
const START = Date.UTC(2026, 0, 1, 9, 0, 0);
/// How long the drawn sample stays mounted: two frames, so its layout and effects run.
const HOLD_FRAMES = 2;
/// The longest it stays mounted when no frame comes (a page hidden meanwhile).
const HOLD_BOUND_MS = 250;
/// The longest the rehearsal waits for an idle moment before it runs anyway.
const IDLE_TIMEOUT_MS = 2_000;

const update = (u: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: u },
});
const text = (value: string) =>
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: value } });
const output = (value: string) => [{ type: "content", content: { type: "text", text: value } }];

const REPLY = [
  "## Why the sample check fails",
  "",
  "The guard in `sample.ts` runs **after** the total, so one value slips past the ceiling:",
  "",
  "1. the first pass sums the values;",
  "2. the second pass checks each one, too late;",
  "   - a nested point, with a [link](https://example.com).",
  "",
  "```ts",
  "export function total(values: number[], ceiling: number): number {",
  "  let sum = 0;",
  "  for (const value of values) sum += Math.min(value, ceiling);",
  "  return sum;",
  "}",
  "```",
  "",
  "| Case | Before | After |",
  "| --- | --- | --- |",
  "| one value | 12 | 10 |",
  "| many values | 40 | 30 |",
  "",
  "> The fix moves the check into the loop.",
].join("\n");

/// The sample chat's records: prompts, a markdown reply, a thought, reads, a command with output, an edit.
export function rehearsalEvents(turns = 3): EventRecord[] {
  const steps: [dir: string, kind: string, msg: Record<string, unknown>, at: number][] = [];
  let clock = START;
  for (let turn = 1; turn <= turns; turn++) {
    steps.push(["mux", "user_message", { text: `Sample question ${turn}: why does the check fail?` }, clock]);
    steps.push(["mux", "turn_started", {}, clock]);
    clock += 500;
    steps.push([
      "in",
      "agent_thought_chunk",
      update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Reading the module first." } }),
      clock,
    ]);
    steps.push(["in", "agent_message_chunk", text("Reading the module first."), (clock += 200)]);
    for (const [id, kind, title, status, extra] of [
      [`read-${turn}`, "read", "Read src/sample.ts", "completed", { locations: [{ path: "/sample/src/sample.ts" }] }],
      [`run-${turn}`, "execute", "bun test sample", "completed", { rawInput: { command: "bun test sample" } }],
      [`edit-${turn}`, "edit", "Edit src/sample.ts", "completed", { locations: [{ path: "/sample/src/sample.ts" }] }],
    ] as const) {
      steps.push([
        "in",
        "tool_call",
        update({ sessionUpdate: "tool_call", toolCallId: id, kind, title, status: "in_progress", ...extra }),
        (clock += 300),
      ]);
      steps.push([
        "in",
        "tool_call_update",
        update({
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status,
          content: output(kind === "execute" ? "1 pass\n0 fail\nRan 1 test in 12 ms" : "export const sample = 1;\n"),
        }),
        (clock += 200),
      ]);
    }
    steps.push(["in", "agent_message_chunk", text(REPLY), (clock += 400)]);
    steps.push(["mux", "turn_result", { status: "completed" }, (clock += 100)]);
    clock += 1_000;
  }
  return steps.map(
    ([dir, kind, msg, at], index) => ({ sessionId: SESSION, seq: index + 1, at, dir, kind, msg }) as EventRecord,
  );
}

/// The sample's rows, folded by the real reducer as a replay (nothing connects or is sent).
function rehearsalRows(): readonly AcpmuxRow[] {
  const events = rehearsalEvents();
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay(SESSION, events, (snapshot) => {
    rows = snapshot.rows;
  });
  try {
    client.seekReplay(events.at(-1)?.seq ?? 0);
  } finally {
    client.close();
  }
  return rows;
}

const OFFSCREEN: React.CSSProperties = {
  position: "fixed",
  left: -10_000,
  top: 0,
  width: "100vw",
  height: "100vh",
  visibility: "hidden",
  pointerEvents: "none",
  contain: "strict",
  overflow: "hidden",
};

let rehearsed = false;
const noToggle = () => {};

/// Draws the sample once per page, when the page is idle and still shown, then nothing.
export function SpareRehearsal() {
  const [rows, setRows] = useState<ReturnType<typeof turnView> | undefined>();
  useEffect(() => {
    if (rehearsed || (window as { __cmuxSpareRehearse?: string }).__cmuxSpareRehearse === "off") return;
    let cancelled = false;
    const run = () => {
      if (cancelled || rehearsed) return;
      // A hidden page folds no snapshot (direct.ts emit), and the next show is the person's open: a parked
      // Chromium spare reports hidden once it painted (PageWebView+AwayDrawing). Rehearsing then would land
      // in the open it is meant to speed up, so a page that is hidden by now skips it.
      if (document.visibilityState === "hidden") return;
      rehearsed = true;
      setRows(turnView(rehearsalRows(), NO_FOLD_TOGGLES, { working: false, clockOffset: 0 }));
    };
    const idle =
      typeof requestIdleCallback === "function"
        ? requestIdleCallback(run, { timeout: IDLE_TIMEOUT_MS })
        : (setTimeout(run, 200) as unknown as number);
    return () => {
      cancelled = true;
      if (typeof cancelIdleCallback === "function") cancelIdleCallback(idle);
      else clearTimeout(idle);
    };
  }, []);
  useEffect(() => {
    if (!rows) return;
    let frames = HOLD_FRAMES;
    const end = () => {
      cancelAnimationFrame(frame);
      clearTimeout(bound);
      setRows(undefined);
      // When it ended, for the restart bench's A/B (it adopts only after this).
      document.documentElement.dataset.spareRehearsed = String(Math.round(performance.now()));
    };
    let frame = requestAnimationFrame(function tick() {
      if (--frames > 0) frame = requestAnimationFrame(tick);
      else end();
    });
    // A page that hides meanwhile draws no frames: the sample still goes now, not on the open's first frame.
    const bound = setTimeout(end, HOLD_BOUND_MS);
    return () => {
      cancelAnimationFrame(frame);
      clearTimeout(bound);
    };
  }, [rows]);
  if (!rows) return null;
  return (
    <div className="acpmux-spare-rehearsal" style={OFFSCREEN} aria-hidden inert data-rehearsal="">
      <VirtualTranscript
        rows={rows}
        sessionId={SESSION}
        expanded={NO_FOLD_TOGGLES}
        readOnly
        onToggleActivity={noToggle}
      />
    </div>
  );
}
