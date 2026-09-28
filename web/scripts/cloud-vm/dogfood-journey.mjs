#!/usr/bin/env node
// A timed end-to-end user journey through cmux Cloud, the way the app drives it,
// but from a plain Linux box with only cmux-tui:
//
//   create -> list -> private tunnel -> WireGuard hub -> attach-endpoint ->
//   headless `remote connect --carrier` -> first prompt in the VM terminal ->
//   agent CLIs present -> sleep (pause) -> wake (resume) -> the same terminal
//   comes back -> client killed and relaunched -> the same terminal is restored
//   -> delete -> gone.
//
// Every step is timed. The run prints one JSON summary and writes it to
// --result-file, success or failure, so a workflow can publish the numbers.
// A throwaway paid smoke user owns the VM, exactly like smoke-vm-api.mjs, and
// is deleted at the end.
import { spawn } from "node:child_process";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  loadTargetEnv,
  optionValue,
  parseWebDirAndTarget,
  requireEnvKeys,
} from "./projects.mjs";

const usage = "Usage: dogfood-journey.mjs [web-dir] <staging|production> --cmux-tui <path> [--url https://preview.example] [--provider freestyle|default] [--skip-sleep] [--result-file <path>] [--screens-dir <path>]";
const args = process.argv.slice(2);
const { webDir, target, project, rest } = parseWebDirAndTarget(args, usage);
const cmuxTui = optionValue(rest, "--cmux-tui");
if (!cmuxTui) {
  console.error(usage);
  process.exit(2);
}
const provider = optionValue(rest, "--provider") ?? "default";
const targetUrl = optionValue(rest, "--url") ?? project.url;
const skipSleep = rest.includes("--skip-sleep");
const resultFile = optionValue(rest, "--result-file");
const screensDir = optionValue(rest, "--screens-dir");
const REQUEST_TIMEOUT_MS = 45_000;

const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const stackModule = await import(pathToFileURL(requireFromWeb.resolve("@hexclave/js")).href);
const { StackServerApp } = stackModule;

const scratch = mkdtempSync(path.join(tmpdir(), "cmux-dogfood-"));
const runStartedAt = performance.now();
const timings = {};
const notes = [];
const children = new Set();
let stage = "setup";
let user;
let vmId;
let authHeaders;
let deviceId;

function note(text) {
  notes.push(text);
  console.error(`note: ${text}`);
}

async function timed(name, work) {
  stage = name;
  const startedAt = performance.now();
  try {
    return await work();
  } finally {
    timings[`${name}Ms`] = Math.round(performance.now() - startedAt);
    console.error(`step ${name} ${timings[`${name}Ms`]}ms`);
  }
}

