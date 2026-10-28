// l10n-allow-file: test fixtures (machine names), not shipped UI.
// The machine-state feed in the composer (Leo, 2026-10-28: "you just get a little green dot ... as if
// you were working on your own computer, but now it's remote"): one word per machine, green only
// once its handshake finished, a spinner while it connects or reconnects, red when it is down; and a
// send to a down machine reconnects it first, so the turn goes out with no Reconnect click.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { rememberTail } from "../src/agent-session/acpmux/tailCache";
import {
  MachineLinkMark,
  computerLink,
  paneMachineLink,
  peerLink,
  pickableDown,
  reconnectsOnUse,
  setMachineLink,
} from "../src/agent-session/acpmux/machineLink";

test("a peer is green only once acpmux says its handshake finished", () => {
  const ssh = { kind: "ssh" as const };
  expect(peerLink({ ...ssh, state: "connected" })).toBe("connected");
  // A degraded link has a socket but no handshake yet: on its way, never green.
  for (const state of ["connecting", "reconnecting", "degraded"]) expect(peerLink({ ...ssh, state })).toBe("connecting");
  expect(peerLink({ ...ssh, state: "offline" })).toBe("offline");
  // An older daemon names no state: its connected flag, and nothing when it said nothing.
  expect(peerLink({ ...ssh, connected: true })).toBe("connected");
  expect(peerLink({ ...ssh, connected: false })).toBe("offline");
  expect(peerLink(ssh)).toBeUndefined();
  expect(peerLink({ kind: "local", state: "connected" })).toBeUndefined();
});

test("this Mac draws no mark; a chat the App runs on another machine draws the App's word", () => {
  const local = { id: "local", kind: "local" as const };
  expect(computerLink(local, undefined)).toBeUndefined();
  expect(computerLink(local, { machine: "m-1", link: "connecting", words: "Reconnecting…" })).toBe("connecting");
  expect(computerLink({ id: "gpu-box", kind: "ssh", state: "offline" }, undefined)).toBe("offline");
});

test("a down machine acpmux lists is a pick that reconnects; one it no longer lists is not", () => {
  expect(pickableDown({ id: "gpu-box", listed: true, link: "offline" })).toBe(true);
  expect(pickableDown({ id: "agent-vm-3", listed: true, link: "connecting" })).toBe(true);
  // An older daemon names no state, only its connected flag: still listed, still a pick.
  expect(pickableDown({ id: "old-daemon-peer", listed: true, link: "offline" })).toBe(true);
  expect(pickableDown({ id: "gone", link: "offline" })).toBe(false);
  expect(pickableDown({ id: "local", link: "offline" })).toBe(true);
  expect(reconnectsOnUse("offline")).toBe(true);
  expect(["connected", "connecting", "paused", undefined].some((link) => reconnectsOnUse(link as never))).toBe(false);
});

test("the mark is a dot, or the turning ring while the machine is on its way, never a pulsing dot", () => {
  const connecting = renderToStaticMarkup(<MachineLinkMark link="connecting" words="Reconnecting…" />);
  expect(connecting).toContain('data-link="connecting"');
  expect(connecting).toContain('aria-label="Reconnecting…"');
  expect(connecting).toContain("cv-spinner");
  // A loading ring, not the agent's working look (which a theme may set to a breathing dot).
  expect(connecting).not.toContain("data-working");
  for (const link of ["connected", "offline", "paused"] as const) {
    const mark = renderToStaticMarkup(<MachineLinkMark link={link} />);
    expect(mark).toContain(`data-link="${link}"`);
    expect(mark).not.toContain("cv-spinner");
  }
});

test("the App's push sets the pane's machine and clears it for a chat on this Mac", () => {
  setMachineLink({ machine: "m-1", link: "offline", words: "Offline" });
  expect(paneMachineLink()).toEqual({ machine: "m-1", link: "offline", words: "Offline" });
  setMachineLink({ machine: "m-1", link: "nonsense" });
  expect(paneMachineLink()).toBeUndefined();
  setMachineLink({ machine: "m-1", link: "connecting" });
  expect(paneMachineLink()).toEqual({ machine: "m-1", link: "connecting", words: "" });
  setMachineLink(null);
  expect(paneMachineLink()).toBeUndefined();
});

