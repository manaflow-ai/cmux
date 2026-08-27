#!/usr/bin/env bun
// Live E2E proof for the Blaxel Cloud VM driver, run directly against the driver (no HTTP
// route, no Postgres): create a sandbox, let the driver install and start the cmux-tui
// remote daemon, mint the cmux-remote attach endpoint (route + enrollment invitation),
// verify the daemon answers on that route, check the smart-sleep watcher, then destroy
// the sandbox. The Noise handshake itself needs a cmux-tui client and is covered by
// `cmux vm tui <id>` from the Mac.
//
// Usage:
//   set -a; source ~/.secrets/cmux.env; set +a   # BL_API_KEY, BL_WORKSPACE
//   bun scripts/test-blaxel-vm-poc.ts [--keep]
import { BlaxelProvider } from "../services/vms/drivers/blaxel";
import { resolveVmImage } from "../services/vms/images/resolver";

const keep = process.argv.includes("--keep");

function log(step: string, detail?: unknown) {
  console.log(`[blaxel-poc] ${step}${detail === undefined ? "" : ` ${JSON.stringify(detail)}`}`);
}

// The daemon route is a tokenized WebSocket URL. Dialing it without a Noise handshake
// proves the ingress + daemon are up (the upgrade completes) without enrolling a device.
async function probeRoute(route: string): Promise<{ opened: boolean; detail: string }> {
  return new Promise((resolve) => {
    const ws = new WebSocket(route);
    const timer = setTimeout(() => {
      ws.close();
      resolve({ opened: false, detail: "timeout" });
    }, 15_000);
    ws.onopen = () => {
      clearTimeout(timer);
      ws.close();
      resolve({ opened: true, detail: "upgrade completed" });
    };
    ws.onerror = (event) => {
      clearTimeout(timer);
      resolve({ opened: false, detail: String((event as { message?: string }).message ?? "error") });
    };
  });
}

const provider = new BlaxelProvider();
const image = resolveVmImage("blaxel", process.env.BLAXEL_SANDBOX_IMAGE, process.env).image;

log("create", { image });
const t0 = Date.now();
const handle = await provider.create({ image });
log("created", { vmId: handle.providerVmId, ms: Date.now() - t0, previewUrl: handle.providerMetadata?.previewUrl });

let failed = false;
try {
  const execResult = await provider.exec(handle.providerVmId, "uname -sm && whoami && cmux-tui --version");
  log("exec", execResult);
  if (execResult.exitCode !== 0) throw new Error("exec failed (cmux-tui missing?)");

  // The legacy attach must be refused: the driver serves cmux-remote only.
  let legacyRefused = false;
  try {
    await provider.openAttach(handle.providerVmId, { requireDaemon: true });
  } catch (err) {
    legacyRefused = /cmux-remote/.test(err instanceof Error ? err.message : String(err));
  }
  log("legacy-attach-refused", { pass: legacyRefused });
  if (!legacyRefused) throw new Error("openAttach must be refused on Blaxel (cmux-tui only)");

  const t1 = Date.now();
  const endpoint = await provider.openCmuxRemote(handle.providerVmId, {
    deviceFingerprint: "poc-device",
    providerMetadata: handle.providerMetadata,
  });
  log("cmux-remote-endpoint", {
    route: endpoint.route.replace(/bl_preview_token=[^&]+/, "bl_preview_token=<redacted>"),
    session: endpoint.session,
    invited: !!endpoint.invitation,
    daemonBuild: endpoint.daemonBuild ?? null,
    ms: Date.now() - t1,
  });
  if (endpoint.transport !== "cmux-remote") throw new Error("expected a cmux-remote endpoint");
  if (!endpoint.invitation) throw new Error("a never-enrolled device must receive an enrollment invitation");

  const probe = await probeRoute(endpoint.route);
  log("route-probe", probe);
  if (!probe.opened) throw new Error(`daemon route did not accept a WebSocket upgrade: ${probe.detail}`);

  const pending = await provider.approveCmuxRemoteEnrollment(handle.providerVmId, endpoint.invitation.invitationId);
  log("approve-unclaimed-invitation", pending);
  if (pending.state !== "pending") throw new Error("an unclaimed invitation must report pending, not approve");

  const status = await provider.getStatus(handle.providerVmId);
  log("status", { status });

  // Smart sleep: the watcher must be the keepAlive process and the daemon must not be, so an
  // idle sandbox can freeze to $0 while a busy one keeps running with the laptop closed.
  const watcherCheck = await provider.exec(
    handle.providerVmId,
    "pgrep -f cmux-smart-sleep >/dev/null && echo watcher-running; pgrep -x cmuxd-remote >/dev/null && echo cmuxd-present",
  );
  log("smart-sleep-watcher", { pass: watcherCheck.stdout.includes("watcher-running") });
  if (!watcherCheck.stdout.includes("watcher-running")) {
    throw new Error("smart-sleep watcher is not running after create");
  }
  if (watcherCheck.stdout.includes("cmuxd-present")) {
    throw new Error("cmuxd-remote must not run on a cmux-tui-only machine");
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
