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
import { liveToolOutput, rowsWithLiveOutput, toolOutputOnly, useLiveToolRow } from "./liveToolOutput";
import { transcriptRangeText } from "./conversation/transcriptCopy";
import { type ChatFind, useChatFind } from "./conversation/chatFind";
import { copyRow } from "./header/copyRow";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { markOneRowChange, oneRowChange, oneRowChangeFrom } from "./rowChanges";
import { ToolActivityRow } from "./rows/ToolActivityRow";
import type { RowProps } from "./rows/rowProps";
import { RowContent } from "./VirtualTranscript";
import { sendEntries, toolGroups } from "./conversation/toolGroups";
import { latestLocalUrl } from "./conversation/previewUrl";

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

/// Each step's update in turn for call `id`, as the pane reads them: whether it took the fast path,
/// and the Preview the pane would show from the output it drew (its own when the update went through
/// it, else the one it drew last).
function stream(id: string, steps: readonly string[]) {
  const fast: boolean[] = [];
  let drawn = steps[0]!;
  for (let at = 1; at < steps.length; at += 1) {
    const pair = update(call(steps[at - 1]!, { id }), call(steps[at]!, { id }));
    const only = toolOutputOnly(pair.previous, pair.next) !== undefined;
    fast.push(only);
    if (!only) drawn = steps[at]!;
  }
  return { fast, preview: latestLocalUrl([drawn]) };
}

test("a link still being printed sends each update through the pane until it ends, colour codes and all", () => {
  // A dev server colours the port: the scheme is well before the second update's text.
  const colored = stream("url-colored", [
    "vite v5\n",
    "vite v5\n  Local: http://localhost:\x1b[1m",
    "vite v5\n  Local: http://localhost:\x1b[1m5173\x1b[0m/\n",
  ]);
  expect(colored).toEqual({ fast: [false, false], preview: "http://localhost:5173/" });
  // A path that goes on in the next update.
  const path = stream("url-path", [
    "start\n",
    "start\nopen http://localhost:5173/ad",
    "start\nopen http://localhost:5173/admin\n",
  ]);
  expect(path).toEqual({ fast: [false, false], preview: "http://localhost:5173/admin" });
  // A long address over three updates, each past the earlier text's last 16 characters.
  const long = "http://localhost:5173/" + "a".repeat(40) + "/" + "b".repeat(40) + "/page";
  const three = stream("url-long", [
    "serving\n",
    `serving\nLocal: ${long.slice(0, 30)}`,
    `serving\nLocal: ${long.slice(0, 70)}`,
    `serving\nLocal: ${long}\n`,
  ]);
  expect(three).toEqual({ fast: [false, false, false], preview: long });
  // A link the pane never saw begin (read first from its last word) counts the same.
  const pair = update(
    call("x\nLocal: http://localhost:\x1b[1m", { id: "url-unseen" }),
    call("x\nLocal: http://localhost:\x1b[1m5173\x1b[0m/\n", { id: "url-unseen" }),
  );
  expect(toolOutputOnly(pair.previous, pair.next)).toBeUndefined();
});

