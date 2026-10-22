// l10n-allow-file: test fixture thoughts, not shipped UI.
// A thought between two calls draws inside their group (toolGroups.ts). The reader's open or closed
// choice stays with that thought when a later call joins the group and moves its "+K more" tail,
// and when "+K more" shows the earlier calls: the thought is named by its place in the whole group,
// never by its place among the rows on screen (Codex review of #24075).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const read = (n: number): AcpmuxActivity => ({
  kind: "tool",
  text: `Read file${n}.ts`,
  tool: {
    id: `read-${n}`,
    title: `Read file${n}.ts`,
    kind: "read",
    status: "completed",
    locations: [{ path: `file${n}.ts` }],
  },
});
const thought = (n: number): AcpmuxActivity => ({
  kind: "thought",
  text: `Thought number ${n}: the helper retries on every status, so check the caller next.`,
  startedAt: 0,
  endedAt: 3_000,
});
/// Reads with a thought after each but the last: read0, thought0, read1, thought1, ...
const items = (reads: number) =>
  Array.from({ length: reads }, (_, n) => (n < reads - 1 ? [read(n), thought(n)] : [read(n)])).flat();
const row = (list: AcpmuxActivity[]): AcpmuxRow => ({
  id: "activity",
  version: list.length,
  at: 1,
  kind: "activity",
  items: list,
});

async function draw(list: AcpmuxActivity[]) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  root ??= createRoot(host);
  await act(async () => root!.render(<ToolRows row={row(list)} sessionId="thought-state" />));
}

test("an opened thought inside a group stays open as calls join and as +K more opens", async () => {
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  await draw(items(6));
  // Six reads: the first is behind "+1 more"; thoughts 1 to 4 show, each closed.
  const toggles = () => [...host.querySelectorAll<HTMLButtonElement>("button.cv-thought")];
  expect(toggles().length).toBe(4);
  const second = toggles()[1]!;
  await act(async () => second.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
  const opened = () =>
    toggles()
      .filter((node) => node.getAttribute("aria-expanded") === "true")
      .map((node) => node.nextElementSibling?.textContent ?? "");
  expect(opened()).toHaveLength(1);
  expect(opened()[0]).toContain("Thought number 2:");
  // A seventh read joins: the tail moves on, the same thought stays the open one.
  await draw(items(7));
  expect(opened()).toHaveLength(1);
  expect(opened()[0]).toContain("Thought number 2:");
  // "+K more" shows the earlier calls: still the same thought.
  const more = host.querySelector<HTMLButtonElement>(".cv-tool-group__more")!;
  await act(async () => more.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
  expect(toggles().length).toBe(6);
  expect(opened()).toHaveLength(1);
  expect(opened()[0]).toContain("Thought number 2:");
});
