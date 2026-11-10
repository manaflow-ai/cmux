// l10n-allow-file: synthetic relay fixtures, not shipped UI.
// Side chats of a chat on another machine (a Cloud chat): `/side` is offered only when the app's
// relay lists the fork operation (the machine's daemon opens side chats), `/btw` only when it lists
// the side question, and neither turns on Fork Conversation, which that relay does not serve.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { cmuxCommandRefusal, CMUX_COMMANDS, mergedCommands, type CmuxCommand } from "./cmuxCommands";
import { canFork, forkRefusal, sideOffer } from "./conversation/messageMenu";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = new Map(["window", "document"].map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)]));
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
  dom.window.close();
});

const turn = { kind: "turnSummary", seq: 7 };
const chat = (over: Partial<AcpmuxSnapshot>): AcpmuxSnapshot =>
  ({
    isWorking: false,
    connection: "connected",
    rows: [turn],
    sessionId: "chat-1",
    summary: { sessionId: "chat-1", cwd: "/root/app", hostKind: "cloud", host: "registry:m1" },
    ...over,
  }) as unknown as AcpmuxSnapshot;
/// A Cloud chat: its folder is on the machine, so the page holds no local folder for it.
const cloud: { localCwd: string | undefined; quick: boolean } = { localCwd: undefined, quick: false };

/// The cmux commands the composer lists, as App.tsx builds them from `sideOffer`.
const offered = (snapshot: AcpmuxSnapshot, at = cloud) => {
  const offer = sideOffer(snapshot, at);
  const enabled = new Set<CmuxCommand["action"]>();
  if (offer.side) enabled.add("side");
  if (offer.btw) enabled.add("btw");
  return mergedCommands([], enabled)
    .map((command) => command.name)
    .filter((name) => name === "side" || name === "btw");
};

test("/side is offered for a Cloud chat only when its relay serves the fork", () => {
  const served = chat({ origin: "remote", canFork: false, canSide: true });
  expect(offered(served)).toContain("side");
  expect(sideOffer(served, cloud)).toMatchObject({ sideHere: true, side: true, sideRow: true, sideFork: undefined });
  // The side fork is not Fork Conversation: the turn footers and the palette's fork stay off.
  expect(canFork(served)).toBe(false);
  expect(forkRefusal(served)).toBe("unavailable");

  const older = chat({ origin: "remote", canFork: false, canSide: false, canBtw: false });
  expect(offered(older)).not.toContain("side");
  expect(sideOffer(older, cloud)).toMatchObject({ sideHere: false, side: false, sideRow: false });
});

test("/btw is not offered for a Cloud chat whose relay starts no side question", () => {
  const older = chat({ origin: "remote", canSide: false, canBtw: false });
  expect(offered(older)).not.toContain("btw");
  expect(sideOffer(older, cloud).btw).toBe(false);
  // Typed anyway, it is refused with a reason and never sent to the agent as a prompt.
  const btw = CMUX_COMMANDS.find((command) => command.action === "btw")!;
  const state = { summary: true, forkable: false, sideAvailable: false, canContinue: false, session: true };
  const refusal = cmuxCommandRefusal(btw, "why?", {
    ...state,
    sideSessions: sideOffer(older, cloud).btw,
    isSideSession: false,
    targets: [],
  });
  expect(refusal).toBe("composer.cmuxBtwDisabled");

  const served = chat({ origin: "remote", canSide: true });
  expect(offered(served)).toContain("btw");
});

test("a working Cloud chat forks into a side chat as it is now, and one with no turn has nothing yet", () => {
  const working = chat({ origin: "remote", canSide: true, isWorking: true, rows: [] });
  expect(sideOffer(working, cloud)).toMatchObject({ side: true, sideRow: false });
  const fresh = chat({ origin: "remote", canSide: true, rows: [] });
  expect(sideOffer(fresh, cloud)).toMatchObject({ side: false, sideFork: "nothingYet" });
});

test("a chat on this computer offers both as before, and Quick Chat neither", () => {
  const local = chat({
    origin: "local",
    canFork: true,
    canSide: true,
    summary: { sessionId: "chat-1", cwd: "/w" } as never,
  });
  const here = { localCwd: "/w", quick: false };
  expect(offered(local, here)).toEqual(expect.arrayContaining(["side", "btw"]));
  expect(offered(local, { localCwd: "/w", quick: true })).toEqual([]);
  // A peer's chat (another computer's acpmux) is never forked from here.
  const peer = chat({
    origin: "local",
    canFork: true,
    canSide: true,
    summary: { sessionId: "chat-1", peer: "mini" } as never,
  });
  expect(sideOffer(peer, cloud).side).toBe(false);
});

type Daemon = { answer(method: string, params: Record<string, any>): Promise<unknown> };

/// A client on a relay that calls the connection remote and lists `operations`.
async function remoteClient(operations: string[] | undefined) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const answer = daemon.answer.bind(daemon);
  const sent: string[] = [];
  daemon.answer = async (method, params) => {
    sent.push(method);
    if (method !== "initialize") return answer(method, params);
    const result = (await answer(method, params)) as { _meta: { acpmux: Record<string, unknown> } };
    const { operations: _local, ...rest } = result._meta.acpmux;
    return {
      ...result,
      _meta: { acpmux: { ...rest, origin: "remote", extensions: [], ...(operations ? { operations } : {}) } },
    };
  };
  let shown: Partial<AcpmuxSnapshot> = {};
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      if ((snapshot as { type?: string }).type === "snapshot") shown = snapshot as unknown as Partial<AcpmuxSnapshot>;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, sent, shown: () => shown };
}

test("the page reads the side chat fork and side question from the remote relay's operations", async () => {
  const served = await remoteClient(["acp.session.fork", "_acpmux/btw"]);
  expect(served.shown().origin).toBe("remote");
  expect(served.shown().canSide).toBe(true);
  expect(served.shown().canFork).toBe(false);
  expect(served.shown().canBtw).toBeUndefined();

  const older = await remoteClient(undefined);
  expect(older.shown().canSide).toBe(false);
  expect(older.shown().canFork).toBe(false);
  expect(older.shown().canBtw).toBe(false);
  // No fork is asked of a relay that lists none.
  expect(await older.client.forkAside("live")).toBeUndefined();
  expect(older.sent).not.toContain("acp.session.fork");
});
