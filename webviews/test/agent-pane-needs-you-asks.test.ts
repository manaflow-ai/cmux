// Needs you's asks (needsYou/asks.ts) are acpmux's pending permission requests in every watched
// chat. An ask answered anywhere (its card, the Feed, `acpmux session allow`, another pane) must
// leave the list: a count of zero clears the chat at once, a count the page cannot account for or
// an answer rereads `_acpmux/info`, and a read that predates a newer ask or a newer read is dropped,
// so a slow read never brings back an answered ask or drops a new one.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import {
  AskTracker,
  PENDING_ASKS_OP,
  pendingReader,
  SIDE_SESSION_METHOD,
  type PendingEntry,
} from "../src/agent-session/acpmux/needsYou/asks";
import { needsYouItems } from "../src/agent-session/acpmux/needsYou/model";
import { sessionEntry } from "../src/agent-session/acpmux/sessionList";

const parse = (message: unknown, sessionId: string): AcpmuxPermission | undefined => {
  const id = (message as { permissionId?: unknown }).permissionId;
  return typeof id === "string"
    ? { permissionId: id, pending: true, options: [], title: `${sessionId}:${id}` }
    : undefined;
};

type Read = { sessionId: string; resolve(entries: readonly PendingEntry[] | undefined): void };

function tracker(now = () => 1000) {
  const reads: Read[] = [];
  let changes = 0;
  const asks = new AskTracker(
    (sessionId) => new Promise((resolve) => reads.push({ sessionId, resolve })),
    parse,
    () => void changes++,
    now,
  );
  return { asks, reads, changes: () => changes };
}
const ids = (asks: AskTracker) => asks.list().map((ask) => ask.permission.permissionId);
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a pending notification adds an ask once, and the list keeps its identity until a change", () => {
  const { asks, changes } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  expect(ids(asks)).toEqual(["p1"]);
  expect(changes()).toBe(1);
  expect(asks.list()).toBe(asks.list());
  expect(asks.list()[0]!.at).toBe(1000);
});

test("a count of zero clears the chat's asks with no read", () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.pending({ sessionId: "s2", permissionId: "p2" });
  asks.session({ sessionId: "s1", pendingPermissions: 0 });
  expect(ids(asks)).toEqual(["p2"]);
  expect(reads).toHaveLength(0);
});

test("an answer elsewhere rereads the chat, and the read's list wins", async () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  // The count still reads 1 (a new ask took the answered one's place), but the change is an answer.
  asks.session({ sessionId: "s1", pendingPermissions: 1 }, "permission_decision");
  expect(reads).toHaveLength(1);
  reads[0]!.resolve([{ permissionId: "p3", request: {}, turnId: "t3" }]);
  await settle();
  expect(ids(asks)).toEqual(["p3"]);
  expect(asks.list()[0]!.permission.turnId).toBe("t3");
});

test("an ask answered in a Chief chat leaves when the host's reread (the pane's own daemon) lists fewer", async () => {
  // The host reads the pane's own acpmux; for a Chief pane that is the Chief home's daemon, which
  // holds the chat, so the reread answers its smaller list instead of null (PR #22646 review).
  const daemon: Record<string, PendingEntry[]> = {
    chief: [
      { permissionId: "c1", request: {}, turnId: "t1" },
      { permissionId: "c2", request: {}, turnId: "t2" },
    ],
  };
  const read = pendingReader(
    () => true,
    async (_op, params) => {
      const entries = daemon[String(params.sessionId)];
      return entries ? { pending: entries } : null;
    },
    async () => {
      throw new Error("Refused by the cmux host");
    },
  );
  const asks = new AskTracker(
    read,
    parse,
    () => {},
    () => 1000,
  );
  asks.pending({ sessionId: "chief", permissionId: "c1" });
  asks.pending({ sessionId: "chief", permissionId: "c2" });
  expect(ids(asks)).toEqual(["c1", "c2"]);
  daemon.chief = [{ permissionId: "c2", request: {}, turnId: "t2" }];
  asks.session({ sessionId: "chief", pendingPermissions: 1 }, "permission_decision");
  await settle();
  expect(ids(asks)).toEqual(["c2"]);
  // A host that answers null for the chat (a read of the wrong daemon) would keep what the page holds.
  const stale = new AskTracker(
    pendingReader(
      () => true,
      async () => null,
      async () => undefined,
    ),
    parse,
    () => {},
    () => 1000,
  );
  stale.pending({ sessionId: "chief", permissionId: "c1" });
  stale.session({ sessionId: "chief", pendingPermissions: 1 }, "permission_decision");
  await settle();
  expect(ids(stale)).toEqual(["c1"]);
});

