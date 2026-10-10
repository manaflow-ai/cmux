// cmux-next-host CLI: login, run, status, logout, install-chrome, dev-loopback-test.

import { hostname, release } from "node:os";
import { existsSync, unlinkSync } from "node:fs";
import { parseArgs } from "node:util";
import { createInterface } from "node:readline/promises";
import { ApiClient, ApiError } from "./backend/api.ts";
import { HostAgent } from "./backend/hostAgent.ts";
import { HostClient } from "./client.ts";
import { HostCore } from "./host.ts";
import { AcpmuxAgents } from "./bridge/acpmuxAgents.ts";
import { DaemonTerminals } from "./bridge/daemonTerminals.ts";
import { discoverTargets } from "./bridge/discover.ts";
import { downloadChrome, findChromeBinaries } from "./providers/browser/chrome.ts";
import { createLoopbackPair } from "./transport/loopback.ts";
import { enableRtcLoggingFromEnv, shutdownWebRtc } from "./transport/webrtc.ts";
import { configPath, makeLogger, readConfig, stateDir, VERSION, writeConfig } from "./util.ts";

const USAGE = `cmux-next-host ${VERSION}

Usage:
  cmux-next-host login --api https://<backend> [--name <host name>] [--yes]
  cmux-next-host run [--relay-only] [--cdp http://127.0.0.1:9222] [--api URL]
                     [--headless-browser] [--no-browser-launch] [--no-browser-download]
                     [--bridge auto|on|off] [--daemon-socket PATH] [--acpmux-socket PATH]
  cmux-next-host status
  cmux-next-host logout
  cmux-next-host install-chrome
  cmux-next-host dev-loopback-test

State lives in ${stateDir()} (override with CMUX_NEXT_HOST_HOME).`;

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);
  const { values } = parseArgs({
    args: rest,
    options: {
      api: { type: "string" },
      name: { type: "string" },
      yes: { type: "boolean", default: false },
      "relay-only": { type: "boolean", default: false },
      cdp: { type: "string" },
      "headless-browser": { type: "boolean", default: false },
      "no-browser-launch": { type: "boolean", default: false },
      "no-browser-download": { type: "boolean", default: false },
      bridge: { type: "string", default: "auto" },
      "daemon-socket": { type: "string" },
      "acpmux-socket": { type: "string" },
    },
    allowPositionals: true,
  });
  switch (cmd) {
    case "login":
      return login(values.api, values.name, values.yes!);
    case "run":
      return run({
        api: values.api,
        relayOnly: values["relay-only"]!,
        cdp: values.cdp,
        headless: values["headless-browser"]!,
        launch: !values["no-browser-launch"],
        download: !values["no-browser-download"],
        bridge: values.bridge as string,
        daemonSocket: values["daemon-socket"],
        acpmuxSocket: values["acpmux-socket"],
      });
    case "status":
      return status();
    case "logout":
      return logout();
    case "install-chrome": {
      const bin = await downloadChrome(makeLogger("chrome"));
      console.log(bin ? `installed ${bin}` : "chrome download failed");
      process.exitCode = bin ? 0 : 1;
      return;
    }
    case "dev-loopback-test":
      return loopbackTest();
    case undefined:
    case "help":
    case "--help":
    case "-h":
      console.log(USAGE);
      return;
    default:
      console.error(`unknown command ${cmd}\n\n${USAGE}`);
      process.exitCode = 2;
  }
}

/** Asks a yes/no question on the terminal; `--yes` answers yes. */
async function confirm(question: string, yes: boolean): Promise<boolean> {
  if (yes) {
    console.log(`${question}y (--yes)`);
    return true;
  }
  if (!process.stdin.isTTY) {
    console.log(`${question}\nNo terminal to answer on; rerun with --yes to accept.`);
    return false;
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    return /^y(es)?$/i.test((await rl.question(question)).trim());
  } finally {
    rl.close();
  }
}

