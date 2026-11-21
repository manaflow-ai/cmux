import { shellQuote } from "../drivers/cmuxTuiDaemon";

/**
 * The guest resolver's IPv6 fallback (manaflow-ai/cmux#46670).
 *
 * When a machine has a TLS rule, the Freestyle agent points the guest at the
 * TLS edge's forwarding resolver, by its IPv4 address only, in two places:
 *
 * - `/etc/resolv.conf`, which glibc reads directly: a plain file (resolved
 *   reports `resolv.conf mode: foreign`) holding `# freestyle-tls forwarding
 *   resolver`, `options timeout:1 attempts:2` and `nameserver 10.32.0.28`.
 * - `/etc/systemd/resolved.conf.d/61-freestyle-tls.conf`, for resolved:
 *   `DNS=`, `DNS=10.32.0.28`, `Domains=~.`.
 *
 * It rewrites both whenever the machine's TLS rules change. The forwarding
 * resolver answers the TLS-steered aliases (coderouter.cmux.internal) and
 * every public name, and it also listens on the edge's IPv6 address.
 *
 * Measured on the production fleet (2026-11-18): IPv4 port 53 to 10.32.0.28
 * timed out on 10 of 12 running machines, UDP and TCP alike, and on a
 * machine created fresh from the current image. On the reported machine,
 * tcpdump showed the queries leave eth0 with no reply, and the platform's
 * own `resolver-health.freestyle.internal` probe also went unanswered. Port
 * 443 to the same address kept working. IPv6 port 53 to 2602:f470:1::28
 * answered on 11 of 12 machines, steered aliases included. With one IPv4
 * server and nothing else, every lookup failed (`EAI_AGAIN`), and a user saw
 * "the internet is down".
 *
 * So every image carries `cmux-edge-resolver`, a path unit and an
 * idempotent script that run whenever the agent writes either file:
 *
 * - In the agent's resolv.conf it adds `nameserver 2602:f470:1::28` right
 *   before the IPv4 line. glibc tries servers in order, and the IPv4 path is
 *   the one that fails, so the IPv6 listener goes first. It also raises the
 *   agent's `timeout:1` to `timeout:2`: the IPv6 listener took about 1.5 s per
 *   query, so at 1 s glibc gave up on it before the answer came back. A
 *   resolv.conf that is not the agent's (a symlink to resolved's stub, a
 *   user's own file, a VPN's) is left alone.
 * - Next to the agent's `61-` drop-in it writes `62-cmux-edge-resolver-v6.conf`:
 *   the same resolver, IPv6 first, then IPv4. resolved stays on whichever
 *   server answers. Once the agent's drop-in is gone (no TLS rule), cmux's is
 *   removed too, and the base's public resolvers apply again. A user's
 *   drop-in that sorts later (`70-…`) still wins.
 *
 * Both names point to the same resolver, so steering and every TLS rule
 * behave the same. Only the address family changes. A restricted network
 * policy that grants DNS grants port 53 to both edge addresses too
 * (drivers/freestyleNetworkPolicy.ts), so the listener chosen here is
 * reachable on every machine.
 *
 * A drop-in change that resolved has not applied yet is marked pending under
 * /run. A failed reload fails the oneshot, which systemd restarts, and every
 * later run retries the reload until one succeeds.
 */

/** The Freestyle TLS edge's IPv6 address: the forwarding resolver's second listener and the 443 grant's v6 leg. */
export const FREESTYLE_EDGE_IPV6 = "2602:f470:1::28";

/** The Freestyle TLS edge's IPv4 address, the only one the agent's resolver files name. */
export const FREESTYLE_EDGE_IPV4 = "10.32.0.28";

/** The first line of the resolv.conf the agent writes; any other resolv.conf is not ours to touch. */
export const FREESTYLE_TLS_RESOLV_HEADER = "# freestyle-tls forwarding resolver";

/** systemd-resolved's drop-in directory; files apply in lexical order. */
export const DEVBOX_RESOLVED_DROP_IN_DIR = "/etc/systemd/resolved.conf.d";

/** The Freestyle agent's TLS resolver drop-in. Ours must sort after it. */
export const FREESTYLE_TLS_RESOLVER_DROP_IN = "61-freestyle-tls.conf";

/** cmux's drop-in: right after the agent's, before anything a user adds at 70 or later. */
export const DEVBOX_RESOLVER_FALLBACK_DROP_IN = "62-cmux-edge-resolver-v6.conf";

