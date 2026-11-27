/**
 * Metadata guard (bead cx-5hr2, discovered from cx-d0d.7): the cmux VM image
 * (web/scripts/cmux-vm-image/bake.ts) and the devbox image
 * (web/scripts/build-devbox-freestyle.ts) block the cloud metadata service for
 * every process but root.
 *
 * Freestyle VMs have a metadata service at 169.254.169.254 (Firecracker MMDS,
 * EC2-style token then GET). Its readers in the image all run as root: the
 * provider's guest agent, `cmux-devbox-boot` (the daemon unit's supervisor),
 * the VM agent (`cmux-vm-agent.service`) and `cmux host`. Agent terminals and
 * everything they start run as the work user (the daemon drops to it), and
 * containers go through the FORWARD hook. Concurrent readers stall the
 * service (vm-image.md 6.2), so an agent's loop would also hurt the bind.
 *
 * The rule: OUTPUT to a metadata address from a uid other than 0 is rejected
 * (a fast "administratively prohibited", not a timeout), and FORWARD to one is
 * rejected for everyone (no container needs it). The addresses also cover the
 * other clouds' services a migrated image could meet (AWS IPv6, Alibaba,
 * Azure), which the browser host also refuses (cmux-browser-host
 * policy/egress.rs).
 *
 * Not a boundary against the work user: it has passwordless sudo, so it can
 * remove the rule. It is a default block for agent shells and the processes
 * they start; the boundary for browsing is the browser host's own egress
 * listener (cmux-browser-host egress_scope.rs).
 *
 * The rule loads from a oneshot unit early at every boot (before the network)
 * and once during the bake, so the parked snapshot carries it live.
 */

/** IPv4 metadata services. */
export const METADATA_V4 = ["169.254.169.254", "100.100.100.200", "168.63.129.16"] as const;
/** IPv6 metadata services. */
export const METADATA_V6 = ["fd00:ec2::254"] as const;

export const METADATA_GUARD_FILE = "/etc/cmux/metadata-guard.nft";
export const METADATA_GUARD_UNIT = "cmux-metadata-guard.service";
export const METADATA_GUARD_TABLE = "cmux_metadata_guard";

/** The nftables ruleset (its own table; loading it again replaces it). */
export function metadataGuardRules(): string {
  const v4 = METADATA_V4.join(", ");
  const v6 = METADATA_V6.join(", ");
  return [
    "#!/usr/sbin/nft -f",
    "# cmux: block the cloud metadata service for every process but root. Managed, do not edit.",
    `table inet ${METADATA_GUARD_TABLE}`,
    `delete table inet ${METADATA_GUARD_TABLE}`,
    `table inet ${METADATA_GUARD_TABLE} {`,
    `  set metadata_v4 { type ipv4_addr; elements = { ${v4} } }`,
    `  set metadata_v6 { type ipv6_addr; elements = { ${v6} } }`,
    "  chain output {",
    "    type filter hook output priority filter; policy accept;",
    "    ip daddr @metadata_v4 meta skuid != 0 counter reject with icmpx admin-prohibited",
    "    ip6 daddr @metadata_v6 meta skuid != 0 counter reject with icmpx admin-prohibited",
    "  }",
    "  chain forward {",
    "    type filter hook forward priority filter; policy accept;",
    "    ip daddr @metadata_v4 counter reject with icmpx admin-prohibited",
    "    ip6 daddr @metadata_v6 counter reject with icmpx admin-prohibited",
    "  }",
    "}",
    "",
  ].join("\n");
}

/** The oneshot unit that loads the rule at every boot, before the network is up. */
export function metadataGuardUnit(): string {
  return [
    "[Unit]",
    "Description=cmux: block the cloud metadata service for non-root processes",
    "DefaultDependencies=no",
    "Before=network-pre.target",
    "Wants=network-pre.target",
    "After=local-fs.target",
    "",
    "[Service]",
    "Type=oneshot",
    "RemainAfterExit=yes",
    `ExecStart=/usr/sbin/nft -f ${METADATA_GUARD_FILE}`,
    "",
    "[Install]",
    "WantedBy=sysinit.target",
    "",
  ].join("\n");
}

/**
 * The bake step after the files are written: enable and load the rule now,
 * then prove it: a non-root process is refused at once, and root still reads
 * the instance id (the VM agent and the boot supervisor need it).
 */
export function metadataGuardEnableCommand(workUser: string): string {
  return [
    `nft -c -f ${METADATA_GUARD_FILE}`,
    "systemctl daemon-reload",
    `systemctl enable --quiet ${METADATA_GUARD_UNIT}`,
    `systemctl restart ${METADATA_GUARD_UNIT}`,
    `nft list table inet ${METADATA_GUARD_TABLE} >/dev/null`,
    metadataGuardCheckCommand(workUser),
  ].join(" && ");
}

/**
 * Prints `user_blocked=<yes|no>` and `root_reads=<yes|no>`; fails unless the
 * user is blocked and root still reads the instance id.
 */
export function metadataGuardCheckCommand(workUser: string): string {
  const token = `curl -sf -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-metadata-token-ttl-seconds: 60'`;
  return [
    `if runuser -u ${workUser} -- ${token} >/dev/null 2>&1; then echo user_blocked=no; else echo user_blocked=yes; fi`,
    `if t=$(${token}) && curl -sf -m 2 -H "X-aws-ec2-metadata-token: $t" http://169.254.169.254/latest/meta-data/instance-id >/dev/null; then echo root_reads=yes; else echo root_reads=no; fi`,
  ].join("; ") + "; true";
}

/** Problems in the check's output (empty: the guard works). */
export function metadataGuardProblems(output: string): string[] {
  const problems: string[] = [];
  if (!/^user_blocked=yes$/m.test(output)) problems.push("a non-root process still reaches the metadata service");
  if (!/^root_reads=yes$/m.test(output)) problems.push("root no longer reads the metadata service (the VM agent and the boot supervisor need it)");
  return problems;
}
