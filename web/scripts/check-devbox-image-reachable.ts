#!/usr/bin/env bun
/**
 * Boots the image the manifest currently ships and proves a client can reach
 * the cmux-tui daemon inside it.
 *
 * The bake already smokes the daemon, but that only covers the moment an image
 * was made. This covers the image we are shipping right now, against the
 * cmux-tui build we are shipping right now, which is the pair that can drift
 * apart without anyone touching either: the manifest pins a snapshot with a
 * baked daemon, while files.cmux.com moves to a new client with every release.
 *
 * The check is a real round trip, not a port probe: enroll a device, connect
 * over `ws://[::1]:1337/v1/link`, open a workspace, run a process, read its
 * output back. When the live client differs from the baked one, the whole
 * round trip runs a second time with the live binary, so a protocol change
 * that would break a freshly built app fails here instead of in production.
 *
 * Usage:
 *   FREESTYLE_API_KEY=... bun scripts/check-devbox-image-reachable.ts [--image <id>]
 *                          [--kind base|desktop] [--size sm] [--keep]
 *   bun scripts/check-devbox-image-reachable.ts --print-key   # no VM, no key
 *
 * `--print-key` prints the identity of what would be tested (image ids plus
 * the live cmux-tui pin) so CI can skip a run that would test nothing new.
 */
import { Freestyle, type FirewallSpec } from "freestyle";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { cmuxTuiWebsocketSmokeCommand, devboxWaitForDaemonCommand, readImageManifest } from "./devbox-image-common";
import { resolveCmuxTuiSource } from "../services/vms/drivers/cmuxTuiDaemon";
import { cleanupOnSignal, throwawayVmOptions } from "./cloud-vm/ci-leftovers";

const argValue = (name: string): string | undefined => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
};
const hasFlag = (name: string): boolean => process.argv.includes(name);

/**
 * What a run would actually test: every default image plus the client build.
 * CI skips a run whose key it has already seen pass, so the daily schedule
 * costs nothing on a day when neither the manifest nor the client moved.
 */
export function reachabilityKey(
  defaults: readonly { version: string; imageId: string }[],
  clientSha256: string,
): string {
  const identity = [...defaults.map((entry) => `${entry.version}=${entry.imageId}`).sort(), `client=${clientSha256}`];
  return createHash("sha256").update(identity.join("\n")).digest("hex");
}

/**
 * A failure that is the provider's, not the image's: no answer about this
 * image or client came back, so asking again on a fresh machine is the honest
 * retry. Main's red runs (11-27, 11-28) were all of this kind:
 * - 429 INFRASTRUCTURE_OVERLOADED: "VM start capacity queue wait expired"
 *   (run 45958065472), no machine started.
 * - 404 BACKGROUND_REQUEST_NOT_FOUND: the create's result expired before the
 *   SDK read it (run 46120812088, 44 min in). A machine may exist; it carries
 *   this run's tag and a TTL, and the workflow's always() step deletes it.
 * - 409 VM_NON_RESPONSIVE, or a TimeoutError ("The operation timed out.",
 *   run 45972063920): the guest stopped answering its agent mid-check.
 * Anything else, a daemon that answers wrong or a client that cannot complete
 * the round trip, is a real red and is never retried.
 */
export function isProviderFault(error: unknown): boolean {
  const e = error as { name?: unknown; status?: unknown; code?: unknown } | null;
  if (!e || typeof e !== "object") return false;
  if (e.name === "TimeoutError") return true;
  return (
    (e.status === 429 && e.code === "INFRASTRUCTURE_OVERLOADED") ||
    (e.status === 404 && e.code === "BACKGROUND_REQUEST_NOT_FOUND") ||
    (e.status === 409 && e.code === "VM_NON_RESPONSIVE")
  );
}

/** Machines one run may ask for before a provider fault is reported as the red. */
export const REACHABILITY_MACHINE_ATTEMPTS = 3;

/**
 * Run `attempt` (one machine: start, check, delete) until it passes, fails for
 * a reason of its own, or provider faults use up `attempts` machines. The wait
 * between machines doubles from `firstWaitMs`.
 */
export async function onFreshMachines<T>(
  attempt: (n: number) => Promise<T>,
  attempts = REACHABILITY_MACHINE_ATTEMPTS,
  firstWaitMs = 30_000,
  sleep: (ms: number) => Promise<void> = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
): Promise<T> {
  for (let n = 1, waitMs = firstWaitMs; ; n += 1, waitMs *= 2) {
    try {
      return await attempt(n);
    } catch (error) {
      if (!isProviderFault(error) || n >= attempts) throw error;
      const e = error as { name?: unknown; status?: unknown; code?: unknown; message?: unknown };
      console.log(
        `provider fault on machine ${n} of ${attempts} (${String(e.status ?? e.name)} ${String(e.code ?? "")}: ${String(e.message)}); ` +
          `fresh machine in ${waitMs / 1000}s`,
      );
      await sleep(waitMs);
    }
  }
}

