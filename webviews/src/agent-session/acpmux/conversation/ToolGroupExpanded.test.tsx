// l10n-allow-file: public-safe regression fixture commands and paths, not shipped copy.
import { afterEach, expect, spyOn, test } from "bun:test";
import { act, useState, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { appendThought, mergeToolItem } from "../direct";
import { SubagentFold } from "../subagents/subagentFold";
import { ToolGroupRow } from "./ToolGroupRow";
import { firstStepCount, stepProbe } from "./toolGroupRowModel";
import { FindReveal, type FindRevealTarget } from "./chatFind";
import { ToolRows } from "./TurnRows";
import * as toolFailure from "./toolFailure";
import * as thoughts from "./thoughts";
import { thoughtLayout } from "./thoughtRowModel";
import { resetTranscriptDisclosure } from "./transcriptDisclosureModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
type GroupEntry = { item: AcpmuxActivity };
const GROUP_KINDS = [
  ["commands", "execute"],
  ["reads", "read"],
  ["searches", "search"],
] as const;

async function render(node: ReactNode): Promise<HTMLElement> {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
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
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
  return container;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  resetTranscriptDisclosure();
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const calls = (kind = "execute"): AcpmuxActivity[] =>
  Array.from({ length: 13 }, (_, at) => ({
    kind: "tool",
    text: `Inspect fixture ${at + 1}`,
    tool: {
      id: `${kind}-${at + 1}`,
      title: `Inspect fixture ${at + 1}`,
      kind,
      status: "completed",
      ...(kind === "execute" ? { command: `echo fixture-${at + 1}`, output: `fixture-${at + 1}\n` } : {}),
    },
  }));

test("opening a command group shows all 13 calls and the intervening thought with no second disclosure", async () => {
  const items = calls();
  items.splice(3, 0, {
    kind: "thought",
    text: "Check every fixture before continuing.",
    startedAt: 1_000,
    endedAt: 11_000,
  });
  const container = await render(<ToolGroupRow kind="commands" items={items} disclosureKey="all-commands" folded />);
  const group = container.querySelector<HTMLButtonElement>("button")!;
  expect(group.getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelectorAll(".cv-command")).toHaveLength(0);
  await act(async () => group.click());
  expect(group.getAttribute("aria-expanded")).toBe("true");
  expect([...container.querySelectorAll(".cv-command__line")].map((node) => node.textContent)).toEqual(
    calls().map((item) => item.tool!.command!),
  );
  expect(container.querySelectorAll(".cv-thought")).toHaveLength(1);
  expect(container.textContent).not.toMatch(/\+\d+ more/);
  expect(container.querySelectorAll(".cv-command[aria-expanded=true]")).toHaveLength(0);
  const first = container.querySelector<HTMLButtonElement>(".cv-command")!;
  await act(async () => first.click());
  expect(first.getAttribute("aria-expanded")).toBe("true");
  expect(container.querySelectorAll(".cv-command[aria-expanded=true]")).toHaveLength(1);
  await act(async () => group.click());
  expect(container.querySelectorAll(".cv-command")).toHaveLength(0);
  await act(async () => group.click());
  expect(container.querySelectorAll(".cv-command")).toHaveLength(13);
  // Closing the group closed the call the reader opened in it (Lucas, 2026-11-11).
  expect(container.querySelectorAll(".cv-command[aria-expanded=true]")).toHaveLength(0);
});

for (const [kind, toolKind] of GROUP_KINDS.slice(1))
  test(`an open ${kind} group shows every call`, async () => {
    const items = calls(toolKind);
    const container = await render(<ToolGroupRow kind={kind} items={items} disclosureKey={`all-${kind}`} />);
    // One step row per call, each between the group's hairlines (ToolGroupRow.tsx Step).
    expect(container.querySelectorAll(".cv-steps > .cv-step > .cv-tool")).toHaveLength(items.length);
    // The shipped sheet keeps a kind icon on every step, so readers can scan a mixed run before
    // opening one row (Leo 2026-11-04, iOS-style grouped tool calls).
    expect(container.querySelectorAll(".cv-steps > .cv-step > .cv-tool > .cv-tool__icon")).toHaveLength(items.length);
    expect(container.textContent).not.toMatch(/\+\d+ more/);
    for (const item of items) expect(container.textContent).toContain(item.text);
  });

for (const [kind, toolKind] of GROUP_KINDS)
  test(`streaming a ${kind} group renders only its changed item`, async () => {
    // rowFailed runs once inside each real CommandRow/ToolRow render, never in the group summary.
    const rendered: string[] = [];
    const rowFailed = toolFailure.rowFailed;
    const probe = spyOn(toolFailure, "rowFailed").mockImplementation((tool) => {
      rendered.push(tool.id);
      return rowFailed(tool);
    });
    const completed = calls(toolKind);
    const live = mergeToolItem(
      undefined,
      {
        title: "Stream sample",
        kind: toolKind,
        ...(toolKind === "execute" ? { rawInput: { command: "echo stream" } } : {}),
      },
      "stream-item",
      "chunk-0",
    );
    let row: AcpmuxRow = {
      id: `stream-${kind}`,
      kind: "activity",
      version: 1,
      at: 1,
      items: [...completed, live],
    };
    try {
      const container = await render(<ToolRows row={row} sessionId={`stream-${kind}`} />);
      const allIds = [...completed.map((item) => item.tool!.id), "stream-item"];
      const ids = () =>
        [...container.querySelectorAll("[data-tool-id]")].map((node) => node.getAttribute("data-tool-id"));
      expect(ids()).toEqual(allIds);
      const toggle = container.querySelector<HTMLButtonElement>('[data-tool-id="stream-item"]')!;
      await act(async () => toggle.click());
      for (let chunk = 1; chunk <= 5; chunk += 1) {
        const next = mergeToolItem(row.items!.at(-1), { status: "in_progress" }, "stream-item", `chunk-${chunk}`);
        row = { ...row, version: row.version + 1, items: [...completed, next] };
        rendered.length = 0;
        await act(async () => root!.render(<ToolRows row={row} sessionId={`stream-${kind}`} />));
        expect(rendered).toEqual(["stream-item"]);
        expect(ids()).toEqual(allIds);
        expect(container.textContent).toContain(`chunk-${chunk}`);
      }
      row = { ...row, version: row.version + 1, items: appendThought(row.items!, "Inspect the next sample.", 1_000) };
      rendered.length = 0;
      await act(async () => root!.render(<ToolRows row={row} sessionId={`stream-${kind}`} />));
      expect(rendered).toEqual([]);
      expect(ids()).toEqual(allIds);
    } finally {
      probe.mockRestore();
    }
  });

for (const [kind, toolKind] of GROUP_KINDS)
  test(`a nested subagent's ${kind} stream keeps its completed item snapshots and skips their renders`, async () => {
    const fold = new SubagentFold();
    const nestedId = `nested-${kind}`;
    let seq = 0;
    const feed = (update: Record<string, unknown>, acpmux: Record<string, unknown>) => {
      seq += 1;
      fold.reduce({ seq, at: seq * 1_000, msg: { params: { update, _meta: { acpmux } } } }, update);
    };
    feed({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id: "parent", parent: null, name: "Sample parent" }] });
    feed(
      { sessionUpdate: "subagent_spawned" },
      { subagents: [{ id: nestedId, parent: "parent", name: "Sample child" }] },
    );
    const completed = calls(toolKind);
    for (const [at, item] of completed.entries()) {
      if (at === 1)
        feed(
          {
            sessionUpdate: "agent_thought_chunk",
            content: { type: "text", text: "Inspect every sample before choosing the next check." },
          },
          { subagent: nestedId },
        );
      feed(
        {
          sessionUpdate: "tool_call",
          toolCallId: item.tool!.id,
          title: item.tool!.title,
          kind: toolKind,
          status: "completed",
          rawInput: { command: item.tool!.command },
        },
        { subagent: nestedId },
      );
    }
    feed(
      {
        sessionUpdate: "tool_call",
        toolCallId: "nested-stream",
        title: "Stream sample",
        kind: toolKind,
        status: "in_progress",
        rawInput: { command: toolKind === "execute" ? "echo nested" : undefined },
        content: { type: "text", text: "nested-0" },
      },
      { subagent: nestedId },
    );
    const shown = () => fold.views()[nestedId]!.find((row) => row.kind === "activity")!;
    const initial = shown();
    const stable = initial.items!.filter((item) => item.tool?.id !== "nested-stream");
    const parsed: string[] = [];
    let mapped = 0;
    let thoughtRenders = 0;
    const arrayMap = Array.prototype.map;
    const mapProbe = spyOn(Array.prototype, "map").mockImplementation(function <U>(
      this: GroupEntry[],
      callback: (value: GroupEntry, index: number, array: GroupEntry[]) => U,
      context?: unknown,
    ): U[] {
      return arrayMap.call(this, (value, at, array) => {
        if (value?.item?.kind === "tool" || value?.item?.kind === "thought") mapped += 1;
        return callback.call(context, value, at, array);
      }) as U[];
    });
    const threshold = thoughtLayout.threshold;
    const renderProbe = spyOn(thoughtLayout, "threshold").mockImplementation(() => {
      thoughtRenders += 1;
      return threshold();
    });
    const thoughtParts = thoughts.thoughtParts;
    const thoughtProbe = spyOn(thoughts, "thoughtParts").mockImplementation((text) => {
      parsed.push(text);
      return thoughtParts(text);
    });
    const rendered: string[] = [];
    const rowFailed = toolFailure.rowFailed;
    const probe = spyOn(toolFailure, "rowFailed").mockImplementation((tool) => {
      rendered.push(tool.id);
      return rowFailed(tool);
    });
    try {
      const container = await render(<ToolRows row={initial} sessionId={`nested-${kind}`} />);
      const ids = () =>
        [...container.querySelectorAll("[data-tool-id]")].map((node) => node.getAttribute("data-tool-id"));
      const expected = [...completed.map((item) => item.tool!.id), "nested-stream"];
      expect(ids()).toEqual(expected);
      await act(async () => container.querySelector<HTMLButtonElement>('[data-tool-id="nested-stream"]')!.click());
      await act(async () => container.querySelector<HTMLButtonElement>(".cv-thought")!.click());
      for (let chunk = 1; chunk <= 5; chunk += 1) {
        feed(
          {
            sessionUpdate: "tool_call_update",
            toolCallId: "nested-stream",
            content: { type: "text", text: `nested-${chunk}` },
          },
          { subagent: nestedId },
        );
        const next = shown();
        rendered.length = 0;
        parsed.length = 0;
        mapped = thoughtRenders = 0;
        await act(async () => root!.render(<ToolRows row={next} sessionId={`nested-${kind}`} />));
        console.log(
          `expanded-work ${kind} mapped=${mapped} rowRenders=${rendered.length} thoughtRenders=${thoughtRenders}`,
        );
        expect(mapped).toBeLessThanOrEqual(1);
        expect(thoughtRenders).toBe(0);
        expect(rendered).toEqual(["nested-stream"]);
        expect(parsed).toEqual([]);
        expect(
          next.items!.filter((item) => item.tool?.id !== "nested-stream").every((item, at) => item === stable[at]),
        ).toBe(true);
        expect(ids()).toEqual(expected);
        expect(container.textContent).toContain(`nested-${chunk}`);
      }
      const before = fold.views().parent!.find((row) => row.kind === "subagents")!;
      feed({ sessionUpdate: "subagent_state_update" }, { subagents: [{ id: nestedId, state: "completed" }] });
      const after = fold.views().parent!.find((row) => row.kind === "subagents")!;
      expect(after).not.toBe(before);
      expect(after.subagents![0]!.state).toBe("completed");
      expect(before.subagents![0]!.state).toBe("running");
    } finally {
      probe.mockRestore();
      thoughtProbe.mockRestore();
      mapProbe.mockRestore();
      renderProbe.mockRestore();
    }
  });