export const DEVBOX_EDGE_RESOLVER_SCRIPT = "/usr/local/libexec/cmux-edge-resolver";
export const DEVBOX_EDGE_RESOLVER_SERVICE = "cmux-edge-resolver.service";
export const DEVBOX_EDGE_RESOLVER_PATH_UNIT = "cmux-edge-resolver.path";
/** Written by each successful run: a checksum of each resolver file as the run left it. */
export const DEVBOX_EDGE_RESOLVER_STAMP = "/run/cmux-edge-resolver.applied";

/** POSIX sh: prints one line per file, its cksum or `absent`. Shared by the script and the settle wait. */
const EDGE_STATE_FUNCTION = 'edge_state() { for f in "$@"; do if [ -e "$f" ]; then cksum < "$f"; else echo absent; fi; done; }';

/**
 * The script. POSIX sh, idempotent, exits 0 unless a write fails. The
 * `CMUX_*` variables exist for tests, which run it against a scratch tree
 * without systemd.
 */
export function devboxEdgeResolverScript(): string {
  return `#!/bin/sh
# cmux-edge-resolver (manaflow-ai/cmux#46670), from web/services/vms/images/dns.ts.
# Adds the Freestyle edge resolver's IPv6 listener wherever the Freestyle
# agent names only its IPv4 address. Run by ${DEVBOX_EDGE_RESOLVER_PATH_UNIT}.
set -u
V4=${FREESTYLE_EDGE_IPV4}
V6=${FREESTYLE_EDGE_IPV6}
RESOLV="\${CMUX_RESOLV_CONF:-/etc/resolv.conf}"
DIR="\${CMUX_RESOLVED_DROP_IN_DIR:-${DEVBOX_RESOLVED_DROP_IN_DIR}}"
AGENT="$DIR/${FREESTYLE_TLS_RESOLVER_DROP_IN}"
OURS="$DIR/${DEVBOX_RESOLVER_FALLBACK_DROP_IN}"
RELOAD="\${CMUX_RESOLVED_RELOAD:-systemctl try-reload-or-restart systemd-resolved}"
# Set while resolved has not yet applied a drop-in change; cleared only by a
# successful reload, so a failed reload is retried on every later run.
PENDING="\${CMUX_RESOLVED_RELOAD_PENDING:-/run/cmux-edge-resolver.reload-pending}"
STAMP="\${CMUX_EDGE_RESOLVER_STAMP:-${DEVBOX_EDGE_RESOLVER_STAMP}}"

# glibc reads the agent's resolv.conf directly. Put the IPv6 listener first,
# and give each try 2 s: the listener takes about 1.5 s per query, and at the
# agent's 1 s glibc abandons it before the answer arrives.
# Replace the file only while it still holds what was read: the agent can
# rewrite it during this run (the last TLS rule removed restores public DNS),
# and an edit of the older contents must never land over that newer write.
# On a change, start again from the new contents; after 5 tries exit 1 and
# let systemd run it again.
tries=0
while :; do
  rm -f "$RESOLV.cmux-src" "$RESOLV.cmux-tmp"
  [ -f "$RESOLV" ] && [ ! -L "$RESOLV" ] || break
  tries=$((tries + 1))
  [ "$tries" -le 5 ] || { echo "cmux-edge-resolver: $RESOLV kept changing; will retry" >&2; exit 1; }
  cp "$RESOLV" "$RESOLV.cmux-src" || exit 1
  grep -qxF '${FREESTYLE_TLS_RESOLV_HEADER}' "$RESOLV.cmux-src" &&
    grep -qxF "nameserver $V4" "$RESOLV.cmux-src" || break
  has6=0
  grep -qxF "nameserver $V6" "$RESOLV.cmux-src" && has6=1
  awk -v v4="nameserver $V4" -v v6="nameserver $V6" -v has6="$has6" '
    $1 == "options" { for (i = 2; i <= NF; i++) if ($i == "timeout:1") $i = "timeout:2" }
    $0 == v4 && has6 == 0 { print v6 }
    { print }' "$RESOLV.cmux-src" > "$RESOLV.cmux-tmp" || exit 1
  eval "\${CMUX_EDGE_RESOLVER_AFTER_READ:-}"
  cmp -s "$RESOLV.cmux-tmp" "$RESOLV.cmux-src" && break
  if cmp -s "$RESOLV.cmux-src" "$RESOLV"; then
    chmod 0644 "$RESOLV.cmux-tmp" && mv -f "$RESOLV.cmux-tmp" "$RESOLV" || exit 1
    break
  fi
done
rm -f "$RESOLV.cmux-src" "$RESOLV.cmux-tmp"

# resolved: the same resolver, IPv6 first, only while the agent's drop-in names it.
if [ -f "$AGENT" ] && grep -qxF "DNS=$V4" "$AGENT"; then
  if ! printf '%s\\n' '# Written by cmux-edge-resolver (manaflow-ai/cmux#46670).' '[Resolve]' 'DNS=' "DNS=$V6 $V4" | cmp -s - "$OURS"; then
    : > "$PENDING" || exit 1
    printf '%s\\n' '# Written by cmux-edge-resolver (manaflow-ai/cmux#46670).' '[Resolve]' 'DNS=' "DNS=$V6 $V4" > "$OURS.cmux-tmp" &&
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

# The completion signal: what the three files held when this run finished.
# The image verifier waits until it matches them (devboxEdgeResolverSettledCommand).
${EDGE_STATE_FUNCTION}
edge_state "$RESOLV" "$AGENT" "$OURS" > "$STAMP.cmux-tmp" && mv -f "$STAMP.cmux-tmp" "$STAMP" || exit 1
exit 0
`;
}

