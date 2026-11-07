// l10n-allow-file: fixture command output, not shipped UI.
// A running command's output update reaches only the row that draws it (liveToolOutput.ts): the
// client says which row changed (direct.ts OrderedRows), the pane tells an output-only update
// apart (`toolOutputOnly`) without reading the other rows, and the row reads the newer output
// (`useLiveToolRow`). Leo, 2026-11-04: "It should just never, ever ... be [freaking] acceptable
// for there to be some sort of linear time growth degradation".
import { afterEach, expect, test } from "bun:test";
import { act, memo } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { OrderedRows } from "./direct";
import { liveToolOutput, toolOutputOnly, useLiveToolRow } from "./liveToolOutput";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { markOneRowChange, oneRowChange, oneRowChangeFrom } from "./rowChanges";
import { ToolActivityRow } from "./rows/ToolActivityRow";
import type { RowProps } from "./rows/rowProps";
import { RowContent } from "./VirtualTranscript";
import { sendEntries, toolGroups } from "./conversation/toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const call = (output: string | undefined, extra: Partial<Tool> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "Run bun test",
  tool: {
    id: "call-1",
    title: "Run bun test",
    kind: "execute",
    status: "in_progress",
    command: "bun test",
    output,
    ...extra,
  },
});
const activity = (item: AcpmuxActivity, version = 1): AcpmuxRow => ({
  id: "activity-1",
  version,
  at: 1,
  kind: "activity",
  toolCount: 1,
  items: [item],
  streaming: true,
});
const prompt: AcpmuxRow = { id: "user-1", version: 1, at: 0, kind: "user", text: "run the tests" };
const snapshot = (rows: AcpmuxRow[], rest: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot =>
  ({ type: "snapshot", protocolVersion: 1, rows, sessions: [], ...rest }) as unknown as AcpmuxSnapshot;

/// Two snapshots whose rows differ in the activity row alone, as the client marks them.
function update(before: AcpmuxActivity, after: AcpmuxActivity) {
  const previous = snapshot([prompt, activity(before)]);
  const rows = [prompt, activity(after, 2)];
  markOneRowChange(rows, previous.rows, 1);
  return { previous, next: snapshot(rows, { sessions: previous.sessions }) };
}

test("an output that grows with plain text is an output-only update", () => {
  const { previous, next } = update(call("pass 1\n"), call("pass 1\npass 2\n"));
  expect(toolOutputOnly(previous, next)).toEqual({ id: "call-1", output: "pass 1\npass 2\n", before: "pass 1\n" });
});

test("anything else goes through the pane", () => {
  const cases: [string, AcpmuxActivity, AcpmuxActivity][] = [
    // A link may be the header's Preview or a pull request in Session Info.
    ["a link", call("pass 1\n"), call("pass 1\n  Local: http://localhost:5173/\n")],
    ["a #N", call("pass 1\n"), call("pass 1\nfixed #12\n")],
    ["a repository flag", call("pass 1\n"), call("pass 1\ngh pr view -R manaflow-ai/cmux\n")],
    // A call's first output makes it more than a draft (toolGroups.ts isDraftCall).
    ["the first output", call(undefined), call("pass 1\n")],
    ["a replaced output", call("pass 1\n"), call("pass 2\npass 3\n")],
    ["a status", call("pass 1\n"), call("pass 1\npass 2\n", { status: "completed" })],
    ["another field", call("pass 1\n"), call("pass 1\npass 2\n", { exitCode: 0 })],
    ["another tool", call("pass 1\n", { kind: "read" }), call("pass 1\npass 2\n", { kind: "read" })],
    // A send's output says whether it went (acpmuxSends.ts).
    [
      "a send",
      call("ok\n", { command: "acpmux send lane-a 'hi'" }),
      call("ok\nqueued\n", { command: "acpmux send lane-a 'hi'" }),
    ],
  ];
  for (const [name, before, after] of cases) {
    // One pair per case: a previous and next from two pairs are unlinked and say nothing.
    const pair = update(before, after);
    expect(toolOutputOnly(pair.previous, pair.next), name).toBeUndefined();
  }
  // Another snapshot field changed with it.
  const { previous, next } = update(call("pass 1\n"), call("pass 1\npass 2\n"));
  expect(toolOutputOnly(previous, { ...next, isWorking: true })).toBeUndefined();
  // Rows the client did not mark are never compared row by row.
  expect(toolOutputOnly(previous, snapshot([prompt, activity(call("pass 1\npass 2\n"), 2)]))).toBeUndefined();
});

test("a batch send's output updates go through the pane, so each recipient's row takes its state", () => {
  // One call sends to three sessions; its output says, a line per recipient, whether each went.
  const command = "for s in lane-a lane-b lane-c; do acpmux send --no-wait $s 'Merged.' 2>&1 | tail -1; done";
  const batch = (output: string) => call(output, { command });
  const steps = ["queued\n", "queued\ndelivered\n", "queued\ndelivered\nacpmux: not_found: no session lane-c\n"];
  const states = (item: AcpmuxActivity) =>
    sendEntries(toolGroups([item])).map(({ send }) => [send.target, send.state, send.delivery]);
  expect(states(batch(steps[0]!))).toEqual([
    ["lane-a", "sent", "queued"],
    ["lane-b", "sending", undefined],
    ["lane-c", "sending", undefined],
  ]);
  for (let at = 1; at < steps.length; at += 1) {
    const before = batch(steps[at - 1]!);
    const after = batch(steps[at]!);
    // Plain text growing the output, as a fast-path update would be, yet the rows read it.
    expect(states(after)).not.toEqual(states(before));
    const pair = update(before, after);
    expect(toolOutputOnly(pair.previous, pair.next), steps[at]).toBeUndefined();
  }
  expect(states(batch(steps[2]!))).toEqual([
    ["lane-a", "sent", "queued"],
    ["lane-b", "sent", "delivered"],
    ["lane-c", "failed", undefined],
  ]);
  // A command that only names acpmux, sending nothing, still streams on the fast path.
  const tail = (output: string) => call(output, { command: "acpmux logs lane-a --follow" });
  const plain = update(tail("line 1\n"), tail("line 1\nline 2\n"));
  expect(toolOutputOnly(plain.previous, plain.next)).toEqual({
    id: "call-1",
    output: "line 1\nline 2\n",
    before: "line 1\n",
  });
});

test("a who-else answer's or a dispatch's output updates go through the pane", () => {
  const whoElse = (output: string) => call(output, { command: "acpmux who-else --json src/app.ts" });
  const answer = '{"schema":"acpmux.who-else.v1","sessions":[]}';
  const pending = update(whoElse("{\n"), whoElse(`{\n${answer.slice(1)}`));
  expect(toolOutputOnly(pending.previous, pending.next)).toBeUndefined();
  const dispatch = (output: string) => call(output, { command: "acpmux dispatch --to lane-a brief.md" });
  const sent = update(dispatch("sending\n"), dispatch("sending\nok\n"));
  expect(toolOutputOnly(sent.previous, sent.next)).toBeUndefined();
});

test("the client marks a snapshot that changed one row in place, and only that", () => {
  const rows = new OrderedRows();
  rows.current = 1;
  rows.set(prompt.id, prompt);
  rows.current = 2;
  rows.set("activity-1", activity(call("pass 1\n")));
  const first = rows.sorted();
  rows.current = 3;
  rows.set("activity-1", activity(call("pass 1\npass 2\n"), 2), false);
  const second = rows.sorted();
  expect(oneRowChangeFrom(second, first)).toBe(1);
  // Two rows changed: unmarked.
  rows.current = 4;
  rows.set(prompt.id, { ...prompt, version: 2 });
  rows.set("activity-1", activity(call("pass 1\npass 2\npass 3\n"), 3), false);
  expect(oneRowChange(rows.sorted())).toBeUndefined();
  // A new row: unmarked.
  rows.current = 5;
  rows.set("assistant-1", { id: "assistant-1", version: 1, at: 2, kind: "assistant", text: "done" });
  expect(oneRowChange(rows.sorted())).toBeUndefined();
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

function mount(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

test("the row that draws the call alone renders its newer output, until the pane draws again", () => {
  const container = mount();
  const renders = { running: 0, other: 0 };
  function Row({ row, name, live }: { row: AcpmuxRow; name: "running" | "other"; live: boolean }) {
    const drawn = useLiveToolRow(row, live);
    renders[name] += 1;
    return <pre data-name={name}>{drawn.items?.[0]?.tool?.output ?? drawn.text}</pre>;
  }
  const other: AcpmuxRow = { ...activity(call("pass 1\n", { id: "call-2" })), id: "activity-2" };
  const draw = (running: AcpmuxRow, live = true) =>
    act(() =>
      root!.render(
        <>
          <Row row={running} name="running" live={live} />
          <Row row={other} name="other" live={live} />
        </>,
      ),
    );
  root = createRoot(container);
  const drawn = activity(call("pass 1\n"));
  draw(drawn);
  const text = () => container.querySelector('[data-name="running"]')!.textContent;
  expect(text()).toBe("pass 1\n");
  renders.running = renders.other = 0;
  act(() => liveToolOutput.set("call-1", "pass 1\npass 2\n", "pass 1\n"));
  act(() => liveToolOutput.set("call-1", "pass 1\npass 2\npass 3\n", "pass 1\npass 2\n"));
  expect(text()).toBe("pass 1\npass 2\npass 3\n");
  expect(renders).toEqual({ running: 2, other: 0 });
  // The pane draws a newer snapshot (its row holds the newest output), and that draw commits.
  const epoch = liveToolOutput.redraw();
  draw(activity(call("pass 1\npass 2\npass 3\npass 4\n"), 4));
  liveToolOutput.settle(epoch);
  expect(text()).toBe("pass 1\npass 2\npass 3\npass 4\n");
  expect(liveToolOutput.size).toBe(0);
  // An update after that draw is told from its rows.
  act(() =>
    liveToolOutput.set("call-1", "pass 1\npass 2\npass 3\npass 4\npass 5\n", "pass 1\npass 2\npass 3\npass 4\n"),
  );
  expect(text()).toBe("pass 1\npass 2\npass 3\npass 4\npass 5\n");
  // A transcript that is not the pane's live one (a replay) keeps its own rows.
  draw(drawn, false);
  expect(text()).toBe("pass 1\n");
  liveToolOutput.settle(liveToolOutput.redraw());
});

test("a client's change record holds no earlier snapshot, however many updates it makes", () => {
  const rows = new OrderedRows();
  rows.current = 1;
  rows.set(prompt.id, prompt);
  rows.current = 2;
  let output = "pass 0\n";
  rows.set("activity-1", activity(call(output)));
  const published: AcpmuxRow[][] = [rows.sorted()];
  for (let tick = 1; tick <= 50; tick += 1) {
    rows.current = 2 + tick;
    output += `pass ${tick}\n`;
    rows.set("activity-1", activity(call(output), 1 + tick), false);
    published.push(rows.sorted());
  }
  const newest = published.at(-1)!;
  const earlier = new Set<unknown>(published.slice(0, -1));
  // Everything the newest snapshot's record reaches: a chain of earlier snapshots kept every one of
  // them alive (5,000 rows and 1,000 updates kept 1,001 arrays).
  const seen = new Set<unknown>();
  const walk = (value: unknown): void => {
    if (value === null || typeof value !== "object" || seen.has(value)) return;
    seen.add(value);
    for (const key of Object.keys(value)) walk((value as Record<string, unknown>)[key]);
  };
  expect(oneRowChange(newest)).toBeDefined();
  walk(oneRowChange(newest));
  expect([...seen].filter((value) => earlier.has(value)).length).toBe(0);
});

test("a running command's row drawn by its memoized renderer shows the newest output on every update", () => {
  const container = mount();
  // ToolActivityRow's own comparator (id, version, session): the one the transcript draws with.
  const Probe = memo(
    function Probe({ row }: RowProps) {
      return <pre>{row.items?.[0]?.tool?.output}</pre>;
    },
    (ToolActivityRow as unknown as { compare: (a: RowProps, b: RowProps) => boolean }).compare,
  );
  root = createRoot(container);
  let output = "pass 1\n";
  const row = activity(call(output), 10);
  act(() =>
    root!.render(<RowContent Component={Probe} liveTools row={row} onToggleActivity={() => {}} expanded={false} />),
  );
  expect(container.textContent).toBe(output);
  for (let tick = 2; tick <= 5; tick += 1) {
    const before = output;
    output += `pass ${tick}\n`;
    act(() => liveToolOutput.set("call-1", output, before));
    expect(container.textContent, `update ${tick - 1}`).toBe(output);
  }
  liveToolOutput.settle(liveToolOutput.redraw());
});