test("a failed step of an opened command group opens to its command, Exit code 1, then its output", async () => {
  const shell = (id: string, description: string, fields: Partial<NonNullable<AcpmuxActivity["tool"]>>) => ({
    kind: "tool",
    text: description,
    tool: {
      id,
      title: description,
      kind: "execute",
      status: "completed",
      description,
      command: `run ${id}`,
      ...fields,
    },
  });
  const items: AcpmuxActivity[] = [
    shell("bg-done", "Find the retry references", { background: { state: "completed", endedAt: 2 }, output: "a\n" }),
    shell("failed", "Count the retry fixture cases", {
      status: "failed",
      output: "Exit code 1\nls: fixtures/retry-cases.json: No such file or directory",
    }),
    shell("passed", "Run the retry tests", { output: "12 pass\n" }),
  ];
  const container = await render(
    <ToolGroupRow kind="commands" items={items} disclosureKey="failed-step-open" folded />,
  );
  await act(async () => container.querySelector<HTMLButtonElement>("button")!.click());
  const failed = container.querySelector<HTMLButtonElement>(".cv-step > .cv-command:has(> .cv-command__failed)")!;
  expect(failed.getAttribute("data-tool-id")).toBe("failed");
  await act(async () => failed.click());
  expect(failed.getAttribute("aria-expanded")).toBe("true");
  const shellBlock = container.querySelector(".cv-shell")!;
  expect(shellBlock.querySelector(".cv-shell__exit")?.textContent).toBe("Exit code 1");
  expect(shellBlock.textContent).toContain("No such file or directory");
});

