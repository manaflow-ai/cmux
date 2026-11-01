// l10n-allow-file: test fixture chat titles and hosts.
// Session Info's Usage (inspector/UsageSection.tsx): what a chat spent in the last 24 hours, from
// acpmux's `usageStats` on the session summary, and every session acpmux lists, this Mac's and its
// peers', sorted by 24h cost or by context. Leo, 2026-10-30: "that visibility into huge-blue guys
// was (and is?) pretty bad i feel like we can make more improvements to acpmux/cmux-next".
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { SessionInfo } from "../src/agent-session/acpmux/session-info/SessionInfo";
import { DEFAULT_SECTIONS, resetSessionInfoState } from "../src/agent-session/acpmux/session-info/sessionInfoState";
import { DEFAULT_ORDER, GROUP_SECTIONS } from "../src/agent-session/acpmux/session-info/sectionOrder";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";
import { byUsage, sameUsageStats, usageCost, usageStatsOf } from "../src/agent-session/acpmux/usageStats";
import { SessionPager, withUsage } from "../src/agent-session/acpmux/sessionPages";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/", pretendToBeVisual: true });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  resetSessionInfoState();
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  resetSessionInfoState();
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function render(node: ReactNode) {
  await act(async () => {
    root ??= createRoot(host);
    root.render(node);
  });
}

async function click(element: Element | null | undefined) {
  expect(element).toBeTruthy();
  await act(async () => {
    element!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
  });
}

const stats = (fields: Record<string, unknown>) => ({
  launcher: "claude",
  autocompact: "none",
  autocompactCap: null,
  contextTokens: null,
  contextWindow: null,
  compactions24h: 0,
  subagentsLive: 0,
  subagents1h: 0,
  subagents24h: 0,
  tokens24h: 0,
  costUsd24h: null,
  updatedAt: 1_761_800_000_000,
  ...fields,
});

/// The build box deputies the usage audit found, beside a quiet chat on this Mac.
const SESSIONS = [
  sessionEntry({
    sessionId: "this-chat",
    name: "acpmux-owner",
    harness: "claude",
    usageStats: stats({ costUsd24h: 12.4, contextTokens: 80_000, tokens24h: 4_000_000 }),
  }),
  sessionEntry({
    sessionId: "dep-fleet",
    name: "build-box/dep-fleet",
    peer: "build-box",
    harness: "claude",
    usageStats: stats({ costUsd24h: 1_420.5, contextTokens: 290_000, subagents24h: 67 }),
  }),
  sessionEntry({
    sessionId: "dep-land",
    name: "build-box/dep-land",
    peer: "build-box",
    harness: "claude",
    usageStats: stats({ costUsd24h: 1_100, contextTokens: 330_000, subagents24h: 90 }),
  }),
  // No readable transcript yet: never listed by usage.
  sessionEntry({ sessionId: "fresh", name: "fresh", harness: "codex" }),
];

test("usageStatsOf reads acpmux's usageStats; null numbers are unknown, and only autocompact none is no cap", () => {
  const parsed = usageStatsOf(
    stats({ autocompactCap: null, costUsd24h: 3.5, contextTokens: 310_000, subagents24h: 90 }),
  );
  expect(parsed).toEqual({
    launcher: "claude",
    autocompact: "none",
    compactions24h: 0,
    subagentsLive: 0,
    subagents1h: 0,
    subagents24h: 90,
    tokens24h: 0,
    contextTokens: 310_000,
    costUsd24h: 3.5,
    updatedAt: 1_761_800_000_000,
  });
  expect(parsed?.autocompactCap).toBeUndefined();
  expect(usageStatsOf(stats({ autocompactCap: 200_000 }))?.autocompactCap).toBe(200_000);
  expect(usageStatsOf(null)).toBeUndefined();
  expect(usageStatsOf({ tokens24h: 5 })).toBeUndefined();
  // Null and nonsense counts stay unknown: never a synthesized 0.
  const unread = usageStatsOf(stats({ tokens24h: null, compactions24h: -1, subagents24h: null }));
  expect(unread?.tokens24h).toBeUndefined();
  expect(unread?.compactions24h).toBeUndefined();
  expect(unread?.subagents24h).toBeUndefined();
  expect(usageStatsOf(stats({ autocompact: undefined }))?.autocompact).toBe("unknown");
  expect(usageStatsOf(stats({ autocompact: "capped", autocompactCap: 200_000 }))?.autocompact).toBe("capped");
  expect(usageStatsOf(stats({ costUsd24h: "12" }))?.costUsd24h).toBeUndefined();
  // The session list carries it on every entry, a peer's included.
  expect(SESSIONS[1]!.usageStats?.costUsd24h).toBe(1_420.5);
  expect(SESSIONS[3]!.usageStats).toBeUndefined();
});