async function main(): Promise<void> {
  const kind = argValue("--kind") ?? "base";
  const size = argValue("--size") ?? "sm";
  const manifest = readImageManifest();
  const defaults = manifest.images.filter((entry) => entry.defaultForKind);
  const target =
    argValue("--image") ??
    defaults.find((entry) => (entry.kind ?? "base") === kind && entry.size?.name === size)?.imageId;

  // The live client is what a machine created today would be driven by.
  const live = await resolveCmuxTuiSource("freestyle");

  if (hasFlag("--print-key")) {
    console.log(reachabilityKey(defaults, live.sha256));
    process.exit(0);
  }

  if (!target) {
    console.error(`no default ${kind}/${size} image in the manifest to reach`);
    process.exit(1);
  }
  const apiKey = process.env.FREESTYLE_API_KEY;
  if (!apiKey) {
    console.error("FREESTYLE_API_KEY is required to boot the image");
    process.exit(1);
  }

  const fs = new Freestyle({ apiKey });
  const FIREWALL: FirewallSpec = { rules: [{ action: "allow", source: {}, destination: { public: true } }] };
  const t0 = Date.now();
  const elapsed = () => `${((Date.now() - t0) / 1000).toFixed(0)}s`;

  console.log(`reaching ${kind}/${size} ${target} with client ${live.commit.slice(0, 10)} (${live.sha256.slice(0, 12)}…)`);
  let failure: string | null = null;
  const checkOneMachine = async (): Promise<void> => {
    // A throwaway machine: paused when idle, deleted at a deadline, and tagged
    // with the CI run so the workflow's always() step deletes it after a cancel
    // (cloud-vm/ci-leftovers.ts). --keep is for a person debugging by hand.
    const { vm, vmId } = await fs.vms.create({
      snapshotId: target,
      displayName: "cmux devbox reachability",
      firewall: FIREWALL,
      ...(hasFlag("--keep") ? {} : throwawayVmOptions()),
    });
    console.log(`${elapsed()} booted ${vmId}`);
    let deleted = false;
    const deleteVm = async () => {
      if (deleted || hasFlag("--keep")) return;
      deleted = true;
      await vm.delete().catch(() => {});
      console.log(`${elapsed()} deleted ${vmId}`);
    };
    const stopSignalCleanup = cleanupOnSignal(deleteVm);
    try {
      const sh = async (command: string, timeoutMs = 300_000) => {
        const r = await vm.exec({ command, timeoutMs, linuxUser: "root" });
        return { code: r.statusCode ?? 124, out: `${r.stdout ?? ""}${r.stderr ?? ""}`.trim() };
      };

      // A restored systemd unit can be active before its control socket exists,
      // or while it still answers with the source snapshot's machine identity.
      // Use the same readiness invariant as image baking and verification.
      const up = await sh(devboxWaitForDaemonCommand(120), 150_000);
      if (up.code !== 0) throw new Error(`the baked daemon never became ready: ${up.out.slice(-300)}`);
      console.log(`${elapsed()} baked daemon is ready on this machine`);

      const baked = await sh("cut -d' ' -f1 /etc/cmux/cmux-tui-pin", 30_000);
      const bakedSha = baked.out.trim();
      const smoke = await sh(cmuxTuiWebsocketSmokeCommand());
      if (smoke.code !== 0) throw new Error(`baked client could not reach the daemon: ${smoke.out.slice(-1200)}`);
      console.log(`${elapsed()} baked client round trip ok`);

      if (bakedSha === live.sha256) {
        console.log(`${elapsed()} live client is the baked one; nothing further to compare`);
      } else {
        // A client newer than the image is the normal state between bakes, and it
        // is the pair production actually runs, so it must complete the same trip.
        // exec runs /bin/sh (dash), so the pipefail-using script needs a bash -c.
        const install =
          `bash -c ${JSON.stringify(
            `set -euo pipefail; curl -fsSL --retry 3 --retry-delay 2 -o /tmp/cmux-tui-live ${live.url}; ` +
              `printf '%s  %s\n' ${live.sha256} /tmp/cmux-tui-live | sha256sum -c >/dev/null; chmod 0755 /tmp/cmux-tui-live`,
          )}`;
        const fetched = await sh(install, 180_000);
        if (fetched.code !== 0) throw new Error(`could not install the live client in the guest: ${fetched.out.slice(-500)}`);
        const liveSmoke = await sh(cmuxTuiWebsocketSmokeCommand("cloud", "/tmp/cmux-tui-live"));
        if (liveSmoke.code !== 0) {
          throw new Error(
            `live client ${live.commit.slice(0, 10)} could not reach the daemon baked from ${bakedSha.slice(0, 12)}…: ` +
              `${liveSmoke.out.slice(-1200)}`,
          );
        }
        console.log(`${elapsed()} live client round trip ok against the baked daemon`);
      }
    } finally {
      stopSignalCleanup();
      if (hasFlag("--keep")) {
        console.log(`${elapsed()} keeping ${vmId} (--keep)`);
      } else {
        await deleteVm();
      }
    }
  };
  try {
    await onFreshMachines(checkOneMachine);
  } catch (error) {
    failure = error instanceof Error ? error.message : String(error);
    if (isProviderFault(error)) failure = `the provider failed ${REACHABILITY_MACHINE_ATTEMPTS} machines, no answer about the image: ${failure}`;
  }

  if (failure) {
    console.error(`UNREACHABLE: ${failure}`);
    process.exit(1);
  }
  console.log(`REACHABLE ${kind}/${size} ${target} in ${elapsed()}`);
}

// Bun-only `import.meta.main` is not in TypeScript's ImportMeta type; use the
// portable entry-point check the sibling devbox scripts already rely on.
const isEntryPoint =
  process.argv[1] !== undefined &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntryPoint) await main();