test("one mixed run exposes individual steps and drills into an MCP call's fields without JSON plumbing", async () => {
  const { mixedToolRunFixture } = await import("./mixedToolRunFixture");
  const row: AcpmuxRow = {
    id: "mixed-sheet",
    kind: "activity",
    at: 1,
    version: 1,
    settled: true,
    foldRun: true,
    items: mixedToolRunFixture(),
  };
  const container = await render(<ToolRows row={row} sessionId="mixed-sheet" />);
  const header = container.querySelector<HTMLButtonElement>("button.cv-tool")!;
  expect(header.textContent).toContain("Ran 2 commands and used 3 tools");
  expect(container.querySelector("[data-mixed-tool-steps]")).toBeNull();
  await act(async () => header.click());
  const steps = container.querySelector("[data-mixed-tool-steps]")!;
  expect(steps.querySelectorAll(":scope > .cv-step")).toHaveLength(5);
  // Same fixture's redundant subgroup summaries: before 1 (Ran 2 commands), after 0.
  expect(steps.querySelectorAll(".is-run")).toHaveLength(0);
  expect(steps.textContent).not.toContain("Loaded tools");
  expect(steps.textContent).toContain("Find the retry handler");
  const grep = [...steps.querySelectorAll<HTMLButtonElement>(".cv-tool")].find((button) =>
    button.textContent?.includes("Find the retry handler"),
  )!;
  await act(async () => grep.click());
  // An opened call is its arguments as labeled fields and its output (ToolDetail.tsx), never one JSON block.
  const fields = [...steps.querySelectorAll(".cv-tool-detail__key")].map((node) => node.textContent);
  expect(fields).toContain("pattern");
  expect(steps.textContent).toContain('"line": 12');
  expect(steps.textContent).not.toContain('"pattern"');
  const waiting = [...steps.querySelectorAll<HTMLElement>(".cv-tool")].find((node) =>
    node.textContent?.includes("Read the retry context"),
  )!;
  expect(waiting.tagName).toBe("DIV");
  expect(waiting.hasAttribute("aria-expanded")).toBe(false);
  expect(waiting.parentElement?.querySelector(".cv-mcp-call")).toBeNull();
  expect(steps.textContent).not.toContain("Waiting…");
});