test("sameUsageStats keeps the previous object while acpmux's numbers are the same, so a snapshot per token redraws no Usage row", () => {
  const first = sameUsageStats(stats({ costUsd24h: 3.5 }), undefined);
  // A new raw object from the next session_changed, the same numbers: the same decoded object.
  expect(sameUsageStats(stats({ costUsd24h: 3.5 }), first)).toBe(first);
  const moved = sameUsageStats(stats({ costUsd24h: 3.6 }), first);
  expect(moved).not.toBe(first);
  expect(moved?.costUsd24h).toBe(3.6);
  expect(sameUsageStats(null, first)).toBeUndefined();
});

test("byUsage ranks by 24h cost or by context, highest first, and leaves out sessions with no usage", () => {
  expect(byUsage(SESSIONS, "cost").map((entry) => entry.sessionId)).toEqual(["dep-fleet", "dep-land", "this-chat"]);
  expect(byUsage(SESSIONS, "context").map((entry) => entry.sessionId)).toEqual(["dep-land", "dep-fleet", "this-chat"]);
  expect(usageCost(1_420.5, "en")).toBe("$1,421");
  expect(usageCost(12.4, "en")).toBe("$12.40");
});

test("Usage is a folded row in the top block, after Context, valued at this chat's 24h cost", async () => {
  expect(GROUP_SECTIONS.about).toEqual(["environment", "context", "usage", "connectors"]);
  expect(DEFAULT_ORDER.indexOf("usage")).toBe(DEFAULT_ORDER.indexOf("context") + 1);
  expect(DEFAULT_SECTIONS.usage).toBe(false);
  await render(
    <SessionInfo
      summary={{ sessionId: "this-chat", cwd: "/repo", usageStats: SESSIONS[0]!.usageStats }}
      allSessions={SESSIONS}
    />,
  );
  const usage = host.querySelector<HTMLElement>('section[data-section="usage"]');
  expect(usage?.querySelector(".acpmux-session-info-section__title")?.textContent).toBe("Usage");
  expect(usage?.querySelector(".acpmux-session-info-section__meta")?.textContent).toBe("$12.40 · 24h");
  expect(usage?.querySelector(".acpmux-session-info-usage")).toBeNull();
});

test("open, Usage lists this chat's numbers, then every host's sessions by 24h cost or context; a row opens that chat", async () => {
  const opened: string[] = [];
  await render(
    <SessionInfo
      summary={{
        sessionId: "this-chat",
        cwd: "/repo",
        usageStats: usageStatsOf(
          stats({ costUsd24h: 12.4, tokens24h: 4_000_000, subagentsLive: 2, subagents1h: 5, subagents24h: 14 }),
        ),
      }}
      allSessions={SESSIONS}
      sections={{ ...DEFAULT_SECTIONS, usage: true }}
      onOpenChat={(id) => opened.push(id)}
      onCompact={() => opened.push("compact")}
    />,
  );
  const usage = host.querySelector<HTMLElement>(".acpmux-session-info-usage")!;
  const own = [...usage.querySelectorAll<HTMLElement>("li[data-usage]")].map((row) => [
    row.dataset.usage,
    row.querySelector(".acpmux-session-info-row__end")?.textContent,
  ]);
  expect(own).toEqual([
    ["cost", "$12.40"],
    ["tokens", "4M"],
    // acpmux sent no context for it: unknown, never 0.
    ["context", "—"],
    ["cap", "No cap"],
    ["compactions", "0"],
    ["subagents", "2 live · 5 in 1h · 14 in 24h"],
    ["launcher", "claude"],
  ]);
  // Each number has its next step: Compact for the context, Show for the subagents (no Subagents
  // section here, so none), and Restart with cap for no cap, disabled until acpmux can do it.
  const actions = (id: string) =>
    [...usage.querySelectorAll<HTMLButtonElement>(`li[data-usage="${id}"] button`)].map((button) => [
      button.textContent,
      button.disabled,
    ]);
  expect(actions("context")).toEqual([["Compact", false]]);
  expect(actions("cap")).toEqual([["Restart with cap", true]]);
  expect(actions("subagents")).toEqual([]);
  await click(usage.querySelector('li[data-usage="context"] button'));
  expect(opened).toEqual(["compact"]);
  opened.length = 0;
  const listed = () =>
    [...usage.querySelectorAll<HTMLElement>("ul[data-sort] > li")].map((row) => [
      row.querySelector(".acpmux-session-info-row__name")?.textContent,
      row.querySelector(".acpmux-session-info-row__detail")?.textContent ?? null,
      row.querySelector(".acpmux-session-info-row__end")?.textContent,
    ]);
  expect(listed()).toEqual([
    ["dep-fleet", "build-box", "$1,421"],
    ["dep-land", "build-box", "$1,100"],
    ["acpmux-owner", null, "$12.40"],
  ]);
  const sortBy = (label: string) =>
    [...usage.querySelectorAll<HTMLButtonElement>(".acpmux-session-info-usage__sort-option")].find(
      (option) => option.textContent === label,
    );
  expect(sortBy("24h cost")?.getAttribute("aria-pressed")).toBe("true");
  // The pressed option is the order shown, so it takes no click (inspector-dead-clicks.test.tsx).
  expect([sortBy("24h cost")?.disabled, sortBy("Context")?.disabled]).toEqual([true, false]);
  await click(sortBy("Context"));
  expect(sortBy("Context")?.getAttribute("aria-pressed")).toBe("true");
  expect([sortBy("24h cost")?.disabled, sortBy("Context")?.disabled]).toEqual([false, true]);
  expect(listed()).toEqual([
    ["dep-land", "build-box", "330K"],
    ["dep-fleet", "build-box", "290K"],
    ["acpmux-owner", null, "80K"],
  ]);
  // A peer's row opens its chat; this chat's own row is plain text (no dead click, nothing to open).
  const rows = [...usage.querySelectorAll<HTMLElement>("ul[data-sort] > li")];
  await click(rows[0]!.querySelector("button"));
  expect(opened).toEqual(["dep-land"]);
  expect(rows[2]!.querySelector("button")).toBeNull();
});

