// A prompt's action row matches Claude Code desktop's (GUI push 2026-10-20): under the bubble, its age
// ("1 hour ago"), its read receipt (one check delivered, two read, "Read by <agent>"), then Copy, Edit,
// Retry, Fork and Pin. Before, a prompt showed a lone bookmark there and a steer said "Steered · the
// agent read it" under it. The row shows on hover or focus only.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
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
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const HOUR = 3_600_000;
const labels = () =>
  [...host.querySelectorAll(".cv-user__actions > *")].map(
    (node) => node.getAttribute("aria-label") ?? node.textContent?.trim(),
  );

async function draw(row: AcpmuxRow, actions: object) {
  const { createRoot } = await import("react-dom/client");
  const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
  const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <TurnActionsContext.Provider value={actions}>
        <UserBubble row={row} text={row.text ?? ""} />
      </TurnActionsContext.Provider>,
    ),
  );
}

test("a read prompt's row reads its age, Read by the agent, Copy, Edit and Fork, in Claude's order", async () => {
  const forked: number[] = [];
  const row: AcpmuxRow = {
    id: "user-4",
    version: 1,
    at: Date.now() - HOUR - 60_000,
    kind: "user",
    seq: 4,
    text: "Cover it",
  };
  await draw(row, {
    edit: { seqs: new Map([["user-4", 3]]), send: async () => true },
    fork: (seq: number) => forked.push(seq),
    forkAny: true,
    // Fork goes through the prompt's own turn, the one its summary closes.
    promptTurns: new Map([["user-4", 5]]),
    route: { name: "Claude Code", harness: "claude" },
  });
  expect(labels()).toEqual(["1 hour ago", "Read by Claude Code", "Copy", "Edit", "Fork from here"]);
  expect(host.querySelector(".cv-user__read")?.getAttribute("data-read")).toBe("true");
  expect(host.querySelector("time.cv-user__time")?.getAttribute("dateTime")).toBe(new Date(row.at).toISOString());
  // The exact time on hover.
  expect(host.querySelector("time.cv-user__time")?.getAttribute("title")).toBeTruthy();
  const forkButton = host.querySelector<HTMLButtonElement>('button[aria-label="Fork from here"]')!;
  expect(forkButton.getAttribute("data-tooltip-detail")).toBe(
    "Starts a new session from this point. This one stays as it is.",
  );
  act(() => forkButton.click());
  expect(forked).toEqual([5]);
});

test("a prompt still being sent has no receipt, and one that cannot fork offers no Fork", async () => {
  await draw({ id: "user-9", version: 1, at: Date.now(), kind: "user", pending: true, text: "Next" }, {});
  expect(labels()).toEqual(["now", "Copy"]);
});

test("a steer the agent has not read yet shows one check: delivered when the step ends", async () => {
  await draw({ id: "user-9", version: 1, at: Date.now(), kind: "user", steer: "waiting", text: "Also this" }, {});
  expect(labels()).toEqual(["now", "Delivered when the current step ends", "Copy"]);
  expect(host.querySelector(".cv-user__read")?.getAttribute("data-read")).toBe("false");
  // No "Steering" / "Steered" line under the bubble any more.
  expect(host.textContent).not.toContain("Steer");
});

test("a read steer reads Read by the agent when the chat names no agent", async () => {
  await draw({ id: "user-9", version: 1, at: Date.now(), kind: "user", steer: "landed", text: "Also this" }, {});
  expect(labels()).toEqual(["now", "Read by the agent", "Copy"]);
});

test("Retry under a prompt sends it again (shown on the last ended turn's prompt)", async () => {
  const sent: [string, string][] = [];
  await draw(
    { id: "user-4", version: 1, at: Date.now(), kind: "user", seq: 4, text: "Cover it" },
    { retry: (rowId: string, prompt: string) => sent.push([rowId, prompt]) },
  );
  const retry = host.querySelector<HTMLButtonElement>('.cv-message-retry button[aria-label="Retry"]')!;
  act(() => retry.click());
  expect(sent).toEqual([["user-4", "Cover it"]]);
});

test("a steer this pane sent reads delivered while it waits for the agent, though acpmux recorded it", async () => {
  const delivery = { state: "read", promptId: "p-1", sessionId: "s-1", sentAt: Date.now() } as const;
  const steer: AcpmuxRow = { id: "user-7", version: 1, at: Date.now(), kind: "user", seq: 7, text: "Rebase first" };
  await draw({ ...steer, steer: "waiting", delivery }, {});
  expect(labels()).toEqual(["now", "Delivered when the current step ends", "Copy"]);
  await draw({ ...steer, steer: "landed", delivery }, {});
  expect(labels()).toEqual(["now", "Read by the agent", "Copy"]);
});

test("a prompt this pane sent shows no receipt on its way, one check once delivered, two once read", async () => {
  const sent = { promptId: "p-2", sessionId: "s-1", sentAt: Date.now() };
  const prompt: AcpmuxRow = { id: "user-8", version: 1, at: Date.now(), kind: "user", seq: 8, text: "Ship it" };
  await draw({ ...prompt, delivery: { ...sent, state: "sending" } }, {});
  expect(labels()).toEqual(["now", "Copy"]);
  await draw({ ...prompt, delivery: { ...sent, state: "delivered" } }, {});
  expect(labels()).toEqual(["now", "Delivered", "Copy"]);
  await draw({ ...prompt, delivery: { ...sent, state: "read" } }, { route: { name: "Codex" } });
  expect(labels()).toEqual(["now", "Read by Codex", "Copy"]);
});

test("the relative time words a prompt's age in the pane's language", async () => {
  const { relativeTime } = await import("../src/agent-session/acpmux/conversation/relativeTime");
  const now = Date.UTC(2026, 9, 20, 12);
  expect(relativeTime(now - 20_000, now, "en")).toBe("now");
  expect(relativeTime(now - 5 * 60_000, now, "en")).toBe("5 minutes ago");
  expect(relativeTime(now - HOUR, now, "en")).toBe("1 hour ago");
  expect(relativeTime(now - 26 * HOUR, now, "en")).toBe("yesterday");
  expect(relativeTime(now - 3 * HOUR, now, "de")).toBe("vor 3 Stunden");
  // Ahead of the minute clock: still "now", never "in 1 minute".
  expect(relativeTime(now + 30_000, now, "en")).toBe("now");
});
