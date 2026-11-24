// l10n-allow-file: test fixtures (subagent names, harness errors), not shipped UI.
// The transcript at rest carries only the chrome a person asked for (Leo, 2026-11-11: "this is kind
// of weird tbh", "why were all these added in the first place?", "plus the second opinion thing"):
// - a subagent the harness refused to start (the concurrent subagent limit) is the parent's own
//   failed tool call: its name and one short status, no Retry, ↺, ⋯ or "13ms";
// - a row's controls on the line and in its ⋯ menu are disjoint: "Retry" never twice.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import { SubagentDoneLine } from "../src/agent-session/acpmux/subagents/SubagentDoneLine";
import {
  RetryAffordanceContext,
  doneLineControls,
  spawnRefused,
  type RetryAffordance,
} from "../src/agent-session/acpmux/subagents/subagentDoneLineModel";
import { TurnActionsContext, type TurnActions } from "../src/agent-session/acpmux/conversation/turnActions";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { settleReact } from "./support/domTeardown";

const REFUSAL =
  "Concurrent subagent limit reached. You can run 40 subagents at once. Do not retry. If the user wants more concurrent subagents, ask them to increase CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS.";

const refused = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "why-forked",
  parent: null,
  name: "Why only some messages are forked",
  task: "Why only some messages are forked",
  state: "failed",
  startedAt: 5_000,
  endedAt: 5_013,
  prompt: "Find out why only some messages are forked",
  error: REFUSAL,
  ...fields,
});

const ranAndFailed = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "fix-reply",
  parent: null,
  name: "Fix reply button",
  task: "Fix reply button",
  state: "failed",
  startedAt: 0,
  endedAt: 61_000,
  prompt: "Fix the reply button",
  retryable: true,
  toolUses: 4,
  error: "Agent terminated early due to an API error.",
  ...fields,
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(agents: Subagent[], affordance: RetryAffordance = "button", actions: TurnActions = {}): HTMLElement {
  if (!dom) {
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
  }
  const host = dom.window.document.getElementById("root")!;
  const rows: AcpmuxRow[] = agents.map((agent, index) => ({
    id: `done-${index}`,
    version: 1,
    at: agent.endedAt ?? 0,
    kind: SUBAGENT_DONE,
    subagents: [agent],
  }));
  act(() => {
    root = createRoot(host);
    root.render(
      <TurnActionsContext.Provider value={{ retryAgent: async () => undefined, restartSubagent: () => {}, ...actions }}>
        <RetryAffordanceContext.Provider value={affordance}>
          {rows.map((row) => (
            <SubagentDoneLine key={row.id} row={row} />
          ))}
        </RetryAffordanceContext.Provider>
      </TurnActionsContext.Provider>,
    );
  });
  return host;
}