/// The Mac's acpmux with one peer, `gpu-box`, in `state`; `_acpmux/peer_reconnect` brings it back.
/// `dropped`: the link went down since the listing said `state`, so the next `session/new` or
/// `session/prompt` there is refused as unreachable until a reconnect. `chat`: a chat on gpu-box.
/// `gone`: the reconnect finds the peer removed (acpmux lists it no more). `cut`: the next
/// `session/new` or `session/prompt` goes out and the link drops before the answer
/// (`peer_disconnected`). `events`: it pushes peer link states (`peerStateEvents`).
/// `origin`: what acpmux says this connection is (`local`, `peer`, `remote`). `failStatus`: that
/// many `_acpmux/status` reads fail first. `hold()`: answers to
/// `_acpmux/status` are read at once but held until `release()`, so a push can come before them.
function daemon(
  state: string,
  { dropped = false, chat = false, gone = false, cut = false, events = false, origin = "local", failStatus = 0 } = {},
) {
  let statusFailures = failStatus;
  /// `_acpmux/peer_reconnect` fails while set (acpmux unreachable for a moment).
  let reconnectFails = false;
  let cutNext = cut;
  const asked: { method: string; params: Record<string, unknown> }[] = [];
  let peerState = state;
  let down = dropped;
  const session = { sessionId: "on-gpu", peer: "gpu-box", host: "gpu-box", cwd: "/home/dev/project", updatedAt: 1 };
  let socket: any;
  let listed = true;
  const added: string[] = [];
  let holding = false;
  const held: (() => void)[] = [];
  /// `_acpmux/peer_reconnect` waits (it settles when `settleReconnect()` is called), answering then.
  let reconnectWaits = false;
  const waitingReconnects: (() => void)[] = [];
  const peers = () => ({
    peers: [
      ...(listed ? [{ name: "gpu-box", transport: "ssh", connected: peerState === "connected", state: peerState }] : []),
      ...added.map((name) => ({ name, transport: "ssh", connected: true, state: "connected" })),
    ],
  });
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin, extensions: [], operations: [], features: events ? ["peerStateEvents"] : [] } },
        };
      case "_acpmux/status":
        if (statusFailures > 0) {
          statusFailures -= 1;
          throw new Error("status unavailable");
        }
        return peers();
      case "_acpmux/peer_reconnect":
        if (reconnectFails) throw new Error("acpmux unavailable");
        if (gone) {
          listed = false;
          return peers();
        }
        peerState = "connected";
        down = false;
        return peers();
      case "session/new":
      case "session/prompt":
        if (cutNext) {
          cutNext = false;
          peerState = "reconnecting";
          throw Object.assign(new Error("peer disconnected"), { data: { reason: "peer_disconnected", peer: "gpu-box" } });
        }
        if (down || peerState !== "connected") throw new Error("peer_unreachable: gpu-box (offline)");
        return method === "session/new" ? { sessionId: "new-chat" } : { stopReason: "end_turn" };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return { sessions: chat ? [session] : [] };
      case "_acpmux/attach":
        return { session, events: [], hasMore: false, lastSeq: 0 };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        asked.push({ method: message.method, params: message.params ?? {} });
        const respond = () => {
          let reply: Record<string, unknown>;
          try {
            reply = { result: answer(message.method) };
          } catch (error) {
            const data = (error as { data?: unknown }).data;
            reply = { error: { code: -32000, message: String((error as Error).message), ...(data ? { data } : {}) } };
          }
          return () => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply }) });
        };
        if (holding && message.method === "_acpmux/status") held.push(respond());
        else if (reconnectWaits && message.method === "_acpmux/peer_reconnect") waitingReconnects.push(() => respond()());
        else queueMicrotask(() => respond()());
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  /// acpmux pushes a notification to the page.
  const notify = (method: string, params: unknown) => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  const hold = () => {
    holding = true;
  };
  /// `newestFirst`: the held answers arrive in the reverse of the order they were asked.
  const release = (newestFirst = false) => {
    holding = false;
    const answers = held.splice(0);
    for (const deliver of newestFirst ? answers.reverse() : answers) deliver();
  };
  /// acpmux lists one more peer from now on.
  const add = (name: string) => added.push(name);
  const waitReconnects = () => {
    reconnectWaits = true;
  };
  const settleReconnect = () => {
    reconnectWaits = false;
    for (const settle of waitingReconnects.splice(0)) settle();
  };
  /// The next `statusReads` status reads fail, and `_acpmux/peer_reconnect` too unless `reconnect` is false.
  const failNext = (statusReads: number, reconnect = true) => {
    reconnectFails = reconnect;
    statusFailures = statusReads;
  };
  return { asked, open, notify, hold, release, add, waitReconnects, settleReconnect, failNext };
}

