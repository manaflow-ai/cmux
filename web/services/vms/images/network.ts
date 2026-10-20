/**
 * The private-network announce: one gratuitous ARP burst from every global
 * IPv4 address the machine holds on a real interface.
 *
 * A machine is reachable from its owner's Mac through the provider's VPC
 * fabric only after the fabric has seen a frame FROM the machine's VPC
 * interface. Measured on Freestyle (2026-09-10): a fresh clone's daemon was
 * listening within one second of create, yet every SYN the Mac's WireGuard
 * hub sent to it for 150 seconds vanished, and a tcpdump on the guest's VPC
 * VLAN interface saw nothing at all, not even the gateway's ARP. Three
 * unsolicited ARPs from the guest made the same address answer within one
 * second. A memory-snapshot clone resumes with its VPC interface already
 * configured, so nothing (no DHCP, no duplicate-address probe) ever
 * transmits on it, and the fabric never learns the clone's MAC until a
 * process inside the guest happens to send something.
 *
 * So the guest announces itself: at boot and on every clone (the boot
 * supervisor, cmux-devbox-boot, keeps announcing every 30 s so an idle
 * machine cannot age out of the fabric's table either). The attach path has
 * its own announce (drivers/freestyleNetworkAnnouncement.ts), which covers
 * machines from an image that predates the supervisor hook.
 *
 * The command is POSIX sh, runs as root (arping needs CAP_NET_RAW), never
 * fails (a missing arping or a machine with no global address is a no-op),
 * and skips container and bridge interfaces, whose addresses are not on the
 * VPC, and the provider's link-local 169.254 leg, which is not a fabric port.
 * Two unsolicited probes a second apart cover a lost broadcast; every
 * interface announces concurrently, so the whole command takes about two
 * seconds however many addresses the machine holds (unsolicited probes get
 * no reply, so arping always runs to its deadline).
 */
export function devboxNetworkAnnounceCommand(): string {
  return (
    "command -v arping >/dev/null 2>&1 && ip -o -4 addr show scope global 2>/dev/null" +
    // The loop body runs in the pipeline's subshell, so the wait must too:
    // outside the braces it would return at once and leave the probes to a
    // process tree the caller may already be tearing down.
    " | { while read -r _ dev _ cidr _; do" +
    ' case "$dev" in lo|docker*|veth*|br-*|virbr*) continue;; esac;' +
    ' case "$cidr" in 169.254.*) continue;; esac;' +
    ' arping -U -c 2 -w 2 -I "$dev" "${cidr%/*}" >/dev/null 2>&1 &' +
    " done; wait; }; true"
  );
}
