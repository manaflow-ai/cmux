// Host agent + signaling against a fake backend (HTTP /v1/ice + /v1/signal relay).
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, describe, expect, it } from "vitest";
import { WebSocketServer, type WebSocket } from "ws";
import { ApiClient } from "../src/backend/api.ts";
import { HostAgent } from "../src/backend/hostAgent.ts";
import { SignalingClient } from "../src/backend/signaling.ts";
import { HostClient } from "../src/client.ts";
import { WebRtcPeer, shutdownWebRtc } from "../src/transport/webrtc.ts";
import { connectedCore } from "./helpers.ts";

afterAll(() => shutdownWebRtc());

interface FakeBackendOptions {
  /** Accept credentials only as ?token= (an older backend). */
  queryOnly?: boolean;
  /** Delay /v1/ice responses (ms). */
  iceDelayMs?: number;
  /** Tokens the backend rejects with 401. */
  revokedTokens?: Set<string>;
  /** Stamp phone frames with this session family (else from "user-token:<family>"). */
  family?: string;
  /** Sent to hosts in welcome.revokedFamilies. */
  revokedFamilies?: string[];
  /** Older backend: stamp only offers with the family. */
  stampOffersOnly?: boolean;
}

async function fakeBackend(opts: FakeBackendOptions = {}) {
  const sockets = new Map<string, WebSocket>(); // address -> socket
  const authModes: string[] = [];
  let n = 0;
  const tokenOf = (req: { headers: Record<string, string | string[] | undefined>; url?: string }) => {
    const header = req.headers.authorization;
    const fromHeader = typeof header === "string" && header.startsWith("Bearer ") ? header.slice(7) : undefined;
    const fromQuery = new URL(req.url ?? "/", "http://x").searchParams.get("token") ?? undefined;
    return opts.queryOnly ? { token: fromQuery, mode: "query" } : { token: fromHeader ?? fromQuery, mode: fromHeader ? "header" : "query" };
  };
  const http = createServer((req, res) => {
    const { token } = tokenOf(req);
    if (req.url === "/v1/ice") {
      if (!token || opts.revokedTokens?.has(token)) {
        res.statusCode = 401;
        res.end(JSON.stringify({ error: { code: "unauthorized", message: "bad token" } }));
        return;
      }
      setTimeout(() => {
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({ iceServers: [], ttl: 600 }));
      }, opts.iceDelayMs ?? 0);
    } else {
      res.statusCode = 404;
      res.end("{}");
    }
  });
  const wss = new WebSocketServer({
    noServer: true,
  });
  http.on("upgrade", (req, socket, head) => {
    const { token, mode } = tokenOf(req);
    if (!req.url?.startsWith("/v1/signal") || !token || opts.revokedTokens?.has(token)) {
      socket.write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
      socket.destroy();
      return;
    }
    authModes.push(mode);
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, token));
  });
  wss.on("connection", (ws: WebSocket, token: string) => {
    const isHost = token.startsWith("host");
    const address = isHost ? "h_1" : `p_${++n}`;
    const family = isHost ? undefined : (opts.family ?? (token.split(":")[1] || null));
    sockets.set(address, ws);
    ws.send(
      JSON.stringify({
        type: "welcome",
        peerId: `p_${address}`,
        hosts: [{ hostId: "h_1", online: sockets.has("h_1") }],
        ...(isHost && opts.revokedFamilies ? { revokedFamilies: opts.revokedFamilies } : {}),
      }),
    );
    ws.on("message", (raw) => {
      const f = JSON.parse(raw.toString());
      if (f.type === "ping") return ws.send('{"type":"pong"}');
      const target = sockets.get(f.to);
      if (!target) return ws.send(JSON.stringify({ type: "error", code: "host_offline", sessionId: f.sessionId }));
      const stamp = isHost || (opts.stampOffersOnly && f.type !== "offer") ? {} : { family };
      target.send(JSON.stringify({ ...f, from: address, ...stamp }));
    });
    ws.on("close", () => sockets.delete(address));
  });
  await new Promise<void>((r) => http.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;
  return {
    base,
    authModes,
    sockets,
    close: () => {
      for (const c of wss.clients) c.terminate();
      wss.close();
      http.close();
    },
  };
}