async function client(state: string, options: Parameters<typeof daemon>[1] = {}) {
  const fake = daemon(state, options);
  const states: (Record<string, string> | undefined)[] = [];
  let latest: any;
  const connected = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t" },
    (snapshot: any) => {
      latest = snapshot;
      states.push(snapshot.peerStates);
    },
    undefined,
    fake.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return {
    client: connected,
    asked: fake.asked,
    states,
    notify: fake.notify,
    hold: fake.hold,
    release: fake.release,
    add: fake.add,
    waitReconnects: fake.waitReconnects,
    settleReconnect: fake.settleReconnect,
    failNext: fake.failNext,
    last: () => latest,
  };
}

test("a new chat's first send to a down peer reconnects it and waits for its handshake, then starts", async () => {
  const { client: pane, asked, states } = await client("offline");
  await pane.startSession("claude", "/home/dev/project", "gpu-box");
  const methods = asked.map((message) => message.method);
  const reconnect = methods.indexOf("_acpmux/peer_reconnect");
  expect(reconnect).toBeGreaterThan(-1);
  expect(reconnect).toBeLessThan(methods.indexOf("session/new"));
  expect(asked[reconnect]!.params).toEqual({ name: "gpu-box", wait: true });
  // The strip showed the spinner while it waited, then green.
  expect(states.some((peerStates) => peerStates?.["gpu-box"] === "connecting")).toBe(true);
  expect(states.at(-1)?.["gpu-box"]).toBe("connected");
});

test("a send to a connected peer never reconnects it", async () => {
  const { client: pane, asked } = await client("connected");
  await pane.startSession("claude", "/home/dev/project", "gpu-box");
  expect(asked.map((message) => message.method)).not.toContain("_acpmux/peer_reconnect");
});

test("a peer that dropped since acpmux listed it refuses the new chat once, then is reconnected and the chat starts", async () => {
  const { client: pane, asked } = await client("connected", { dropped: true });
  expect(await pane.startSession("claude", "/home/dev/project", "gpu-box")).toBe("new-chat");
  const methods = asked.map((message) => message.method);
  const reconnect = methods.indexOf("_acpmux/peer_reconnect");
  expect(reconnect).toBeGreaterThan(methods.indexOf("session/new"));
  expect(asked[reconnect]!.params).toEqual({ name: "gpu-box", wait: true });
  expect(methods.lastIndexOf("session/new")).toBeGreaterThan(reconnect);
});

test("a send in a chat whose machine is down reconnects it first, then the turn goes out", async () => {
  const { client: pane, asked } = await client("offline", { chat: true });
  await pane.select("on-gpu");
  await pane.send("hello");
  const methods = asked.map((message) => message.method);
  const reconnect = methods.indexOf("_acpmux/peer_reconnect");
  expect(reconnect).toBeGreaterThan(-1);
  expect(asked[reconnect]!.params).toEqual({ name: "gpu-box", wait: true });
  expect(methods.indexOf("session/prompt")).toBeGreaterThan(reconnect);
});

