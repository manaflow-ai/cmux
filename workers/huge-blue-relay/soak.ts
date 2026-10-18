import assert from "node:assert/strict";
import { readFileSync, mkdirSync } from "node:fs";
import { randomUUID } from "node:crypto";

const api = process.env.CMUX_SOAK_API ?? "http://127.0.0.1:1340";
const auth = readFileSync(process.env.CMUX_SOAK_TOKEN_FILE!, "utf8").trim();
const bin = process.env.CMUX_SOAK_BIN ?? "/home/leo/.local/bin/cmux-tui";
const root = process.env.CMUX_SOAK_STATE!;
if (!root) throw new Error("isolated soak state path required");
mkdirSync(root, { recursive: true, mode: 0o700 });
const runId = randomUUID();
const events: Record<string, unknown>[] = [];
function receipt(step: string, values: Record<string, unknown> = {}) {
  const event = { step, ...values, at: new Date().toISOString() };
  events.push(event); console.log(JSON.stringify(event));
}
async function request(path: string, body?: unknown, expected = 200, key?: string) {
  const response = await fetch(api + path, { method: body ? "POST" : "GET", headers: {
    authorization: `Bearer ${auth}`, "content-type": "application/json", ...(key ? { "idempotency-key": key } : {}),
  }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(30_000) });
  const data = await response.json();
  assert.equal(response.status, expected, `HTTP ${path} failed: ${JSON.stringify(data)}`);
  assert.equal(response.headers.get("cache-control"), "no-store");
  return data as any;
}
async function denied(route: string) {
  const response = await fetch(route.replace(/^wss:/, "https:"), { signal: AbortSignal.timeout(10_000) });
  assert.equal(response.status, 401);
}
async function connect(endpoint: any, state: string) {
  const child = Bun.spawn([bin, "remote", "connect", endpoint.route, "--carrier", "--session", endpoint.session,
    "--headless", "--json", "--connect-timeout-seconds", "12", "--reconnect-attempts", "1", "--reconnect-initial-ms", "100",
    "--reconnect-max-ms", "500", "--heartbeat-interval-ms", "1000", "--heartbeat-timeout-ms", "2000", "--state-dir", state],
    { stdout: "pipe", stderr: "pipe" });
  const ready = (async () => {
    const reader = child.stdout.getReader(); let pending = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) throw new Error("native client ended before connected");
      pending += new TextDecoder().decode(value);
      let index: number;
      while ((index = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, index); pending = pending.slice(index + 1);
        const event = JSON.parse(line);
        if (event.connection?.state === "connected") return { socket: event.local_socket as string, sessionId: event.connection.session_id as string };
      }
    }
  })();
  let timer: ReturnType<typeof setTimeout>;
  try {
    const readyResult = await Promise.race([ready, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("native attach deadline")), 15_000); })]);
    receipt("native_connected", { sessionId: readyResult.sessionId });
    return { child, ...readyResult };
  } catch (error) { child.kill("SIGKILL"); throw error; }
  finally { clearTimeout(timer!); }
}
async function rpc(socket: string, args: string[]) {
  const child = Bun.spawn([bin, "--socket", socket, "--json", ...args], { stdout: "pipe", stderr: "pipe" });
  const output = await new Response(child.stdout).text();
  assert.equal(await child.exited, 0, `native RPC failed: ${args.slice(0, 2).join(" ")}`);
  const result = JSON.parse(output); return result.value ?? result;
}
async function discard(child: ReturnType<typeof Bun.spawn>) { child.kill("SIGKILL"); await child.exited; }

try {
  assert.equal((await fetch(api + "/api/workspaces")).status, 401);
  await request("/api/workspaces", { name: "missing idempotency" }, 400);
  for (let cycle = 0; cycle < Number(process.env.CMUX_SOAK_CYCLES ?? 3); cycle++) {
    const key = `${runId}:${cycle}`;
    const body = { name: `relay-soak-${cycle}` };
    const first = await request("/api/workspaces", body, 201, key);
    const replay = await request("/api/workspaces", body, 201, key);
    assert.equal(first.runtimeId, replay.runtimeId);
    assert.equal(first.provider, "huge-blue");
    assert(!JSON.stringify(first).includes("hba_"));
    const path = `/api/workspaces/${first.runtimeId}`;
    receipt("create_replay", { cycle, runtimeId: first.runtimeId });
    const attach = (await request(path, { action: "attach" })).target;
    const client = await connect(attach, `${root}/${cycle}`);
    const marker = `relay-soak-${runId}-${cycle}`;
    const terminal = await rpc(client.socket, ["workspace", attach.providerWorkspaceId, "run", "--on-exit", "keep", "--", "/bin/sh", "-c", `printf '${marker}'; hostname`]);
    const terminalId = String(terminal.terminal_id ?? terminal.terminal?.id ?? terminal.terminalId);
    await rpc(client.socket, ["terminal", terminalId, "process", "wait", "--timeout-ms", "10000"]);
    await discard(client.child);
    const reconnect = await connect(attach, `${root}/${cycle}`);
    const output = await rpc(reconnect.socket, ["terminal", terminalId, "output", "read", "--after", "0"]);
    assert(String(output.text).includes(marker));
    assert(String(output.text).includes("huge-blue"));
    receipt("crash_reconnect_output", { cycle, terminalId });
    const rotated = (await request(path, { action: "rotate" })).target;
    assert.notEqual(rotated.token, attach.token);
    await denied(attach.route);
    await discard(reconnect.child);
    const rotatedClient = await connect(rotated, `${root}/${cycle}`);
    await request(path, { action: "suspend" });
    await denied(rotated.route);
    await discard(rotatedClient.child);
    await request(path, { action: "attach" }, 409);
    await request(path, { action: "resume" });
    await denied(rotated.route);
    const resumed = (await request(path, { action: "attach" })).target;
    const resumedClient = await connect(resumed, `${root}/${cycle}`);
    await discard(resumedClient.child);
    receipt("rotation_suspend_resume", { cycle });
    // Wait for the exact endpoint expiry, then prove the relay rejects it.
    const remaining = resumed.expiresAtUnix * 1000 - Date.now() + 1_500;
    if (remaining > 0) await Bun.sleep(remaining);
    await denied(resumed.route);
    receipt("token_expired", { cycle });
    const fresh = (await request(path, { action: "attach" })).target;
    const final = await connect(fresh, `${root}/${cycle}`);
    await rpc(final.socket, ["workspace", fresh.providerWorkspaceId, "close"]);
    await discard(final.child);
    const stopped = await request(path, { action: "stop" });
    assert.equal(stopped.lifecycle, "stopped");
    await denied(fresh.route);
    await request(path, { action: "attach" }, 409);
    const stoppedAgain = await request(path, { action: "stop" });
    assert.equal(stoppedAgain.runtimeId, first.runtimeId);
    receipt("stopped_cleaned", { cycle });
  }
  receipt("soak_passed", { runId, cycles: Number(process.env.CMUX_SOAK_CYCLES ?? 3), sha: process.env.CMUX_SOURCE_SHA });
} catch (error) {
  // Error text may contain endpoint URLs from native libraries; never emit it.
  receipt("soak_failed", { runId, error: error instanceof Error ? error.name : "unknown" });
  throw error;
}
