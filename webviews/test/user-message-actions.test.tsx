// A prompt's action row under its bubble follows Leo's spec (2026-10-21), after Claude's: the read receipt (one check delivered, two read, "Read by
// <agent>"), its age ("3 days ago", the exact time on hover), a dot, then Copy, Retry and Fork, then
// cmux's Edit; no Pin. Before, a prompt showed a lone bookmark there and a steer said "Steered · the
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
// Each item of the row by its name: a control's label (Retry's wrapper by its button's), else its text.
const labels = () =>
  [...host.querySelectorAll(".cv-user__actions > *")].map(
    (node) =>
      node.getAttribute("aria-label") ??
      node.querySelector("button")?.getAttribute("aria-label") ??
      node.textContent?.trim(),
  );
/// The tooltip text an item of the row shows on hover (its `title`, which ui/titleTooltips.ts draws).
const tooltip = (selector: string) => host.querySelector(`.cv-user__actions ${selector}`)?.getAttribute("title");

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

test("a read prompt's row is Leo's: check, age, dot, Copy, Retry, Fork, each naming itself; no Pin", async () => {
  const forked: number[] = [];
  const sent: [string, string][] = [];
  const row: AcpmuxRow = {
    id: "user-4",
    version: 1,
    at: Date.now() - 3 * 24 * HOUR - 60_000,
    kind: "user",
    seq: 4,
    text: "Cover it",
  };
  await draw(row, {
    edit: { seqs: new Map([["user-4", 3]]), send: async () => true },
    fork: (seq: number) => forked.push(seq),
    forkAny: true,
    retry: (rowId: string, prompt: string) => sent.push([rowId, prompt]),
    // Fork goes through the prompt's own turn, the one its summary closes.
    promptTurns: new Map([["user-4", 5]]),
    route: { name: "Claude Code", harness: "claude" },
  });
  // Leo's row, then cmux's own Edit where the chat can fork before the prompt.
  expect(labels()).toEqual(["Read by Claude Code", "3 days ago", "·", "Copy", "Retry", "Fork from here", "Edit"]);
  expect(host.querySelector(".cv-message-pin")).toBeNull();
  expect(host.querySelector(".cv-user__read")?.getAttribute("data-read")).toBe("true");
  expect(host.querySelector("time.cv-user__time")?.getAttribute("dateTime")).toBe(new Date(row.at).toISOString());
  // Each names itself on hover; the time gives its exact date and time.
  expect(tooltip(".cv-user__read")).toBe("Read by Claude Code");
  expect(tooltip("time")?.replace(/\s/g, " ")).toBe(
    new Date(row.at)
      .toLocaleString("en-US", {
        year: "numeric",
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      })
      .replace(/\s/g, " "),
  );
  expect(tooltip('button[aria-label="Copy"]')).toBe("Copy");
  expect(tooltip('button[aria-label="Retry"]')).toBe("Retry");
  expect(tooltip('button[aria-label="Fork from here"]')).toBe("Fork from here");
  const forkButton = host.querySelector<HTMLButtonElement>('button[aria-label="Fork from here"]')!;
  expect(forkButton.getAttribute("data-tooltip-detail")).toBe(
    "Starts a new session from this point. This one stays as it is.",
  );
  act(() => forkButton.click());
  expect(forked).toEqual([5]);
  act(() => host.querySelector<HTMLButtonElement>('button[aria-label="Retry"]')!.click());
  expect(sent).toEqual([["user-4", "Cover it"]]);
});

test("a chat that cannot fork at a prompt hides Fork there rather than showing it disabled", async () => {
  await draw(
    { id: "user-2", version: 1, at: Date.now(), kind: "user", seq: 2, text: "First" },
    { fork: () => {}, forkSeq: 9, promptTurns: new Map([["user-2", 3]]), retry: () => {} },
  );
  expect(labels()).toEqual(["Read by the agent", "just now", "·", "Copy", "Retry"]);
});

test("a prompt still being sent has no receipt, and one that cannot fork offers no Fork", async () => {
  await draw({ id: "user-9", version: 1, at: Date.now(), kind: "user", pending: true, text: "Next" }, {});
  expect(labels()).toEqual(["just now", "·", "Copy"]);
});

test("a steer the agent has not read yet shows one check: delivered when the step ends", async () => {
  await draw({ id: "user-9", version: 1, at: Date.now(), kind: "user", steer: "waiting", text: "Also this" }, {});
  expect(labels()).toEqual(["Delivered when the current step ends", "just now", "·", "Copy"]);
  expect(host.querySelector(".cv-user__read")?.getAttribute("data-read")).toBe("false");
  // No "Steering" / "Steered" line under the bubble any more.
  expect(host.textContent).not.toContain("Steer");
});

test("a read steer reads Read by the agent when the chat names no agent", async () => {
  await draw({ id: "user-9", version: 1, at: Date.now(), kind: "user", steer: "landed", text: "Also this" }, {});
  expect(labels()).toEqual(["Read by the agent", "just now", "·", "Copy"]);
  // The same two checks as any read prompt, and no "Steered · the agent read it" line.
  expect(host.querySelector(".cv-user__read")?.getAttribute("data-read")).toBe("true");
  expect(host.textContent).not.toContain("Steer");
});

