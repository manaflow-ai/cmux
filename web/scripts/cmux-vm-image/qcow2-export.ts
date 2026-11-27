/**
 * The root filesystem of a baked image as a tarball in R2, the input of the qcow2 export (RFD 0100 step 6: the
 * layered image in a second format, for hosts that run agent VMs themselves). Boots one VM from the snapshot,
 * bind-mounts its root read-only (so /proc, /sys, /dev and other mounts stay out), tars it with numeric owners,
 * xattrs and ACLs, compresses it with zstd, and PUTs it to a presigned R2 URL: the guest never holds an R2 key.
 * The VM is recorded in the run's ledger and deleted here; the bake's cleanup step deletes it too if this dies.
 * scripts/ci/vm-image-qcow2.sh turns the tarball into the qcow2 on the runner.
 *
 * Usage (from web/): bun ../images/cmux-vm/qcow2-export.ts --snapshot <sh-id> --tag <tag> --out-dir <dir>
 *   with QCOW2_ROOTFS_PUT_URL set to the presigned PUT URL (scripts/ci/r2-presign.py).
 * Prints `ROOTFS_TAR <sha256> <bytes>` when the upload finished.
 */
import path from "node:path";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run, sleep, StepLog } from "./guest";

const EXPORT_DIR = "/var/tmp/cmux-qcow2";
const ROOT_BIND = "/mnt/cmux-rootfs-export";
/** The tar and the upload run detached and are polled: one exec held open for minutes is cut by the provider. */
const EXPORT_BUDGET_MS = 40 * 60_000;

/** The guest script: everything it runs is POSIX sh (the guest's /bin/sh is dash). */
export function exportScript(putUrl: string): string {
  const q = (s: string) => `'${s.replace(/'/g, `'"'"'`)}'`;
  return [
    "set -eu",
    `mkdir -p ${EXPORT_DIR} ${ROOT_BIND}`,
    `mountpoint -q ${ROOT_BIND} || mount --bind / ${ROOT_BIND}`,
    `mount -o remount,bind,ro ${ROOT_BIND}`,
    // The baked image ships without apt lists (roll 45615566876: "Unable to locate package zstd"), so update first.
    "command -v zstd >/dev/null || { apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q zstd >/dev/null; }",
    `tar --numeric-owner --xattrs --xattrs-include='*' --acls --sparse -C ${ROOT_BIND} --exclude=./var/tmp/cmux-qcow2 -cf - . | zstd -q -T0 -6 -o ${EXPORT_DIR}/rootfs.tar.zst`,
    `sha256sum ${EXPORT_DIR}/rootfs.tar.zst | cut -d' ' -f1 > ${EXPORT_DIR}/sha256`,
    `stat -c %s ${EXPORT_DIR}/rootfs.tar.zst > ${EXPORT_DIR}/bytes`,
    // No -f: R2's 403 body (SignatureDoesNotMatch, AccessDenied, RequestTimeTooSkewed, ...) names the cause; -f hid it (roll 45690843632).
    `code=$(curl -sS --retry 5 --retry-all-errors --max-time 1800 -o ${EXPORT_DIR}/put.out -w '%{http_code}' -T ${EXPORT_DIR}/rootfs.tar.zst ${q(putUrl)}) || code=curl-failed`,
    `case "$code" in 2??) ;; *) echo "R2 PUT $code: $(head -c 600 ${EXPORT_DIR}/put.out 2>/dev/null) date=$(date -u +%Y%m%dT%H%M%SZ)" >&2; exit 22;; esac`,
  ].join("\n");
}

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  const tag = argValue("--tag", argv);
  const outDir = path.resolve(argValue("--out-dir", argv) ?? "");
  const putUrl = process.env.QCOW2_ROOTFS_PUT_URL ?? "";
  if (!snapshotId || !tag || !putUrl) throw new Error("--snapshot, --tag and QCOW2_ROOTFS_PUT_URL are required");
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const L = new StepLog(path.join(outDir, `qcow2-export-${tag}.log`));
  const name = `cmuxnp-dev-vmimg-${tag}-qcow2`;
  const { vm, vmId, t0 } = await createVm(freestyleClient(), ledger, { name, snapshotId });
  try {
    await firstExec(vm, t0);
    await vm.fs.writeFile(`/root/cmux-qcow2-export.sh`, exportScript(putUrl), { mode: 0o700 });
    await L.step(vm, "start export", `rm -f ${EXPORT_DIR}/status; mkdir -p ${EXPORT_DIR}; nohup sh -c 'sh /root/cmux-qcow2-export.sh > ${EXPORT_DIR}/log 2>&1; echo $? > ${EXPORT_DIR}/status' >/dev/null 2>&1 &`);
    const deadline = Date.now() + EXPORT_BUDGET_MS;
    for (;;) {
      if (Date.now() > deadline) throw new Error(`export did not finish in ${EXPORT_BUDGET_MS / 60_000} min`);
      await sleep(15_000);
      const r = await run(vm, `cat ${EXPORT_DIR}/status 2>/dev/null || true`, 30_000).catch(() => undefined);
      const status = r?.stdout.trim();
      if (!status) continue;
      const tail = (await run(vm, `tail -5 ${EXPORT_DIR}/log`, 30_000)).stdout.trim();
      if (status !== "0") throw new Error(`export failed (status ${status}): ${tail}`);
      const facts = (await run(vm, `cat ${EXPORT_DIR}/sha256 ${EXPORT_DIR}/bytes`, 30_000)).stdout.trim().split("\n");
      L.log(`ROOTFS_TAR ${facts[0]} ${facts[1]}`);
      L.log(`export took ${((Date.now() - t0) / 1000).toFixed(0)}s`);
      return 0;
    }
  } finally {
    await deleteVm(vm, vmId, name, ledger);
  }
}
