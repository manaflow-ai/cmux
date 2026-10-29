/**
 * Guest commands that put the DNS fallback (`cmux-dns`, cmux issue 26640) on a
 * running Freestyle machine, or take it off. The image bake installs the same
 * files with the same commands (devbox-image-common.ts), so a machine fixed in
 * place matches a machine created from a new image. The runner is
 * scripts/install-fleet-dns-fallback.ts; docs/cloud-guest-upgrades.md is the
 * runbook.
 *
 * Every command runs as root through `sh -c` and prints one result line last
 * on stdout: `OK installed`, `OK removed`, `SKIP <why>`, or `FAIL <reason>`.
 * A failed install puts back what the machine had before (the files, the unit
 * states and resolv.conf), then checks that it did, and says so when it did not.
 */
import { createHash } from "node:crypto";
import {
  DEVBOX_DNS_PATH,
  DEVBOX_DNS_UNITS,
  devboxDnsCheckCommand,
  devboxDnsInstallCommand,
} from "../devbox-image-common";

const RESOLV_CONF = "/etc/resolv.conf";
/** The first line the platform writes on a machine with TLS rules (seen on production machines, 2026-10-29). */
const PLATFORM_RESOLV_HEADER = "# freestyle-tls forwarding resolver";
/** The first line cmux-dns's guard writes. */
const GUARD_MARKER = "# cmux-dns";
/** The platform's own resolv.conf options (`options timeout:1 attempts:2`); the guard replaces them. */
const PLATFORM_RESOLV_OPTIONS = "timeout:1 attempts:2";
/** Every file the fallback owns, the stub first. Their contents together are its version. */
const FILES = [DEVBOX_DNS_PATH, ...Object.keys(DEVBOX_DNS_UNITS)];
/** The units whose enabled and active states an install may change, the stub first. */
const UNITS = ["cmux-dns.service", "cmux-dns-guard.path", "cmux-dns-guard.service"];
const BACKUP_SUFFIX = ".cmux-old";
/**
 * One run per machine at a time. The kernel holds the lock on an open file and
 * drops it when the run's shell exits, killed or not, so a dead run never
 * blocks the next one and no two runs can both take it.
 */
const LOCK_FILE = "/run/cmux-dns-fleet.lock";
const RESULT_LINE = /^(OK|SKIP|FAIL) /;

const NO_SYSTEMD = `if [ ! -d /run/systemd/system ] || [ ! -x /usr/bin/python3 ]; then echo "SKIP no-systemd"; exit 0; fi`;

/** Takes the machine's lock or stops with `SKIP busy`; the log goes when the script exits, the lock with the shell. */
const TAKE_LOCK = [
  `if ! command -v flock >/dev/null 2>&1; then echo "SKIP no-flock"; exit 0; fi`,
  `log=""; trap 'rm -f "$log"' EXIT`,
  `exec 9>${LOCK_FILE} || { echo "FAIL lock ${LOCK_FILE}"; exit 0; }`,
  `if ! flock -n 9; then echo "SKIP busy"; exit 0; fi`,
].join("\n");

/** `echo <base64> | base64 -d > <file>`: the provider exec body carries no quoting of its own. */
function writeFileCommand(file: string, content: string, mode: string): string {
  return `echo ${Buffer.from(content).toString("base64")} | base64 -d > ${file}.cmux-new && chmod ${mode} ${file}.cmux-new && mv -f ${file}.cmux-new ${file}`;
}

/** The sha256 of the installed files, read in {@link FILES} order; a missing file changes it. */
const INSTALLED_VERSION = `$(cat ${FILES.join(" ")} 2>/dev/null | sha256sum | cut -d' ' -f1)`;

function versionOf(script: string): string {
  const hash = createHash("sha256").update(script);
  for (const unit of Object.values(DEVBOX_DNS_UNITS)) hash.update(unit);
  return hash.digest("hex");
}

/**
 * Points a resolv.conf the guard wrote back at the platform: the stub's line
 * and the guard's comments go, every platform resolver the guard recorded
 * comes back (libc reads three), and only the guard's timeout and attempts
 * are swapped for the platform's. Any other file is left alone. `--remove`
 * uses it; a failed install puts its saved copy back instead.
 */
export function restoreResolvConfCommand(file = RESOLV_CONF): string {
  const awk = [
    `$0 ~ /^# cmux-dns upstream / { for (i = 4; i <= NF; i++) up[++n] = $i; next }`,
    `/^# / { next }`,
    `$1 == "nameserver" { if ($2 != "127.0.0.2") kept[++k] = $2; next }`,
    `$1 == "options" { line = "options"; for (i = 2; i <= NF; i++) if ($i !~ /^(timeout|attempts):/) line = line " " $i; opts = line " ${PLATFORM_RESOLV_OPTIONS}"; next }`,
    `{ print }`,
    `END { if (opts != "") print opts; if (n == 0) for (i = 1; i <= k; i++) print "nameserver " kept[i]; for (i = 1; i <= n && i <= 3; i++) print "nameserver " up[i] }`,
  ].join(" ");
  return `if head -1 ${file} | grep -qx '${GUARD_MARKER}'; then ` +
    `awk '${awk}' ${file} > ${file}.cmux-new && chmod 644 ${file}.cmux-new && mv -f ${file}.cmux-new ${file}; fi`;
}

