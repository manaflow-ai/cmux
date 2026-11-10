// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// While the agent compacts the conversation the live line says so, with the compaction's own time:
// never "Thinking", and no token count, since no model thinks or writes then. The transcript's own
// "Compacting the conversation…" row folds into that line, so one status line shows (Leo,
// 2026-11-07: "when you're compacting the conversation, just show it as you're compacting ...
// You're not thinking during this time ... That should replace the thinking area", on
// "Compacting the conversation..." over "Thinking 1m 35s · 1.8K tokens").
// Gallery: agent-pane.live-line-compacting.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { THINKING, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { WorkingCountsContext, type WorkingCounts } from "../src/agent-session/acpmux/conversation/workingForModel";
import { settleReact } from "./support/domTeardown";

const START = Date.UTC(2026, 10, 7, 8, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const prompt = row("u-1", "user", 0, { text: "Finish the migration and run the tests" });
const reply = row("a-1", "assistant", 5, { text: "Migrating now." });
const compacting = (reason?: string) =>
  row("compaction-9", "compaction", 30, { compaction: { state: "running", ...(reason && { reason }) } });
const view = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set(), { working: true, agentFamily: "claude", now: START + 125_000 });

test("a running compaction is the live line's state, and its row folds into the line", () => {
  const shaped = view([prompt, reply, compacting()]);
  const line = shaped.at(-1)!;
  expect(line.kind).toBe(THINKING);
  expect(line.liveState).toBe("compacting");
  // Its own clock, from the compaction's start.
  expect(line.doingAt).toBe(START + 30_000);
  // One status line: no separate compaction row while it runs.
  expect(shaped.some((entry) => entry.kind === "compaction")).toBe(false);
});

test("a note after a running compaction leaves it the line's state; a reply after it does not", () => {
  const note = row("failover-10", "failover", 40, { failover: { from: "claude", to: "codex" } });
  const noted = view([prompt, reply, compacting(), note]);
  expect(noted.at(-1)!.liveState).toBe("compacting");
  expect(noted.some((entry) => entry.kind === "compaction")).toBe(false);
  const answered = view([prompt, compacting(), row("a-2", "assistant", 50, { text: "Picking up again." })]);
  expect(answered.at(-1)!.liveState).not.toBe("compacting");
});

test("a finished compaction lands in the transcript at once and the line reads Thinking again", () => {
  const done = { ...compacting(), version: 2, compaction: { state: "completed" as const } };
  const shaped = view([prompt, reply, done]);
  expect(shaped.at(-1)!.liveState).toBeUndefined();
  expect(shaped.at(-1)!.doing).toBeUndefined();
  expect(shaped.some((entry) => entry.id === "compaction-9")).toBe(true);
});

test("an account-switch compaction keeps its own words on the line", () => {
  const line = view([prompt, reply, compacting("account_switch")]).at(-1)!;
  expect(line).toMatchObject({ liveState: "compacting", liveCompaction: { reason: "account_switch" } });
});

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 1_800,
};

const line = (props: Parameters<typeof Thinking>[0]) => (
  <WorkingCountsContext.Provider value={counts}>
    <Thinking since={START} now={() => START + 95_000} below turnTotal {...props} />
  </WorkingCountsContext.Provider>
);

test("the compacting line says Compacting with the compaction's time, never Thinking or tokens", () => {
  act(() => root!.render(line({})));
  // Base: "Thinking 1m 35s · 1.8K tokens", as in Leo's capture.
  expect(container.textContent).toContain("Thinking");
  expect(container.textContent).toContain("tokens");

  act(() =>
    root!.render(line({ liveState: "compacting", liveCompaction: { state: "running" }, doingAt: START + 83_000 })),
  );
  const text = container.querySelector(".cv-worked")!.textContent!;
  expect(text).toContain("Compacting conversation…");
  expect(text).toContain("12s");
  expect(text).not.toContain("Thinking");
  expect(text).not.toContain("1m 35s");
  expect(text).not.toContain("tokens");
  expect(container.querySelector(".cv-thinking")?.getAttribute("aria-label")).toBeNull();
});

test("the account-switch compaction's line keeps its meaning", () => {
  act(() =>
    root!.render(
      line({
        liveState: "compacting",
        liveCompaction: { state: "running", reason: "account_switch" },
        doingAt: START + 83_000,
      }),
    ),
  );
  expect(container.textContent).toContain("Compacting the conversation to continue on another account…");
  expect(container.textContent).not.toContain("Thinking");
});