test("a chat is read once per reported count, not on every summary change", () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.session({ sessionId: "s1", pendingPermissions: 1 }, "status");
  asks.session({ sessionId: "s1", pendingPermissions: 1 }, "status");
  asks.session({ sessionId: "s1", pendingPermissions: 1 }, "title");
  expect(reads).toHaveLength(1);
  // A new request with the count unchanged (one answered, one asked) is read again.
  asks.session({ sessionId: "s1", pendingPermissions: 1 }, "permission_request");
  expect(reads).toHaveLength(2);
});

test("an ask answered while a newer ask arrives during the read still leaves", async () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "old" });
  asks.session({ sessionId: "s1", pendingPermissions: 1 }, "permission_decision");
  // "old" was answered elsewhere; "new" arrives while the read is out.
  asks.pending({ sessionId: "s1", permissionId: "new" });
  reads[0]!.resolve([]);
  await settle();
  expect(ids(asks)).toEqual(["new"]);
});

test("grouped requests are left to their group card", async () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "g1", groupId: "grp" });
  expect(ids(asks)).toEqual([]);
  asks.session({ sessionId: "s1", pendingPermissions: 2 });
  reads[0]!.resolve([{ permissionId: "g2", groupId: "grp" }, { permissionId: "solo" }]);
  await settle();
  expect(ids(asks)).toEqual(["solo"]);
});

test("asks found by a read (opened before the page saw them) are dated by the chat's last change", async () => {
  const { asks, reads } = tracker(() => 5000);
  asks.sessions([{ sessionId: "s1", pendingPermissions: 2, updatedAt: 1200 }]);
  reads[0]!.resolve([{ permissionId: "a" }, { permissionId: "b" }]);
  await settle();
  expect(ids(asks)).toEqual(["a", "b"]);
  expect(asks.list().map((ask) => ask.at)).toEqual([1200, 1200]);
});

test("a read that predates a newer ask or a newer read is dropped", async () => {
  const { asks, reads } = tracker();
  asks.session({ sessionId: "s1", pendingPermissions: 1 });
  // The ask arrives while the first read is out: that read may not include it.
  asks.pending({ sessionId: "s1", permissionId: "new" });
  reads[0]!.resolve([]);
  await settle();
  expect(ids(asks)).toEqual(["new"]);
  // Two reads out at once: only the newer counts, however they land.
  asks.session({ sessionId: "s1", pendingPermissions: 2 });
  asks.session({ sessionId: "s1", pendingPermissions: 2 }, "permission_resolved");
  reads[2]!.resolve([{ permissionId: "new" }, { permissionId: "late" }]);
  await settle();
  reads[1]!.resolve([]);
  await settle();
  expect(ids(asks)).toEqual(["new", "late"]);
});

test("a read that fails, or a chat that cannot be read, keeps what the page holds; a purge drops it", async () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.session({ sessionId: "s1", pendingPermissions: 2 });
  reads[0]!.resolve(undefined);
  await settle();
  expect(ids(asks)).toEqual(["p1"]);
  asks.forget("s1");
  expect(ids(asks)).toEqual([]);
});