async function api(method, route, body, timeoutMs = REQUEST_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${targetUrl}${route}`, {
      method,
      headers: { ...authHeaders, ...(body === undefined ? {} : { "content-type": "application/json" }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
    const text = await response.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {}
    return { status: response.status, text, json };
  } finally {
    clearTimeout(timer);
  }
}

function expectStatus(response, statuses, what) {
  if (!statuses.includes(response.status)) {
    throw new Error(`${what} expected ${statuses.join("/")}, got ${response.status}: ${response.text.slice(0, 400)}`);
  }
  return response.json;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// One long-running cmux-tui process whose stdout is JSON lines.
function startJsonProcess(name, argv) {
  const child = spawn(cmuxTui, [...argv, "--exit-with-parent"], { stdio: ["pipe", "pipe", "pipe"] });
  children.add(child);
  child.on("error", (error) => { stderr += `\nspawn failed: ${error.message}`; });
  const lines = [];
  const waiters = [];
  let buffer = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      event.atMs = Math.round(performance.now() - runStartedAt);
      lines.push(event);
      for (const waiter of [...waiters]) {
        if (waiter.match(event)) {
          waiters.splice(waiters.indexOf(waiter), 1);
          waiter.resolve(event);
        }
      }
    }
  });
  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(-4000);
  });
  const exited = new Promise((resolve) => child.on("exit", (code, signal) => {
    children.delete(child);
    for (const waiter of waiters.splice(0)) {
      waiter.reject(new Error(`${name} exited (${code ?? signal}) before the expected event: ${stderr.slice(-600)}`));
    }
    resolve({ code, signal });
  }));
  return {
    child,
    lines,
    exited,
    stderr: () => stderr,
    // A position in the event log; take it before the action whose effect you
    // wait for, so an event that lands before the action returns is not missed.
    mark: () => lines.length,
    // Resolves with the first matching event at or after `from`, seen or future.
    waitFor(match, timeoutMs, what, from = 0) {
      const seen = lines.slice(from).find(match);
      if (seen) return Promise.resolve(seen);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          const index = waiters.indexOf(waiter);
          if (index < 0) return;
          waiters.splice(index, 1);
          reject(new Error(`${name}: no ${what} within ${timeoutMs}ms: ${stderr.slice(-600)}`));
        }, timeoutMs);
        const waiter = {
          match,
          resolve: (event) => { clearTimeout(timer); resolve(event); },
          reject: (error) => { clearTimeout(timer); reject(error); },
        };
        waiters.push(waiter);
      });
    },
    stop(signal = "SIGTERM") {
      if (child.exitCode === null && child.signalCode === null) child.kill(signal);
      return exited;
    },
  };
}

function runTui(argv, timeoutMs = 30_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmuxTui, argv, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

function wireGuardKeypair() {
  const { publicKey, privateKey } = generateKeyPairSync("x25519");
  // The raw 32-byte keys are the tails of the SPKI and PKCS#8 encodings.
  const publicRaw = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
  const privateRaw = privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32);
  return { publicKey: publicRaw.toString("base64"), privateKey: privateRaw.toString("base64") };
}

// Same edit as VMTunnelManager.completedConfig: fill the blank PrivateKey and
// narrow AllowedIPs to this owner's networks.
function completedConfig(config, privateKey, allowedIPs) {
  const lines = config.split("\n");
  const key = (line) => line.split("=")[0].trim().toLowerCase();
  const privateIndex = lines.findIndex((line) => key(line) === "privatekey");
  if (privateIndex >= 0) lines[privateIndex] = `PrivateKey = ${privateKey}`;
  else lines.splice(lines.findIndex((line) => line.trim().toLowerCase() === "[interface]") + 1, 0, `PrivateKey = ${privateKey}`);
  if (allowedIPs.length > 0) {
    const routes = `AllowedIPs = ${allowedIPs.join(", ")}`;
    const allowedIndex = lines.findIndex((line) => key(line) === "allowedips");
    if (allowedIndex >= 0) lines[allowedIndex] = routes;
    else lines.splice(lines.findIndex((line) => line.trim().toLowerCase() === "[peer]") + 1, 0, routes);
  }
  return lines.join("\n");
}

function privateRoute(vm) {
  const address = vm?.address?.ipv4 || vm?.address?.ipv6;
  if (!address) return null;
  return `ws://${address.includes(":") ? `[${address}]` : address}:1337/v1/link`;
}

function connectArgv(route, session, hubSocket) {
  return [
    "remote", "connect", route,
    "--device-name", "cmux-dogfood",
    "--state-dir", path.join(scratch, "client-state"),
    "--headless", "--json", "--lanes", "single",
    "--carrier",
    "--wireguard-hub", hubSocket,
    "--session", session,
  ];
}

const isConnected = (event) => event.event === "connection-snapshot" && event.connection?.state === "connected";

// A fresh machine's session may have no workspace yet; the app creates one on
// first open, so do the same.
async function ensureTerminal(localSocket) {
  const listTerminals = async () => {
    const list = await runTui(["--socket", localSocket, "--json", "terminal", "list"]);
    if (list.code !== 0) throw new Error(`terminal list failed (${list.code}): ${list.stderr.slice(-400)}`);
    return JSON.parse(list.stdout || "[]");
  };
  let terminals = await listTerminals();
  if (terminals.length === 0) {
    const created = await runTui(["--socket", localSocket, "--json", "workspace", "create"]);
    if (created.code !== 0) throw new Error(`workspace create failed (${created.code}): ${created.stderr.slice(-400)}`);
    terminals = await listTerminals();
  }
  if (terminals.length === 0) throw new Error("the session has no terminal after workspace create");
  return terminals[0].id;
}

async function saveScreen(localSocket, terminal, name) {
  const screen = await runTui(["--socket", localSocket, "terminal", terminal, "screen", "read"]);
  if (screensDir) writeFileSync(path.join(screensDir, `${name}.txt`), screen.stdout);
  return screen.stdout;
}

