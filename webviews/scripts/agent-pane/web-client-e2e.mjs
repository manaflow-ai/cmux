#!/usr/bin/env node
// The web client's round trip, recorded: a browser on another device opens a chat running on a
// daemon, sends to it and sees the reply (Leo's feature map, 2026-11-23, "Web client for local
// chats"). It drives headless Chromium through the `acpmux web --app` link: the sign-in screen
// (browser/BrowserSignIn.tsx), the chat, the composer, the reply. It records a video, a
// screenshot per step and each step's time.
//
// Two modes:
//   local (default)  starts a daemon of its own (scratch ACPMUX_HOME, loopback listener, the
//                    `fake` harness from cmux-tui/crates/acpmux/tests/fake_agent.py, which replies
//                    "echo: <text>"), serving the pane built from this checkout
//                    (scripts/cmux-next/build-agent-pane-web.sh), and creates the chat.
//   --url URL        an existing `acpmux web --app` link (a daemon on another machine, served over
//                    tailnet HTTPS by `acpmux web --tailnet`); `--session ID` names the chat.
//
// Stubbed, and only this: Stack Auth's emailed code. `_acpmux/browser_sign_in_start` and
// `_complete` call Stack itself (cmux-stack-auth, its origin a constant), and no test hook or fake
// Stack exists, so the page's socket is routed through Playwright (page.routeWebSocket) and those
// two methods are answered there with a made-up access token. Everything after is real daemon
// code: `_acpmux/device_enroll` mints and redeems a join on the mesh hub, `_acpmux/device_hello`
// checks the device with the hub and admits the socket (server/web_device.rs `admit`), then the
// chat's load, prompt and stream. In local mode the mesh hub is a fake one this script serves on
// loopback (the four endpoints those calls use, from cmux-cloud-client/openapi.json), and the
// daemon's home holds a join record naming it (machine-credential.json, meshRelay in config).
// --real-sign-in stubs nothing (a person reads the emailed code: --email, --code).
//
//   node scripts/agent-pane/web-client-e2e.mjs [--out DIR] [--pane DIR] [--acpmux BIN]
//        [--url URL --session ID] [--real-sign-in --email E --code C] [--timeout-ms N]
//
// Outputs in --out (default $FAST_CHECKS_OUT, else a temp dir): video/*.webm, NN-step.png,
// timings.json (pass/fail, each step's ms, what was stubbed), daemon.log.
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { parseArgs } from "node:util";
import { chromium } from "playwright";
import { webviews } from "./mockLaunch.mjs";

const repo = path.resolve(webviews, "..");
const { values: args } = parseArgs({
  options: {
    out: { type: "string" },
    pane: { type: "string" },
    acpmux: { type: "string" },
    url: { type: "string" },
    session: { type: "string" },
    "real-sign-in": { type: "boolean", default: false },
    email: { type: "string", default: "e2e@cmux.test" },
    code: { type: "string", default: "424242" },
    message: { type: "string" },
    "timeout-ms": { type: "string", default: "60000" },
  },
});
const STEP_MS = Number(args["timeout-ms"]);
const out = path.resolve(args.out ?? process.env.FAST_CHECKS_OUT ?? fs.mkdtempSync(path.join(os.tmpdir(), "web-e2e-")));
fs.mkdirSync(out, { recursive: true });
const report = {
  mode: args.url ? "remote" : "local",
  stubbed: args["real-sign-in"] ? [] : ["_acpmux/browser_sign_in_start", "_acpmux/browser_sign_in_complete"],
  fakeHub: !args.url,
  steps: [],
  ok: false,
};
const cleanups = [];
const log = (...a) => console.log("[web-e2e]", ...a);

function writeReport() {
  fs.writeFileSync(path.join(out, "timings.json"), JSON.stringify(report, null, 2) + "\n");
}

let page;
let shot = 0;
async function step(name, fn) {
  const start = performance.now();
  const entry = { name, ms: 0, ok: false };
  report.steps.push(entry);
  try {
    const result = await fn();
    entry.ok = true;
    return result;
  } catch (error) {
    entry.error = String(error?.message ?? error).split("\n")[0];
    throw error;
  } finally {
    entry.ms = Math.round(performance.now() - start);
    log(`${entry.ok ? "ok  " : "FAIL"} ${name} ${entry.ms} ms${entry.error ? ` (${entry.error})` : ""}`);
    if (page) {
      const file = `${String(++shot).padStart(2, "0")}-${name.replace(/\W+/g, "-")}.png`;
      await page.screenshot({ path: path.join(out, file) }).catch(() => undefined);
    }
    writeReport();
  }
}