test("after a lag every chat with open requests is read again, and a chat no longer listed is dropped", async () => {
  const { asks, reads } = tracker();
  asks.sessions([
    { sessionId: "s1", pendingPermissions: 1 },
    { sessionId: "gone", pendingPermissions: 1 },
  ]);
  reads[0]!.resolve([{ permissionId: "p1" }]);
  reads[1]!.resolve([{ permissionId: "p-gone" }]);
  await settle();
  expect(ids(asks)).toEqual(["p1", "p-gone"]);
  // The lag may have hidden p1's answer and a new ask, with the count unchanged; "gone" was purged.
  asks.resync([
    { sessionId: "s1", pendingPermissions: 1 },
    { sessionId: "idle", pendingPermissions: 0 },
  ]);
  expect(ids(asks)).toEqual(["p1"]);
  expect(reads.slice(2).map((read) => read.sessionId)).toEqual(["s1"]);
  reads[2]!.resolve([{ permissionId: "p2" }]);
  await settle();
  expect(ids(asks)).toEqual(["p2"]);
});

test("a lag on named chats rereads only those and drops no other chat", () => {
  const { asks, reads } = tracker();
  asks.pending({ sessionId: "s1", permissionId: "p1" });
  asks.pending({ sessionId: "s2", permissionId: "p2" });
  asks.resync([{ sessionId: "s2", pendingPermissions: 1 }], new Set(["s2"]));
  expect(reads.map((read) => read.sessionId)).toEqual(["s2"]);
  expect(ids(asks)).toEqual(["p1", "p2"]);
});

test("a read still out for a chat that is dropped never brings its asks back", async () => {
  const { asks, reads } = tracker();
  asks.sessions([{ sessionId: "s1", pendingPermissions: 1 }]);
  asks.resync([]);
  reads[0]!.resolve([{ permissionId: "late" }]);
  await settle();
  expect(ids(asks)).toEqual([]);
});

// A chat on another computer (an SSH or Cloud peer's) is listed by this daemon with its `peer`
// (acpmux hub/peers.rs `remote_summary`) and its pending count. Its asks are that computer's: the
// page never reads them (a read of a peer's chat is forwarded to the peer daemon, acpmux
// server/peer_forward.rs), so the chat stays one `input` item with no Allow or Deny (PR #22646 review).
test("a chat on another computer is never read, and stays an input item with no answers", async () => {
  const { asks, reads } = tracker();
  const far = {
    sessionId: "far",
    name: "build-host/fix",
    peer: "build-host",
    pendingPermissions: 2,
    indicator: "input",
  };
  const near = { sessionId: "near", name: "near", pendingPermissions: 1 };
  asks.sessions([far, near]);
  expect(reads.map((read) => read.sessionId)).toEqual(["near"]);
  asks.session({ ...far, pendingPermissions: 3 }, "permission_request");
  asks.session({ ...far, pendingPermissions: 3 }, "permission_decision");
  asks.resync([far, near]);
  asks.resync([far], new Set(["far"]));
  expect(reads.map((read) => read.sessionId)).toEqual(["near", "near"]);
  // A pending notice for the peer's chat (relayed by the watch) is not drawn as an answerable ask.
  asks.pending({ sessionId: "far", permissionId: "p-far" });
  expect(ids(asks)).toEqual([]);

  const items = needsYouItems({
    sessions: [sessionEntry(far)],
    // Even an ask the page somehow holds for it is not offered: that computer answers it.
    asks: [{ sessionId: "far", permission: parse({ permissionId: "p-stray" }, "far")!, at: 1 }],
  });
  expect(items.map((item) => [item.id, item.kind, item.answers.length])).toEqual([["chat:far", "input", 0]]);
});

