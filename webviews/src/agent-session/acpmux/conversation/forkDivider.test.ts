// l10n-allow-file: test fixtures (model, harness and chat names), not shipped UI.
// Leo 2026-11-11: "you select a different model. So say you select ChatGPT. That's implicitly you're
// forking it, right? So all it should be is like, you know, it looks like there's a line, and it's
// like, you know, forked from previous ... from that point on, then it just looks like it's
// ChatGPT", and: "An extra menu with a questionnaire is not seamless." A model switch forks the
// chat in this pane with no review or question; the transcript shows one divider naming what the
// chat ran, from acpmux's record (`forkOrigin`), and from then on the chat is the new model.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { translate } from "../i18n";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = (["window", "document"] as const).map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, { window: dom.window, document: dom.window.document });
});
afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

const settle = async (check: () => boolean) => {
  // timeout: test-only bound; a state that never comes fails the test instead of hanging it.
  const deadline = performance.now() + 2_000;
  while (!check()) {
    if (performance.now() > deadline) throw new Error("timed out");
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  }
};

const catalog = [
  {
    id: "claude",
    name: "Claude Code",
    family: "claude",
    models: [{ id: "claude-opus-5-5", name: "Claude Opus 5.5" }],
  },
  { id: "codex", name: "Codex", family: "codex", models: [{ id: "gpt-6.1-sol", name: "GPT-6.1 Sol" }] },
] as unknown as AcpmuxSnapshot["catalog"];

const entry = (fields: Record<string, unknown>) =>
  ({ displayTitle: "", ...fields }) as unknown as import("../sessionList").AcpmuxSessionEntry;

test("a switch's divider names the model the chat ran, from acpmux's record", async () => {
  const { forkDividers, withForkDividers } = await import("./forkDivider");
  const sessions = [
    entry({ sessionId: "a", harness: "claude", title: "Fix the login page" }),
    entry({
      sessionId: "b",
      harness: "codex",
      parentId: "a",
      forkSeq: 9,
      forkOrigin: { sessionId: "a", harness: "claude", family: "claude", model: "claude-opus-5-5" },
    }),
  ];
  const dividers = forkDividers("b", sessions, catalog, translate, true);
  expect(dividers).toEqual([{ label: "Forked from Claude Opus 5.5", parentId: "a", openInTab: { sessionId: "b", parentId: "a" } }]);
  const rows: AcpmuxRow[] = [
    { id: "u1", version: 1, at: 1, kind: "user", text: "hi" },
    { id: "forked-from-10", forkParentId: "a", version: 1, at: 2, kind: "notice", text: "Forked from Fix the login page." },
    { id: "u2", version: 1, at: 3, kind: "user", text: "now you" },
  ];
  const drawn = withForkDividers(rows, dividers);
  expect(drawn[1]!.forkDivider?.label).toBe("Forked from Claude Opus 5.5");
  expect(drawn[0]).toBe(rows[0]!);
  // Without a native host there is no tab to open: the line only.
  expect(forkDividers("b", sessions, catalog, translate, false)).toEqual([{ label: "Forked from Claude Opus 5.5", parentId: "a" }]);
});

