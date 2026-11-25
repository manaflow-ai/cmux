// l10n-allow-file: test fixture chat names, asks and errors, not shipped UI.
// The agent status island (statusIsland/, experiment `agent-status-island`): its experiment is off
// by default, it counts running agents, picks the ask (or failure) its card shows, expands by
// itself for a new one and stays collapsed once the person folds it, and draws Allow and Deny from
// the Needs you answers.
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { experimentArm } from "../src/experiments/experiment";
import { experimentById } from "../src/experiments/registry";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { needsYouItems, type WatchedAsk } from "../src/agent-session/acpmux/needsYou/model";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import {
  islandAnswers,
  islandExpanded,
  islandState,
  islandToggle,
} from "../src/agent-session/acpmux/statusIsland/model";
import { StatusIsland } from "../src/agent-session/acpmux/statusIsland/StatusIsland";
import { statusIslandExperiment } from "../src/agent-session/acpmux/statusIsland/statusIsland.experiment";

const chat = (sessionId: string, fields: Partial<AcpmuxSessionEntry> = {}): AcpmuxSessionEntry => ({
  sessionId,
  title: sessionId,
  harness: "claude",
  updatedAt: 1_000,
  ...fields,
});
const options: AcpmuxPermission["options"] = [
  { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
  { id: "allow_always", name: "Always allow", kind: "allow_always", allow: true },
  { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
];
const ask = (sessionId: string, permissionId: string, at = 2_000): WatchedAsk => ({
  sessionId,
  at,
  permission: { permissionId, title: "Run the linter", command: "bun run lint", pending: true, options },
});
const state = (sessions: AcpmuxSessionEntry[], asks: WatchedAsk[] = []) =>
  islandState({ sessions, items: needsYouItems({ sessions, asks }) });
const working = [
  chat("a", { indicator: "working" }),
  chat("b", { indicator: "working" }),
  chat("c", { indicator: "working" }),
];
const actions = { answer: async () => undefined, goTo: () => undefined, openSession: () => undefined };
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

describe("experiment", () => {
  test("is registered and off by default", () => {
    expect(experimentById("agent-status-island")).toBe(statusIslandExperiment);
    expect(statusIslandExperiment.defaultArm).toBe("off");
    expect(experimentArm(statusIslandExperiment, { overrides: {}, stored: {} })).toBe("off");
    expect(experimentArm(statusIslandExperiment, { overrides: {}, stored: { "agent-status-island": "on" } })).toBe(
      "on",
    );
  });
});

describe("islandState", () => {
  test("idle with nothing running, running with working agents, archived and side chats aside", () => {
    expect(state([])).toEqual({ running: 0, waiting: 0, tone: "idle" });
    const s = state([
      ...working,
      chat("x", { indicator: "working", archived: true }),
      chat("y", { indicator: "working", side: true }),
    ]);
    expect(s).toEqual({ running: 3, waiting: 0, tone: "running" });
    expect(islandExpanded(s)).toBe(false);
  });

  test("an ask outranks a failure and becomes the card's focus", () => {
    const sessions = [
      ...working,
      chat("asker", { indicator: "input", pendingPermissions: 1 }),
      chat("f", { indicator: "failed" }),
    ];
    const s = state(sessions, [ask("asker", "p1")]);
    expect(s.tone).toBe("attention");
    expect(s.running).toBe(3);
    expect(s.waiting).toBe(1);
    expect(s.attention?.permissionId).toBe("p1");
    expect(s.focus).toBe("ask:acpmux:p1");
    expect(s.failure).toBeUndefined();
  });

  test("the newest failed or lost chat shows when nothing asks", () => {
    const s = state([
      chat("old", { indicator: "failed", updatedAt: 1 }),
      chat("new", { indicator: "lost", updatedAt: 5, laneError: "Machine unreachable", title: "Port the sheet" }),
    ]);
    expect(s.tone).toBe("error");
    expect(s.failure).toEqual({
      sessionId: "new",
      name: "Port the sheet",
      harness: "claude",
      error: "Machine unreachable",
    });
    expect(s.focus).toBe("failed:new:5");
  });

  test("a new failure of the same chat (a new run moved its activityAt) is a new focus", () => {
    const first = state([chat("f", { indicator: "failed", activityAt: 10, updatedAt: 10 })]);
    const warmed = state([chat("f", { indicator: "failed", activityAt: 10, updatedAt: 20 })]);
    const again = state([chat("f", { indicator: "failed", activityAt: 30, updatedAt: 30 })]);
    expect(warmed.focus).toBe(first.focus);
    expect(again.focus).not.toBe(first.focus);
    expect(islandExpanded(again, { focus: first.focus!, open: false })).toBe(true);
  });

  test("F6: the newest failure is ranked by activity, not by a warm or resume's updatedAt", () => {
    const s = state([
      chat("recent", { indicator: "failed", activityAt: 50, updatedAt: 50 }),
      // An old failure whose pane was just warmed: its updatedAt is newest, its activity is not.
      chat("warmed", { indicator: "failed", activityAt: 10, updatedAt: 90 }),
    ]);
    expect(s.failure?.sessionId).toBe("recent");
    expect(s.focus).toBe("failed:recent:50");
  });
});

describe("islandExpanded", () => {
  test("a new focus opens by itself; the one the person folded stays folded until another comes", () => {
    const first = state([chat("asker", { pendingPermissions: 1 })], [ask("asker", "p1")]);
    expect(islandExpanded(first)).toBe(true);
    const folded = { focus: first.focus!, open: false };
    expect(islandExpanded(first, folded)).toBe(false);
    const second = state([chat("asker", { pendingPermissions: 1 })], [ask("asker", "p2", 3_000)]);
    expect(islandExpanded(second, folded)).toBe(true);
  });
});

describe("islandToggle", () => {
  test("a press is kept while its focus is on show and forgotten once it clears", () => {
    const folded = { focus: "failed:f:1", open: false };
    expect(islandToggle(folded, "failed:f:1")).toBe(folded);
    expect(islandToggle(folded, undefined)).toBeUndefined();
    expect(islandToggle(folded, "ask:acpmux:p1")).toBeUndefined();
    expect(islandToggle(undefined, "failed:f:1")).toBeUndefined();
  });
});

describe("islandAnswers", () => {
  test("allow once first, then deny once: the Needs you answers, no lasting allow", () => {
    const item = state([chat("asker")], [ask("asker", "p1")]).attention!;
    expect(islandAnswers(item).map((answer) => [answer.id, answer.tone])).toEqual([
      ["allow_once", "allow"],
      ["reject_once", "deny"],
    ]);
  });
});

describe("StatusIsland", () => {
  test("compact pills: idle and three running", () => {
    expect(text(renderToStaticMarkup(<StatusIsland state={state([])} actions={actions} />))).toBe("No agents running");
    expect(text(renderToStaticMarkup(<StatusIsland state={state(working)} actions={actions} />))).toBe("3");
    // No word on the pill; its hover and VoiceOver still name it.
    expect(renderToStaticMarkup(<StatusIsland state={state(working)} actions={actions} />)).toContain(
      'aria-label="Running · 3"',
    );
  });

  test("the approval card names the asking chat and draws Allow then Deny", () => {
    const html = renderToStaticMarkup(
      <StatusIsland
        state={state([...working, chat("Tab strip review")], [ask("Tab strip review", "p1")])}
        actions={actions}
      />,
    );
    expect(html).toContain("data-expanded");
    expect(text(html)).toBe("Tab strip review Claude 3 Run the linter bun run lint Allow Deny");
    expect(html).toContain('class="acpmux-status-island__count" role="img" aria-label="Running · 3"');
  });

  test("the error card says the agent stopped, with its error and Open Chat", () => {
    const html = renderToStaticMarkup(
      <StatusIsland
        state={state([chat("Port the sheet", { indicator: "failed", laneError: "out of context" })])}
        actions={actions}
      />,
    );
    expect(text(html)).toBe("Port the sheet Claude Stopped on an error out of context Open Chat");
  });
});
