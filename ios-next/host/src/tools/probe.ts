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
import { WebRtcPeer, enableRtcLoggingFromEnv, shutdownWebRtc } from "../transport/webrtc.ts";
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
      duration: { type: "string", default: "0" },
      agent: { type: "string" },
      "attach-terminal": { type: "string" },
      type: { type: "string" },
      "agent-history": { type: "string" },
      "skip-echo": { type: "boolean", default: false },
      "agent-prompt": { type: "string" },
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
  enableRtcLoggingFromEnv((m) => console.error(`${new Date().toISOString()} ${m}`));
  const t0 = performance.now();

  const api = new ApiClient(apiBase, token);
  const ice = await api.ice();
  const iceUrls = ice.iceServers.flatMap((s) => (Array.isArray(s.urls) ? s.urls : [s.urls]));
  report.iceUrls = iceUrls;
  log(`ice: ${iceUrls.join(", ") || "(none)"}`);

  const signaling = new SignalingClient({ url: () => api.signalUrl(), token: () => api.bearer, log: (m) => log(`signal: ${m}`) });
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
      if (sig.type === "description") signaling.send({ type: "offer", to: hostId, sessionId, sdp: sig.sdp, ...(relayOnly ? { policy: "relay" as const } : {}) });
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

  if (!values["skip-echo"]) {
    const echo = await client.terminalEcho();
    report.terminalEcho = echo;
    log(`terminal echo ok in ${echo.ms} ms`);
  }

  // Bridge checks: list the Mac's terminals and agent sessions; optionally
  // attach an existing terminal, type into it and print what it shows.
  const { terminals } = await client.request("term.list");
  report.terminals = terminals;
  log(`terminals: ${JSON.stringify(terminals.map((t: any) => ({ id: t.id, title: t.title, grid: `${t.cols}x${t.rows}` })))}`);
  if (values["attach-terminal"]) {
    const { streamId, terminal } = await client.request("term.attach", { terminalId: values["attach-terminal"], cols: 50, rows: 20 });
    let screen = "";
    client.onStream(streamId, (p) => (screen += new TextDecoder().decode(p)));
    await new Promise((r) => setTimeout(r, 1000));
    const replayBytes = screen.length;
    if (values.type) client.sendInput(streamId, values.type);
    await new Promise((r) => setTimeout(r, 2500));
    const plain = screen.replace(/\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>c]|\r/g, "");
    report.attached = { terminal, replayBytes, tail: plain.slice(-600) };
    log(`attached ${terminal.id} at ${terminal.cols}x${terminal.rows}; replay ${replayBytes} bytes; screen tail:\n${plain.trim().split("\n").filter(Boolean).slice(-8).join("\n")}`);
    await client.request("term.detach", { streamId });
  }
  const { sessions } = await client.request("agent.list");
  report.sessions = sessions;
  log(`agent sessions: ${JSON.stringify(sessions.map((x: any) => ({ id: x.id, title: x.title, harness: x.harness, status: x.status })))}`);
  if (values["agent-history"]) {
    const h = await client.request("agent.history", { sessionId: values["agent-history"] }, 60_000);
    log(`history ${values["agent-history"]}: ${JSON.stringify(h.items.map((i: any) => [i.kind, (i.text ?? i.title ?? i.stopReason ?? "").slice(0, 80), i.output ? i.output.slice(0, 40) : undefined].filter((x) => x !== undefined)))}`);
  }

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

  // Optional agent turn: --agent codex --agent-prompt "..." prints the tool rows
  // (title, status, output) so tool output mapping can be checked end to end.
  if (values.agent) {
    const items = new Map<string, any>();
    let sessionId = "";
    const ended = new Promise<void>((resolve) => {
      client.peer.on("event", (topic, p) => {
        if (topic !== "agent.item" || (sessionId && p.sessionId !== sessionId)) return;
        items.set(p.item.id, p.item);
        if (p.item.kind === "permission" && !p.item.resolved) {
          const allow = p.item.options.find((o: any) => o.kind === "allow_once") ?? p.item.options[0];
          if (allow) void client.request("agent.permission", { sessionId: p.sessionId, itemId: p.item.id, optionId: allow.id });
        }
        if (p.item.kind === "turnEnd") resolve();
      });
    });
    const { session } = await client.request("agent.create", { harness: values.agent, prompt: values["agent-prompt"] ?? "Run `echo probe-tool-check` in the shell." }, 60_000);
    sessionId = session.id;
    await Promise.race([ended, new Promise((_, rej) => setTimeout(() => rej(new Error("agent turn timeout")), 240_000))]);
    const tools = [...items.values()].filter((i) => i.kind === "tool").map((i) => ({ title: i.title, status: i.status, input: i.input, output: i.output }));
    const reply = [...items.values()].filter((i) => i.kind === "assistant").map((i) => i.text).join("\n");
    report.agent = { sessionId, tools, reply };
    log(`agent tools: ${JSON.stringify(tools, null, 2)}`);
    log(`agent reply: ${reply}`);
    await client.request("agent.close", { sessionId });
  }

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

  // Soak: keep the link up for --duration seconds with a ping every 2 s and a
  // terminal round trip every 30 s; fail on the first missed ping or close.
  const duration = Number(values.duration) * 1000;
  if (duration > 0) {
    const soakStart = Date.now();
    let closedReason: string | null = null;
    peer.link.on("state", (s) => {
      if (s === "closed") closedReason = peer.link.closeReason ?? "closed";
    });
    const { terminal } = await client.request("term.create", { cols: 80, rows: 24 });
    const { streamId } = await client.request("term.attach", { terminalId: terminal.id, cols: 80, rows: 24 });
    let termOut = "";
    client.onStream(streamId, (p) => (termOut += new TextDecoder().decode(p)));
    let pings = 0;
    let misses = 0;
    let missedTotal = 0;
    let worst = 0;
    let echoes = 0;
    let nextEcho = Date.now() + 30_000;
    while (Date.now() - soakStart < duration) {
      await new Promise((r) => setTimeout(r, 2000));
      const elapsed = Math.round((Date.now() - soakStart) / 1000);
      if (closedReason) throw new Error(`soak: link closed after ${elapsed}s: ${closedReason}`);
      // Same liveness rule as the app: three unanswered pings in a row.
      const s = performance.now();
      try {
        await client.request("host.ping", {}, 8000);
        misses = 0;
      } catch (err) {
        misses++;
        missedTotal++;
        log(`soak ${elapsed}s: ping unanswered (${misses}/3): ${(err as Error).message}`);
        if (misses >= 3) throw new Error(`soak: 3 pings unanswered after ${elapsed}s`);
        continue;
      }
      const rtt = performance.now() - s;
      worst = Math.max(worst, rtt);
      pings++;
      if (Date.now() >= nextEcho) {
        const marker = `soak-${elapsed}`;
        client.sendInput(streamId, `echo ${marker}\r`);
        const deadline = Date.now() + 8000;
        while (termOut.split(marker).length < 3 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
        if (termOut.split(marker).length < 3) throw new Error(`soak: terminal echo failed after ${elapsed}s`);
        echoes++;
        nextEcho = Date.now() + 30_000;
        const p = peer.selectedPair();
        log(`soak ${elapsed}s: ${pings} pings ok (worst ${worst.toFixed(0)} ms), ${echoes} echoes, pair ${p?.local}->${p?.remote}`);
      }
    }
    report.soak = { seconds: Math.round((Date.now() - soakStart) / 1000), pings, missedPings: missedTotal, echoes, worstRttMs: Math.round(worst), pair: peer.selectedPair() };
    await client.request("term.close", { terminalId: terminal.id });
  }

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