afterEach(async () => {
  act(() => root?.unmount());
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

test("a subagent refused at spawn is told apart from one that ran and failed", () => {
  expect(spawnRefused(refused())).toBe(true);
  // A retryable flag does not make a refusal a run: the harness still never started it.
  expect(spawnRefused(refused({ retryable: true }))).toBe(true);
  // It ran: tokens, a tool call, a reply, an agent id, its own chat, or more than a moment.
  expect(spawnRefused(refused({ tokens: 12 }))).toBe(false);
  expect(spawnRefused(refused({ toolUses: 1 }))).toBe(false);
  expect(spawnRefused(refused({ lastMessage: "Looking at direct.ts" }))).toBe(false);
  expect(spawnRefused(refused({ agentId: "a1b2" }))).toBe(false);
  expect(spawnRefused(refused({ child: "sess-1" }))).toBe(false);
  expect(spawnRefused(refused({ endedAt: 5_000 + 61_000 }))).toBe(false);
  // Not failed, still unended, or acpmux retrying it: not a refusal.
  expect(spawnRefused(refused({ state: "cancelled" }))).toBe(false);
  expect(spawnRefused(refused({ endedAt: undefined }))).toBe(false);
  expect(spawnRefused(refused({ retry: { attempt: 1, of: 4 } }))).toBe(false);
  expect(spawnRefused(ranAndFailed())).toBe(false);
});

test("a refused subagent's row is its name and one short status, nothing else", () => {
  for (const affordance of ["button", "link", "menu"] as const) {
    const host = render([refused({ retryable: true })], affordance);
    const row = host.querySelector<HTMLElement>(".cv-subagent-done-row")!;
    expect(row.dataset.refused).toBe("");
    expect(row.querySelector(".cv-subagent-failed__title")?.textContent).toBe("Why only some messages are forked");
    expect(row.querySelector(".cv-subagent-failed__reason")?.textContent).toBe("Concurrent subagent limit reached");
    // No Retry (inline or link), no ↺ Restart, no ⋯ menu, no duration, no chevron: nothing to click.
    expect(row.querySelectorAll("button")).toHaveLength(0);
    expect(row.querySelector("[data-menu]")).toBeNull();
    expect(row.querySelector(".cv-subagent-done__time")).toBeNull();
    expect(row.querySelector(".cv-tool__chevron")).toBeNull();
    expect(row.textContent).not.toContain("13ms");
    expect(row.textContent).not.toContain("retry");
    // The whole reason stays in the tooltip.
    expect(row.querySelector(".cv-subagent-failed__text")?.getAttribute("title")).toContain(REFUSAL);
    act(() => root?.unmount());
    root = undefined;
  }
});

test("a line's controls and its menu's items are disjoint, and Retry and Restart never both show", () => {
  for (const affordance of ["button", "link", "menu"] as const)
    for (const retry of [false, true])
      for (const restart of [false, true])
        for (const refusedLine of [false, true]) {
          const { line, menu } = doneLineControls({ retry, restart, affordance, refused: refusedLine });
          expect(line.filter((control) => menu.includes(control))).toEqual([]);
          const all = [...line, ...menu];
          expect(new Set(all).size).toBe(all.length);
          expect(all.includes("retry") && all.includes("restart")).toBe(false);
          if (refusedLine) expect(all).toEqual([]);
        }
});

test("a failed run offers Retry once: on the line with no menu, or only in the menu", () => {
  let host = render([ranAndFailed()], "button");
  let row = host.querySelector<HTMLElement>(".cv-subagent-done-row")!;
  expect(row.querySelector(".cv-subagent-done__controls > .cv-subagent-retry")?.textContent).toBe("Retry");
  expect(row.querySelector('[data-menu="subagent-done"]')).toBeNull();
  // Its prompt would allow Restart, but Retry already runs it again.
  expect(row.querySelector(".cv-subagent-restart")).toBeNull();
  // The time stays in the row grammar's trailing column.
  expect(row.querySelector(".cv-subagent-done__time")?.textContent).toBe("1m 1s");
  act(() => root?.unmount());
  root = undefined;

  host = render([ranAndFailed({ toolUses: 2 })], "menu");
  row = host.querySelector<HTMLElement>(".cv-subagent-done-row")!;
  expect(
    row.querySelector(".cv-subagent-done__controls > :is(.cv-subagent-retry, .cv-subagent-retry-link)"),
  ).toBeNull();
  expect(row.querySelector('[data-menu="subagent-done"]')).not.toBeNull();
  act(() => root?.unmount());
  root = undefined;

  // One acpmux cannot retry offers no Retry at all: the chat's agent already read the error (Leo,
  // 2026-11-14: "we maybe want to remove the "ask parent to retry" if we haven't already").
  host = render([ranAndFailed({ retryable: undefined, toolUses: 2 })], "menu");
  row = host.querySelector<HTMLElement>(".cv-subagent-done-row")!;
  expect(row.querySelector(".cv-subagent-retry, .cv-subagent-retry-link, [data-menu]")).toBeNull();
  expect(host.textContent).not.toContain("parent");
});

test.each(
  (["cancelled", "disconnected"] as const).flatMap((state) =>
    (["button", "link", "menu"] as const).map((affordance) => [state, affordance] as const),
  ),
)("a %s helper keeps one Resume and its refusal note with the %s affordance", async (state, affordance) => {
  const agent = ranAndFailed({ state, resumable: true });
  const resumed: string[] = [];
  const host = render([agent], affordance, {
    resumeAgent: async (target) => {
      resumed.push(target.id);
      return "retry.busy";
    },
  });
  const row = host.querySelector<HTMLElement>(".cv-subagent-done-row")!;
  expect(row.hasAttribute("data-refused")).toBe(false);
  const button = row.querySelector<HTMLButtonElement>("button.cv-subagent-resume")!;
  expect(button.getAttribute("aria-label")).toBe("Resume");
  expect(row.querySelectorAll(".cv-subagent-restart")).toHaveLength(1);
  expect(row.querySelector(".cv-subagent-retry, .cv-subagent-retry-link, [data-menu]")).toBeNull();
  await act(async () => button.click());
  expect(resumed).toEqual([agent.id]);
  expect(row.querySelector(".cv-subagent-resume__note")?.textContent).toBeTruthy();
  expect(button.disabled).toBe(false);
});

test("a failed line's Retry waits for the pointer or keyboard focus, over the words' end", () => {
  // The row is the reveal's host and its controls the shared reveal (ui/motion/motion.css), which
  // shows them under the pointer, with focus inside the row or while their menu is open.
  let host = render([ranAndFailed()], "button");
  const row = host.querySelector<HTMLElement>(".cv-subagent-done-row")!;
  expect(row.classList.contains("ui-reveal-host")).toBe(true);
  expect(row.hasAttribute("data-reveal-overlap")).toBe(true);
  const controls = row.querySelector<HTMLElement>(".cv-subagent-done__controls")!;
  expect(controls.classList.contains("ui-reveal")).toBe(true);
  expect(controls.parentElement?.classList.contains("cv-subagent-done__trail")).toBe(true);
  act(() => root?.unmount());
  root = undefined;
  host = render([ranAndFailed({ toolUses: 2 })], "menu");
  expect(host.querySelector('.cv-subagent-done__controls [data-menu="subagent-done"]')).not.toBeNull();
});

test('the catalog has no "Ask parent to retry"', () => {
  const catalog = JSON.parse(
    readFileSync(new URL("../src/agent-session/acpmux/Localizable.xcstrings", import.meta.url), "utf8"),
  ) as { strings: Record<string, unknown> };
  expect(catalog.strings["retry.askParent"]).toBeUndefined();
});
