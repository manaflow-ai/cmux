/**
 * The image's resolver: systemd-resolved, with /etc/resolv.conf a link to its stub. Tailscale
 * (on a machine that installs it) then runs in resolved mode on its own, because it picks
 * resolved only when resolv.conf is the stub and resolved runs; with a plain file it writes
 * resolv.conf itself ("direct" mode), the way huge-blue lost DNS. The provider's
 * /etc/systemd/resolved.conf.d/60-freestyle-vms.conf is left alone.
 *
 * images/cmux-vm/machine-health/cmux-dns-check is the check, baked as DNS_CHECK_PATH and the
 * same script any systemd machine runs.
 *
 * A machine created with a TLS edge rule (gateway mode, a network policy's domains) gets the
 * provider's 61-freestyle-tls.conf and a plain resolv.conf after it resumes: the edge resolver is
 * then its only resolver, and every name fails while that resolver stalls. cmux-dns-scope
 * (DNS_SCOPE_PATH, run by cmux-dns-scope.path) keeps the edge resolver first, the only one for
 * *.cmux.internal, puts the public resolvers behind it and links resolv.conf back to the stub.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const MACHINE_HEALTH_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../images/cmux-vm/machine-health");
export const DNS_CHECK_PATH = "/usr/local/sbin/cmux-dns-check";
export const RESOLV_CONF = "/etc/resolv.conf";
export const RESOLVED_STUB = "/run/systemd/resolve/stub-resolv.conf";
export const DNS_SCOPE_PATH = "/usr/local/sbin/cmux-dns-scope";
export const DNS_SCOPE_UNIT = "cmux-dns-scope";

export function dnsCheckScript(): string {
  return readFileSync(path.join(MACHINE_HEALTH_DIR, "cmux-dns-check"), "utf8");
}

export function dnsScopeScript(): string {
  return readFileSync(path.join(MACHINE_HEALTH_DIR, "cmux-dns-scope"), "utf8");
}

/**
 * cmux-dns-scope's units: the path unit runs it whenever the provider's TLS drop-in, resolv.conf or
 * resolved's stub file changes (resolved rewrites the stub when it restarts, which drops the runtime
 * link settings the script makes), and the service runs it once at boot too.
 */
export function dnsScopeUnits(): Record<string, string> {
  return {
    [`/etc/systemd/system/${DNS_SCOPE_UNIT}.service`]: [
      "[Unit]",
      "Description=cmux: public resolvers behind the TLS-edge resolver, *.cmux.internal on it",
      "After=systemd-resolved.service",
      "",
      "[Service]",
      "Type=oneshot",
      `ExecStart=${DNS_SCOPE_PATH}`,
      "TimeoutStartSec=30",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "",
    ].join("\n"),
    [`/etc/systemd/system/${DNS_SCOPE_UNIT}.path`]: [
      "[Unit]",
      "Description=cmux: rescope DNS when the provider's TLS-edge resolver config changes",
      "",
      "[Path]",
      "PathChanged=/etc/systemd/resolved.conf.d/61-freestyle-tls.conf",
      `PathChanged=${RESOLV_CONF}`,
      `PathChanged=${RESOLVED_STUB}`,
      `Unit=${DNS_SCOPE_UNIT}.service`,
      "",
      "[Install]",
      "WantedBy=paths.target",
      "",
    ].join("\n"),
  };
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
    // dnsScopeUnits() are written before this step; the path unit watches from now on, in every clone.
    `systemctl daemon-reload && systemctl enable ${DNS_SCOPE_UNIT}.service >/dev/null 2>&1 && systemctl enable --now ${DNS_SCOPE_UNIT}.path >/dev/null 2>&1`,
    `systemctl is-active --quiet ${DNS_SCOPE_UNIT}.path && echo '${DNS_SCOPE_UNIT}.path active'`,
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