/** The oneshot the path unit starts; also runs at boot. Never rate-limited: the agent writes in bursts. */
export function devboxEdgeResolverServiceUnit(): string {
  return [
    "[Unit]",
    "Description=cmux: add the Freestyle edge resolver's IPv6 listener (manaflow-ai/cmux#46670)",
    "After=systemd-resolved.service",
    "StartLimitIntervalSec=0",
    "",
    "[Service]",
    "Type=oneshot",
    `ExecStart=${DEVBOX_EDGE_RESOLVER_SCRIPT}`,
    // A failed resolved reload exits 1 and stays pending; retry it.
    "Restart=on-failure",
    "RestartSec=10",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ].join("\n");
}

/** Fires the oneshot whenever the agent writes either resolver file. */
export function devboxEdgeResolverPathUnit(): string {
  return [
    "[Unit]",
    "Description=cmux: watch the Freestyle agent's resolver files (manaflow-ai/cmux#46670)",
    "",
    "[Path]",
    "PathChanged=/etc/resolv.conf",
    `PathChanged=${DEVBOX_RESOLVED_DROP_IN_DIR}/${FREESTYLE_TLS_RESOLVER_DROP_IN}`,
    `Unit=${DEVBOX_EDGE_RESOLVER_SERVICE}`,
    "",
    "[Install]",
    "WantedBy=paths.target",
    "",
  ].join("\n");
}

/** Shell that writes `contents` to `target` at `mode` (temp file and rename). */
function writeFileCommand(target: string, contents: string, mode: string): string {
  const lines = contents.replace(/\n$/, "").split("\n").map(shellQuote).join(" ");
  const tmp = shellQuote(`${target}.cmux-tmp`);
  return `printf '%s\\n' ${lines} > ${tmp} && chmod ${mode} ${tmp} && mv -f ${tmp} ${shellQuote(target)}`;
}

/**
 * Root shell that installs the script and both units, enables them, and runs
 * the script once. Idempotent; safe on a running machine (the bake runs it,
 * and an operator can run the same command on an existing machine through
 * the exec API).
 */
export function devboxEdgeResolverInstallCommand(): string {
  return [
    "mkdir -p /usr/local/libexec /etc/systemd/system",
    writeFileCommand(DEVBOX_EDGE_RESOLVER_SCRIPT, devboxEdgeResolverScript(), "0755"),
    `sh -n ${DEVBOX_EDGE_RESOLVER_SCRIPT}`,
    writeFileCommand(`/etc/systemd/system/${DEVBOX_EDGE_RESOLVER_SERVICE}`, devboxEdgeResolverServiceUnit(), "0644"),
    writeFileCommand(`/etc/systemd/system/${DEVBOX_EDGE_RESOLVER_PATH_UNIT}`, devboxEdgeResolverPathUnit(), "0644"),
    "systemctl daemon-reload",
    `systemctl enable ${DEVBOX_EDGE_RESOLVER_SERVICE} >/dev/null 2>&1`,
    `systemctl enable --now ${DEVBOX_EDGE_RESOLVER_PATH_UNIT} >/dev/null 2>&1`,
    `systemctl start ${DEVBOX_EDGE_RESOLVER_SERVICE}`,
  ].join(" && ");
}

/**
 * Proof on a machine, as root: the script and units are installed and armed,
 * and wherever the agent named only its IPv4 resolver, the IPv6 listener is
 * there too (in resolv.conf when it is the agent's, and in resolved's
 * global servers).
 */