/** True when nothing of the fallback is left: no files, no running stub, and resolv.conf not guarded. */
const NOTHING_LEFT = `[ "${INSTALLED_VERSION}" = "$(printf '' | sha256sum | cut -d' ' -f1)" ] && ` +
  `! systemctl is-active cmux-dns.service >/dev/null 2>&1 && ! head -1 ${RESOLV_CONF} | grep -qx '${GUARD_MARKER}'`;

/** Stops the fallback, deletes its files, and gives resolv.conf back to the platform. Every step runs. */
export function dnsFallbackRemoveCommand(): string {
  return [
    `systemctl disable --now ${UNITS.join(" ")} >/dev/null 2>&1`,
    `rm -f ${FILES.join(" ")}`,
    "systemctl daemon-reload >/dev/null 2>&1",
    restoreResolvConfCommand(),
  ].join("; ");
}

/** Reads each unit's enabled and active state into e<i> and a<i> before the install touches them. */
const SAVE_UNIT_STATES = UNITS.map((unit, index) =>
  `e${index}=$(systemctl is-enabled ${unit} 2>/dev/null); a${index}=$(systemctl is-active ${unit} 2>/dev/null)`).join("; ");

/**
 * Puts the machine back as it was. Units that were off are stopped and
 * disabled while their files still exist (so no enable link is left behind),
 * then the saved files come back (a file that was not there is deleted), then
 * units that were on are enabled and restarted on the old files. Last,
 * resolv.conf comes back when it still holds a guard's rewrite; a newer
 * platform rewrite stays.
 */
const RESTORE_PREVIOUS = [
  ...UNITS.map((unit, index) =>
    `if [ "$a${index}" != active ]; then systemctl stop ${unit}; fi; if [ "$e${index}" != enabled ]; then systemctl disable ${unit}; fi`),
  `for f in ${FILES.join(" ")}; do if [ -e "$f${BACKUP_SUFFIX}" ]; then mv -f "$f${BACKUP_SUFFIX}" "$f"; else rm -f "$f"; fi; done`,
  "systemctl daemon-reload",
  ...UNITS.map((unit, index) =>
    `if [ "$e${index}" = enabled ]; then systemctl enable ${unit}; fi; if [ "$a${index}" = active ]; then systemctl restart ${unit}; fi`),
  `if head -1 ${RESOLV_CONF} | grep -qx '${GUARD_MARKER}' && [ -e ${RESOLV_CONF}${BACKUP_SUFFIX} ]; then mv -f ${RESOLV_CONF}${BACKUP_SUFFIX} ${RESOLV_CONF}; fi`,
].join("; ");

/** The restore worked: the same files as before, the stub in the same state, and no guard left behind when there was none. */
const RESTORED = `[ "${INSTALLED_VERSION}" = "$installed" ] && [ "$(systemctl is-active cmux-dns.service 2>/dev/null)" = "$a0" ] && ` +
  `{ [ "$had" = 1 ] || ! head -1 ${RESOLV_CONF} | grep -qx '${GUARD_MARKER}'; }`;

const DROP_BACKUPS = `for f in ${[...FILES, RESOLV_CONF].join(" ")}; do rm -f "$f${BACKUP_SUFFIX}"; done`;

/**
 * Installs `script` (the cmux-dns source) and its units, then runs the bake's
 * install and check commands. A machine that already runs this version and
 * passes the check is left alone, and so is one whose resolv.conf the platform
 * did not write (a VPN, Tailscale or a user's own resolver owns it). When only
 * the check fails, the files are not rewritten and a running stub keeps its
 * cache; a new version restarts it.
 */
