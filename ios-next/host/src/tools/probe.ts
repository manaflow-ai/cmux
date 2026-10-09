// Headless PHONE-side self-test. Logs in with a user access token, signals an
// offer to a host through the backend, completes the WebRTC link and
// exercises the RPC surface. Used to verify distant connectivity.
//
//   CMUX_NEXT_TOKEN=<accessToken> tsx src/tools/probe.ts --api https://<backend> [--host h_..] [--relay-only] [--json]

import { randomBytes } from "node:crypto";
import { parseArgs } from "node:util";
import { ApiClient } from "../backend/api.ts";
import { SignalingClient, type SignalFrame } from "../backend/signaling.ts";
import { HostClient } from "../client.ts";
import { WebRtcPeer, shutdownWebRtc } from "../transport/webrtc.ts";
import { readConfig } from "../util.ts";

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      api: { type: "string" },
      host: { type: "string" },
      "relay-only": { type: "boolean", default: false },
      json: { type: "boolean", default: false },
      pings: { type: "string", default: "50" },
      timeout: { type: "string", default: "45" },
    },
  });
  const token = process.env.CMUX_NEXT_TOKEN;
  if (!token) throw new Error("set CMUX_NEXT_TOKEN to a user access token");
  const apiBase = values.api ?? process.env.CMUX_NEXT_API ?? readConfig().api;
  if (!apiBase) throw new Error("--api https://<backend> is required");
  const relayOnly = values["relay-only"]!;
  const timeoutMs = Number(values.timeout) * 1000;
  const log = (m: string) => {
    if (!values.json) console.log(m);
  };
  const report: Record<string, unknown> = { api: apiBase, relayOnly };
  const t0 = performance.now();

  const api = new ApiClient(apiBase, token);
  const ice = await api.ice();
  const iceUrls = ice.iceServers.flatMap((s) => (Array.isArray(s.urls) ? s.urls : [s.urls]));
  report.iceUrls = iceUrls;
  log(`ice: ${iceUrls.join(", ") || "(none)"}`);

  const signaling = new SignalingClient({ url: () => api.signalUrl(), log: (m) => log(`signal: ${m}`) });
  const welcomeP = signaling.waitWelcome();
  signaling.start();
  const welcome = await welcomeP;
  log(`welcome: peer ${welcome.peerId}, hosts ${JSON.stringify(welcome.hosts ?? [])}`);
  const hostId = values.host ?? welcome.hosts?.find((h) => h.online)?.hostId;
  if (!hostId) throw new Error("no online host (pass --host)");
  report.hostId = hostId;

  const sessionId = `s_${randomBytes(8).toString("hex")}`;
  const peer = new WebRtcPeer({
    role: "offerer",
    iceServers: ice.iceServers,
    relayOnly,
    name: "probe",
    onSignal: (sig) => {
      if (sig.type === "description") signaling.send({ type: "offer", to: hostId, sessionId, sdp: sig.sdp });
      else signaling.send({ type: "candidate", to: hostId, sessionId, candidate: sig.candidate, sdpMid: sig.sdpMid, sdpMLineIndex: sig.sdpMLineIndex });
    },
  });
  const failed = new Promise<never>((_, reject) => {
    signaling.on("frame", (f: SignalFrame) => {
      if (f.type === "answer" && f.sessionId === sessionId) peer.setRemoteDescription(f.sdp, "answer");
      else if (f.type === "candidate" && f.sessionId === sessionId) peer.addRemoteCandidate(f.candidate, f.sdpMid ?? "0");
      else if (f.type === "bye" && f.sessionId === sessionId) reject(new Error("host said bye"));
      else if (f.type === "error" && (!f.sessionId || f.sessionId === sessionId)) reject(new Error(`signaling error ${f.code} ${f.message ?? ""}`));
    });
  });
  failed.catch(() => {});
  const opened = new Promise<void>((resolve, reject) => {
    peer.link.on("state", (s) => {
      if (s === "open") resolve();
      if (s === "closed") reject(new Error(`link closed: ${peer.link.closeReason ?? ""}`));
    });
  });
  const timeout = new Promise<never>((_, reject) => setTimeout(() => reject(new Error("link connect timeout")), timeoutMs).unref());
  await Promise.race([opened, failed, timeout]);
  const connectMs = Math.round(performance.now() - t0);
  const pair = peer.selectedPair();
  report.connectMs = connectMs;
  report.selectedPair = pair;
  log(`link open in ${connectMs} ms via ${pair ? `${pair.local}(${pair.localAddress}) -> ${pair.remote}(${pair.remoteAddress}) ${pair.transport}` : "?"}`);

  const client = new HostClient(peer.link);
  const hello = await client.hello("cmux-next-probe");
  report.hello = hello;
  log(`hello: ${JSON.stringify(hello)}`);

  const echo = await client.terminalEcho();
  report.terminalEcho = echo;
  log(`terminal echo ok in ${echo.ms} ms`);

  const { harnesses } = await client.request("agent.harnesses");
  report.harnesses = harnesses.map((h: any) => ({ id: h.id, available: h.available }));
  log(`harnesses: ${harnesses.map((h: any) => `${h.id}=${h.available}`).join(" ")}`);

  try {
    const { tabs } = await client.request("browser.list", {}, 60_000);
    report.tabs = tabs.length;
    log(`browser tabs: ${tabs.length}`);
  } catch (err) {
    report.tabs = `error: ${(err as Error).message}`;
    log(`browser.list: ${(err as Error).message}`);
  }

  const { conversations } = await client.request("conv.list");
  report.conversations = conversations.length;

  const n = Number(values.pings);
  const rtts: number[] = [];
  for (let i = 0; i < n; i++) {
    const s = performance.now();
    await client.request("host.ping");
    rtts.push(performance.now() - s);
  }
  rtts.sort((a, b) => a - b);
  const pct = (p: number) => Number(rtts[Math.min(rtts.length - 1, Math.floor(p * rtts.length))]!.toFixed(1));
  report.rttMs = { n, min: pct(0), p50: pct(0.5), p95: pct(0.95), max: pct(1), sctpRtt: peer.rttMs() };
  log(`rtt over ${n} pings: min ${pct(0)} p50 ${pct(0.5)} p95 ${pct(0.95)} max ${pct(1)} ms`);
  report.selectedPair = peer.selectedPair() ?? pair;

  signaling.send({ type: "bye", to: hostId, sessionId });
  peer.close();
  signaling.stop();
  report.ok = true;
  if (values.json) console.log(JSON.stringify(report, null, 2));
  else console.log(`PROBE OK (${(report.selectedPair as any)?.local ?? "?"} -> ${(report.selectedPair as any)?.remote ?? "?"})`);
  shutdownWebRtc();
  process.exit(0);
}

main().catch((err) => {
  console.error(`PROBE FAILED: ${err instanceof Error ? err.message : err}`);
  shutdownWebRtc();
  process.exit(1);
});