test("a switch back names Codex's model, an earlier cut its own, and an id never reads as code", async () => {
  const { forkDividers, withForkDividers, forkOriginName } = await import("./forkDivider");
  const sessions = [
    entry({ sessionId: "a", harness: "claude", title: "Fix the login page" }),
    entry({
      sessionId: "b",
      harness: "codex",
      parentId: "a",
      forkOrigin: { sessionId: "a", harness: "claude", model: "claude-opus-5-5" },
    }),
    entry({
      sessionId: "c",
      harness: "claude",
      parentId: "b",
      forkOrigin: { sessionId: "b", harness: "codex", model: "gpt-6.1-sol" },
    }),
  ];
  const dividers = forkDividers("c", sessions, catalog, translate, true);
  expect(dividers.map((d) => d?.label)).toEqual(["Forked from GPT-6.1 Sol", "Forked from Claude Opus 5.5"]);
  // Only the shown chat's own cut moves it to a tab.
  expect(dividers[1]?.openInTab).toBeUndefined();
  const rows = [
    { id: "forked-from-3", forkParentId: "a", version: 1, at: 1, kind: "notice" },
    { id: "forked-from-7", forkParentId: "b", version: 1, at: 2, kind: "notice" },
  ] as AcpmuxRow[];
  expect(withForkDividers(rows, dividers).map((row) => row.forkDivider?.label)).toEqual([
    "Forked from Claude Opus 5.5",
    "Forked from GPT-6.1 Sol",
  ]);
  // A model the catalog does not list: a Claude id read out, else the harness's name.
  expect(forkOriginName({ sessionId: "a", harness: "claude", model: "claude-sonnet-9-1" }, catalog, translate)).toBe(
    "Sonnet 9.1",
  );
  expect(forkOriginName({ sessionId: "a", harness: "codex", model: "x-internal-17" }, catalog, translate)).toBe(
    "Codex",
  );
  expect(forkOriginName({ sessionId: "a", harness: "codex" }, catalog, translate)).toBe("Codex");
});

test("an ordinary fork's divider names its chat, and one whose chat is gone keeps acpmux's line", async () => {
  const { forkDividers } = await import("./forkDivider");
  const sessions = [
    entry({ sessionId: "a", harness: "claude", title: "Fix the login page" }),
    entry({ sessionId: "b", harness: "claude", parentId: "a", forkSeq: 4 }),
    entry({ sessionId: "c", harness: "claude", parentId: "gone", forkSeq: 4 }),
  ];
  expect(forkDividers("b", sessions, catalog, translate, true)).toEqual([{ label: "Forked from Fix the login page", parentId: "a" }]);
  expect(forkDividers("c", sessions, catalog, translate, true)).toEqual([undefined]);
  expect(forkDividers("a", sessions, catalog, translate, true)).toEqual([]);
});

test("late divider metadata and renamed parents reach the transcript's outer frame", async () => {
  const { sameRowFrame } = await import("../virtualTranscriptModel");
  const row: AcpmuxRow = { id: "forked-from-10", forkParentId: "a", version: 1, at: 2, kind: "notice", text: "Earlier chat" };
  const named = { ...row, forkDivider: { label: "Forked from Claude Opus 5.5" } };
  expect(sameRowFrame({ row }, { row: named })).toBe(false);
  expect(sameRowFrame({ row: named }, { row: { ...named } })).toBe(true);
  const renamed = { ...named, forkDivider: { label: "Forked from Retry upload" } };
  expect(sameRowFrame({ row: named }, { row: renamed })).toBe(false);
  const linked = { ...named, forkDivider: { ...named.forkDivider, openInTab: { sessionId: "b", parentId: "a" } } };
  expect(sameRowFrame({ row: named }, { row: linked })).toBe(false);
  const retargeted = { ...linked, forkDivider: { ...linked.forkDivider, openInTab: { sessionId: "b", parentId: "c" } } };
  expect(sameRowFrame({ row: linked }, { row: retargeted })).toBe(false);
});

test("the session list reads acpmux's forkOrigin", async () => {
  const { sessionEntry } = await import("../sessionList");
  const read = sessionEntry({
    sessionId: "b",
    harness: "codex",
    parentId: "a",
    forkOrigin: { sessionId: "a", harness: "claude", family: "claude", model: "claude-opus-5-5" },
  });
  expect(read.forkOrigin).toEqual({ sessionId: "a", harness: "claude", family: "claude", model: "claude-opus-5-5" });
  expect(sessionEntry({ sessionId: "x", forkOrigin: { harness: "claude" } }).forkOrigin).toBeUndefined();
});