test("Retry under a prompt sends it again (shown under every prompt)", async () => {
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
  expect(labels()).toEqual(["Delivered when the current step ends", "just now", "·", "Copy"]);
  await draw({ ...steer, steer: "landed", delivery }, {});
  expect(labels()).toEqual(["Read by the agent", "just now", "·", "Copy"]);
});

test("a prompt this pane sent shows no receipt on its way, one check once delivered, two once read", async () => {
  const sent = { promptId: "p-2", sessionId: "s-1", sentAt: Date.now() };
  const prompt: AcpmuxRow = { id: "user-8", version: 1, at: Date.now(), kind: "user", seq: 8, text: "Ship it" };
  await draw({ ...prompt, delivery: { ...sent, state: "sending" } }, {});
  expect(labels()).toEqual(["just now", "·", "Copy"]);
  await draw({ ...prompt, delivery: { ...sent, state: "delivered" } }, {});
  expect(labels()).toEqual(["Delivered", "just now", "·", "Copy"]);
  await draw({ ...prompt, delivery: { ...sent, state: "read" } }, { route: { name: "Codex" } });
  expect(labels()).toEqual(["Read by Codex", "just now", "·", "Copy"]);
});

test("the relative time words a message's age as Claude's hover row does, in the pane's language", async () => {
  const { relativeTime } = await import("../src/agent-session/acpmux/conversation/relativeTime");
  const now = Date.UTC(2026, 9, 21, 13, 16);
  const MINUTE = 60_000;
  const DAY = 24 * HOUR;
  expect(relativeTime(now, now, "en-US")).toBe("just now");
  expect(relativeTime(now - 59_000, now, "en-US")).toBe("just now");
  expect(relativeTime(now - MINUTE, now, "en-US")).toBe("1 minute ago");
  expect(relativeTime(now - 5 * MINUTE, now, "en-US")).toBe("5 minutes ago");
  // Each unit starts at its full length and rounds within it, as Claude's (Math.round of the
  // negative count rounds a half toward now).
  expect(relativeTime(now - 59 * MINUTE, now, "en-US")).toBe("59 minutes ago");
  expect(relativeTime(now - HOUR, now, "en-US")).toBe("1 hour ago");
  expect(relativeTime(now - 90 * MINUTE, now, "en-US")).toBe("1 hour ago");
  expect(relativeTime(now - 15 * HOUR, now, "en-US")).toBe("15 hours ago");
  expect(relativeTime(now - 23.6 * HOUR, now, "en-US")).toBe("24 hours ago");
  expect(relativeTime(now - DAY, now, "en-US")).toBe("yesterday");
  expect(relativeTime(now - 36 * HOUR, now, "en-US")).toBe("yesterday");
  expect(relativeTime(now - 3 * DAY, now, "en-US")).toBe("3 days ago");
  // Past a week it keeps counting; it never switches to a date.
  expect(relativeTime(now - 7 * DAY, now, "en-US")).toBe("last week");
  expect(relativeTime(now - 15 * DAY, now, "en-US")).toBe("2 weeks ago");
  expect(relativeTime(now - 30 * DAY, now, "en-US")).toBe("last month");
  expect(relativeTime(now - 100 * DAY, now, "en-US")).toBe("3 months ago");
  expect(relativeTime(now - 400 * DAY, now, "en-US")).toBe("last year");
  // Ahead of the minute clock: still just now, never "in 1 minute".
  expect(relativeTime(now + 30_000, now, "en-US")).toBe("just now");
  expect(relativeTime(now + 5 * MINUTE, now, "en-US")).toBe("just now");
  // Other languages: Intl's words, and their own word for now.
  expect(relativeTime(now - 3 * HOUR, now, "de")).toBe("vor 3 Stunden");
  expect(relativeTime(now - DAY, now, "de")).toBe("gestern");
  expect(relativeTime(now - 10_000, now, "de")).toBe("jetzt");
});

test("the hover tooltip writes the exact time as Claude's: Oct 20, 2026, 10:16 PM", async () => {
  const { exactTime: exact } = await import("../src/agent-session/acpmux/conversation/relativeTime");
  // ICU puts a narrow no-break space before AM/PM; it reads as a space.
  const exactTime = (at: number, locale?: string) => exact(at, locale).replace(/\s/g, " ");
  // Built in local time, so the fields read back the same in any time zone.
  const evening = new Date(2026, 9, 20, 22, 16).getTime();
  expect(exactTime(evening, "en-US")).toBe("Oct 20, 2026, 10:16 PM");
  expect(exactTime(new Date(2026, 0, 5, 9, 3).getTime(), "en-US")).toBe("Jan 5, 2026, 9:03 AM");
  // The same fields in the pane's language.
  expect(exactTime(evening, "de")).toBe("20. Okt. 2026, 22:16");
  // A tag Intl refuses falls back to the system's language, never a throw.
  expect(() => exactTime(evening, "not a language")).not.toThrow();
});

test("the time under a prompt names its exact time, shown above it", async () => {
  const at = new Date(2026, 9, 20, 22, 16).getTime();
  await draw({ id: "user-3", version: 1, at, kind: "user", seq: 3, text: "Ship it" }, {});
  const time = host.querySelector("time.cv-user__time")!;
  expect(time.getAttribute("title")?.replace(/\s/g, " ")).toBe("Oct 20, 2026, 10:16 PM");
  expect(time.getAttribute("data-tooltip-side")).toBe("top");
});
