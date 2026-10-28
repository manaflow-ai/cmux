// l10n-allow-file: test fixtures (machine names), not shipped UI.
// The machine-state feed in the composer (Leo, 2026-10-28: "you just get a little green dot ... as if
// you were working on your own computer, but now it's remote"): one word per machine, green only
// once its handshake finished, a spinner while it connects or reconnects, red when it is down; and a
// send to a down machine reconnects it first, so the turn goes out with no Reconnect click.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
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
function daemon(state: string, { dropped = false, chat = false } = {}) {
  const asked: { method: string; params: Record<string, unknown> }[] = [];
  let peerState = state;
  let down = dropped;
  const session = { sessionId: "on-gpu", peer: "gpu-box", host: "gpu-box", cwd: "/home/dev/project", updatedAt: 1 };
  let socket: any;
  const peers = () => ({ peers: [{ name: "gpu-box", transport: "ssh", connected: peerState === "connected", state: peerState }] });
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/status":
        return peers();
      case "_acpmux/peer_reconnect":
        peerState = "connected";
        down = false;
        return peers();
      case "session/new":
      case "session/prompt":
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
        queueMicrotask(() => {
          let reply: Record<string, unknown>;
          try {
            reply = { result: answer(message.method) };
          } catch (error) {
            reply = { error: { code: -32000, message: String((error as Error).message) } };
          }
          socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply }) });
        });
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { asked, open };
}

async function client(state: string, options: Parameters<typeof daemon>[1] = {}) {
  const fake = daemon(state, options);
  const states: (Record<string, string> | undefined)[] = [];
  const connected = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t" },
    (snapshot: any) => states.push(snapshot.peerStates),
    undefined,
    fake.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client: connected, asked: fake.asked, states };
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

test("a pick's reconnect and the send behind it reconnect the machine once at a time", async () => {
  const { client: pane, asked } = await client("offline");
  await Promise.all([pane.reconnectPeer("gpu-box"), pane.startSession("claude", "/home/dev/project", "gpu-box")]);
  const reconnects = asked.filter((message) => message.method === "_acpmux/peer_reconnect");
  expect(reconnects).toHaveLength(1);
  expect(asked.map((message) => message.method)).toContain("session/new");
});