test("unknown numbers show an em dash, never 0 or $0.00, and an unread cap offers no restart", async () => {
  await render(
    <SessionInfo
      summary={{
        sessionId: "this-chat",
        usageStats: usageStatsOf({
          launcher: null,
          autocompact: "unknown",
          tokens24h: null,
          costUsd24h: null,
          updatedAt: 1,
        }),
      }}
      allSessions={[]}
      sections={{ ...DEFAULT_SECTIONS, usage: true }}
    />,
  );
  const values = Object.fromEntries(
    [...host.querySelectorAll<HTMLElement>("li[data-usage]")].map((row) => [
      row.dataset.usage,
      row.querySelector(".acpmux-session-info-row__end")?.textContent,
    ]),
  );
  expect(values).toEqual({ cost: "—", tokens: "—", context: "—", cap: "—", compactions: "—", subagents: "—" });
  expect(host.querySelectorAll("li[data-usage] button").length).toBe(0);
  // Folded, the section names no value rather than a made-up one.
  expect(host.querySelector('section[data-section="usage"] .acpmux-session-info-section__meta')).toBeNull();
});

test("sorted by 24h cost, a session whose cost is unknown shows an em dash, never its token count; by context it shows its context", async () => {
  const sessions = [
    sessionEntry({
      sessionId: "priced",
      name: "priced",
      usageStats: stats({ costUsd24h: 12.4, contextTokens: 80_000, tokens24h: 4_000_000 }),
    }),
    // acpmux read its tokens and context but not its cost (a harness with no price table).
    sessionEntry({
      sessionId: "unpriced",
      name: "unpriced",
      usageStats: stats({ costUsd24h: null, contextTokens: 210_000, tokens24h: 9_000_000 }),
    }),
  ];
  await render(
    <SessionInfo
      summary={{ sessionId: "x" }}
      allSessions={sessions}
      sections={{ ...DEFAULT_SECTIONS, usage: true }}
    />,
  );
  const usage = host.querySelector<HTMLElement>(".acpmux-session-info-usage")!;
  const listed = () =>
    [...usage.querySelectorAll<HTMLElement>("ul[data-sort] > li")].map((row) => [
      row.querySelector(".acpmux-session-info-row__name")?.textContent,
      row.querySelector(".acpmux-session-info-row__end")?.textContent,
    ]);
  expect(usage.querySelector("ul[data-sort]")?.getAttribute("data-sort")).toBe("cost");
  expect(listed()).toEqual([
    ["priced", "$12.40"],
    ["unpriced", "—"],
  ]);
  const context = [...usage.querySelectorAll<HTMLButtonElement>(".acpmux-session-info-usage__sort-option")].find(
    (option) => option.textContent === "Context",
  );
  await click(context);
  expect(listed()).toEqual([
    ["unpriced", "210K"],
    ["priced", "80K"],
  ]);
});

test("a chat with no usage of its own still shows Usage while another session reports some; none at all shows none", async () => {
  await render(<SessionInfo summary={{ sessionId: "fresh", cwd: "/repo" }} allSessions={SESSIONS} />);
  const usage = host.querySelector<HTMLElement>('section[data-section="usage"]');
  expect(usage).not.toBeNull();
  expect(usage?.querySelector(".acpmux-session-info-section__meta")).toBeNull();
  await render(<SessionInfo summary={{ sessionId: "fresh", cwd: "/repo" }} allSessions={[SESSIONS[3]!]} />);
  expect(host.querySelector('section[data-section="usage"]')).toBeNull();
});