async function waitForScreen(localSocket, terminal, pattern, timeoutMs) {
  const result = await runTui(
    ["--socket", localSocket, "--json", "terminal", terminal, "screen", "wait", "--pattern", pattern, "--timeout-ms", String(timeoutMs)],
    timeoutMs + 10_000,
  );
  if (result.code !== 0) throw new Error(`screen wait for /${pattern}/ failed (${result.code}): ${result.stderr.slice(-400)}`);
  // A timeout is a normal result with matched false and exit status 0.
  let matched = false;
  try {
    matched = JSON.parse(result.stdout).matched === true;
  } catch {}
  if (!matched) throw new Error(`/${pattern}/ did not appear on the terminal within ${timeoutMs}ms`);
}

async function sessionHeaders(stackUser, expiresInMillis) {
  const session = await stackUser.createSession({ expiresInMillis, isImpersonation: true });
  const tokens = await session.getTokens();
  if (!tokens.accessToken || !tokens.refreshToken) throw new Error("Stack did not return session tokens");
  return { authorization: `Bearer ${tokens.accessToken}`, "x-stack-refresh-token": tokens.refreshToken };
}

// Deletes every VM and device grant the account holds. Returns true when the
// account is empty, so its user can be deleted without orphaning anything.
async function emptyAccount(headers) {
  const saved = authHeaders;
  authHeaders = headers;
  try {
    let clean = true;
    const list = await api("GET", "/api/vm");
    if (list.status !== 200) return false;
    for (const vm of list.json?.vms ?? []) {
      const destroy = await api("DELETE", `/api/vm/${encodeURIComponent(vm.id)}`);
      if (destroy.status !== 200 && destroy.status !== 404) {
        console.error(`cleanup_needed_vm=${vm.id} status=${destroy.status}`);
        clean = false;
      }
    }
    const grants = await api("GET", "/api/vm/tunnel");
    if (grants.status !== 200) return false;
    for (const grant of grants.json?.devices ?? []) {
      const query = grant.accessGrantId ?? grant.id
        ? `accessGrantId=${encodeURIComponent(grant.accessGrantId ?? grant.id)}`
        : `deviceId=${encodeURIComponent(grant.deviceId)}`;
      const revoke = await api("DELETE", `/api/vm/tunnel?${query}`);
      if (revoke.status !== 200 && revoke.status !== 404) {
        console.error(`cleanup_needed_tunnel=${grant.deviceId ?? grant.id} status=${revoke.status}`);
        clean = false;
      }
    }
    return clean;
  } catch (error) {
    console.error(`cleanup_failed ${error instanceof Error ? error.message : String(error)}`);
    return false;
  } finally {
    authHeaders = saved;
  }
}

// Earlier dogfood runs that died before cleanup (runner cancelled, job
// timeout). The canary sweeps production smoke users; staging has no sweep.
async function sweepDogfoodLeftovers(app, emailPrefix) {
  const cutoff = Date.now() - 60 * 60_000;
  const swept = { users: 0, kept: 0 };
  for (const leftover of await app.listUsers({ query: emailPrefix, limit: 100 })) {
    if (!leftover.primaryEmail?.startsWith(emailPrefix)) continue;
    if (leftover.signedUpAt.getTime() > cutoff) continue;
    const headers = await sessionHeaders(leftover, 5 * 60 * 1000).catch(() => null);
    if (headers && await emptyAccount(headers)) {
      await leftover.delete();
      swept.users += 1;
    } else {
      swept.kept += 1;
    }
  }
  return swept;
}

let cleanedUp = false;
async function cleanup() {
  if (cleanedUp) return;
  cleanedUp = true;
  for (const child of children) child.kill("SIGKILL");
  // Covers a create that failed or timed out after the provider started a VM.
  const clean = authHeaders ? await emptyAccount(authHeaders) : true;
  if (user && clean) await user.delete().catch((error) => console.error(`cleanup_delete_user_failed ${error.message}`));
  else if (user) console.error(`cleanup_kept_user_for_sweep=${user.id}`);
  rmSync(scratch, { recursive: true, force: true });
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    console.error(`received ${signal}; cleaning up`);
    cleanup().finally(() => process.exit(130));
  });
}