// A running turn draws by liveTurnWork.experiment.ts: the `line` arm draws no finished run
// of the stretch still running (one live line, as chatgpt.com draws a running turn); the `runs` arm
// keeps each finished run's calls in sight until the turn ends. Each arm is pinned for its case.
async function underLiveTurnArm<T>(arm: "line" | "runs", body: () => Promise<T>): Promise<T> {
  const before = globalThis.cmuxExperiments;
  globalThis.cmuxExperiments = { ...before, "live-turn-work": arm };
  try {
    return await body();
  } finally {
    if (before === undefined) delete globalThis.cmuxExperiments;
    else globalThis.cmuxExperiments = before;
  }
}

for (const agentFamily of ["claude", "codex"])
  test(`${agentFamily} live turn under the one-line arm draws its finished mixed calls as no row`, async () => {
    const { mixedToolTurnFixture } = await import("./mixedToolRunFixture");
    const { turnView } = await import("./turns");
    const projected = await underLiveTurnArm("line", async () =>
      turnView(mixedToolTurnFixture(true), new Set(["worked-mixed-prompt"]), { agentFamily, working: true }),
    );
    // The prompt stays; the finished run leaves no row, its work is the turn's one live line.
    expect(projected.some((row) => row.kind === "user")).toBe(true);
    expect(projected.some((row) => row.kind === "activity")).toBe(false);
    expect(projected.some((row) => row.doing?.includes("Capture the repaired screen"))).toBe(false);
  });