async function login(apiArg: string | undefined, name: string | undefined, yes = false): Promise<void> {
  const cfg = readConfig();
  const apiBase = apiArg ?? cfg.api ?? process.env.CMUX_NEXT_API;
  if (!apiBase) throw new Error("--api https://<backend> is required");
  const api = new ApiClient(apiBase);
  const hostName = name ?? cfg.hostName ?? hostname().replace(/\.local$/, "");
  const start = await api.pairStart(hostName, `macOS ${release()}`);
  console.log(`\nPair this Mac ("${hostName}") from the cmux app:\n\n    ${start.userCode}\n`);
  console.log("Waiting for approval...");
  const expires = typeof start.expiresAt === "number" ? start.expiresAt : Date.parse(String(start.expiresAt));
  const deadline = Number.isFinite(expires) ? expires : Date.now() + 10 * 60_000;
  let interval = Math.max(1, start.interval || 3) * 1000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, interval));
    let res;
    try {
      res = await api.pairPoll(start.deviceCode);
    } catch (err) {
      if (err instanceof ApiError && (err.code === "slow_down" || err.status === 429)) {
        interval += 2000;
        continue;
      }
      if (err instanceof ApiError && err.status < 500) throw err;
      continue;
    }
    if (res.status === "approved" && "hostToken" in res) {
      const approver = res.approverEmail ?? res.approvedBy?.email ?? res.email ?? `user ${res.userId}`;
      if (!(await confirm(`Approved by ${approver}. Allow this account full access to this Mac? [y/N] `, yes))) {
        console.log("Not paired: the token was discarded. Remove the pending host from the app if it appears there.");
        process.exitCode = 1;
        return;
      }
      writeConfig({ ...cfg, api: api.base, hostId: res.hostId, hostToken: res.hostToken, userId: res.userId, hostName });
      console.log(`Paired as ${res.hostId}. Token saved to ${configPath()}.`);
      console.log("Start the host with: cmux-next-host run");
      return;
    }
    if (res.status !== "pending") throw new Error(`pairing ${res.status}`);
  }
  throw new Error("pairing code expired; run login again");
}

interface RunOptions {
  api?: string;
  relayOnly: boolean;
  cdp?: string;
  headless: boolean;
  launch: boolean;
  download: boolean;
  /** auto (bridge when a cmux-next app is running), on, off. */
  bridge?: string;
  daemonSocket?: string;
  acpmuxSocket?: string;
}

/** Bridges to the running cmux-next app, or null for standalone mode. */
async function setupBridge(opts: RunOptions, log: (m: string) => void) {
  const mode = opts.bridge ?? "auto";
  if (mode === "off") return null;
  if (mode !== "auto" && mode !== "on") throw new Error("--bridge must be auto, on or off");
  const explicit = { daemonSocket: opts.daemonSocket, acpmuxSocket: opts.acpmuxSocket };
  let targets = await discoverTargets(explicit);
  if (!targets.daemonSocket && !targets.acpmuxSocket) {
    if (mode === "on") throw new Error("--bridge on: no running cmux-next app found (no daemon or acpmux socket)");
    log("no running cmux-next app found; standalone mode (own terminals and agents)");
    return null;
  }
  log(`bridging to cmux-next: daemon ${targets.daemonSocket ?? "none"} (session ${targets.session ?? "?"}), acpmux ${targets.acpmuxSocket ?? "none"}`);
  // The app may restart (new socket); re-discover periodically.
  const timer = setInterval(() => {
    void discoverTargets(explicit).then((t) => {
      if (t.daemonSocket !== targets.daemonSocket || t.acpmuxSocket !== targets.acpmuxSocket) log(`cmux-next targets changed: daemon ${t.daemonSocket ?? "none"}, acpmux ${t.acpmuxSocket ?? "none"}`);
      targets = { daemonSocket: t.daemonSocket ?? targets.daemonSocket, session: t.session ?? targets.session, acpmuxSocket: t.acpmuxSocket ?? targets.acpmuxSocket };
    });
  }, 15_000);
  timer.unref();
  return {
    terminals: targets.daemonSocket ? new DaemonTerminals(() => targets.daemonSocket, { log: makeLogger("bridge") }) : undefined,
    agents: targets.acpmuxSocket ? new AcpmuxAgents(() => targets.acpmuxSocket, { log: makeLogger("bridge") }) : undefined,
  };
}