test("a send in a chat whose machine dropped since it was listed is refused once, then reconnected and sent again", async () => {
  const { client: pane, asked } = await client("connected", { chat: true, dropped: true });
  await pane.select("on-gpu");
  await pane.send("hello");
  const methods = asked.map((message) => message.method);
  const reconnect = methods.indexOf("_acpmux/peer_reconnect");
  expect(reconnect).toBeGreaterThan(methods.indexOf("session/prompt"));
  const prompts = asked.filter((message) => message.method === "session/prompt");
  expect(prompts).toHaveLength(2);
  // The same prompt, so acpmux runs it once.
  expect((prompts[1]!.params._meta as any).acpmux.promptId).toBe((prompts[0]!.params._meta as any).acpmux.promptId);
});

test("a pick's reconnect and the sends behind it reconnect the machine once at a time", async () => {
  const { client: pane, asked } = await client("offline");
  await Promise.all([
    pane.reconnectPeer("gpu-box"),
    pane.startSession("claude", "/home/dev/project", "gpu-box"),
    pane.startSession("claude", "/home/dev/other", "gpu-box"),
  ]);
  const reconnects = asked.filter((message) => message.method === "_acpmux/peer_reconnect");
  expect(reconnects).toHaveLength(1);
  expect(asked.map((message) => message.method)).toContain("session/new");
});

test("a send whose machine is gone after its reconnect keeps the refusal and is not sent again", async () => {
  const { client: pane, asked } = await client("connected", { chat: true, dropped: true, gone: true });
  await pane.select("on-gpu");
  await pane.send("hello").catch(() => undefined);
  expect(asked.filter((message) => message.method === "session/prompt")).toHaveLength(1);
  expect(asked.map((message) => message.method)).toContain("_acpmux/peer_reconnect");
});

test("a prompt whose link dropped after it went out is sent again under its id once the machine is back", async () => {
  const { client: pane, asked } = await client("connected", { chat: true, cut: true });
  await pane.select("on-gpu");
  await pane.send("hello");
  const prompts = asked.filter((message) => message.method === "session/prompt");
  // acpmux runs a prompt id once: the second copy answers with the first run, never a second turn.
  expect(prompts).toHaveLength(2);
  expect((prompts[1]!.params._meta as any).acpmux.promptId).toBe((prompts[0]!.params._meta as any).acpmux.promptId);
  expect(asked.map((message) => message.method)).toContain("_acpmux/peer_reconnect");
});

test("a new chat whose link dropped after session/new went out fails as it did, never a second chat", async () => {
  const { client: pane, asked } = await client("connected", { cut: true });
  await expect(pane.startSession("claude", "/home/dev/project", "gpu-box")).rejects.toThrow();
  expect(asked.filter((message) => message.method === "session/new")).toHaveLength(1);
  expect(asked.map((message) => message.method)).not.toContain("_acpmux/peer_reconnect");
});

test("with acpmux's pushes the strip follows each peer change, repeats change nothing, and the open reads nothing", async () => {
  const { client: pane, asked, states, notify } = await client("connected", { events: true });
  const reads = () => asked.filter((message) => message.method === "_acpmux/status").length;
  const read = reads();
  await pane.refreshPeersOnOpen();
  expect(reads()).toBe(read);
  let at = 2;
  // `again`: a lagging watcher's repeat of the last note (the same `at`).
  const note = (state: string, error: string | null = null, again = false) =>
    notify("_acpmux/peer_state_changed", { peer: "gpu-box", state, lastSeen: 1, error, at: again ? at : ++at });
  note("reconnecting");
  expect(states.at(-1)?.["gpu-box"]).toBe("reconnecting");
  const emitted = states.length;
  note("reconnecting", null, true);
  expect(states.length).toBe(emitted);
  note("connected");
  expect(states.at(-1)?.["gpu-box"]).toBe("connected");
  // A removed peer leaves the list.
  note("offline", "removed");
  expect(states.at(-1)?.["gpu-box"]).toBeUndefined();
  // One not listed yet: the list is read again, for its transport.
  notify("_acpmux/peer_state_changed", { peer: "new-box", state: "connecting", lastSeen: null, error: null, at: 3 });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(reads()).toBe(read + 1);
});

