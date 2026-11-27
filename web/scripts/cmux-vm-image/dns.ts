/**
 * The image's resolver: systemd-resolved, with /etc/resolv.conf a link to its stub. Tailscale
 * (on a machine that installs it) then runs in resolved mode on its own, because it picks
 * resolved only when resolv.conf is the stub and resolved runs; with a plain file it writes
 * resolv.conf itself ("direct" mode), the way huge-blue lost DNS. The provider's
 * /etc/systemd/resolved.conf.d/60-freestyle-vms.conf is left alone.
 *
 * images/cmux-vm/machine-health/cmux-dns-check is the check, baked as DNS_CHECK_PATH and the
 * same script any systemd machine runs.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const MACHINE_HEALTH_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../images/cmux-vm/machine-health");
export const DNS_CHECK_PATH = "/usr/local/sbin/cmux-dns-check";
export const RESOLV_CONF = "/etc/resolv.conf";
export const RESOLVED_STUB = "/run/systemd/resolve/stub-resolv.conf";

export function dnsCheckScript(): string {
  return readFileSync(path.join(MACHINE_HEALTH_DIR, "cmux-dns-check"), "utf8");
}

/**
 * Bake step: systemd-resolved enabled and running, and resolv.conf the link to its stub. A base
 * that already has both is left as it is (the expected case); a plain resolv.conf is replaced
 * only when resolved runs and its stub names a nameserver, so a clone is never left without one.
 * Prints `resolv.conf linked` or `resolv.conf was a link already`, then the check's lines.
 */
export function resolverBakeCommand(): string {
  return [
    "systemctl enable --now systemd-resolved.service >/dev/null 2>&1",
    "systemctl is-active --quiet systemd-resolved.service",
    `if [ "$(readlink -f ${RESOLV_CONF})" = ${RESOLVED_STUB} ] && [ -L ${RESOLV_CONF} ]; then echo 'resolv.conf was a link already'; else grep -q '^nameserver ' ${RESOLVED_STUB} && ln -sfn ../run/systemd/resolve/stub-resolv.conf ${RESOLV_CONF} && echo 'resolv.conf linked'; fi`,
    // The provider's drop-ins, recorded for the bake log only (never edited); none is not an error.
    "echo \"resolved.conf.d: $(ls /etc/systemd/resolved.conf.d 2>/dev/null || echo none)\"",
    DNS_CHECK_PATH,
  ].join(" && ");
}

/** Smoke step on a clone: restart resolved (and tailscaled when installed), then every check. */
export const DNS_SMOKE_COMMAND = `${DNS_CHECK_PATH} --restart`;

/** Problems in cmux-dns-check output: every FAIL line, or a missing PASS for the link or a public name. */
export function dnsCheckProblems(code: number, stdout: string): string[] {
  const lines = stdout.trim().split("\n").filter(Boolean);
  const problems = lines.filter((l) => l.startsWith("FAIL ")).map((l) => l.slice(5));
  if (!lines.some((l) => l.startsWith("PASS resolv.conf:"))) problems.push("no PASS for the resolv.conf link");
  if (!lines.some((l) => /^PASS resolve (?!tailnet)/.test(l))) problems.push("no public name resolved");
  if (code !== 0 && problems.length === 0) problems.push(`cmux-dns-check exit ${code}`);
  return problems;
}
