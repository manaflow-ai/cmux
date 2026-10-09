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

async function fakeBackend() {
  const sockets = new Map<string, WebSocket>(); // address -> socket
  let n = 0;
  const http = createServer((req, res) => {
    if (req.url === "/v1/ice") {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ iceServers: [], ttl: 600 }));
    } else {
      res.statusCode = 404;
      res.end("{}");
    }
  });
  const wss = new WebSocketServer({ server: http, path: "/v1/signal" });
  wss.on("connection", (ws, req) => {
    const token = new URL(req.url!, "http://x").searchParams.get("token")!;
    const isHost = token.startsWith("host");
    const address = isHost ? "h_1" : `p_${++n}`;
    sockets.set(address, ws);
    ws.send(JSON.stringify({ type: "welcome", peerId: `p_${address}`, hosts: [{ hostId: "h_1", online: sockets.has("h_1") }] }));
    ws.on("message", (raw) => {
      const f = JSON.parse(raw.toString());
      if (f.type === "ping") return ws.send('{"type":"pong"}');
      const target = sockets.get(f.to);
      if (!target) return ws.send(JSON.stringify({ type: "error", code: "host_offline", sessionId: f.sessionId }));
      target.send(JSON.stringify({ ...f, from: address }));
    });
    ws.on("close", () => sockets.delete(address));
  });
  await new Promise<void>((r) => http.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;
  return { base, close: () => { for (const c of wss.clients) c.terminate(); wss.close(); http.close(); } };
}

describe("HostAgent over signaling", () => {
  it("answers a phone offer and serves RPC over the resulting WebRTC link", async () => {
    const backend = await fakeBackend();
    const { core } = await connectedCore({ terminal: { shell: "/bin/sh", args: [] } });
    const agent = new HostAgent({ api: new ApiClient(backend.base, "host-token"), core, log: () => {} });
    const hostOpen = new Promise<void>((r) => agent.signaling.once("open", () => r()));
    agent.start();
    await hostOpen;

    const api = new ApiClient(backend.base, "user-token");
    const signaling = new SignalingClient({ url: () => api.signalUrl() });
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
    signaling.stop();
    agent.stop();
    core.shutdown();
    backend.close();
  });
});
