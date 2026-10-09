import { randomBytes } from "node:crypto";
import { afterAll, describe, expect, it } from "vitest";
import { HostClient } from "../src/client.ts";
import type { Lane } from "../src/transport/link.ts";
import { parseIceUrl, toNdcIceServers, WebRtcPeer, shutdownWebRtc } from "../src/transport/webrtc.ts";
import { connectedCore } from "./helpers.ts";

afterAll(() => shutdownWebRtc());

/** Two in-process peers with direct signaling (no backend). */
function pair() {
  let offerer!: WebRtcPeer;
  let answerer!: WebRtcPeer;
  answerer = new WebRtcPeer({
    role: "answerer",
    iceServers: [],
    onSignal: (s) => {
      if (s.type === "description") offerer.setRemoteDescription(s.sdp, s.sdpType);
      else offerer.addRemoteCandidate(s.candidate, s.sdpMid);
    },
  });
  offerer = new WebRtcPeer({
    role: "offerer",
    iceServers: [],
    onSignal: (s) => {
      if (s.type === "description") answerer.setRemoteDescription(s.sdp, s.sdpType);
      else answerer.addRemoteCandidate(s.candidate, s.sdpMid);
    },
  });
  const open = (p: WebRtcPeer) => new Promise<void>((r) => (p.link.state === "open" ? r() : p.link.on("state", (s) => s === "open" && r())));
  return { offerer, answerer, ready: Promise.all([open(offerer), open(answerer)]) };
}

describe("ICE server conversion", () => {
  it("parses stun/turn urls", () => {
    expect(parseIceUrl("turn:turn.example.com:3478?transport=tcp")).toEqual({ scheme: "turn", hostname: "turn.example.com", port: 3478, transport: "tcp" });
    expect(parseIceUrl("turns:t.example.com:443?transport=tcp")).toMatchObject({ scheme: "turns", port: 443 });
    expect(
      toNdcIceServers([
        { urls: ["stun:stun.cloudflare.com:3478", "turn:t.example.com:3478?transport=udp", "turns:t.example.com:5349"], username: "u:1", credential: "p" },
      ]),
    ).toEqual([
      "stun:stun.cloudflare.com:3478",
      { hostname: "t.example.com", port: 3478, username: "u:1", password: "p", relayType: "TurnUdp" },
      { hostname: "t.example.com", port: 5349, username: "u:1", password: "p", relayType: "TurnTls" },
    ]);
  });
});

describe("WebRTC link between two node-datachannel peers", () => {
  it("opens three negotiated lanes and passes a 2 MB bulk message", async () => {
    const { offerer, answerer, ready } = pair();
    await ready;
    expect(offerer.selectedPair()?.local).toBe("host");
    const big = new Uint8Array(randomBytes(2 * 1024 * 1024));
    const got = new Promise<{ lane: Lane; data: Uint8Array }[]>((resolve) => {
      const out: { lane: Lane; data: Uint8Array }[] = [];
      answerer.link.on("message", (lane, data) => {
        out.push({ lane, data });
        if (out.length === 3) resolve(out);
      });
    });
    offerer.link.send("blk", big);
    offerer.link.send("int", Uint8Array.of(1, 2, 3));
    offerer.link.send("ctl", "{\"t\":\"evt\",\"topic\":\"x\"}");
    const msgs = await got;
    const blk = msgs.find((m) => m.lane === "blk")!;
    expect(blk.data.byteLength).toBe(big.byteLength);
    expect(Buffer.compare(Buffer.from(blk.data), Buffer.from(big))).toBe(0);
    expect(msgs.find((m) => m.lane === "int")!.data).toEqual(Uint8Array.of(1, 2, 3));
    const closed = new Promise<void>((r) => answerer.link.on("state", (s) => s === "closed" && r()));
    offerer.close();
    await closed;
  });

  it("serves the host RPC surface over WebRTC", async () => {
    const { core } = await connectedCore({ terminal: { shell: "/bin/sh", args: [] } });
    try {
      const { offerer, answerer, ready } = pair();
      core.attach(answerer.link);
      await ready;
      const client = new HostClient(offerer.link);
      expect((await client.hello()).hostId).toBe("h_test");
      const echo = await client.terminalEcho();
      expect(echo.ms).toBeLessThan(15_000);
      offerer.close();
    } finally {
      core.shutdown();
    }
  });
});
