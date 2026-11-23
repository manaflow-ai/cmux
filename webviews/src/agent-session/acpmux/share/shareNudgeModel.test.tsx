// l10n-allow-file: test fixtures.
// The share nudge shows once per install, on the first chat's first good reply, seen live, and
// only for a chat this Mac can share.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { memoryTipHost, type TipHost } from "../../../ui/featureTips/store";
import type { AcpmuxRow } from "../model";
import type { AcpmuxSessionEntry } from "../sessionList";
import {
  SHARE_NUDGE_ID,
  firstReplyCompleted,
  ownChats,
  shareNudgeBlocked,
  useShareNudge,
  type ShareNudgeChat,
  type ShareNudgeContext,
  type ShareNudgeState,
} from "./shareNudgeModel";
import { settleReact } from "../../../../test/support/domTeardown";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: 0,
  kind,
  ...extra,
});
const firstReply = [
  row("u1", "user"),
  row("a1", "assistant"),
  row("summary-1", "turnSummary", { status: "completed" }),
];
const session = (sessionId: string, extra: Partial<AcpmuxSessionEntry> = {}): AcpmuxSessionEntry => ({
  sessionId,
  ...extra,
});

const chat = (extra: Partial<ShareNudgeChat> = {}): ShareNudgeChat => ({
  sessionId: "s1",
  origin: "local",
  listedSessions: true,
  sessions: [session("s1")],
  rows: firstReply,
  ...extra,
});
const context: ShareNudgeContext = { nativeHost: true, quick: false, subagentPane: false, tipsOn: true };

test("the first chat's first completed reply on this Mac may show the nudge", () => {
  expect(shareNudgeBlocked(chat(), context)).toBeUndefined();
});

test("a second chat of the person's own blocks it; side chats and agent-started chats do not count", () => {
  expect(shareNudgeBlocked(chat({ sessions: [session("s1"), session("s2")] }), context)).toBe("not-first-chat");
  expect(shareNudgeBlocked(chat({ sessions: [session("s1"), session("old", { archived: true })] }), context)).toBe(
    "not-first-chat",
  );
  const helpers = [
    session("s1"),
    session("side", { side: true }),
    session("sub", { startedBy: "s1" }),
    session("spawn", { spawnedBy: "s1" }),
    session("lane", { reportsTo: "s1" }),
  ];
  expect(ownChats(helpers).map((entry) => entry.sessionId)).toEqual(["s1"]);
  expect(shareNudgeBlocked(chat({ sessions: helpers }), context)).toBeUndefined();
  // A chat tagged as reporting to itself is still the person's own.
  expect(ownChats([session("s1", { reportsTo: "s1" })]).map((entry) => entry.sessionId)).toEqual(["s1"]);
  // Before the daemon's list is read, the count is unknown.
  expect(shareNudgeBlocked(chat({ listedSessions: undefined }), context)).toBe("unlisted");
});

test("only the first reply, and only one that completed", () => {
  expect(firstReplyCompleted(firstReply)).toBe(true);
  const twoTurns = [...firstReply, row("u2", "user"), row("summary-2", "turnSummary", { status: "completed" })];
  expect(shareNudgeBlocked(chat({ rows: twoTurns }), context)).toBe("not-first-reply");
  for (const failed of [{ status: "failed" }, { status: "cancelled" }, { status: "completed", error: "boom" }])
    expect(firstReplyCompleted([row("u1", "user"), row("summary-1", "turnSummary", failed)])).toBe(false);
});

test("never for a chat this Mac cannot share, a read-only chat, or a page without sharing", () => {
  expect(shareNudgeBlocked(chat({ origin: "remote" }), context)).toBe("not-local");
  expect(shareNudgeBlocked(chat({ origin: "peer" }), context)).toBe("not-local");
  expect(shareNudgeBlocked(chat({ summary: { watching: "claude" } }), context)).toBe("read-only");
  expect(shareNudgeBlocked(chat({ sessions: [session("s1", { peer: "box" })] }), context)).toBe("peer");
  expect(shareNudgeBlocked(chat({ sessions: [session("s1", { hostKind: "cloud" })] }), context)).toBe("peer");
  expect(shareNudgeBlocked(chat(), { ...context, nativeHost: false })).toBe("no-host");
  expect(shareNudgeBlocked(chat(), { ...context, quick: true })).toBe("quick");
  expect(shareNudgeBlocked(chat(), { ...context, subagentPane: true })).toBe("subagent");
  expect(shareNudgeBlocked(chat(), { ...context, tipsOn: false })).toBe("tips-off");
});

// The hook, driven through a turn's start and end.
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
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

