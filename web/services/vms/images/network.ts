import { shellQuote } from "../drivers/cmuxTuiDaemon";

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
 * The command is POSIX sh, runs as root (arping and raw sockets need
 * CAP_NET_RAW), never fails (a missing arping or python3, or a machine with
 * no global address, is a no-op), and skips container and bridge interfaces,
 * whose addresses are not on the VPC, and the provider's link-local 169.254
 * leg, which is not a fabric port. Two unsolicited probes a second apart
 * cover a lost broadcast; every interface announces concurrently, so the
 * whole command takes about two seconds however many addresses the machine
 * holds (unsolicited probes get no reply, so arping always runs to its
 * deadline). The IPv6 half (one neighbor advertisement per global address)
 * runs after it and takes a few milliseconds.
 */
/**
 * The unsolicited announcement itself, for the addresses named in argv[1] (a
 * JSON array): one gratuitous ARP per IPv4, one unsolicited neighbor
 * advertisement per IPv6, from the UP ethernet link that holds the address,
 * over raw sockets (root). Exits non-zero when nothing was announced. One
 * implementation: the attach path runs it with the addresses the provider
 * assigned (drivers/freestyleNetworkAnnouncement.ts), the boot supervisor
 * with the global IPv6 addresses it finds on the machine.
 */
export const PRIVATE_NETWORK_ANNOUNCE_SCRIPT = `import ipaddress,json,socket,struct,subprocess,sys
expected = {ipaddress.ip_address(value) for value in json.loads(sys.argv[1])}
links = json.loads(subprocess.check_output(['ip', '-j', 'address', 'show'], timeout=3))
announced = set()
for link in links:
    if link.get('link_type') != 'ether' or 'UP' not in link.get('flags', []):
        continue
    mac = bytes.fromhex(link['address'].replace(':', ''))
    for address in link.get('addr_info', []):
        ip = ipaddress.ip_address(address['local'])
        if ip not in expected or ip in announced:
            continue
        try:
            if ip.version == 4:
                packet = b'\\xff'*6 + mac + struct.pack('!HHHBBH', 0x0806, 1, 0x0800, 6, 4, 1)
                packet += mac + ip.packed + b'\\x00'*6 + ip.packed
                with socket.socket(socket.AF_PACKET, socket.SOCK_RAW) as stream:
                    stream.bind((link['ifname'], 0))
                    stream.send(packet)
            else:
                index = link['ifindex']
                packet = struct.pack('!BBHI', 136, 0, 0, 0x20000000) + ip.packed + bytes([2, 1]) + mac
                with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as stream:
                    stream.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
                    stream.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
                    stream.bind((str(ip), 0, 0, index))
                    stream.sendto(packet, ('ff02::1', 0, 0, index))
        except OSError:
            continue
        announced.add(ip)
if not announced:
    raise SystemExit('Private network addresses are not ready on the guest')
`;

/**
 * IPv4: the arping burst described above. IPv6, when python3 is present
 * (every devbox image; the guard keeps a container without it a no-op): one
 * unsolicited neighbor advertisement per global IPv6 address on a real
 * interface, sent by PRIVATE_NETWORK_ANNOUNCE_SCRIPT. A private Freestyle
 * network can assign either family and the Mac dials whichever answers, and
 * the fabric learns an IPv6 neighbor the way it learns an IPv4 one: only
 * from a frame the guest sends.
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
    " done; wait; };" +
    " command -v python3 >/dev/null 2>&1 && ip -o -6 addr show scope global 2>/dev/null" +
    ' | { list=""; while read -r _ dev _ cidr _; do' +
    ' case "$dev" in lo|docker*|veth*|br-*|virbr*) continue;; esac;' +
    ' list="${list:+$list,}\\"${cidr%/*}\\"";' +
    ` done; [ -n "$list" ] && python3 -c ${shellQuote(PRIVATE_NETWORK_ANNOUNCE_SCRIPT)} "[$list]" >/dev/null 2>&1; }; true`
  );
}