// The whole journey must end well inside the workflow's job timeout, so the
// cleanup always gets to run.
const DEADLINE_MS = 25 * 60 * 1000;
const deadline = setTimeout(() => {
  console.error(`journey exceeded ${DEADLINE_MS}ms at stage ${stage}; cleaning up`);
  const output = summary({ ok: false, stage, error: `deadline exceeded during ${stage}` });
  console.log(JSON.stringify(output, null, 2));
  if (resultFile) writeFileSync(resultFile, `${JSON.stringify(output)}\n`);
  cleanup().finally(() => process.exit(1));
}, DEADLINE_MS);

function summary(outcome) {
  return {
    ...outcome,
    ...(outcome.error ? { error: outcome.error.replace(/\s+/g, " ").slice(0, 600) } : {}),
    target,
    url: targetUrl,
    durationMs: Math.round(performance.now() - runStartedAt),
    timings,
    notes,
  };
}

let hub;
let link;
const result = {};
try {
  const env = loadTargetEnv(project);
  requireEnvKeys(env, [
    "NEXT_PUBLIC_STACK_PROJECT_ID",
    "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
    "STACK_SECRET_SERVER_KEY",
  ], `${project.projectName} dogfood`);
  const app = new StackServerApp({
    projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
    publishableClientKey: env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
    secretServerKey: env.STACK_SECRET_SERVER_KEY,
  });
  const version = await runTui(["--version"]);
  result.clientVersion = version.stdout.trim();

  const emailPrefix = `cmux-${project.stackLabel}-smoke+dogfood-`;
  result.swept = await sweepDogfoodLeftovers(app, emailPrefix);
  const suffix = `${Date.now()}-${randomBytes(3).toString("hex")}`;
  await timed("signIn", async () => {
    // The smoke prefix keeps these users inside the canary's leftover sweep.
    user = await app.createUser({
      primaryEmail: `${emailPrefix}${suffix}@manaflow.dev`,
      primaryEmailVerified: true,
      primaryEmailAuthEnabled: true,
      password: randomBytes(24).toString("base64url"),
      displayName: "cmux dogfood",
    });
    await user.update({ clientReadOnlyMetadata: { cmuxVmPlan: "pro" } });
    authHeaders = await sessionHeaders(user, 45 * 60 * 1000);
  });

  const displayName = `dogfood ${suffix.slice(-6)}`;
  const created = await timed("create", async () => expectStatus(await api("POST", "/api/vm", {
    ...(provider === "default" ? {} : { provider }),
    displayName,
  }, 5 * 60 * 1000), [200], "POST /api/vm"));
  vmId = created.id;
  result.vm = {
    provider: created.provider,
    imageVersion: created.imageVersion,
    cmuxTuiContract: created.cmuxTuiContract ?? null,
    displayName: created.displayName ?? null,
    hasAddress: Boolean(privateRoute(created)),
    createdBy: created.createdBy ?? created.creator ?? created.userId ?? null,
    createdAt: created.createdAt ?? null,
  };
  if (created.displayName !== displayName) note(`create response displayName is ${JSON.stringify(created.displayName)}, asked for ${JSON.stringify(displayName)}`);
  if (!privateRoute(created)) note("create response has no private address; the app must re-list before its first link");

  const listed = await timed("list", async () => {
    const list = expectStatus(await api("GET", "/api/vm"), [200], "GET /api/vm");
    return (list.vms ?? []).find((vm) => vm.id === vmId);
  });
  if (!listed) throw new Error("the new VM is missing from GET /api/vm");
  result.listedFields = Object.keys(listed).sort();
  const route = privateRoute(listed) ?? privateRoute(created);
  if (!route) throw new Error("the VM has no private address in create or list");

  const keys = wireGuardKeypair();
  deviceId = `dogfood-${suffix}`;
  const tunnel = await timed("tunnel", async () => expectStatus(await api("POST", "/api/vm/tunnel", {
    clientPublicKey: keys.publicKey,
    deviceId,
    deviceFingerprint: deviceId,
    tunnelPurpose: "terminal",
    deviceName: "cmux dogfood (CI)",
    architecture: process.arch,
    cmuxChannel: "dogfood",
  }), [200], "POST /api/vm/tunnel"));
  const allowed = (tunnel.networks ?? []).flatMap((network) => [network.cidr, network.cidrV6])
    .concat([tunnel.network?.cidr, tunnel.network?.cidrV6])
    .filter((value, index, all) => value && all.indexOf(value) === index);
  const configPath = path.join(scratch, "wg", "cmux.conf");
  rmSync(path.dirname(configPath), { recursive: true, force: true });
  mkdirSync(path.dirname(configPath), { recursive: true, mode: 0o700 });
  writeFileSync(configPath, completedConfig(tunnel.clientConfig, keys.privateKey, allowed), { mode: 0o600 });
  const hubSocket = path.join(scratch, "hub", "hub.sock");

  // A freshly enrolled peer can take a moment to reach the provider, and the
  // hub gives its first handshake about 10 s.
  await timed("hub", async () => {
    for (let attempt = 1; ; attempt += 1) {
      hub = startJsonProcess("wg hub", ["wg", "hub", "--config", configPath, "--socket", hubSocket]);
      try {
        await hub.waitFor((event) => event.event === "hub-ready", 30_000, "hub-ready");
        if (attempt > 1) note(`wg hub became ready on attempt ${attempt}`);
        return;
      } catch (error) {
        await hub.stop("SIGKILL");
        if (attempt >= 3) throw error;
        await sleep(3000);
      }
    }
  });

  // The app asks once so an older daemon is brought to the trusted build; a
  // fresh image already serves the trusted listener.
  const attach = await timed("attach", async () => {
    const startedAt = performance.now();
    for (;;) {
      const response = await api("POST", `/api/vm/${encodeURIComponent(vmId)}/attach-endpoint`, {
        transport: "cmux-remote",
        clientCapabilities: ["wireguard-hub"],
      });
      if (response.status === 200 && response.json?.trustedCarrier) return response.json;
      const retryable = response.status === 502 && response.json?.retryable === true;
      if (response.status === 200) note("attach-endpoint answered without trustedCarrier; retrying like the app would");
      if ((!retryable && response.status !== 200) || performance.now() - startedAt > 180_000) {
        // The 200 body carries the route token; never put it in a public log.
        const { error, message, code } = response.json ?? {};
        throw new Error(`attach-endpoint ${response.status}: ${JSON.stringify({ error, message, code, trustedCarrier: response.json?.trustedCarrier })}`);
      }
      await sleep(Math.max(1, response.json?.retryAfterSeconds ?? 2) * 1000);
    }
  });
  const session = attach.session ?? "cmux";

  const connected = await timed("connect", async () => {
    link = startJsonProcess("remote connect", connectArgv(route, session, hubSocket));
    return link.waitFor(isConnected, 90_000, "connected snapshot");
  });
  const localSocket = connected.local_socket;
  result.transportPath = connected.connection?.transport?.selected_path?.kind ?? null;

  // The shell computes the suffix, so the echoed command line never matches.
  const marker = `dogfood-${randomBytes(4).toString("hex")}`;
  const typeLine = async (terminal, line) => {
    const write = await runTui(["--socket", localSocket, "terminal", terminal, "write", "--text", `${line}\n`]);
    if (write.code !== 0) throw new Error(`terminal write failed (${write.code}): ${write.stderr.slice(-400)}`);
  };
  const terminal = await timed("firstPrompt", async () => {
    const id = await ensureTerminal(localSocket);
    await typeLine(id, `echo ${marker}-$((1+1))`);
    await waitForScreen(localSocket, id, `${marker}-2`, 60_000);
    return id;
  });
  await saveScreen(localSocket, terminal, "01-first-prompt");

  result.agents = await timed("agents", async () => {
    const response = await api("POST", `/api/vm/${encodeURIComponent(vmId)}/exec`, {
      command: "export HOME=/root; for f in /etc/profile.d/*.sh; do [ -r \"$f\" ] && . \"$f\"; done; for c in claude codex cr cmux; do printf '%s ' \"$c\"; ($c --version 2>/dev/null || echo missing) | head -1; done",
      timeoutMs: 60_000,
    }, 90_000);
    const output = expectStatus(response, [200], "POST exec").stdout ?? "";
    return Object.fromEntries(output.trim().split("\n").map((line) => {
      const [name, ...value] = line.split(" ");
      return [name, value.join(" ").trim()];
    }));
  });
  for (const [name, value] of Object.entries(result.agents)) {
    if (value === "missing") note(`${name} is not on PATH in the VM`);
  }

  if (!skipSleep) {
    const beforePause = link.mark();
    await timed("pause", async () => {
      expectStatus(await api("POST", `/api/vm/${encodeURIComponent(vmId)}/pause`, {}, 3 * 60 * 1000), [200, 202], "pause");
    });
    // Is the machine asleep? Whether the terminal still runs commands within
    // 5 s of pause returning, and what the control plane says.
    const liveDeadline = Date.now() + 5_000;
    await typeLine(terminal, `echo ${marker}-$((2+2))`).catch((error) => note(`terminal write while paused failed: ${error.message.slice(0, 120)}`));
    const liveWindowMs = liveDeadline - Date.now();
    if (liveWindowMs <= 0) note("terminal write while paused took over 5 s");
    result.terminalLiveWhilePaused = liveWindowMs > 0
      && await waitForScreen(localSocket, terminal, `${marker}-4`, liveWindowMs).then(() => true, () => false);
    const shown = await api("GET", `/api/vm/${encodeURIComponent(vmId)}`)
      .catch((error) => ({ status: 0, json: null, text: error.message }));
    result.statusAfterPause = shown.json?.status ?? `http ${shown.status}`;
    if (result.terminalLiveWhilePaused) note("the terminal still ran a command after pause returned");
    // How the headless client reports a sleeping machine.
    const lostAfter = await link.waitFor((event) => event.event === "connection-snapshot" && event.connection?.state !== "connected", 60_000, "non-connected snapshot after pause", beforePause)
      .then((event) => event.connection.state)
      .catch((error) => { note(`client did not notice the pause within 60s (${error.message.slice(0, 120)})`); return null; });
    result.clientStateWhileAsleep = lostAfter;
    const beforeResume = link.mark();
    await timed("resume", async () => {
      expectStatus(await api("POST", `/api/vm/${encodeURIComponent(vmId)}/resume`, {}, 5 * 60 * 1000), [200], "resume");
    });
    // The client may have reconnected before /resume answered; that counts.
    await timed("reconnectAfterResume", async () => {
      if (lostAfter === null) return;
      await link.waitFor(isConnected, 120_000, "connected snapshot after resume", beforeResume);
    });
    await timed("terminalAfterResume", async () => {
      await waitForScreen(localSocket, terminal, `${marker}-2`, 30_000);
      await typeLine(terminal, `echo ${marker}-$((1+2))`);
      await waitForScreen(localSocket, terminal, `${marker}-3`, 30_000);
    });
    // Was the line typed while paused kept and run after waking, or lost?
    if (!result.terminalLiveWhilePaused) {
      result.pausedKeystrokesRanAfterResume = await waitForScreen(localSocket, terminal, `${marker}-4`, 1_000)
        .then(() => true, () => false);
    }
    await saveScreen(localSocket, terminal, "02-after-resume");
  }

  // A crash or relaunch: the client dies without saying goodbye, then a new
  // one dials the same machine with no control-plane call.
  await link.stop("SIGKILL");
  const relaunched = await timed("relaunchReconnect", async () => {
    link = startJsonProcess("remote connect (relaunch)", connectArgv(route, session, hubSocket));
    return link.waitFor(isConnected, 90_000, "connected snapshot after relaunch");
  });
  await timed("restoredTerminal", async () => {
    await waitForScreen(relaunched.local_socket, terminal, `${marker}-2`, 30_000);
  });
  await saveScreen(relaunched.local_socket, terminal, "03-after-relaunch");

  await link.stop();
  await hub.stop();
  await timed("delete", async () => {
    expectStatus(await api("DELETE", `/api/vm/${encodeURIComponent(vmId)}`), [200], "DELETE");
  });
  const deletedId = vmId;
  vmId = undefined;
  await timed("goneFromList", async () => {
    const list = expectStatus(await api("GET", "/api/vm"), [200], "GET /api/vm");
    const still = (list.vms ?? []).find((vm) => vm.id === deletedId);
    if (still) note(`deleted VM still listed with status ${still.status}`);
  });

  const output = summary({ ok: true, ...result });
  console.log(JSON.stringify(output, null, 2));
  if (resultFile) writeFileSync(resultFile, `${JSON.stringify(output)}\n`);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  const output = summary({ ok: false, stage, error: message, ...result });
  console.log(JSON.stringify(output, null, 2));
  if (resultFile) writeFileSync(resultFile, `${JSON.stringify(output)}\n`);
  process.exitCode = 1;
} finally {
  clearTimeout(deadline);
  await cleanup();
}
