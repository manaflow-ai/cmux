// l10n-allow-file: public-safe regression fixture commands and paths, not shipped copy.
import { afterEach, expect, spyOn, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { appendThought, mergeToolItem } from "../direct";
import { SubagentFold } from "../subagents/subagentFold";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRows } from "./TurnRows";
import * as toolFailure from "./toolFailure";
import * as thoughts from "./thoughts";
import { thoughtLayout } from "./ThoughtRow";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";

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
  expect(container.querySelectorAll(".cv-command[aria-expanded=true]")).toHaveLength(1);
});

for (const [kind, toolKind] of GROUP_KINDS.slice(1))
  test(`an open ${kind} group shows every call`, async () => {
    const items = calls(toolKind);
    const container = await render(<ToolGroupRow kind={kind} items={items} disclosureKey={`all-${kind}`} />);
    // One step row per call, each between the group's hairlines (ToolGroupRow.tsx Step).
    expect(container.querySelectorAll(".cv-steps > .cv-step > .cv-tool")).toHaveLength(items.length);
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
    const enabled = thoughtLayout.enabled;
    const renderProbe = spyOn(thoughtLayout, "enabled").mockImplementation(() => {
      thoughtRenders += 1;
      return enabled();
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
