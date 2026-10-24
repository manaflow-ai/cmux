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
/// Each test draws its own row id: ThoughtRow keeps the reader's choices by id for the whole module.
const row = (list: AcpmuxActivity[], id: string): AcpmuxRow => ({
  id,
  version: list.length,
  at: 1,
  kind: "activity",
  items: list,
});

const command: AcpmuxActivity = {
  kind: "tool",
  text: "Ran ls",
  tool: { id: "cmd", title: "ls", kind: "execute", command: "ls", status: "completed" },
};

async function draw(list: AcpmuxActivity[], id = "activity") {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  root ??= createRoot(host);
  await act(async () => root!.render(<ToolRows row={row(list, id)} sessionId="thought-state" />));
}

const toggles = () => [...host.querySelectorAll<HTMLButtonElement>("button.cv-thought")];
const opened = () =>
  toggles()
    .filter((node) => node.getAttribute("aria-expanded") === "true")
    .map((node) => node.nextElementSibling?.textContent ?? "");
const click = (node: Element) => act(async () => node.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));

test("an opened thought inside a group stays open as calls join and as +K more opens", async () => {
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  await draw(items(6));
  // Six reads: the first is behind "+1 more"; thoughts 1 to 4 show, each closed.
  expect(toggles().length).toBe(4);
  const second = toggles()[1]!;
  await act(async () => second.dispatchEvent(new window.MouseEvent("click", { bubbles: true })));
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

test("an opened thought stays open when the call after it finishes and joins it to a group", async () => {
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  // A live run leaves out the read still running (turns.ts codexRuns): the thought draws on its own.
  await draw([command, read(0), read(1), thought(0)], "joins");
  expect(toggles().length).toBe(1);
  await click(toggles()[0]!);
  expect(opened()).toHaveLength(1);
  // The read finishes: the thought now sits inside "Read 3 files", still open.
  await draw([command, read(0), read(1), thought(0), read(2)], "joins");
  expect(host.querySelector(".cv-tool-group")).not.toBeNull();
  expect(opened()).toHaveLength(1);
  expect(opened()[0]).toContain("Thought number 0:");
});

test("one activity shown twice in a group keeps two thoughts' states apart", async () => {
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  const same = thought(9);
  const list = [read(0), same, read(1), same, read(2)];
  await draw(list, "twice");
  expect(toggles().length).toBe(2);
  await click(toggles()[0]!);
  expect(toggles().map((node) => node.getAttribute("aria-expanded"))).toEqual(["true", "false"]);
  // Drawn again from scratch, each thought reads its own saved choice.
  act(() => root?.unmount());
  root = undefined;
  await draw(list, "twice");
  expect(toggles().map((node) => node.getAttribute("aria-expanded"))).toEqual(["true", "false"]);
});

test("a thought that takes another's place on its own row starts closed", async () => {
  const { resetTranscriptDisclosure } = await import("../src/agent-session/acpmux/conversation/transcriptDisclosure");
  resetTranscriptDisclosure();
  // The live run leaves out each read still running: thought 0 draws on its own after the group.
  await draw([command, read(0), read(1), thought(0)], "replaced");
  await click(toggles()[0]!);
  expect(opened()).toHaveLength(1);
  // read 2 finishes and joins thought 0 to the group; thought 1 now draws on its own where thought 0 was.
  await draw([command, read(0), read(1), thought(0), read(2), thought(1)], "replaced");
  expect(toggles()).toHaveLength(2);
  expect(opened()).toHaveLength(1);
  expect(opened()[0]).toContain("Thought number 0:");
});