/** A free loopback port. */
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

/** The person, team and device the fake hub knows. */
const OWNER = { userId: "user_e2e", teamId: "team_e2e" };
const ACCESS_TOKEN = "e2e-stub-access-token";
const DEVICE_CREDENTIAL = "cmm_e2e_browser_device";

/** A mesh hub on loopback with the endpoints the browser's enroll and hello use. Every other call
 * (the daemon's heartbeat, relay, capabilities) is answered 404 and counted. */
async function startFakeHub() {
  const http = await import("node:http");
  const calls = (report.hubCalls = {});
  let devicePublicKey = "";
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const route = `${req.method} ${req.url.replace(/\?.*/, "")}`;
      calls[route] = (calls[route] ?? 0) + 1;
      const bearer = (req.headers.authorization ?? "").replace(/^Bearer /i, "");
      const send = (status, value) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify(value ?? {}));
      };
      const json = () => {
        try {
          return JSON.parse(body);
        } catch {
          return {};
        }
      };
      if (route === "POST /v1/machines/join-tokens") {
        if (bearer !== ACCESS_TOKEN) return send(401, { code: "auth.unauthorized" });
        return send(200, {
          joinTokenId: "jt_e2e",
          token: "cmj_e2e_join_token",
          expiresAt: new Date(Date.now() + 600_000).toISOString(),
          teamId: OWNER.teamId,
          label: json().label,
        });
      }
      if (route === "POST /v1/machines/join-tokens/redeem") {
        const redeem = json();
        if (redeem.token !== "cmj_e2e_join_token" || redeem.platform !== "web")
          return send(401, { code: "join.invalid" });
        devicePublicKey = redeem.wgPublicKey;
        return send(200, {
          credential: DEVICE_CREDENTIAL,
          machineId: "machine_e2e_browser",
          joinTokenId: "jt_e2e",
          ...OWNER,
          wgPublicKey: devicePublicKey,
          expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
        });
      }
      if (route === "GET /v1/machines/credentials/self" && bearer === DEVICE_CREDENTIAL) {
        return send(200, {
          machineId: "machine_e2e_browser",
          ...OWNER,
          joinTokenId: "jt_e2e",
          platform: "web",
          hostname: "web",
          name: "web",
          wgPublicKey: devicePublicKey,
          credentialGeneration: 1,
          expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
        });
      }
      send(404, { code: "e2e.not_served" });
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise((resolve) => server.close(resolve)));
  server.unref();
  return `http://127.0.0.1:${server.address().port}`;
}

function acpmuxBin() {
  if (args.acpmux) return args.acpmux;
  for (const candidate of [path.join(os.homedir(), ".local/bin/acpmux"), "/usr/local/bin/acpmux"])
    if (fs.existsSync(candidate)) return candidate;
  return "acpmux";
}

