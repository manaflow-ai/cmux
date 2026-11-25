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

/**
 * The edge resolver's IPv6 listener (the classic devbox fix, cmux#46670 / #46692, for this image).
 *
 * A clone created with a TLS rule (every gateway-mode create: coderouter.cmux.internal) gets the
 * Freestyle agent's resolver files: a plain /etc/resolv.conf holding `options timeout:1 attempts:2`
 * and `nameserver 10.32.0.28`, and resolved.conf.d/61-freestyle-tls.conf (`DNS=10.32.0.28`,
 * `Domains=~.`). IPv4 port 53 to 10.32.0.28 goes unanswered on much of the fleet; the same resolver
 * on the edge's IPv6 address, 2602:f470:1::28, answers (and answers the steered names). Roll
 * 45360379569 (2026-11-24 09:11Z) resolved through 10.32.0.28; rolls 45381501414 (15:22Z) and
 * 45474884363 (20:38Z) got no answer at all on the edge-rule clone (edge-rule-resolve, then
 * edge-rule-bind-probe), and that clone stands for every gateway-mode machine.
 *
 * cmux-edge-resolver.path runs an idempotent POSIX sh oneshot whenever the agent writes either file:
 * the IPv6 listener goes before the IPv4 line in the agent's resolv.conf (timeout:1 raised to 2: the
 * listener takes about 1.5 s), and 62-cmux-edge-resolver-v6.conf gives resolved the same pair, IPv6
 * first, while the agent's 61- drop-in names 10.32.0.28 (removed when it goes). A resolv.conf that is
 * a link (the image's own stub link) or names no 10.32.0.28 is left alone.
 */
export const FREESTYLE_EDGE_IPV6 = "2602:f470:1::28";
export const FREESTYLE_EDGE_IPV4 = "10.32.0.28";
export const RESOLVED_DROP_IN_DIR = "/etc/systemd/resolved.conf.d";
export const FREESTYLE_TLS_DROP_IN = "61-freestyle-tls.conf";
export const EDGE_RESOLVER_DROP_IN = "62-cmux-edge-resolver-v6.conf";
export const EDGE_RESOLVER_SCRIPT = "/usr/local/sbin/cmux-edge-resolver";
export const EDGE_RESOLVER_SERVICE = "cmux-edge-resolver.service";
export const EDGE_RESOLVER_PATH_UNIT = "cmux-edge-resolver.path";

