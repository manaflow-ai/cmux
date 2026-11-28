/**
 * The SBOM and file manifest of a layered bake's image, taken off the per-commit critical path
 * (bake.ts --defer-inventory). The bake snapshots, leaves its builder running and records it as
 * `inventoryVmId` in bake-<name>.json; this reads the builder's tree (the snapshot's: nothing ran on it
 * since), downloads both files into the out dir, merges them into that bake json (the image record the
 * candidate step reads) and deletes the builder. The workflow runs it beside the smoke.
 *
 * Usage (from web/): bun ../images/cmux-vm/inventory.ts --out-dir <dir> [--lock <path>]
 */
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { collectInventory } from "./bake";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run, StepLog, type Vm, wakeVm } from "./guest";
import { SELF_UPDATE_OFF } from "./host-agent";
import { guestShape, type GuestShape } from "./large-image";
import { DEFAULT_LOCK_PATH, readInputsLock } from "./lock";

/** Tries of the whole collect: a connection the provider cut (run 42410303540: ECONNRESET on the file manifest's
 * exec after 49 s) or a call that timed out is retried, a step that ran and failed (StepLog's "step X failed") is not. */
export const INVENTORY_TRIES = 3;

export function retriesInventory(error: unknown, attempt: number): boolean {
  if (attempt >= INVENTORY_TRIES) return false;
  const text = String(error);
  if (/\bstep \S+ failed\b/.test(text)) return false;
  // freestyle's FreestyleApiError carries the HTTP status apart from its prose message (cleanup.ts notFound).
  const status = (error as { status?: unknown } | null)?.status;
  if (status === 502 || status === 503 || status === 504) return true;
  // A call the client gave up on (TimeoutError, no status: rolls 45829777164 and 45883186922) never reached a guest
  // verdict; the steps are detached (StepLog.detachedStep), so only a short start, poll or download can time out.
  if ((error as { name?: unknown } | null)?.name === "TimeoutError" || /\bTimeoutError\b/.test(text)) return true;
  return /ECONNRESET|socket connection was closed|socket hang up|ETIMEDOUT|EPIPE|ECONNREFUSED|fetch failed|UND_ERR|\b50[234]\b/i.test(text);
}

/**
 * The shape the SBOM scan and file manifest run at. The builder is left at the base size (2 vCPU, 3.9 GiB) the image
 * boots at, and both read the whole tree at once beside the cmux daemon: the scan took 442 s of its 600 s budget in
 * roll 46085354594 and ran past it in roll 46090412457 (file manifest 153 s, then 253 s), on a tree of the same size
 * (33179 components). syft 1.52.0 peaked at 680 MB for 1530 packages on a lane VM, so the image's 33179 want GiB, not
 * MB, of a 3.9 GiB guest; on 2 CPUs with a hasher beside it the scan took 10.4/9.9 s, on 4 CPUs 8.1/7.9 s. The snapshot
 * is already taken and the builder is deleted after this, so growing it changes no image. vCPU and memory only (one
 * provider call, 114 ms in the smoke's resize-sm-to-md): the scan writes only its outputs under /tmp.
 */
export const INVENTORY_SHAPE = { cpu: 4, memoryMb: 8192 } as const;

/** Grows the inventory target to INVENTORY_SHAPE unless it is already that size (a large-image bake leaves its builder
 * grown, and resize only grows). A refused or failed resize is logged and the scan runs as it is. */
export async function growForInventory(vm: Vm, log: (line: string) => void, shape: (vm: Vm) => Promise<GuestShape> = guestShape): Promise<void> {
  const t0 = Date.now();
  try {
    const before = await shape(vm);
    // The guest sees a little less memory than it was given (3915 MB of 4096 at base size).
    if (before.cpu >= INVENTORY_SHAPE.cpu && before.memoryMb >= INVENTORY_SHAPE.memoryMb * 0.85) {
      log(`INVENTORY shape ${JSON.stringify(before)} kept`);
      return;
    }
    await vm.resize({ cpu: Math.max(before.cpu, INVENTORY_SHAPE.cpu), memory: Math.max(Math.ceil(before.memoryMb / 1024) * 1024, INVENTORY_SHAPE.memoryMb) });
    const after = await shape(vm).catch(() => "unread");
    log(`INVENTORY shape ${JSON.stringify(before)} -> ${JSON.stringify(after)} in ${Date.now() - t0} ms`);
  } catch (error) {
    log(`WARN inventory resize to ${INVENTORY_SHAPE.cpu} vCPU / ${INVENTORY_SHAPE.memoryMb} MB failed, scanning as it is: ${String(error)}`);
  }
}

/** How long a retry waits for the builder to answer a trivial exec before it moves to a clone of the snapshot. */
export const BUILDER_PROBE_MS = 60_000;

type Target = { vm: Vm; vmId: string };

/**
 * The collect with its retries. A retry first asks the builder for a trivial exec: roll 46078031124's builder stopped
 * answering after its file manifest (the SBOM poll timed out for its whole 660 s, then both retries timed out on their
 * first mkdir: 1546.8 s, components=none), so retrying on it could never pass. #63475 starts a builder the provider paused; a builder that still does not answer is left
 * for the caller's delete and the retry runs on a fresh clone of the bake's own snapshot (the same tree: nothing ran on
 * the builder after it), recorded as `inventoryVmId`'s replacement in `inventoryClone`.
 */