/** A daemon of this run's own: scratch home (0700, as the daemon requires), loopback listener. */
async function startLocalDaemon() {
  const bin = acpmuxBin();
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "web-e2e-daemon-"));
  fs.chmodSync(scratch, 0o700);
  const home = path.join(scratch, "home");
  const work = path.join(scratch, "work");
  fs.mkdirSync(home, { mode: 0o700 });
  fs.mkdirSync(work);
  const port = await freePort();
  const hub = await startFakeHub();
  // This daemon's join: the owner a browser must sign in as (cli/cloud_join.rs browser_app_owner).
  fs.writeFileSync(
    path.join(home, "machine-credential.json"),
    JSON.stringify({
      credential: "cmm_e2e_daemon",
      machine_id: "machine_e2e_daemon",
      team_id: OWNER.teamId,
      name: "e2e-daemon",
      hub_origin: hub,
      last_heartbeat: null,
      revoked: false,
      wgPublicKey: Buffer.alloc(32, 7).toString("base64"),
      user_id: OWNER.userId,
    }),
    { mode: 0o600 },
  );
  const config = {
    meshRelay: { url: hub, credential: "join" },
    harnesses: { fake: { argv: ["python3", path.join(repo, "cmux-tui/crates/acpmux/tests/fake_agent.py")] } },
    defaultHarness: "fake",
    permissionPolicy: "approve-all",
    websocket: { listen: `127.0.0.1:${port}` },
  };
  fs.writeFileSync(path.join(home, "config.json"), JSON.stringify(config), { mode: 0o600 });
  let pane = args.pane;
  if (!pane) {
    pane = path.join(scratch, "pane");
    log("building the pane from this checkout");
    execFileSync("sh", [path.join(repo, "scripts/cmux-next/build-agent-pane-web.sh"), "--out", pane], {
      stdio: ["ignore", "ignore", "inherit"],
      timeout: 600_000,
    });
  }
  const env = {
    ...process.env,
    ACPMUX_HOME: home,
    ACPMUX_SOCKET: path.join(scratch, "s.sock"),
    ACPMUX_APP_ASSETS_DIR: path.resolve(pane),
    ACPMUX_DAEMON_PRUNE: "0",
  };
  const daemonLog = fs.openSync(path.join(out, "daemon.log"), "w");
  const daemon = spawn(bin, ["daemon", "run", "--log", "info"], { env, stdio: ["ignore", daemonLog, daemonLog] });
  cleanups.push(async () => {
    try {
      execFileSync(bin, ["daemon", "shutdown", "--end-agents"], { env, timeout: 20_000, stdio: "ignore" });
    } catch {}
    if (daemon.exitCode === null) daemon.kill("SIGTERM");
  });
  const cli = (...argv) => execFileSync(bin, argv, { env, timeout: 60_000, encoding: "utf8" });
  const deadline = Date.now() + 30_000;
  while (!fs.existsSync(env.ACPMUX_SOCKET)) {
    if (daemon.exitCode !== null) throw new Error(`daemon exited ${daemon.exitCode}; see daemon.log`);
    if (Date.now() > deadline) throw new Error("daemon socket did not appear in 30 s");
    await new Promise((r) => setTimeout(r, 100));
  }
  const created = JSON.parse(cli("new", "--machine", "local", "--cwd", work, "-n", "web-e2e-chat", "-d", "--json"));
  const sessionId = created.sessionId ?? created.id;
  if (!sessionId) throw new Error(`no session id in acpmux new output: ${Object.keys(created).join(",")}`);
  const url = JSON.parse(cli("web", "--app", "--no-open", "--json")).url;
  return { url, sessionId };
}

/** The page's socket through Playwright: the sign-in and device methods answered here. */
async function stubSignIn(target) {
  await target.routeWebSocket(/\/app\/ws$/, (ws) => {
    const server = ws.connectToServer();
    frames.push(`open ${ws.url().replace(/[?#].*/, "")}`);
    ws.onMessage((frame) => {
      let message;
      try {
        message = JSON.parse(String(frame));
      } catch {}
      frames.push(`-> ${message?.method ?? `(id ${message?.id})`}`);
      const answer = message && typeof message.id !== "undefined" && stubAnswer(message.method, message.params);
      if (answer) {
        report.stubCalls = (report.stubCalls ?? 0) + 1;
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer }));
      } else server.send(frame);
    });
    server.onMessage((frame) => {
      let message;
      try {
        message = JSON.parse(String(frame));
      } catch {}
      frames.push(
        `<- ${message?.method ?? `(id ${message?.id})${message?.error ? ` error ${message.error.message}` : ""}`}`,
      );
      ws.send(frame);
    });
    server.onClose((code, reason) => {
      frames.push(`server closed ${code} ${reason}`);
      ws.close({ code, reason });
    });
    ws.onClose((code, reason) => {
      frames.push(`page closed ${code} ${reason}`);
      server.close({ code, reason });
    });
  });
}

/** Each frame's method or id (never its params: no token or credential lands in the log). */
const frames = [];
cleanups.push(() => fs.writeFileSync(path.join(out, "frames.log"), frames.join("\n") + "\n"));

let stubKey = "";
function stubAnswer(method, params) {
  switch (method) {
    case "_acpmux/browser_sign_in_start":
      stubKey = String(params?.publicKey ?? "");
      return { expiresIn: 300 };
    case "_acpmux/browser_sign_in_complete":
      return params?.code === args.code ? { accessToken: ACCESS_TOKEN, publicKey: stubKey } : undefined;
    default:
      return undefined;
  }
}