// The switch itself, on the mock daemon: a pick of Codex's model then a send forks the chat in this
// pane (no review: no `_acpmux/handoff*` request), and the pane is the new model's from then on
// (its header, model chip and permission mode read the summary).
test("a switch forks in place, asks nothing, and the chat is the new model's from then on", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const { forgetTail } = await import("../tailCache");
  const { forkDividers } = await import("./forkDivider");
  forgetTail(mockHost.sessionId!);
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const requests: string[] = [];
  const send = socket.send.bind(socket);
  socket.send = (data: string) => {
    requests.push(String(JSON.parse(data).method ?? ""));
    return send(data);
  };
  let shown: AcpmuxSnapshot | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      if ((snapshot as { type?: string }).type === "snapshot") shown = snapshot;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const source = mockHost.sessionId!;
    await settle(() => shown?.summary?.sessionId === source && shown.canFork === true);
    const before = shown!.summary!;
    expect(before.harness).toBe("claude");
    const beforeMode = before.modes?.currentModeId;
    // The model menu holds the pick (ComposerPickers); the composer's send forks onto it
    // (App.tsx `chat.switchModel`, which calls forkTo and then sends the message there).
    const { holdFork, heldFork, sendHeldFork } = await import("../forkHold");
    holdFork({ sessionId: source, harness: "codex", model: "gpt-6-astra" });
    const forked = (await sendHeldFork(source, { fork: (pick) => client.forkTo(pick) }))!;
    expect(heldFork(source)).toBeUndefined();
    await settle(
      () => shown?.summary?.sessionId === forked && shown.rows.some((row) => row.id.startsWith("forked-from-")),
    );
    // No review, no question: Continue In…'s requests were never made.
    expect(requests.filter((method) => /handoff_(prepare|draft|start)/.test(method))).toEqual([]);
    // The chat is Codex's now, on the picked model, in Codex's own permission modes.
    const after = shown!.summary!;
    expect(after.harness).toBe("codex");
    expect(after.model).toBe("gpt-6-astra");
    expect(after.modes?.availableModes.map((mode) => mode.id)).not.toEqual(
      before.modes?.availableModes.map((mode) => mode.id),
    );
    expect(after.modes?.currentModeId).not.toBe(beforeMode);
    // The earlier conversation stays above the cut, and the cut names what the chat ran.
    const cut = shown!.rows.findIndex((row) => row.id.startsWith("forked-from-"));
    expect(cut).toBeGreaterThan(0);
    const listed = shown!.sessions.find((s) => s.sessionId === forked);
    expect(listed?.forkOrigin).toMatchObject({ sessionId: source, harness: "claude", model: before.model });
    const [divider] = forkDividers(forked, shown!.sessions, shown!.catalog, translate, true);
    expect(divider?.label).toMatch(/^Forked from \S/);
    // A name, never the model's id.
    expect(divider?.label).not.toContain(String(before.model));
    expect(divider?.openInTab).toEqual({ sessionId: forked, parentId: source });
  } finally {
    client.close?.();
  }
});

test("an earlier-turn fork labels only the ancestor cuts actually inherited, even after renumbering", async () => {
  const { forkDividers, withForkDividers } = await import("./forkDivider");
  const sessions = [
    entry({ sessionId: "a", title: "Original" }),
    entry({ sessionId: "b", parentId: "a", forkSeq: 9,
      forkOrigin: { sessionId: "a", harness: "claude", model: "claude-opus-5-5" } }),
    entry({ sessionId: "c", parentId: "b", forkSeq: 19,
      forkOrigin: { sessionId: "b", harness: "codex", model: "gpt-6.1-sol" } }),
    entry({ sessionId: "d", parentId: "c", forkSeq: 15 }),
  ];
  const dividers = forkDividers("d", sessions, catalog, translate, true);
  const rows = [
    { id: "forked-from-2", forkParentId: "a", version: 1, at: 1, kind: "notice" },
    { id: "forked-from-8", forkParentId: "c", version: 1, at: 2, kind: "notice" },
  ] as AcpmuxRow[];
  const drawn = withForkDividers(rows, dividers);
  expect(drawn[0]!.forkDivider?.label).toBe("Forked from Claude Opus 5.5");
  expect(drawn[1]!.forkDivider?.openInTab).toBeUndefined();
  // A paginated window containing only the older cut keeps its own identity too.
  expect(withForkDividers(rows.slice(0, 1), dividers)[0]!.forkDivider?.label).toBe("Forked from Claude Opus 5.5");
});