export async function collectWithRetries(
  builder: Target,
  inventory: Record<string, unknown>,
  log: (line: string) => void,
  deps: {
    collect: (vm: Vm, attempt: number) => Promise<void>;
    answers: (vm: Vm) => Promise<boolean>;
    clone?: (attempt: number) => Promise<Target>;
  },
): Promise<void> {
  let target = builder;
  for (let attempt = 1; ; attempt++) {
    try {
      await deps.collect(target.vm, attempt);
      delete inventory.error;
      return;
    } catch (error) {
      inventory.error = String(error);
      if (!retriesInventory(error, attempt)) throw error;
      log(`INVENTORY RETRY ${attempt}/${INVENTORY_TRIES - 1}: ${inventory.error}`);
    }
    if (deps.clone !== undefined && !(await deps.answers(target.vm))) {
      log(`INVENTORY builder ${target.vmId} did not answer an exec in ${BUILDER_PROBE_MS / 1000} s; retrying on a clone of the snapshot`);
      target = await deps.clone(attempt + 1);
      inventory.inventoryClone = target.vmId;
    }
  }
}

export async function main(argv = process.argv): Promise<number> {
  const outDir = path.resolve(argValue("--out-dir", argv) ?? "");
  const bakeJson = readdirSync(outDir).find((f) => /^bake-.*\.json$/.test(f));
  if (!bakeJson) throw new Error(`no bake-*.json in ${outDir}`);
  const file = path.join(outDir, bakeJson);
  const record = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown> & { name: string; inventoryVmId?: string; snapshotId?: string; lockPath?: string };
  const vmId = record.inventoryVmId;
  if (!vmId) {
    console.log("INVENTORY none: the bake recorded its SBOM and manifest before the snapshot");
    return 0;
  }
  // The bake's own lock (recorded in its json), so a bake from another lock gets its own Syft pin.
  const lock = readInputsLock(path.resolve(argValue("--lock", argv) ?? record.lockPath ?? DEFAULT_LOCK_PATH));
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const L = new StepLog(path.join(outDir, `inventory-${record.name}.log`));
  const fs = freestyleClient();
  const vm = fs.vms.ref(vmId) as unknown as Vm;
  const inventory: Record<string, unknown> = {};
  const t0 = Date.now();
  // The builder was idle on the network since its snapshot (createVm's idle pause); roll 46078031124 lost it mid-scan
  // and every retry's first exec timed out. Each try and each run of failed polls reads its state and starts it.
  const clones: Array<{ vm: Vm; vmId: string; name: string }> = [];
  try {
    await collectWithRetries({ vm, vmId }, inventory, (line) => L.log(line), {
      collect: async (target, attempt) => {
        // #63475: the provider pauses an idle builder; read its state and start it before each try and on failed polls.
        const wakeTarget = () => wakeVm(target, (line) => L.log(line), target === vm ? `${record.name} (inventory)` : `${record.name} (inventory clone)`);
        await wakeTarget().catch((error: unknown) => L.log(`WARN inventory wake before try ${attempt}: ${String(error)}`));
        await growForInventory(target, (line) => L.log(line));
        await collectInventory(target, L, { devTree: false, outDir }, lock, inventory, record.name, attempt === 1 ? undefined : `/tmp/cmux-out-${attempt}`, wakeTarget);
      },
      // Woken first (#63475), so a paused builder is started, not replaced; only one that still does not answer is.
      answers: (target) =>
        wakeVm(target, (line) => L.log(line), `${record.name} (inventory probe)`)
          .catch(() => undefined)
          .then(() => firstExec(target, Date.now(), BUILDER_PROBE_MS))
          .then(() => true, () => false),
      clone: record.snapshotId === undefined ? undefined : async (attempt) => {
        const name = `${record.name}-inventory-${attempt}`;
        const made = await createVm(fs, ledger, { name, snapshotId: record.snapshotId as string });
        clones.push({ vm: made.vm, vmId: made.vmId, name });
        await firstExec(made.vm, made.t0);
        // As a smoke clone: the snapshot as baked, no self-update before the scan reads its tree.
        await run(made.vm, `mkdir -p /etc/cmux && touch ${SELF_UPDATE_OFF}`, 60_000);
        return { vm: made.vm, vmId: made.vmId };
      },
    });
  } catch (error) {
    inventory.error = String(error);
    L.log(`INVENTORY FAILED: ${inventory.error}`);
  } finally {
    for (const c of clones) await deleteVm(c.vm, c.vmId, c.name, ledger).catch((error) => L.log(`INVENTORY clone delete failed ${c.vmId}: ${String(error)}`));
    await deleteVm(vm, vmId, `${record.name} (inventory)`, ledger);
  }
  inventory.inventoryMs = Date.now() - t0;
  // Re-read: the bake json is this run's image record and nothing else writes it while this runs.
  const latest = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
  writeFileSync(file, `${JSON.stringify({ ...latest, ...inventory, inventorySteps: L.steps }, null, 2)}\n`);
  L.log(`INVENTORY_DONE ${record.name} ${((inventory.inventoryMs as number) / 1000).toFixed(1)}s components=${String(inventory.sbomComponents ?? "none")}`);
  return inventory.error ? 1 : 0;
}
