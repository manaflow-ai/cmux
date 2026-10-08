/**
 * Real-VM check of the metadata guard (metadata-guard.ts) without a bake: a
 * clone of an existing cmux VM image snapshot gets the guard exactly as the
 * bake installs it, then:
 * - before the guard, the work user (an agent shell's user) reads the
 *   metadata service (proof the check can fail);
 * - after it, the work user's `curl 169.254.169.254` fails at once, through
 *   the exec API as that user (an agent shell) and through `runuser`;
 * - root still reads the instance id (the VM agent and the boot supervisor);
 * - the rule survives a restart of the unit (the boot path).
 * The clone is deleted by its exact id, also on failure.
 *
 * Usage (from web/): FREESTYLE_API_KEY_FILE=<path> bun scripts/cmux-vm-image/metadata-guard-probe.ts
 *   --snapshot <snapshot id> [--name cmuxnp-dev-metaguard-<tag>] [--out-dir <dir>]
 */
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { argValue, createVm, deleteVm, firstExec, freestyleClient, Ledger, run } from "./guest";
import {
  METADATA_GUARD_FILE,
  METADATA_GUARD_UNIT,
  metadataGuardCheckCommand,
  metadataGuardEnableCommand,
  metadataGuardProblems,
  metadataGuardRules,
  metadataGuardUnit,
} from "./metadata-guard";

const AGENT_SHELL_CURL = "curl -s -m 3 -o /dev/null -w '%{http_code}' http://169.254.169.254/latest/meta-data/; echo \" exit=$?\"";

export async function main(argv = process.argv): Promise<number> {
  const snapshotId = argValue("--snapshot", argv);
  if (!snapshotId) throw new Error("usage: metadata-guard-probe.ts --snapshot <id> [--name cmuxnp-dev-...]");
  const name = argValue("--name", argv) ?? `cmuxnp-dev-metaguard-${Date.now().toString(36)}`;
  const outDir = path.resolve(argValue("--out-dir", argv) ?? `cmux-vm-image-out/${name}`);
  const ledger = new Ledger(path.join(outDir, "resources.tsv"));
  const fs = freestyleClient();
  const { vm, vmId, t0 } = await createVm(fs, ledger, { name, snapshotId });
  console.log(`VM ${vmId} (${name})`);
  const problems: string[] = [];
  try {
    await firstExec(vm, t0);
    const before = await run(vm, metadataGuardCheckCommand(DEVBOX_WORK_USER));
    console.log(`before the guard:\n${before.stdout.trim()}`);
    if (!/^user_blocked=no$/m.test(before.stdout)) problems.push("the work user could not read the metadata service before the guard: the check proves nothing");
    await vm.fs.writeFile(METADATA_GUARD_FILE, metadataGuardRules(), { mode: 0o644 });
    await vm.fs.writeFile(`/etc/systemd/system/${METADATA_GUARD_UNIT}`, metadataGuardUnit(), { mode: 0o644 });
    const enabled = await run(vm, metadataGuardEnableCommand(DEVBOX_WORK_USER));
    console.log(`after the guard (exit ${enabled.code}):\n${enabled.stdout.trim()}${enabled.stderr.trim() ? `\n${enabled.stderr.trim()}` : ""}`);
    if (enabled.code !== 0) problems.push(`the guard did not load: ${enabled.stderr.trim().slice(-300)}`);
    problems.push(...metadataGuardProblems(enabled.stdout));
    const shell = await run(vm, AGENT_SHELL_CURL, 30_000, DEVBOX_WORK_USER);
    console.log(`agent shell (${DEVBOX_WORK_USER}) curl 169.254.169.254: ${shell.stdout.trim()} in ${shell.ms} ms`);
    if (!/^000 exit=[1-9]/.test(shell.stdout.trim())) problems.push(`the agent shell reached the metadata service: ${shell.stdout.trim()}`);
    const restarted = await run(vm, `systemctl restart ${METADATA_GUARD_UNIT} && ${metadataGuardCheckCommand(DEVBOX_WORK_USER)} && nft list table inet cmux_metadata_guard | grep -c reject`);
    console.log(`after a unit restart:\n${restarted.stdout.trim()}`);
    problems.push(...metadataGuardProblems(restarted.stdout).map((p) => `after a restart: ${p}`));
  } finally {
    await deleteVm(vm, vmId, name, ledger);
    console.log(`deleted VM ${vmId}`);
  }
  for (const problem of problems) console.log(`PROBLEM ${problem}`);
  console.log(problems.length === 0 ? "METADATA GUARD PASSED" : "METADATA GUARD FAILED");
  return problems.length === 0 ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then(
    (code) => process.exit(code),
    (error) => {
      console.error(error);
      process.exit(1);
    },
  );
}
