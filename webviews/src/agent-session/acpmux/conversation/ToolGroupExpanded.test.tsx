// l10n-allow-file: public-safe regression fixture commands and paths, not shipped copy.
import { afterEach, expect, spyOn, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { appendThought, mergeToolItem } from "../direct";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRows } from "./TurnRows";
import * as toolFailure from "./toolFailure";
import { resetTranscriptDisclosure } from "./transcriptDisclosure";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

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
  // Full command bodies remain independent of the group's disclosure.
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

for (const [kind, toolKind] of [
  ["reads", "read"],
  ["searches", "search"],
] as const)
  test(`an open ${kind} group shows every call`, async () => {
    const items = calls(toolKind);
    const container = await render(<ToolGroupRow kind={kind} items={items} disclosureKey={`all-${kind}`} />);
    expect(container.querySelectorAll(".cv-tool-group > .cv-tool:not(.cv-tool-group__more)")).toHaveLength(
      items.length,
    );
    expect(container.textContent).not.toMatch(/\+\d+ more/);
    for (const item of items) expect(container.textContent).toContain(item.text);
  });

for (const [kind, toolKind] of [
  ["commands", "execute"],
  ["reads", "read"],
  ["searches", "search"],
] as const)
  test(`streaming a ${kind} group renders only its changed item`, async () => {
    // rowFailed runs once inside each real CommandRow/ToolRow render, never in the group summary.
    // Count that work without replacing either production row with a test renderer.
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
      // Open only the live call's full body; its streamed result must stay live through the bailout.
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
      // A thought chunk changes the activity version too, while every tool snapshot stays intact.
      row = { ...row, version: row.version + 1, items: appendThought(row.items!, "Inspect the next sample.", 1_000) };
      rendered.length = 0;
      await act(async () => root!.render(<ToolRows row={row} sessionId={`stream-${kind}`} />));
      expect(rendered).toEqual([]);
      expect(ids()).toEqual(allIds);
    } finally {
      probe.mockRestore();
    }
  });
