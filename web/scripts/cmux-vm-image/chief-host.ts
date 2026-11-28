/**
 * The Cloud Chief host on the image (images/cmux-vm/chief): `cmux-chief.service` runs
 * `optchat-chief host --conversation-source cloud`, installed disabled; `cmux-chief-update.timer`
 * replaces the binary with the newest published build and restarts the host between turns.
 *
 * The bake stages the folder and runs its install.sh, the same file scripts/cmux-next/cloud-chief-check.ts
 * runs on a fresh staging machine with a pull request's build. With an `optchat-chief` program in the lock
 * the first build is the image's own (/opt/cmux/current/bin/optchat-chief); without one the unit fetches the
 * newest published build on its first start.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CURRENT_BIN, type InputsLock } from "./lock";

export const CHIEF_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../images/cmux-vm/chief");
/** Where the bake stages the folder before install.sh copies it into place. */
export const CHIEF_STAGED = "/root/cmux-chief";
export const CHIEF_FILES = [
  { name: "install.sh", mode: 0o755 },
  { name: "cmux-chief-host", mode: 0o755 },
  { name: "cmux-chief-update", mode: 0o755 },
  { name: "cmux-chief.service", mode: 0o644 },
  { name: "cmux-chief-update.service", mode: 0o644 },
  { name: "cmux-chief-update.timer", mode: 0o644 },
  // Executor for the Chief (RFD 0111): its unit, the setup step that hands its key to the Chief, the GitHub app.
  { name: "cmux-executor.service", mode: 0o644 },
  { name: "cmux-executor-setup", mode: 0o755 },
  { name: "executor-github-index.ts", mode: 0o644 },
  { name: "executor-github-package.json", mode: 0o644 },
] as const;

export function chiefHostFiles(): Array<{ path: string; text: string; mode: number }> {
  return CHIEF_FILES.map((f) => ({ path: `${CHIEF_STAGED}/${f.name}`, text: readFileSync(path.join(CHIEF_DIR, f.name), "utf8"), mode: f.mode }));
}

/** The image's own build, when the lock pins one. */
export function chiefBinary(lock: InputsLock): string | null {
  return lock.programs.some((p) => p.name === "optchat-chief" && p.firstUse !== true) ? `${CURRENT_BIN}/optchat-chief` : null;
}

/** install.sh, then a check that the units parse and stay disabled. Prints `chief-host-ok ...` last. */
export function chiefHostInstallCommand(binary: string | null): string {
  return [
    `sh ${CHIEF_STAGED}/install.sh ${CHIEF_STAGED}${binary ? ` ${binary}` : ""}`,
    "systemd-analyze verify /etc/systemd/system/cmux-chief.service /etc/systemd/system/cmux-chief-update.service /etc/systemd/system/cmux-chief-update.timer /etc/systemd/system/cmux-executor.service",
    'test "$(systemctl is-enabled cmux-chief.service 2>/dev/null || true)" = disabled',
    "test -L /etc/systemd/system/cmux-chief.service.wants/cmux-executor.service",
    "python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' /usr/local/lib/cmux-chief/cmux-executor-setup",
    `rm -rf ${CHIEF_STAGED}`,
    `echo "chief-host-ok $(/var/lib/cmux-chief/current --version 2>/dev/null || echo 'no build yet')"`,
  ].join(" && ");
}