test("plain output, and output after a link has ended, still takes the fast path", () => {
  expect(
    stream("plain", ["pass 1\n", "pass 1\npass 2", "pass 1\npass 2 done\n", "pass 1\npass 2 done\npass 3\n"]).fast,
  ).toEqual([true, true, true]);
  const after = stream("after-link", [
    "boot\n",
    "boot\n  Local: http://localhost:5173/\n",
    "boot\n  Local: http://localhost:5173/\n\x1b[32mready\x1b[0m in 210 ms\n",
    "boot\n  Local: http://localhost:5173/\n\x1b[32mready\x1b[0m in 210 ms\npage reload src/app.ts\n",
  ]);
  expect(after).toEqual({ fast: [false, true, true], preview: "http://localhost:5173/" });
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

test("a `cmux acp send` batch's queued, then delivered, output goes through the pane to its rows", () => {
  // The form names no `acpmux`, and its plain lines start as no JSON: the readers still parse it.
  const command = "for s in lane-a lane-b; do cmux acp send --no-wait $s 'Merged.' 2>&1 | tail -1; done";
  const batch = (output: string) => call(output, { command });
  const states = (item: AcpmuxActivity) =>
    sendEntries(toolGroups([item])).map(({ send }) => [send.target, send.state, send.delivery]);
  const steps = ["queued\n", "queued\ndelivered\n"];
  const pair = update(batch(steps[0]!), batch(steps[1]!));
  expect(toolOutputOnly(pair.previous, pair.next)).toBeUndefined();
  expect(states(batch(steps[0]!))).toEqual([
    ["lane-a", "sent", "queued"],
    ["lane-b", "sending", undefined],
  ]);
  expect(states(batch(steps[1]!))).toEqual([
    ["lane-a", "sent", "queued"],
    ["lane-b", "sent", "delivered"],
  ]);
  // A single send of the same form, its output piped through a filter.
  const single = (output: string) => call(output, { command: "cmux acp send --no-wait lane-a 'Merged.' | tail -1" });
  const one = update(single("sending\n"), single("sending\nqueued\n"));
  expect(toolOutputOnly(one.previous, one.next)).toBeUndefined();
});

test("every command form the row readers parse goes through the pane", () => {
  const forms: [string, Partial<Tool>][] = [
    ["a path-qualified cmux", { command: "/usr/local/bin/cmux acp send lane-a 'hi'" }],
    ["an env prefix", { command: "env CMUX_SOCKET=/tmp/cmux.sock cmux acp send lane-a 'hi'" }],
    ["an assignment prefix", { command: "CMUX_SOCKET=/tmp/cmux.sock cmux acp send lane-a 'hi'" }],
    ["a timeout wrapper", { command: "timeout 30 cmux acp send lane-a 'hi'" }],
    ["a shell -c", { command: "bash -c 'cmux acp send lane-a hi'" }],
    ["a reach wrapper", { command: "reach devbox 'cmux acp send lane-a hi'" }],
    [
      "a shell function",
      { command: "tell() { cmux acp send --no-wait \"$1\" 'Merged.' 2>&1 | tail -1; }; tell lane-a; tell lane-b" },
    ],
    ["the debug cli", { command: "acpmux-debug-cli send lane-a 'hi'" }],
    ["an upper-case who-else", { command: "ACPMUX who-else --json src/app.ts" }],
    ["an upper-case dispatch", { command: "ACPMUX dispatch --to lane-a brief.md" }],
    ["a who-else by title", { command: "./ask.sh", title: "who_else" }],
    ["a dispatch by title", { command: "./brief.sh", title: "dispatch" }],
  ];
  for (const [name, extra] of forms) {
    const pair = update(call("working\n", extra), call("working\nqueued\n", extra));
    expect(toolOutputOnly(pair.previous, pair.next), name).toBeUndefined();
  }
  // A dispatch card takes its kind from JSON output, after a blank first line.
  const report = (output: string) => call(output, { command: "./notify.sh" });
  const json = update(report("\n"), report('\n{"event":{"kind":"report"},"summary":"done"}'));
  expect(toolOutputOnly(json.previous, json.next)).toBeUndefined();
});

test("plain command output still takes the fast path", () => {
  for (const command of ["bun test", "acpmux logs lane-a --follow", "cmux acp status lane-a"]) {
    const plain = (output: string) => call(output, { command });
    for (let at = 1; at < 4; at += 1) {
      const before = "line\n".repeat(at);
      const pair = update(plain(before), plain(before + "line\n"));
      expect(toolOutputOnly(pair.previous, pair.next), command).toEqual({
        id: "call-1",
        output: before + "line\n",
        before,
      });
    }
  }
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
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function mount(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
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

/// A running command's output grown through the fast path: the pane keeps `rows`, the store holds
/// the newer output (review of #37907: what reads the pane's rows at a person's action sees it).
function grownWithoutThePane() {
  const before = call("pass 1\n");
  const after = call("pass 1\npass 2\n");
  const { previous, next } = update(before, after);
  const fast = toolOutputOnly(previous, next);
  // The fast path: the pane draws nothing for this update.
  expect(fast).toEqual({ id: "call-1", output: "pass 1\npass 2\n", before: "pass 1\n" });
  liveToolOutput.set(fast!.id, fast!.output, fast!.before);
  return previous.rows;
}

test("copying a running command's row reads the output it took without the pane", () => {
  const rows = grownWithoutThePane();
  try {
    // Keyboard copy of the row or of a range (VirtualTranscript `copyRows`).
    expect(transcriptRangeText(rowsWithLiveOutput(rows), ["activity-1"])).toBe("Run bun test\npass 1\npass 2");
    expect(transcriptRangeText(rowsWithLiveOutput(rows), ["user-1", "activity-1"])).toBe(
      "run the tests\n\nRun bun test\npass 1\npass 2",
    );
    // Rows without a newer output stay the same objects.
    const live = rowsWithLiveOutput(rows);
    expect(live[0]).toBe(rows[0]);
    // A row drawn since with other output is newer than the entry.
    const redrawn = [prompt, activity(call("other\n"), 3)];
    expect(rowsWithLiveOutput(redrawn)).toBe(redrawn);
  } finally {
    liveToolOutput.settle(liveToolOutput.redraw());
  }
  expect(rowsWithLiveOutput(rows)).toBe(rows);
});

test("Copy Response and Copy as Markdown hold no call output, so the pane's rows are exact for them", () => {
  const rows = grownWithoutThePane();
  try {
    const answered = [...rows, { id: "assistant-1", version: 1, at: 2, kind: "assistant", text: "Done." } as AcpmuxRow];
    const copied: string[] = [];
    const menu = copyRow({ link: undefined, rows: answered }, (text) => copied.push(text));
    for (const child of menu!.children!) child.onSelect?.();
    expect(copied).toEqual(["Done.", "> run the tests\n\nDone."]);
  } finally {
    liveToolOutput.settle(liveToolOutput.redraw());
  }
});

test("Find opened after a running command's output grew without the pane finds the new output", () => {
  const container = mount();
  const rows = grownWithoutThePane();
  let find: ChatFind | undefined;
  function Find() {
    find = useChatFind(rows);
    return null;
  }
  try {
    root = createRoot(container);
    act(() => root!.render(<Find />));
    act(() => find!.show("pass 2"));
    expect(find!.matches.map((match) => match.rowId)).toEqual(["activity-1"]);
  } finally {
    liveToolOutput.settle(liveToolOutput.redraw());
  }
});
