// cmux-next-host CLI: login, run, status, logout, install-chrome, dev-loopback-test.

import { hostname, release } from "node:os";
import { existsSync, unlinkSync } from "node:fs";
import { parseArgs } from "node:util";
import { ApiClient, ApiError } from "./backend/api.ts";
import { HostAgent } from "./backend/hostAgent.ts";
import { HostClient } from "./client.ts";
import { HostCore } from "./host.ts";
import { downloadChrome, findChromeBinaries } from "./providers/browser/chrome.ts";
import { createLoopbackPair } from "./transport/loopback.ts";
import { shutdownWebRtc } from "./transport/webrtc.ts";
import { configPath, makeLogger, readConfig, stateDir, VERSION, writeConfig } from "./util.ts";

const USAGE = `cmux-next-host ${VERSION}

Usage:
  cmux-next-host login --api https://<backend> [--name <host name>]
  cmux-next-host run [--relay-only] [--cdp http://127.0.0.1:9222] [--api URL]
                     [--headless-browser] [--no-browser-launch] [--no-browser-download]
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
      "relay-only": { type: "boolean", default: false },
      cdp: { type: "string" },
      "headless-browser": { type: "boolean", default: false },
      "no-browser-launch": { type: "boolean", default: false },
      "no-browser-download": { type: "boolean", default: false },
    },
    allowPositionals: true,
  });
  switch (cmd) {
    case "login":
      return login(values.api, values.name);
    case "run":
      return run({
        api: values.api,
        relayOnly: values["relay-only"]!,
        cdp: values.cdp,
        headless: values["headless-browser"]!,
        launch: !values["no-browser-launch"],
        download: !values["no-browser-download"],
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

async function login(apiArg: string | undefined, name: string | undefined): Promise<void> {
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
      writeConfig({ ...cfg, api: api.base, hostId: res.hostId, hostToken: res.hostToken, userId: res.userId, hostName });
      console.log(`Paired as ${res.hostId}. Token saved to ${configPath()}.`);
      console.log("Start the host with: cmux-next-host run");
      return;
    }
    if (res.status !== "pending") throw new Error(`pairing ${res.status}`);
  }
  throw new Error("pairing code expired; run login again");
}

async function run(opts: { api?: string; relayOnly: boolean; cdp?: string; headless: boolean; launch: boolean; download: boolean }): Promise<void> {
  const log = makeLogger("host");
  const cfg = readConfig();
  const apiBase = opts.api ?? cfg.api;
  if (!apiBase || !cfg.hostToken || !cfg.hostId) throw new Error("not logged in: run `cmux-next-host login --api https://<backend>` first");
  const core = new HostCore({
    hostId: cfg.hostId,
    hostName: cfg.hostName,
    log,
    browser: { cdp: opts.cdp, headless: opts.headless, launch: opts.launch, download: opts.download, log: makeLogger("browser") },
  });
  const api = new ApiClient(apiBase, cfg.hostToken);
  const agent = new HostAgent({ api, core, relayOnly: opts.relayOnly, log });
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