for (const agentFamily of ["claude", "codex"])
  for (const working of [false, true])
    test(`${agentFamily} ${
      working
        ? "live turn under the runs arm folds mixed calls into one run"
        : "finished turn projects mixed calls into one folded run"
    }`, async () => {
      const { mixedToolTurnFixture } = await import("./mixedToolRunFixture");
      const { turnView } = await import("./turns");
      const project = async () =>
        turnView(mixedToolTurnFixture(working), new Set(["worked-mixed-prompt"]), { agentFamily, working });
      // The live case covers the `runs` arm; the finished turn draws the same under either arm.
      const projected = working ? await underLiveTurnArm("runs", project) : await project();
      const work = projected.find((row) => row.kind === "activity")!;
      expect(work).toBeDefined();
      // A live turn folds its finished runs as the ended turn does, as the Codex app (Lucas, 2026-11-11:
      // "we should not auto expand commands etc when the turn is live").
      expect(work.foldRun).toBe(true);
      const container = await render(<ToolRows row={work} sessionId={`${agentFamily}-${working}`} />);
      const header = container.querySelector<HTMLButtonElement>("button.cv-tool")!;
      expect(header.getAttribute("aria-expanded")).toBe("false");
      await act(async () => header.click());
      // A finished call stays in its run while the live line reads Thinking (#37635), so a live
      // turn of finished calls lists every step, as the ended turn does.
      expect(container.querySelectorAll("[data-mixed-tool-steps] > .cv-step")).toHaveLength(5);
      expect(projected.some((row) => row.doing?.includes("Capture the repaired screen"))).toBe(false);
    });

test("an opened mixed run keeps a command's returned image and printed screenshot", async () => {
  const shot = "data:image/png;base64,iVBORw0KGgo=";
  const row: AcpmuxRow = {
    id: "mixed-capture",
    kind: "activity",
    at: 1,
    version: 1,
    settled: true,
    foldRun: true,
    items: [
      {
        kind: "tool",
        text: "Read notes.md",
        tool: { id: "read-notes", title: "Read notes.md", kind: "read", status: "completed", output: "notes" },
      },
      {
        kind: "tool",
        text: "screencapture",
        tool: {
          id: "capture-shell",
          title: "Bash",
          kind: "execute",
          status: "completed",
          command: "screencapture /tmp/shot.png",
          output: "Saved /tmp/shot.png",
          images: [shot],
        },
      },
    ],
  };
  const container = await render(<ToolRows row={row} sessionId="mixed-capture" />);
  await act(async () => container.querySelector<HTMLButtonElement>("button.cv-tool")!.click());
  const steps = container.querySelector("[data-mixed-tool-steps]")!;
  // Closed, a command's images are one small image at its row's edge; opened, the strip under it
  // (Lucas, 2026-11-11), as the Codex app's rows draw them.
  expect(steps.querySelector(".cv-tool-images")).toBeNull();
  expect(steps.querySelector(".cv-tool-visual")).not.toBeNull();
  await act(async () => steps.querySelector<HTMLButtonElement>('button[data-tool-id="capture-shell"]')!.click());
  const strip = steps.querySelector(".cv-tool-images");
  expect(strip).not.toBeNull();
  expect(steps.querySelector(".cv-tool-visual")).toBeNull();
  expect(strip!.querySelector(`img[src="${shot}"]`)).not.toBeNull();
});

test("a finished turn whose only work is hidden discovery folds nothing under Worked for", async () => {
  const { mixedToolRunFixture } = await import("./mixedToolRunFixture");
  const { turnView, WORKED } = await import("./turns");
  const at = Date.UTC(2026, 10, 4, 0, 0);
  const discovery = mixedToolRunFixture()[2]!;
  const turn: AcpmuxRow[] = [
    { id: "discovery-prompt", version: 1, kind: "user", at, text: "Which tools can you use?" },
    { id: "discovery-activity", version: 1, kind: "activity", at: at + 1000, items: [discovery], toolCount: 0 },
    { id: "discovery-answer", version: 1, kind: "assistant", at: at + 2000, text: "The repo tools." },
    { id: "discovery-summary", version: 1, kind: "turnSummary", at: at + 3000, status: "completed", toolCount: 0 },
  ];
  for (const agentFamily of ["codex", "claude"]) {
    const projected = turnView(turn, new Set(), { agentFamily });
    expect(projected.some((row) => row.kind === WORKED)).toBe(false);
    expect(projected.some((row) => row.kind === "activity")).toBe(false);
    expect(projected.some((row) => row.text === "The repo tools.")).toBe(true);
  }
});