// acpmux relays a peer's request with `peer` and `via: "peer"` (server/pending.rs
// `peer_permission_pending`). It can land before that chat's summary (the snapshot's list), when
// the page does not yet know the chat is remote: the notice itself names the peer, so it is never
// held as an answerable ask (PR #22646 review).
test("a peer's pending notice that beats its chat's summary is not held as an ask", () => {
  const { asks, reads, changes } = tracker();
  asks.pending({ sessionId: "far", permissionId: "p-far", peer: "build-host", via: "peer" });
  expect(ids(asks)).toEqual([]);
  expect(changes()).toBe(0);
  // The summary arrives later and names the peer: still nothing to read or hold.
  asks.sessions([{ sessionId: "far", peer: "build-host", pendingPermissions: 1 }]);
  expect(ids(asks)).toEqual([]);
  expect(reads).toHaveLength(0);
});

// The read path, against the real allowlists rather than a stand-in: the pane's relay sends only
// the methods in AcpmuxPaneMethods.requests (Swift), so `_acpmux/info` there is refused and every
// read fails, leaving answered asks listed (PR #22646 review). In the app the read is the page op
// the host serves (AgentPageOps), and Ask about this sends a relay method the allowlist takes, with
// params its knownParams take.
const repo = path.resolve(import.meta.dir, "../..");
const swift = (file: string) =>
  readFileSync(path.join(repo, "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane", file), "utf8");
const literals = (text: string) => [...text.matchAll(/"([^"\\]+)"/g)].map((match) => match[1]!);
function swiftSet(text: string, name: string): string[] {
  const start = text.indexOf(`static let ${name}: Set<String> = [`);
  expect(start).toBeGreaterThan(-1);
  const body = text.slice(start, text.indexOf("\n    ]", start));
  // String literals outside `//` comments.
  return literals(body.replace(/\/\/.*$/gm, ""));
}

test("in the app a chat's open requests are read through the host op, never the relay", async () => {
  const relay = swiftSet(swift("AcpmuxPaneMethods.swift"), "requests");
  const ops = literals(swift("AgentPageProvider.swift").slice(0, swift("AgentPageProvider.swift").indexOf("].map")));
  expect(ops).toContain(PENDING_ASKS_OP);
  const host: string[] = [];
  const daemon: string[] = [];
  const read = pendingReader(
    () => true,
    async (op, params) => {
      host.push(`${op}:${String(params.sessionId)}`);
      return { pending: [{ permissionId: "p1" }] };
    },
    async (method) => {
      daemon.push(method);
      // The relay answers what it does not allow with a refusal.
      if (!relay.includes(method)) throw new Error("Refused by the cmux host");
      return { pending: [] };
    },
  );
  expect(await read("s1")).toEqual([{ permissionId: "p1" }]);
  expect(host).toEqual([`${PENDING_ASKS_OP}:s1`]);
  expect(daemon).toEqual([]);
  // In mock mode (an in-page daemon, no relay) it asks the daemon itself.
  const mock = pendingReader(
    () => false,
    async () => undefined,
    async (method, params) => (method === "_acpmux/info" && params.sessionId === "s1" ? { pending: [] } : undefined),
  );
  expect(await mock("s1")).toEqual([]);
  // A host that cannot read the chat answers null: the page keeps what it holds.
  expect(
    await pendingReader(
      () => true,
      async () => null,
      async () => undefined,
    )("s1"),
  ).toBeUndefined();
});

test("Ask about this sends a relay method the pane's allowlist takes, with params it knows", () => {
  const relay = swiftSet(swift("AcpmuxPaneMethods.swift"), "requests");
  expect(relay).toContain(SIDE_SESSION_METHOD);
  const params = swift("AcpmuxPaneMethods+Params.swift");
  const line = params.split("\n").find((text) => text.includes(`"${SIDE_SESSION_METHOD}": (`));
  expect(line).toBeDefined();
  const known = literals(line!.slice(line!.indexOf("(")));
  // direct.ts `btw` sends exactly these.
  for (const key of ["sessionId", "question"]) expect(known).toContain(key);
});