async function run(opts: RunOptions): Promise<void> {
  const log = makeLogger("host");
  const cfg = readConfig();
  const apiBase = opts.api ?? cfg.api;
  if (!apiBase || !cfg.hostToken || !cfg.hostId) {
    // Exit 0 so a LaunchAgent (KeepAlive SuccessfulExit=false) does not loop.
    console.error("not logged in: run `cmux-next-host login --api https://<backend>` first");
    process.exit(0);
  }
  enableRtcLoggingFromEnv(makeLogger("rtc"));
  const bridge = await setupBridge(opts, log);
  const core = new HostCore({
    hostId: cfg.hostId,
    hostName: cfg.hostName,
    log,
    bridge: bridge ?? undefined,
    browser: { cdp: opts.cdp, headless: opts.headless, launch: opts.launch, download: opts.download, log: makeLogger("browser") },
  });
  const api = new ApiClient(apiBase, cfg.hostToken);
  const agent: HostAgent = new HostAgent({
    api,
    core,
    relayOnly: opts.relayOnly,
    log,
    onRevoked: (reason) => {
      const current = readConfig();
      if (current.hostToken === cfg.hostToken) writeConfig({ api: current.api, hostName: current.hostName });
      console.error(`\ncmux-next-host stopped: ${reason}.\nThe host token was removed from ${configPath()}. Pair again with: cmux-next-host login --api ${api.base}`);
      agent.stop();
      core.shutdown();
      shutdownWebRtc();
      process.exit(0);
    },
  });
  agent.start();
  log(`cmux-next-host ${VERSION} running as ${cfg.hostId} (${core.hostName}) against ${api.base}${opts.relayOnly ? " [relay only]" : ""}`);
  if (!opts.cdp && opts.launch && opts.download && findChromeBinaries().length === 0) {
    void downloadChrome(makeLogger("browser")).then((bin) => log(bin ? `browser ready: ${bin}` : "no browser; browser.v1 disabled"));
  }
  const harnesses = await core.agents.harnesses();
  log(`harnesses: ${harnesses.map((h) => `${h.id}=${h.available ? "available" : "unavailable"}`).join(" ")}`);
  const stop = (sig: string) => {
    log(`${sig}: shutting down`);
    agent.stop();
    core.shutdown();
    shutdownWebRtc();
    process.exit(0);
  };
  process.on("SIGINT", () => stop("SIGINT"));
  process.on("SIGTERM", () => stop("SIGTERM"));
  await new Promise(() => {});
}

async function status(): Promise<void> {
  const cfg = readConfig();
  const loggedIn = Boolean(cfg.hostToken);
  console.log(`state dir: ${stateDir()}`);
  console.log(`api:       ${cfg.api ?? "(not set)"}`);
  console.log(`paired:    ${loggedIn ? `yes, host ${cfg.hostId} "${cfg.hostName}" for user ${cfg.userId}` : "no"}`);
  const core = new HostCore({ hostId: cfg.hostId, hostName: cfg.hostName, browser: { launch: false } });
  for (const h of await core.agents.harnesses()) console.log(`harness:   ${h.id} ${h.available ? "available" : "unavailable"}`);
  const browsers = findChromeBinaries();
  console.log(`browser:   ${browsers[0] ?? "none (cmux-next-host install-chrome)"}`);
  if (loggedIn && cfg.api) {
    try {
      const ice = await new ApiClient(cfg.api, cfg.hostToken).ice();
      const urls = ice.iceServers.flatMap((s) => (Array.isArray(s.urls) ? s.urls : [s.urls]));
      console.log(`backend:   reachable, ${urls.length} ICE urls (${urls.filter((u) => u.startsWith("turn")).length} TURN)`);
    } catch (err) {
      console.log(`backend:   ${(err as Error).message}`);
    }
  }
  core.shutdown();
}

function logout(): void {
  if (existsSync(configPath())) {
    const cfg = readConfig();
    writeConfig({ api: cfg.api, hostName: cfg.hostName });
  }
  console.log("Logged out (host token removed). Remove the host from the app to revoke it server-side.");
  if (process.argv.includes("--purge") && existsSync(configPath())) unlinkSync(configPath());
}

async function loopbackTest(): Promise<void> {
  const core = new HostCore({ hostId: "loopback", browser: { launch: false }, log: makeLogger("host") });
  const [phone, host] = createLoopbackPair();
  core.attach(host);
  const client = new HostClient(phone);
  await new Promise((r) => phone.once("state", r));
  const hello = await client.hello("dev-loopback-test");
  console.log("hello", hello);
  const t0 = performance.now();
  for (let i = 0; i < 50; i++) await client.request("host.ping");
  console.log(`ping x50: ${((performance.now() - t0) / 50).toFixed(2)} ms avg`);
  console.log("terminal echo", await client.terminalEcho());
  console.log("harnesses", (await client.request("agent.harnesses")).harnesses.map((h: any) => `${h.id}:${h.available}`));
  console.log("conversations", (await client.request("conv.list")).conversations.map((c: any) => c.id));
  try {
    console.log("tabs", (await client.request("browser.list")).tabs.length);
  } catch (err) {
    console.log("browser.list", (err as Error).message);
  }
  phone.close();
  core.shutdown();
  console.log("dev-loopback-test OK");
  process.exit(0);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  shutdownWebRtc();
  process.exit(1);
});