test("a click opens a long run with only a window's steps drawn, the rest reserved and drawn after the fold", async () => {
  const items = Array.from({ length: 100 }, (_, at) => calls()[at % 13]!).map((item, at) => ({
    ...item,
    tool: { ...item.tool!, id: `execute-long-${at + 1}` },
  }));
  // The draws after the fold wait here until the test runs them, however soon their timer fires.
  const held: (() => void)[] = [];
  stepProbe.hold = (draw) => void held.push(draw);
  try {
    const container = await render(<ToolGroupRow kind="commands" items={items} disclosureKey="long-run" folded />);
    const line = container.querySelector<HTMLButtonElement>('button[data-tool-group="long-run"]')!;
    expect(line.getAttribute("aria-expanded")).toBe("false");
    const first = firstStepCount(window.innerHeight);
    expect(first).toBeLessThan(100);
    await act(async () => line.click());
    const steps = () => container.querySelectorAll('[data-tool-group-items="long-run"] > .cv-step').length;
    // The click's frame draws a window's worth, and a box for the rest.
    expect(steps()).toBe(first);
    expect(container.querySelector("[data-steps-rest]")?.getAttribute("data-steps-rest")).toBe(String(100 - first));
    // After the fold (none plays in a test DOM), a window's worth per draw until every step is drawn.
    for (let tries = 0; tries < 100 && steps() < 100; tries++) {
      const draw = held.shift();
      if (draw) await act(async () => draw());
      else await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
    }
    expect(steps()).toBe(100);
    expect(container.querySelector("[data-steps-rest]")).toBeNull();
  } finally {
    stepProbe.hold = undefined;
  }
});

test("a run opened by itself (not a click) draws every step at once", async () => {
  const items = Array.from({ length: 60 }, (_, at) => calls()[at % 13]!).map((item, at) => ({
    ...item,
    tool: { ...item.tool!, id: `execute-open-${at + 1}` },
  }));
  const container = await render(<ToolGroupRow kind="commands" items={items} disclosureKey="open-run" />);
  expect(container.querySelectorAll('[data-tool-group-items="open-run"] > .cv-step').length).toBe(60);
  expect(container.querySelector("[data-steps-rest]")).toBeNull();
});

test("Find into a click-opened run still drawing draws every step, its match past the first window", async () => {
  const items = Array.from({ length: 100 }, (_, at) => calls()[at % 13]!).map((item, at) => ({
    ...item,
    tool: { ...item.tool!, id: `execute-find-${at + 1}` },
  }));
  let reveal: (target: FindRevealTarget | undefined) => void = () => {};
  function Scene() {
    const [target, setTarget] = useState<FindRevealTarget | undefined>(undefined);
    reveal = setTarget;
    return (
      <FindReveal.Provider value={target}>
        <ToolGroupRow kind="commands" items={items} disclosureKey="find-run" folded />
      </FindReveal.Provider>
    );
  }
  // The rows past the first window wait: the draws after the fold are held, not run.
  const held: (() => void)[] = [];
  stepProbe.hold = (draw) => void held.push(draw);
  try {
    const container = await render(<Scene />);
    await act(async () => container.querySelector<HTMLButtonElement>('button[data-tool-group="find-run"]')!.click());
    const steps = () => container.querySelectorAll('[data-tool-group-items="find-run"] > .cv-step').length;
    const first = firstStepCount(window.innerHeight);
    for (let tries = 0; tries < 20 && held.length === 0; tries++)
      await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
    expect(held.length).toBeGreaterThan(0);
    expect(steps()).toBe(first);
    expect(container.querySelector('[data-tool-id="execute-find-80"]')).toBeNull();
    await act(async () =>
      reveal({ rowId: "find-run", card: false, needle: "", repaint: () => {}, toolId: "execute-find-80" }),
    );
    expect(steps()).toBe(100);
    expect(container.querySelector('[data-tool-id="execute-find-80"]')).not.toBeNull();
    expect(container.querySelector("[data-steps-rest]")).toBeNull();
  } finally {
    stepProbe.hold = undefined;
  }
});