async function main() {
  const started = performance.now();
  let target = args.url ? { url: args.url, sessionId: args.session } : undefined;
  if (!target) target = await step("start daemon and chat", startLocalDaemon);
  report.sessionId = target.sessionId;

  const shell = process.env.CMUX_CHROME_HEADLESS_SHELL;
  // recordVideo needs Playwright's ffmpeg (2 MB); a fleet worker may not have fetched it.
  try {
    execFileSync(process.execPath, [path.join(webviews, "node_modules/playwright/cli.js"), "install", "ffmpeg"], {
      timeout: 180_000,
      stdio: "ignore",
    });
  } catch (error) {
    log(`playwright install ffmpeg failed (${error.message}); the video may be missing`);
  }
  const browser = await step("launch browser", async () => {
    try {
      return await chromium.launch(shell ? { executablePath: shell } : { channel: "chrome" });
    } catch (error) {
      log(`system chrome unavailable (${String(error.message).split("\n")[0]}); playwright chromium`);
      report.browser = "playwright-chromium";
      return chromium.launch();
    }
  });
  report.browser ??= shell ? "chrome-headless-shell" : "system-chrome";
  cleanups.push(() => browser.close());
  const context = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    recordVideo: { dir: path.join(out, "video"), size: { width: 1280, height: 800 } },
  });
  cleanups.unshift(() => context.close()); // first: closing the context writes the video
  page = await context.newPage();
  const consoleLines = [];
  page.on("console", (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
  page.on("pageerror", (e) => consoleLines.push(`pageerror: ${e.message}`));
  cleanups.push(() => fs.writeFileSync(path.join(out, "console.log"), consoleLines.join("\n") + "\n"));
  if (!args["real-sign-in"]) await stubSignIn(page);

  // The chat rides the link (`?session=`, browser/host.ts), as a link to one chat does.
  const link = new URL(target.url);
  if (target.sessionId) link.searchParams.set("session", target.sessionId);
  await step("open link: sign-in screen", async () => {
    await page.goto(link.href, { timeout: STEP_MS });
    await page.locator(".browser-sign-in-form input[type=email]").waitFor({ timeout: STEP_MS });
  });
  await step("sign in: email", async () => {
    await page.locator(".browser-sign-in-form input[type=email]").fill(args.email);
    await page.locator(".browser-sign-in-form button[type=submit]").click();
    await page.locator(".browser-sign-in-form input[autocomplete=one-time-code]").waitFor({ timeout: STEP_MS });
  });
  await step("sign in: code", async () => {
    await page.locator(".browser-sign-in-form input[autocomplete=one-time-code]").fill(args.code);
    await page.locator(".browser-sign-in-form button[type=submit]").click();
    await page.locator(".browser-sign-in-form").waitFor({ state: "detached", timeout: STEP_MS });
  });
  const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']").first();
  await step("open chat", async () => {
    await prompt.waitFor({ timeout: STEP_MS });
  });
  const text = args.message ?? `hello from the browser ${Date.now()}`;
  report.message = text;
  await step("send", async () => {
    await prompt.click();
    await page.keyboard.type(text);
    await page.keyboard.press("Enter");
    // Sent: the composer is empty again and the message is in the transcript.
    await page.waitForFunction(
      (selector) => !document.querySelector(selector)?.textContent?.trim(),
      ".acpmux-composer-prompt [contenteditable='true']",
      { timeout: STEP_MS },
    );
    await page.getByText(text, { exact: true }).first().waitFor({ timeout: STEP_MS });
  });
  // The fake harness answers "echo: <text>"; a real agent's reply is any new assistant text.
  await step("see reply", async () => {
    await page
      .getByText(args.url ? text : `echo: ${text}`)
      .last()
      .waitFor({ timeout: STEP_MS });
  });
  report.totalMs = Math.round(performance.now() - started);
  report.ok = true;
}

let code = 0;
try {
  await main();
} catch (error) {
  code = 1;
  report.error = String(error?.message ?? error).split("\n")[0];
  console.error(error);
} finally {
  for (const fn of cleanups)
    await Promise.resolve()
      .then(fn)
      .catch((e) => log("cleanup:", e.message));
  const videos = fs.existsSync(path.join(out, "video")) ? fs.readdirSync(path.join(out, "video")) : [];
  report.video = videos.map((v) => path.join("video", v));
  writeReport();
  log(`${report.ok ? "PASS" : "FAIL"} -> ${out}`);
}
process.exit(code);
