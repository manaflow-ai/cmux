#!/usr/bin/env bun
// Live E2E proof for the Blaxel Cloud VM driver, run directly against the driver (no HTTP
// route, no Postgres): create a sandbox, bootstrap cmuxd-remote, attach the WebSocket PTY
// with a single-use lease, run a shell round trip, verify the lease is consumed on replay,
// then destroy the sandbox.
//
// Usage:
//   set -a; source ~/.secrets/blaxel.env; set +a   # BL_API_KEY, BL_WORKSPACE
//   export CMUX_VM_BLAXEL_DAEMON_PATH=/path/to/cmuxd-remote-linux-amd64
//   bun scripts/test-blaxel-vm-poc.ts [--keep]
import { BlaxelProvider } from "../services/vms/drivers/blaxel";
import { resolveVmImage } from "../services/vms/images/resolver";

const keep = process.argv.includes("--keep");

function log(step: string, detail?: unknown) {
  console.log(`[blaxel-poc] ${step}${detail === undefined ? "" : ` ${JSON.stringify(detail)}`}`);
}

async function attachOnce(
  url: string,
  headers: Record<string, string>,
  token: string,
  sessionId: string,
  command: string,
  expect: string,
): Promise<{ ready: boolean; output: string }> {
  // Browser-style WebSocket can't set headers, so pass the preview token the query-param way
  // Blaxel also supports. The Mac client uses the returned headers instead.
  const previewToken = headers["X-Blaxel-Preview-Token"] ?? "";
  const ws = new WebSocket(`${url}?bl_preview_token=${encodeURIComponent(previewToken)}`);
  let ready = false;
  let output = "";
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.close();
      resolve();
    }, 15_000);
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: "auth", token, session_id: sessionId, cols: 100, rows: 30 }));
    };
    ws.onmessage = (event) => {
      const data = event.data;
      if (typeof data === "string") {
        const frame = JSON.parse(data) as { type?: string };
        if (frame.type === "ready") {
          ready = true;
          ws.send(new TextEncoder().encode(`${command}\n`));
        }
        return;
      }
      output += new TextDecoder().decode(data as ArrayBuffer | Uint8Array);
      if (output.includes(expect)) {
        clearTimeout(timer);
        ws.close();
        resolve();
      }
    };
    ws.onerror = () => {
      clearTimeout(timer);
      resolve();
    };
    ws.onclose = () => {
      clearTimeout(timer);
      resolve();
    };
    void reject;
  });
  return { ready, output };
}

const provider = new BlaxelProvider();
const image = resolveVmImage("blaxel", process.env.BLAXEL_SANDBOX_IMAGE, process.env).image;

log("create", { image });
const t0 = Date.now();
const handle = await provider.create({ image });
log("created", { vmId: handle.providerVmId, ms: Date.now() - t0 });

let failed = false;
try {
  const execResult = await provider.exec(handle.providerVmId, "uname -sm && whoami");
  log("exec", execResult);
  if (execResult.exitCode !== 0) throw new Error("exec failed");

  const t1 = Date.now();
  const endpoint = await provider.openAttach(handle.providerVmId, { requireDaemon: true });
  if (endpoint.transport !== "websocket") throw new Error("expected websocket endpoint");
  log("attach-endpoint", { url: endpoint.url, ms: Date.now() - t1, daemon: !!endpoint.daemon });

  const marker = `cmux-blaxel-poc-${Math.floor(Math.random() * 1e6)}`;
  const attach = await attachOnce(
    endpoint.url,
    endpoint.headers,
    endpoint.token,
    endpoint.sessionId,
    `echo ${marker} $((6*7))`,
    `${marker} 42`,
  );
  log("pty-round-trip", { ready: attach.ready, pass: attach.output.includes(`${marker} 42`) });
  if (!attach.ready || !attach.output.includes(`${marker} 42`)) {
    throw new Error(`PTY round trip failed; output tail: ${attach.output.slice(-300)}`);
  }

  // Single-use lease: a replay with the same token must be rejected before a PTY starts.
  const replay = await attachOnce(
    endpoint.url,
    endpoint.headers,
    endpoint.token,
    endpoint.sessionId,
    "echo should-not-run",
    "should-not-run",
  );
  log("single-use-replay-rejected", { pass: !replay.ready });
  if (replay.ready) throw new Error("replayed single-use lease was accepted");

  const status = await provider.getStatus(handle.providerVmId);
  log("status", { status });

  // Smart sleep: the watcher must be the keepAlive process and the daemon must not be, so an
  // idle sandbox can freeze to $0 while a busy one keeps running with the laptop closed.
  const watcherCheck = await provider.exec(
    handle.providerVmId,
    "pgrep -f cmux-smart-sleep >/dev/null && echo watcher-running",
  );
  log("smart-sleep-watcher", { pass: watcherCheck.stdout.includes("watcher-running") });
  if (!watcherCheck.stdout.includes("watcher-running")) {
    throw new Error("smart-sleep watcher is not running after create");
  }
} catch (err) {
  failed = true;
  console.error("[blaxel-poc] FAIL:", err);
} finally {
  if (keep) {
    log("keeping sandbox for manual inspection", { vmId: handle.providerVmId });
  } else {
    await provider.destroy(handle.providerVmId);
    log("destroyed", { vmId: handle.providerVmId });
  }
}

if (failed) process.exit(1);
log("PASS");