export function dnsFallbackInstallCommand(script: string): string {
  const writes = [
    writeFileCommand(DEVBOX_DNS_PATH, script, "755"),
    ...Object.entries(DEVBOX_DNS_UNITS).map(([file, unit]) => writeFileCommand(file, unit, "644")),
    "systemctl daemon-reload",
    // enable --now leaves a running stub alone; an older copy must restart to load the new one.
    "systemctl try-restart cmux-dns.service",
  ].join(" && ");
  return [
    NO_SYSTEMD,
    TAKE_LOCK,
    `target=${versionOf(script)}`,
    `installed=${INSTALLED_VERSION}`,
    `if [ "$installed" = "$target" ] && { ${devboxDnsCheckCommand}; } >/dev/null 2>&1; then echo "SKIP current"; exit 0; fi`,
    `first=$(head -1 ${RESOLV_CONF} 2>/dev/null)`,
    `if [ -L ${RESOLV_CONF} ] || [ ! -f ${RESOLV_CONF} ] || { [ "$first" != '${PLATFORM_RESOLV_HEADER}' ] && [ "$first" != '${GUARD_MARKER}' ]; }; then echo "SKIP custom-resolv-conf"; exit 0; fi`,
    `log=$(mktemp) || { echo "FAIL mktemp"; exit 0; }`,
    `had=0; if [ -e ${DEVBOX_DNS_PATH} ]; then had=1; fi`,
    SAVE_UNIT_STATES,
    `for f in ${[...FILES, RESOLV_CONF].join(" ")}; do rm -f "$f${BACKUP_SUFFIX}"; if [ -e "$f" ]; then cp -p "$f" "$f${BACKUP_SUFFIX}" || { echo "FAIL backup $f"; exit 0; }; fi; done`,
    `if { if [ "$installed" != "$target" ]; then ${writes}; fi && ${devboxDnsInstallCommand} && ${devboxDnsCheckCommand}; } >"$log" 2>&1; then`,
    `  ${DROP_BACKUPS}; echo "OK installed"; exit 0`,
    `fi`,
    // ASCII only: a byte cut through systemctl's arrow would garble the line.
    `reason=$(tail -n 3 "$log" | tr '\\n' ' ' | tr -cd '\\40-\\176' | cut -c1-200)`,
    // Same files: nothing was written, so nothing is put back and the stub keeps its cache.
    `if [ "$installed" = "$target" ]; then ${DROP_BACKUPS}; echo "FAIL $reason(left the installed fallback in place)"; exit 0; fi`,
    `{ ${RESTORE_PREVIOUS}; } >/dev/null 2>&1`,
    `if ${RESTORED}; then`,
    `  ${DROP_BACKUPS}`,
    `  if [ "$had" = 1 ]; then echo "FAIL $reason(restored the previous fallback)"; else echo "FAIL $reason(rolled back)"; fi`,
    `else echo "FAIL $reason(rollback incomplete: check ${RESOLV_CONF}, the cmux-dns units and the ${BACKUP_SUFFIX} copies)"; fi`,
  ].join("\n");
}

/** Removes the fallback and checks that nothing is left; a machine without it reports `OK removed` too. */
export function dnsFallbackUninstallCommand(): string {
  return [
    NO_SYSTEMD,
    TAKE_LOCK,
    `{ ${dnsFallbackRemoveCommand()}; } >/dev/null 2>&1`,
    `if ${NOTHING_LEFT}; then echo "OK removed"; else echo "FAIL remove incomplete: check ${RESOLV_CONF} and the cmux-dns units"; fi`,
  ].join("\n");
}

/**
 * The machine's result: the last result line on stdout, so a warning on
 * stderr (sudo, a login profile) never hides it. Without one, the command did
 * not finish: `FAIL` with what it printed.
 */
export function dnsFallbackResult(stdout: string, stderr = ""): string {
  const result = stdout.split("\n").map((line) => line.trim()).filter((line) => RESULT_LINE.test(line)).at(-1);
  if (result) return result;
  const printed = `${stdout}\n${stderr}`.trim().split("\n").at(-1)?.trim() ?? "";
  return `FAIL ${printed.slice(0, 200) || "no output"}`;
}

/**
 * Runs `run` over `ids` in batches of `concurrency` and stops after the first
 * batch with a FAIL or ERR, so one bad result is looked at before it repeats
 * across the fleet. The machines it did not start are returned.
 */
export async function runInBatches(
  ids: readonly string[],
  run: (id: string) => Promise<string>,
  concurrency: number,
  report: (id: string, line: string) => void,
): Promise<{ failed: number; notRun: string[] }> {
  let failed = 0;
  for (let start = 0; start < ids.length; start += concurrency) {
    const batch = ids.slice(start, start + concurrency);
    const results = await Promise.all(batch.map(run));
    batch.forEach((id, index) => {
      const line = results[index] ?? "ERR no result";
      if (/^(FAIL|ERR)/.test(line)) failed += 1;
      report(id, line);
    });
    if (failed > 0) return { failed, notRun: ids.slice(start + concurrency) };
  }
  return { failed, notRun: [] };
}

/** Every entry must be a machine id: a typo must stop the run, not shrink it. */
export function parseMachineIds(entries: readonly string[]): string[] {
  const ids = entries.map((entry) => entry.trim()).filter((entry) => entry !== "");
  const invalid = ids.filter((entry) => !/^vm-[0-9a-f]{32}$/.test(entry));
  if (invalid.length > 0) throw new Error(`not machine ids: ${invalid.join(", ")}`);
  if (ids.length === 0) throw new Error("no machines: pass --vm <id> or --vms-file <file>");
  return [...new Set(ids)];
}

/** Only these flags exist: a typo such as `--rollback` must stop the run, not install. */
export function parseFleetArgs(argv: readonly string[]): { vms: string[]; vmsFile?: string; remove: boolean; dryRun: boolean } {
  const parsed = { vms: [] as string[], vmsFile: undefined as string | undefined, remove: false, dryRun: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = (): string => {
      const next = argv[index + 1];
      if (next === undefined || next.startsWith("--")) throw new Error(`${arg} needs a value`);
      index += 1;
      return next;
    };
    if (arg === "--vm") parsed.vms.push(value());
    else if (arg === "--vms-file") parsed.vmsFile = value();
    else if (arg === "--remove") parsed.remove = true;
    else if (arg === "--dry-run") parsed.dryRun = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return parsed;
}