type Live = ShareNudgeChat & { isWorking: boolean; turnsEnded?: number };

async function mount(host: TipHost, start: Live) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT"]) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  const state: { current?: ShareNudgeState } = {};
  function Probe({ live }: { live: Live }) {
    state.current = useShareNudge(live, context, host);
    return null;
  }
  root = createRoot(dom.window.document.getElementById("root")!);
  // A render, then the app's answer: the record's read and write settle on later microtasks.
  const render = async (live: Live) => {
    await act(async () => root!.render(<Probe live={live} />));
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  };
  await render(start);
  return { state, render };
}

const running: Live = { ...chat({ rows: [row("u1", "user")] }), isWorking: true, turnsEnded: 0 };
const answered: Live = { ...chat(), isWorking: false, turnsEnded: 1 };

test("seen live, it shows once and the app keeps its record before it draws", async () => {
  const host = memoryTipHost();
  const { state, render } = await mount(host, running);
  expect(state.current?.shown).toBe(false);
  await render(answered);
  expect(state.current?.shown).toBe(true);
  // The app's claim keeps it and spends the tips' one 14-day budget.
  expect(host.records[SHARE_NUDGE_ID]).toBe("shown");
  expect(host.lastShownAt).not.toBeNull();
  await act(async () => state.current?.close());
  expect(state.current?.shown).toBe(false);
});

test("a tip that showed in the last 14 days holds the nudge for good", async () => {
  const host = memoryTipHost();
  host.lastShownAt = host.now() - 86_400_000;
  const { state, render } = await mount(host, running);
  await render(answered);
  expect(state.current?.shown).toBe(false);
  expect(host.records[SHARE_NUDGE_ID]).toBeUndefined();
});

test("a footer that lands a snapshot after the turn stops still shows it", async () => {
  const { state, render } = await mount(memoryTipHost(), running);
  await render({ ...answered, rows: [row("u1", "user"), row("a1", "assistant")] });
  expect(state.current?.shown).toBe(false);
  await render(answered);
  expect(state.current?.shown).toBe(true);
});

test("a chat reopened after its reply, or an install that already saw it, shows nothing", async () => {
  const reopened = await mount(memoryTipHost(), answered);
  await reopened.render({ ...answered });
  expect(reopened.state.current?.shown).toBe(false);
  await act(async () => root!.unmount());
  root = undefined;

  const seen = memoryTipHost({ [SHARE_NUDGE_ID]: "closed" });
  const again = await mount(seen, running);
  await again.render(answered);
  expect(again.state.current?.shown).toBe(false);
});

test("it goes when the next turn starts or a second chat appears", async () => {
  const { state, render } = await mount(memoryTipHost(), running);
  await render(answered);
  expect(state.current?.shown).toBe(true);
  await render({ ...answered, isWorking: true });
  expect(state.current?.shown).toBe(false);

  await act(async () => root!.unmount());
  root = undefined;
  const second = await mount(memoryTipHost(), running);
  await second.render(answered);
  expect(second.state.current?.shown).toBe(true);
  await second.render({ ...answered, sessions: [session("s1"), session("s2")] });
  expect(second.state.current?.shown).toBe(false);
});

test("an app that keeps no records shows no nudge", async () => {
  const host: TipHost = {
    ...memoryTipHost(),
    read: () => Promise.reject(new Error("tips.state.noRecords")),
    claim: () => Promise.reject(new Error("tips.state.unsupported")),
  };
  const { state, render } = await mount(host, running);
  await render(answered);
  expect(state.current?.shown).toBe(false);
});

test("two panes ending a turn at once: the app's claim gives it to one only", async () => {
  const host = memoryTipHost();
  // Both panes ask before either answer lands, as two windows would.
  const asked = await Promise.all([host.claim(SHARE_NUDGE_ID, undefined), host.claim(SHARE_NUDGE_ID, undefined)]);
  expect(asked.filter(Boolean)).toHaveLength(1);

  // Through the hook: a second pane on the same install draws nothing.
  const fresh = memoryTipHost();
  const first = await mount(fresh, running);
  await first.render(answered);
  expect(first.state.current?.shown).toBe(true);
  await act(async () => root!.unmount());
  root = undefined;
  const other = await mount(fresh, running);
  await other.render(answered);
  expect(other.state.current?.shown).toBe(false);
});

test("a lane another chat started does not count as the person's second chat", async () => {
  const { state, render } = await mount(memoryTipHost(), running);
  await render({ ...answered, sessions: [session("s1"), session("lane", { reportsTo: "s1" })] });
  expect(state.current?.shown).toBe(true);
});