test("an older peer list read that answers after a newer one is dropped, so an added peer stays", async () => {
  const { client: pane, states, hold, release, add } = await client("connected", { events: true });
  hold();
  const older = pane.refreshPeers();
  add("new-box");
  const newer = pane.refreshPeers();
  release(true);
  await Promise.all([older, newer]);
  expect(states.at(-1)?.["new-box"]).toBe("connected");
  expect(states.at(-1)?.["gpu-box"]).toBe("connected");
});

test("a list read while a reconnect waits never leaves the machine down once the reconnect answers", async () => {
  const { client: pane, asked, states, waitReconnects, settleReconnect } = await client("offline");
  waitReconnects();
  const reconnect = pane.reconnectPeer("gpu-box", true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  // The list opens while the reconnect waits: acpmux still says offline.
  await pane.refreshPeersOnOpen();
  expect(states.at(-1)?.["gpu-box"]).toBe("offline");
  settleReconnect();
  await reconnect;
  expect(states.at(-1)?.["gpu-box"]).toBe("connected");
  expect(asked.filter((message) => message.method === "_acpmux/peer_reconnect")).toHaveLength(1);
});

test("a list read while a reconnect waits that answers after it never leaves the machine down", async () => {
  const { client: pane, states, hold, release, waitReconnects, settleReconnect } = await client("offline");
  hold();
  waitReconnects();
  const reconnect = pane.reconnectPeer("gpu-box", true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  // The list opens while the reconnect waits; acpmux's answer (offline) is held back.
  const open = pane.refreshPeersOnOpen();
  settleReconnect();
  await new Promise((resolve) => setTimeout(resolve, 0));
  // The stale answer arrives last.
  release(true);
  await Promise.all([reconnect, open]);
  expect(states.at(-1)?.["gpu-box"]).toBe("connected");
});

test("a reconnect whose every read fails puts the mark back, never a spinner that stays", async () => {
  const { client: pane, asked, states, failNext } = await client("offline", { events: true });
  failNext(1);
  await pane.reconnectPeer("gpu-box", true);
  expect(states).toContainEqual(expect.objectContaining({ "gpu-box": "connecting" }));
  expect(states.at(-1)?.["gpu-box"]).toBe("offline");
  // The next open reads the list again, with acpmux's pushes on too.
  const reads = asked.filter((message) => message.method === "_acpmux/status").length;
  await pane.refreshPeersOnOpen();
  expect(asked.filter((message) => message.method === "_acpmux/status")).toHaveLength(reads + 1);
});

test("a push during a reconnect whose reads fail is kept, and a reconnect's answer stands when the read after it fails", async () => {
  const pushed = await client("offline", { events: true });
  pushed.failNext(1);
  pushed.waitReconnects();
  const reconnect = pushed.client.reconnectPeer("gpu-box", true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  pushed.notify("_acpmux/peer_state_changed", { peer: "gpu-box", state: "connecting", lastSeen: null, error: null, at: 9 });
  pushed.settleReconnect();
  await reconnect;
  expect(pushed.states.at(-1)?.["gpu-box"]).toBe("connecting");

  // A read during the wait says offline and wins; the reconnect answers connected; the read after it fails.
  const raced = await client("offline");
  raced.hold();
  raced.waitReconnects();
  const again = raced.client.reconnectPeer("gpu-box", true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const open = raced.client.refreshPeersOnOpen();
  raced.release();
  await open;
  raced.failNext(1, false);
  raced.settleReconnect();
  await again;
  expect(raced.states.at(-1)?.["gpu-box"]).toBe("connected");
});

test("a reconnect's own answer goes in as the newest list, under the pushes since it began", async () => {
  // A read begun during the wait answers last, after the read following the reconnect failed: dropped.
  const raced = await client("offline");
  raced.hold();
  raced.waitReconnects();
  const reconnect = raced.client.reconnectPeer("gpu-box", true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  const open = raced.client.refreshPeersOnOpen();
  raced.failNext(1, false);
  raced.settleReconnect();
  await new Promise((resolve) => setTimeout(resolve, 0));
  raced.release(true);
  await Promise.all([reconnect, open]);
  expect(raced.states.at(-1)?.["gpu-box"]).toBe("connected");

  // A push since the reconnect began (the link dropped again) stays over its answer.
  const dropped = await client("offline", { events: true });
  dropped.waitReconnects();
  const again = dropped.client.reconnectPeer("gpu-box", true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  dropped.notify("_acpmux/peer_state_changed", { peer: "gpu-box", state: "reconnecting", lastSeen: 1, error: null, at: 9 });
  dropped.failNext(1, false);
  dropped.settleReconnect();
  await again;
  expect(dropped.states.at(-1)?.["gpu-box"]).toBe("reconnecting");
});

test("another machine's push never keeps a failed reconnect's spinner", async () => {
  const { client: pane, states, notify, failNext, waitReconnects, settleReconnect, add } = await client("offline", {
    events: true,
  });
  add("new-box");
  await pane.refreshPeers();
  failNext(1);
  waitReconnects();
  const reconnect = pane.reconnectPeer("gpu-box", true);
  await new Promise((resolve) => setTimeout(resolve, 0));
  notify("_acpmux/peer_state_changed", { peer: "new-box", state: "reconnecting", lastSeen: 1, error: null, at: 9 });
  settleReconnect();
  await reconnect;
  expect(states.at(-1)?.["gpu-box"]).toBe("offline");
  expect(states.at(-1)?.["new-box"]).toBe("reconnecting");
});

test("a lagging watcher's older note never replaces a newer one", async () => {
  const { states, notify } = await client("connected", { events: true });
  notify("_acpmux/peer_state_changed", { peer: "gpu-box", state: "connected", lastSeen: 1, error: null, at: 5 });
  notify("_acpmux/peer_state_changed", { peer: "gpu-box", state: "reconnecting", lastSeen: 1, error: null, at: 6 });
  expect(states.at(-1)?.["gpu-box"]).toBe("reconnecting");
  notify("_acpmux/peer_state_changed", { peer: "gpu-box", state: "connected", lastSeen: 1, error: null, at: 5 });
  expect(states.at(-1)?.["gpu-box"]).toBe("reconnecting");
});

test("the peer list is read once the watch is on, and a failed read is read again as the list opens", async () => {
  const { client: pane, asked } = await client("connected", { events: true, failStatus: 1 });
  const methods = asked.map((message) => message.method);
  expect(methods.indexOf("_acpmux/watch")).toBeGreaterThan(-1);
  expect(methods.indexOf("_acpmux/status")).toBeGreaterThan(methods.indexOf("_acpmux/watch"));
  const reads = () => asked.filter((message) => message.method === "_acpmux/status").length;
  await pane.refreshPeersOnOpen();
  expect(reads()).toBe(2);
  // Read now: with the pushes on, the next open reads nothing.
  await pane.refreshPeersOnOpen();
  expect(reads()).toBe(2);
});

test("an older daemon with no pushes is read again as the list opens", async () => {
  const { client: pane, asked } = await client("connected");
  const reads = () => asked.filter((message) => message.method === "_acpmux/status").length;
  const read = reads();
  await pane.refreshPeersOnOpen();
  expect(reads()).toBe(read + 1);
});

test("a connection that is not this machine's own acpmux reads no peer list and ignores its pushes", async () => {
  for (const origin of ["peer", "remote"]) {
    const { client: pane, asked, states, notify } = await client("connected", { events: true, origin });
    const reads = () => asked.filter((message) => message.method === "_acpmux/status").length;
    expect(reads()).toBe(0);
    const emitted = states.length;
    notify("_acpmux/peer_state_changed", { peer: "gpu-box", state: "offline", lastSeen: 1, error: null, at: 2 });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(states.length).toBe(emitted);
    expect(states.at(-1)?.["gpu-box"]).toBeUndefined();
    await pane.refreshPeersOnOpen();
    await pane.reconnectPeer("gpu-box", true, true);
    expect(reads()).toBe(0);
    expect(asked.map((message) => message.method)).not.toContain("_acpmux/peer_reconnect");
  }
});

test("a chat's peer on a connection that lists no peers is not shown down", async () => {
  const { knownMachines } = await import("../src/agent-session/acpmux/environments");
  const chats = [{ host: "gpu-box", peer: "gpu-box" }];
  const [unlisted] = knownMachines([], chats, {}, [], {}, {}, false);
  expect(unlisted?.connected).toBeUndefined();
  expect(peerLink(unlisted!)).toBeUndefined();
  expect(pickableDown({ ...unlisted!, ...(peerLink(unlisted!) ? { link: peerLink(unlisted!) } : {}) })).toBe(false);
  // This machine's own acpmux that no longer lists it: not connected, as before.
  const [gone] = knownMachines([], chats, {}, [], {}, {});
  expect(peerLink(gone!)).toBe("offline");
  // Until a read answers, this machine's own acpmux's list is not known either.
  const failed = await client("connected", { events: true, failStatus: 1 });
  expect(failed.last()?.peersUnlisted).toBe(true);
  await failed.client.refreshPeersOnOpen();
  expect(failed.last()?.peersUnlisted).toBeUndefined();
  // The pane says so in its snapshot on another host's connection, and not on this machine's own.
  expect((await client("connected", { events: true, origin: "peer" })).last()?.peersUnlisted).toBe(true);
  expect((await client("connected", { events: true })).last()?.peersUnlisted).toBeUndefined();
});

test("a push that comes while the peer list is read stays on top of that read's older answer", async () => {
  const { client: pane, states, notify, hold, release } = await client("connected", { events: true });
  hold();
  const read = pane.refreshPeers();
  // The daemon answered "connected"; the link dropped before that answer reached the page.
  notify("_acpmux/peer_state_changed", { peer: "gpu-box", state: "reconnecting", lastSeen: 1, error: null, at: 2 });
  expect(states.at(-1)?.["gpu-box"]).toBe("reconnecting");
  release();
  await read;
  expect(states.at(-1)?.["gpu-box"]).toBe("reconnecting");
});

// Leo, 2026-10-28: "after you've connected something remotely ... how good is it in terms of that
// whole, like, recovery flow". The offline chat's Reconnect (ChatUnavailableState) only read the
// lists again, so its machine sat out acpmux's backoff of up to a minute; it reconnects it now.
async function missingChat(state: string) {
  rememberTail("on-gpu", {
    events: [],
    summary: { sessionId: "on-gpu", peer: "gpu-box" },
    turnOpener: undefined,
    historyExhausted: true,
    queue: [],
    configSeq: 0,
    usageFromSeq: 0,
  });
  const fake = daemon(state, { events: true });
  let latest: any;
  const pane = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: "on-gpu",
      sessionMustExist: true,
    },
    (snapshot: any) => {
      latest = snapshot;
    },
    undefined,
    fake.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { pane, asked: fake.asked, last: () => latest };
}

test("Reconnect on an offline chat reconnects its machine, waiting for it, then reads the lists", async () => {
  const { pane, asked } = await missingChat("offline");
  asked.length = 0;
  await pane.recheckMissing();
  const methods = asked.map((message) => message.method);
  const reconnect = methods.indexOf("_acpmux/peer_reconnect");
  expect(reconnect).toBe(0);
  expect(asked[reconnect]!.params).toEqual({ name: "gpu-box", wait: true });
  expect(methods.slice(reconnect + 1)).toContain("_acpmux/watch");
  pane.close();
});

test("Reconnect on a chat whose machine is connected only reads the lists again", async () => {
  const { pane, asked } = await missingChat("connected");
  asked.length = 0;
  await pane.recheckMissing();
  expect(asked.map((message) => message.method)).not.toContain("_acpmux/peer_reconnect");
  pane.close();
});