test("more than five sessions fold behind View all", async () => {
  const many = Array.from({ length: 7 }, (_, at) =>
    sessionEntry({ sessionId: `s${at}`, name: `lane-${at}`, usageStats: stats({ costUsd24h: at }) }),
  );
  await render(
    <SessionInfo summary={{ sessionId: "x" }} allSessions={many} sections={{ ...DEFAULT_SECTIONS, usage: true }} />,
  );
  const rows = () => host.querySelectorAll("ul[data-sort] > li").length;
  expect(rows()).toBe(5);
  const fold = host.querySelector(".acpmux-session-info-usage-fold");
  expect(fold?.textContent).toBe("View all 7");
  await click(fold);
  expect(rows()).toBe(7);
});

// The usage itself has to be asked for: a plain `_acpmux/watch` or `_acpmux/sessions` read carries
// acpmux's last pass, and none at all while nothing asked since acpmux started (hub/usage_view.rs),
// so Usage and the sessions by usage list stayed empty or stale.
test("the usage read asks _acpmux/sessions for usage on every page, as the cmux host's pane policy lets it", async () => {
  const policy = JSON.parse(
    readFileSync(path.resolve(import.meta.dir, "../../cmux-tui/crates/cmux-agent-pane-policy/policy.json"), "utf8"),
  ) as { known_params: Record<string, { params: string[] }> };
  const asked: Array<{ method: string; params: Record<string, unknown> }> = [];
  const pages: Record<string, { sessions: unknown[]; nextCursor: string | null }> = {
    first: {
      sessions: [{ sessionId: "dep-fleet", usageStats: stats({ costUsd24h: 1_500 }) }, { sessionId: "fresh" }],
      nextCursor: "k1",
    },
    k1: { sessions: [{ sessionId: "dep-land", usageStats: stats({ costUsd24h: 1_200 }) }], nextCursor: null },
  };
  const pager = new SessionPager(async (method, params) => {
    asked.push({ method, params });
    return pages[(params.cursor as string | undefined) ?? "first"];
  });
  const usage = await pager.usage();
  expect(asked.map((ask) => ask.method)).toEqual(["_acpmux/sessions", "_acpmux/sessions"]);
  for (const ask of asked) {
    expect(ask.params.usage).toBe(true);
    // The host refuses a frame with a param its policy lacks (#20644): the list would be lost.
    for (const key of Object.keys(ask.params)) expect(policy.known_params["_acpmux/sessions"]!.params).toContain(key);
  }
  expect([...usage.keys()]).toEqual(["dep-fleet", "dep-land"]);
});

test("withUsage lays newer numbers over the list, keeps a turn's newer ones, and keeps the array when nothing moved", () => {
  const raw = [
    { sessionId: "dep-fleet", usageStats: stats({ costUsd24h: 1_420.5 }) },
    { sessionId: "dep-land", usageStats: stats({ costUsd24h: 1_100, updatedAt: 1_761_800_009_000 }) },
    { sessionId: "fresh" },
  ];
  const read = new Map<string, unknown>([
    ["dep-fleet", stats({ costUsd24h: 1_500, updatedAt: 1_761_800_005_000 })],
    // Older than the turn end acpmux announced meanwhile: the list keeps the turn's.
    ["dep-land", stats({ costUsd24h: 900, updatedAt: 1_761_800_005_000 })],
    ["fresh", stats({ costUsd24h: 0.4, updatedAt: 1_761_800_005_000 })],
  ]);
  const next = withUsage(raw, read);
  expect(next).not.toBe(raw);
  expect(next.map((session) => (session.usageStats as { costUsd24h?: number } | undefined)?.costUsd24h)).toEqual([
    1_500, 1_100, 0.4,
  ]);
  expect(next[1]).toBe(raw[1]);
  // The same numbers read again later: nothing to draw, the same array.
  const again = new Map<string, unknown>([["dep-fleet", stats({ costUsd24h: 1_500, updatedAt: 1_761_800_010_000 })]]);
  expect(withUsage(next, again)).toBe(next);
});

test("Session Info asks for every chat's usage once when it shows", async () => {
  let asked = 0;
  const onShowUsage = () => {
    asked += 1;
  };
  await render(
    <SessionInfo summary={{ sessionId: "fresh", cwd: "/repo" }} allSessions={SESSIONS} onShowUsage={onShowUsage} />,
  );
  expect(asked).toBe(1);
  // A redraw with the same callback asks nothing more.
  await render(
    <SessionInfo summary={{ sessionId: "fresh", cwd: "/repo" }} allSessions={SESSIONS} onShowUsage={onShowUsage} />,
  );
  expect(asked).toBe(1);
});