describe("HostAgent over signaling", () => {
  it("answers a phone offer and serves RPC over the resulting WebRTC link", async () => {
    // Slow /v1/ice: the phone's trickled candidates reach the host before its
    // peer exists and must be buffered, not dropped.
    const backend = await fakeBackend({ iceDelayMs: 400 });
    const { core } = await connectedCore({ terminal: { shell: "/bin/sh", args: [] } });
    const agent = new HostAgent({ api: new ApiClient(backend.base, "host-token"), core, log: () => {} });
    const hostOpen = new Promise<void>((r) => agent.signaling.once("open", () => r()));
    agent.start();
    await hostOpen;

    const api = new ApiClient(backend.base, "user-token");
    const signaling = new SignalingClient({ url: () => api.signalUrl(), token: () => api.bearer });
    const welcome = signaling.waitWelcome();
    signaling.start();
    expect((await welcome).hosts).toEqual([{ hostId: "h_1", online: true }]);
    const sessionId = "s_test";
    const peer = new WebRtcPeer({
      role: "offerer",
      iceServers: (await api.ice()).iceServers,
      onSignal: (s) => {
        if (s.type === "description") signaling.send({ type: "offer", to: "h_1", sessionId, sdp: s.sdp });
        else signaling.send({ type: "candidate", to: "h_1", sessionId, candidate: s.candidate, sdpMid: s.sdpMid, sdpMLineIndex: 0 });
      },
    });
    signaling.on("frame", (f) => {
      if (f.type === "answer") peer.setRemoteDescription(f.sdp, "answer");
      if (f.type === "candidate") peer.addRemoteCandidate(f.candidate, f.sdpMid);
    });
    await new Promise<void>((r) => peer.link.on("state", (s) => s === "open" && r()));
    const client = new HostClient(peer.link);
    expect((await client.hello()).hostId).toBe("h_test");
    expect((await client.terminalEcho()).marker).toMatch(/cmux-probe/);
    expect(agent.peerCount).toBe(1);

    // bye from the phone tears down the host peer
    signaling.send({ type: "bye", to: "h_1", sessionId });
    const deadline = Date.now() + 5000;
    while (agent.peerCount > 0 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    expect(agent.peerCount).toBe(0);

    peer.close();

    // An offer with policy "relay" makes the host relay-only for that session:
    // it must not advertise host/srflx candidates.
    const relayFrames: any[] = [];
    signaling.on("frame", (f: any) => f.sessionId === "s_relay" && relayFrames.push(f));
    const relayPeer = new WebRtcPeer({
      role: "offerer",
      iceServers: [],
      onSignal: (s) => {
        if (s.type === "description") signaling.send({ type: "offer", to: "h_1", sessionId: "s_relay", sdp: s.sdp, policy: "relay" });
        else signaling.send({ type: "candidate", to: "h_1", sessionId: "s_relay", candidate: s.candidate, sdpMid: s.sdpMid, sdpMLineIndex: 0 });
      },
    });
    const answer = await new Promise<any>((resolve) => {
      const t = setInterval(() => {
        const a = relayFrames.find((f) => f.type === "answer");
        if (a) {
          clearInterval(t);
          resolve(a);
        }
      }, 20);
    });
    await new Promise((r) => setTimeout(r, 1500));
    const advertised = [
      ...relayFrames.filter((f) => f.type === "candidate").map((f) => f.candidate as string),
      ...String(answer.sdp).split(/\r?\n/).filter((l) => l.startsWith("a=candidate")),
    ];
    expect(advertised.filter((c) => !/typ relay/.test(c))).toEqual([]);
    expect(agent.peerCount).toBe(1);
    expect(backend.authModes.every((m) => m === "header")).toBe(true);
    relayPeer.close();
    signaling.stop();
    agent.stop();
    core.shutdown();
    backend.close();
  });
});

describe("signaling credentials", () => {
  it("falls back to ?token= only when the backend rejects the Authorization header", async () => {
    const backend = await fakeBackend({ queryOnly: true });
    const api = new ApiClient(backend.base, "user-token");
    const signaling = new SignalingClient({ url: () => api.signalUrl(), token: () => api.bearer, minBackoffMs: 10 });
    const welcome = signaling.waitWelcome(5000);
    signaling.start();
    await welcome;
    expect(backend.authModes).toEqual(["query"]);
    signaling.stop();
    backend.close();
  });

  it("revokes on close 4003 and 4004 and on 401 after a confirmed connection", async () => {
    for (const code of [4003, 4004]) {
      const backend = await fakeBackend();
      const { core } = await connectedCore();
      const reasons: string[] = [];
      const agent = new HostAgent({ api: new ApiClient(backend.base, "host-token"), core, log: () => {}, onRevoked: (r) => reasons.push(r) });
      const open = new Promise<void>((r) => agent.signaling.once("open", () => r()));
      agent.start();
      await open;
      backend.sockets.get("h_1")!.close(code, "bye");
      const deadline = Date.now() + 3000;
      while (reasons.length === 0 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
      expect(reasons[0]).toMatch(code === 4003 ? /removed/ : /deleted/);
      expect(agent.signaling.isOpen).toBe(false);
      core.shutdown();
      backend.close();
    }

    const revokedTokens = new Set<string>();
    const backend = await fakeBackend({ revokedTokens });
    const { core } = await connectedCore();
    const reasons: string[] = [];
    const agent = new HostAgent({ api: new ApiClient(backend.base, "host-token"), core, log: () => {}, onRevoked: (r) => reasons.push(r) });
    const open = new Promise<void>((r) => agent.signaling.once("open", () => r()));
    agent.start();
    await open;
    revokedTokens.add("host-token");
    // HTTP re-validation notices it even while the socket stays up.
    expect(await agent.validate()).toBe(false);
    expect(reasons[0]).toMatch(/401/);
    core.shutdown();
    backend.close();
  });

  it("revokes when a reconnect is rejected with 401", async () => {
    const revokedTokens = new Set<string>();
    const backend = await fakeBackend({ revokedTokens });
    const api = new ApiClient(backend.base, "host-token");
    const signaling = new SignalingClient({ url: () => api.signalUrl(), token: () => api.bearer, minBackoffMs: 10, maxBackoffMs: 20 });
    const revoked = new Promise<string>((r) => signaling.once("revoked", r));
    const welcome = signaling.waitWelcome(5000);
    signaling.start();
    await welcome;
    revokedTokens.add("host-token");
    backend.sockets.get("h_1")!.close(1011, "restart");
    expect(await revoked).toMatch(/401/);
    backend.close();
  });
});

async function phoneSignaling(backend: Awaited<ReturnType<typeof fakeBackend>>, token = "user-token") {
  const api = new ApiClient(backend.base, token);
  const signaling = new SignalingClient({ url: () => api.signalUrl(), token: () => api.bearer });
  const frames: any[] = [];
  signaling.on("frame", (f) => frames.push(f));
  const welcome = signaling.waitWelcome();
  signaling.start();
  await welcome;
  return { signaling, frames };
}

async function startAgent(backend: Awaited<ReturnType<typeof fakeBackend>>) {
  const { core } = await connectedCore();
  const logs: string[] = [];
  const agent = new HostAgent({ api: new ApiClient(backend.base, "host-token"), core, log: (m) => logs.push(m) });
  const open = new Promise<void>((r) => agent.signaling.once("open", () => r()));
  agent.start();
  await open;
  return { core, agent, logs };
}

async function linkedPhone(backend: Awaited<ReturnType<typeof fakeBackend>>, sessionId: string, token = "user-token") {
  const api = new ApiClient(backend.base, token);
  const signaling = new SignalingClient({ url: () => api.signalUrl(), token: () => api.bearer });
  const welcome = signaling.waitWelcome();
  signaling.start();
  await welcome;
  const peer = new WebRtcPeer({
    role: "offerer",
    iceServers: [],
    onSignal: (s) => {
      if (s.type === "description") signaling.send({ type: "offer", to: "h_1", sessionId, sdp: s.sdp });
      else signaling.send({ type: "candidate", to: "h_1", sessionId, candidate: s.candidate, sdpMid: s.sdpMid, sdpMLineIndex: 0 });
    },
  });
  signaling.on("frame", (f: any) => {
    if (f.sessionId !== sessionId) return;
    if (f.type === "answer") peer.setRemoteDescription(f.sdp, "answer");
    if (f.type === "candidate") peer.addRemoteCandidate(f.candidate, f.sdpMid);
  });
  await new Promise<void>((r) => peer.link.on("state", (s) => s === "open" && r()));
  return { api, signaling, peer };
}


describe("phone session families and peer routing", () => {
  it("drops every link of a revoked family and follows a phone's new peerId", async () => {
    const backend = await fakeBackend({ family: "fam_1" });
    const { core } = await connectedCore();
    const agent = new HostAgent({ api: new ApiClient(backend.base, "host-token"), core, log: () => {} });
    const open = new Promise<void>((r) => agent.signaling.once("open", () => r()));
    agent.start();
    await open;
    const a = await linkedPhone(backend, "s_a");
    const opened = Date.now() + 3000;
    while (!agent.sessions()[0]?.open && Date.now() < opened) await new Promise((r) => setTimeout(r, 20));
    expect(agent.sessions()).toEqual([expect.objectContaining({ sessionId: "s_a", family: "fam_1", open: true, remotePeerId: "p_1" })]);

    // The phone's signaling reconnects (new peerId) and keeps talking about s_a.
    const again = await linkedPhone(backend, "s_b");
    again.signaling.send({ type: "candidate", to: "h_1", sessionId: "s_a", candidate: "candidate:1 1 UDP 1 192.0.2.1 9 typ relay raddr 0.0.0.0 rport 0", sdpMid: "0", sdpMLineIndex: 0 });
    const deadline = Date.now() + 3000;
    while (agent.sessions().find((x) => x.sessionId === "s_a")?.remotePeerId !== "p_2" && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    expect(agent.sessions().find((x) => x.sessionId === "s_a")?.remotePeerId).toBe("p_2");

    const closed = new Promise<void>((r) => a.peer.link.on("state", (s) => s === "closed" && r()));
    backend.sockets.get("h_1")!.send(JSON.stringify({ type: "revoked", family: "fam_1" }));
    const until = Date.now() + 3000;
    while (agent.peerCount > 0 && Date.now() < until) await new Promise((r) => setTimeout(r, 20));
    expect(agent.peerCount).toBe(0);
    await closed;
    for (const x of [a, again]) {
      x.peer.close();
      x.signaling.stop();
    }
    agent.stop();
    core.shutdown();
    backend.close();
  });
});

describe("revoked families and family-scoped frames", () => {
  it("still connects through a backend that stamps only offers", async () => {
    const backend = await fakeBackend({ stampOffersOnly: true });
    const { core, agent, logs } = await startAgent(backend);
    const phone = await linkedPhone(backend, "s_old_backend", "user-token:fam_a");
    expect(agent.sessions()[0]).toMatchObject({ family: "fam_a" });
    expect(logs.some((l) => /not stamped/.test(l))).toBe(true);
    phone.peer.close();
    phone.signaling.stop();
    agent.stop();
    core.shutdown();
    backend.close();
  });

  const until = async (cond: () => boolean) => {
    const deadline = Date.now() + 3000;
    while (!cond() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  };

  it("refuses offers from a revoked family (frame or welcome list) for a while", async () => {
    const backend = await fakeBackend({ revokedFamilies: ["fam_old"] });
    const { core, agent, logs } = await startAgent(backend);
    const old = await phoneSignaling(backend, "user-token:fam_old");
    old.signaling.send({ type: "offer", to: "h_1", sessionId: "s_old", sdp: "v=0" });
    await until(() => old.frames.some((f) => f.type === "bye" && f.sessionId === "s_old"));
    expect(old.frames.some((f) => f.type === "bye" && f.sessionId === "s_old")).toBe(true);
    expect(agent.peerCount).toBe(0);

    const live = await linkedPhone(backend, "s_live", "user-token:fam_live");
    await until(() => agent.sessions()[0]?.open === true);
    backend.sockets.get("h_1")!.send(JSON.stringify({ type: "revoked", family: "fam_live" }));
    await until(() => agent.peerCount === 0);
    expect(agent.peerCount).toBe(0);
    const retry = await phoneSignaling(backend, "user-token:fam_live");
    retry.signaling.send({ type: "offer", to: "h_1", sessionId: "s_again", sdp: "v=0" });
    await until(() => retry.frames.some((f) => f.type === "bye"));
    expect(agent.peerCount).toBe(0);
    expect(logs.some((l) => /refusing offer from revoked session family fam_live/.test(l))).toBe(true);
    for (const x of [old, retry, live]) x.signaling.stop();
    live.peer.close();
    agent.stop();
    core.shutdown();
    backend.close();
  });

  it("ignores bye, candidates and peer moves from a different family; legacy offers log a warning", async () => {
    const backend = await fakeBackend();
    const { core, agent, logs } = await startAgent(backend);
    const owner = await linkedPhone(backend, "s_x", "user-token:fam_a");
    await until(() => agent.sessions()[0]?.open === true);
    const ownerPeer = agent.sessions()[0]!.remotePeerId;
    const other = await phoneSignaling(backend, "user-token:fam_b");
    other.signaling.send({ type: "candidate", to: "h_1", sessionId: "s_x", candidate: "candidate:1 1 UDP 1 192.0.2.1 9 typ host", sdpMid: "0", sdpMLineIndex: 0 });
    other.signaling.send({ type: "bye", to: "h_1", sessionId: "s_x" });
    other.signaling.send({ type: "offer", to: "h_1", sessionId: "s_x", sdp: "v=0" });
    await until(() => logs.filter((l) => /different session family|another family/.test(l)).length >= 3);
    expect(agent.peerCount).toBe(1);
    expect(agent.sessions()[0]).toMatchObject({ sessionId: "s_x", family: "fam_a", open: true, remotePeerId: ownerPeer });

    const legacy = await linkedPhone(backend, "s_legacy", "user-token");
    await until(() => agent.sessions().find((x) => x.sessionId === "s_legacy")?.open === true);
    expect(logs.some((l) => /\[s_legacy\] token without session family/.test(l))).toBe(true);
    for (const x of [owner, legacy]) {
      x.peer.close();
      x.signaling.stop();
    }
    other.signaling.stop();
    agent.stop();
    core.shutdown();
    backend.close();
  });
});