export function devboxEdgeResolverCheckCommand(): string {
  const agentDropIn = `${DEVBOX_RESOLVED_DROP_IN_DIR}/${FREESTYLE_TLS_RESOLVER_DROP_IN}`;
  return [
    `test -x ${DEVBOX_EDGE_RESOLVER_SCRIPT}`,
    `systemctl is-enabled --quiet ${DEVBOX_EDGE_RESOLVER_SERVICE}`,
    `systemctl is-active --quiet ${DEVBOX_EDGE_RESOLVER_PATH_UNIT}`,
    `{ ! grep -qxF ${shellQuote(FREESTYLE_TLS_RESOLV_HEADER)} /etc/resolv.conf || grep -qxF 'nameserver ${FREESTYLE_EDGE_IPV6}' /etc/resolv.conf; }`,
    `{ [ ! -f ${agentDropIn} ] || resolvectl dns 2>/dev/null | grep -i '^Global:' | grep -qw '${FREESTYLE_EDGE_IPV6}'; }`,
    "echo edge-resolver-ipv6-ok",
  ].join(" && ");
}

/**
 * Root shell that waits, at most `timeoutSeconds`, until the agent has
 * written its TLS resolver files and cmux-edge-resolver has finished a run
 * over exactly those contents: the stamp its last successful run wrote
 * equals the files' checksums now. That is the service's own completion
 * signal, not a settling delay, so the TLS-rule check that follows reads
 * the state the service produced. Prints `edge-resolver-settled`, or exits 1
 * with `edge-resolver-not-settled` and both states.
 */
export function devboxEdgeResolverSettledCommand(timeoutSeconds: number): string {
  const agentDropIn = `${DEVBOX_RESOLVED_DROP_IN_DIR}/${FREESTYLE_TLS_RESOLVER_DROP_IN}`;
  const ours = `${DEVBOX_RESOLVED_DROP_IN_DIR}/${DEVBOX_RESOLVER_FALLBACK_DROP_IN}`;
  const files = `/etc/resolv.conf ${agentDropIn} ${ours}`;
  return [
    EDGE_STATE_FUNCTION,
    `deadline=$(($(date +%s) + ${Math.max(1, Math.floor(timeoutSeconds))}))`,
    `until [ -f ${agentDropIn} ] && grep -qxF ${shellQuote(FREESTYLE_TLS_RESOLV_HEADER)} /etc/resolv.conf && [ -f ${DEVBOX_EDGE_RESOLVER_STAMP} ] && [ "$(edge_state ${files})" = "$(cat ${DEVBOX_EDGE_RESOLVER_STAMP})" ]; do`,
    `  [ "$(date +%s)" -lt "$deadline" ] || { echo edge-resolver-not-settled; edge_state ${files}; cat ${DEVBOX_EDGE_RESOLVER_STAMP} 2>/dev/null; systemctl status --no-pager ${DEVBOX_EDGE_RESOLVER_SERVICE} 2>&1 | tail -5; exit 1; }`,
    "  sleep 0.2",
    "done",
    "echo edge-resolver-settled",
  ].join("\n");
}

/**
 * Proof on a machine that has a TLS rule for `steeredDomain`, as root: the
 * agent's files exist, the IPv6 listener comes first in both, and real
 * lookups answer through them (a public name, and the steered name resolving
 * to the edge, which proves steering still works). The image verifier runs it
 * after adding a TLS rule, because a machine created with a firewall alone
 * never gets the agent's files and would pass the plain check on its
 * "no agent file" branches.
 */
export function devboxEdgeResolverTlsCheckCommand(steeredDomain: string): string {
  const agentDropIn = `${DEVBOX_RESOLVED_DROP_IN_DIR}/${FREESTYLE_TLS_RESOLVER_DROP_IN}`;
  const ours = `${DEVBOX_RESOLVED_DROP_IN_DIR}/${DEVBOX_RESOLVER_FALLBACK_DROP_IN}`;
  return [
    `grep -qxF ${shellQuote(FREESTYLE_TLS_RESOLV_HEADER)} /etc/resolv.conf`,
    `test -f ${agentDropIn}`,
    `test -f ${ours}`,
    `[ "$(grep -m1 '^nameserver ' /etc/resolv.conf)" = 'nameserver ${FREESTYLE_EDGE_IPV6}' ]`,
    `grep -qxF 'nameserver ${FREESTYLE_EDGE_IPV4}' /etc/resolv.conf`,
    `[ "$(resolvectl dns 2>/dev/null | awk 'tolower($1) == "global:" { print $2 }')" = '${FREESTYLE_EDGE_IPV6}' ]`,
    "getent ahosts api.anthropic.com >/dev/null",
    `getent ahosts ${shellQuote(steeredDomain)} | grep -qE '^(${FREESTYLE_EDGE_IPV4.replaceAll(".", "\\.")}|${FREESTYLE_EDGE_IPV6})[[:space:]]'`,
    "echo edge-resolver-tls-rule-ok",
  ].join(" && ");
}