/** The oneshot. `CMUX_*` variables exist for tests, which run it on a scratch tree without systemd. */
export function edgeResolverScript(): string {
  return `#!/bin/sh
# cmux-edge-resolver, from web/scripts/cmux-vm-image/dns.ts: adds the Freestyle edge resolver's
# IPv6 listener wherever the Freestyle agent names only its IPv4 address. Run by ${EDGE_RESOLVER_PATH_UNIT}.
set -u
V4=${FREESTYLE_EDGE_IPV4}
V6=${FREESTYLE_EDGE_IPV6}
RESOLV="\${CMUX_RESOLV_CONF:-${RESOLV_CONF}}"
DIR="\${CMUX_RESOLVED_DROP_IN_DIR:-${RESOLVED_DROP_IN_DIR}}"
AGENT="$DIR/${FREESTYLE_TLS_DROP_IN}"
OURS="$DIR/${EDGE_RESOLVER_DROP_IN}"
RELOAD="\${CMUX_RESOLVED_RELOAD:-systemctl try-reload-or-restart systemd-resolved}"
PENDING="\${CMUX_RESOLVED_RELOAD_PENDING:-/run/cmux-edge-resolver.reload-pending}"

apply_pass() {
  # glibc reads the agent's plain resolv.conf directly. Replace it only while it still holds what
  # was read, so an agent write during this run is never overwritten with older contents.
  tries=0
  while :; do
    rm -f "$RESOLV.cmux-src" "$RESOLV.cmux-tmp"
    [ -f "$RESOLV" ] && [ ! -L "$RESOLV" ] || break
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || { echo "cmux-edge-resolver: $RESOLV kept changing; will retry" >&2; exit 1; }
    cp "$RESOLV" "$RESOLV.cmux-src" || exit 1
    grep -qxF "nameserver $V4" "$RESOLV.cmux-src" || break
    has6=0
    grep -qxF "nameserver $V6" "$RESOLV.cmux-src" && has6=1
    awk -v v4="nameserver $V4" -v v6="nameserver $V6" -v has6="$has6" '
      $1 == "options" { for (i = 2; i <= NF; i++) if ($i == "timeout:1") $i = "timeout:2" }
      $0 == v4 && has6 == 0 { print v6 }
      { print }' "$RESOLV.cmux-src" > "$RESOLV.cmux-tmp" || exit 1
    cmp -s "$RESOLV.cmux-tmp" "$RESOLV.cmux-src" && break
    if cmp -s "$RESOLV.cmux-src" "$RESOLV"; then
      chmod 0644 "$RESOLV.cmux-tmp" && mv -f "$RESOLV.cmux-tmp" "$RESOLV" || exit 1
      break
    fi
  done
  rm -f "$RESOLV.cmux-src" "$RESOLV.cmux-tmp"

  # resolved: the same resolver, IPv6 first, only while the agent's drop-in names it.
  if [ -f "$AGENT" ] && grep -qxF "DNS=$V4" "$AGENT"; then
    if ! printf '%s\\n' '# Written by cmux-edge-resolver.' '[Resolve]' 'DNS=' "DNS=$V6 $V4" | cmp -s - "$OURS"; then
      : > "$PENDING" || exit 1
      printf '%s\\n' '# Written by cmux-edge-resolver.' '[Resolve]' 'DNS=' "DNS=$V6 $V4" > "$OURS.cmux-tmp" &&
        chmod 0644 "$OURS.cmux-tmp" && mv -f "$OURS.cmux-tmp" "$OURS" || exit 1
    fi
  elif [ -e "$OURS" ]; then
    : > "$PENDING" || exit 1
    rm -f "$OURS" || exit 1
  fi
  if [ -e "$PENDING" ]; then
    $RELOAD || { echo "cmux-edge-resolver: systemd-resolved reload failed; will retry" >&2; exit 1; }
    rm -f "$PENDING"
  fi
}

state() { for f in "$RESOLV" "$AGENT" "$OURS"; do if [ -e "$f" ]; then cksum < "$f"; else echo absent; fi; done; }
# The path unit does not watch while this runs: repeat until a pass starts and ends on the same files.
passes=0
while :; do
  passes=$((passes + 1))
  [ "$passes" -le 10 ] || { echo "cmux-edge-resolver: resolver files kept changing; will retry" >&2; exit 1; }
  before="$(state)"
  apply_pass
  [ "$before" = "$(state)" ] && break
done
exit 0
`;
}

export function edgeResolverServiceUnit(): string {
  return [
    "[Unit]",
    "Description=cmux: add the Freestyle edge resolver's IPv6 listener",
    "After=systemd-resolved.service",
    "StartLimitIntervalSec=0",
    "",
    "[Service]",
    "Type=oneshot",
    `ExecStart=${EDGE_RESOLVER_SCRIPT}`,
    "Restart=on-failure",
    "RestartSec=10",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ].join("\n");
}

export function edgeResolverPathUnit(): string {
  return [
    "[Unit]",
    "Description=cmux: watch the Freestyle agent's resolver files",
    "",
    "[Path]",
    `PathChanged=${RESOLV_CONF}`,
    `PathChanged=${RESOLVED_DROP_IN_DIR}/${FREESTYLE_TLS_DROP_IN}`,
    `Unit=${EDGE_RESOLVER_SERVICE}`,
    "",
    "[Install]",
    "WantedBy=paths.target",
    "",
  ].join("\n");
}

/** The guest files the bake writes for the edge resolver (path, contents, mode). */
export function edgeResolverFiles(): Array<[string, string, number]> {
  return [
    [EDGE_RESOLVER_SCRIPT, edgeResolverScript(), 0o755],
    [`/etc/systemd/system/${EDGE_RESOLVER_SERVICE}`, edgeResolverServiceUnit(), 0o644],
    [`/etc/systemd/system/${EDGE_RESOLVER_PATH_UNIT}`, edgeResolverPathUnit(), 0o644],
  ];
}

/** Bake step after the files are written: units enabled and armed, one run, proof it is armed. */
export const EDGE_RESOLVER_ARM_COMMAND = [
  `sh -n ${EDGE_RESOLVER_SCRIPT}`,
  "systemctl daemon-reload",
  `systemctl enable ${EDGE_RESOLVER_SERVICE} >/dev/null 2>&1`,
  `systemctl enable --now ${EDGE_RESOLVER_PATH_UNIT} >/dev/null 2>&1`,
  `systemctl start ${EDGE_RESOLVER_SERVICE}`,
  `systemctl is-active --quiet ${EDGE_RESOLVER_PATH_UNIT}`,
  "echo edge-resolver-armed",
].join(" && ");
