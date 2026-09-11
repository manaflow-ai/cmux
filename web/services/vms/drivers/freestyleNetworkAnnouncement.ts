import { Effect } from "effect";
import type { Vm } from "freestyle";
import { isIP } from "node:net";
import { shellQuote } from "./cmuxTuiDaemon";
import { ProviderError } from "./types";

/**
 * A resumed snapshot can acquire a VPC address before the provider learns its
 * link-layer mapping. Announce only addresses actually assigned to this guest:
 * one gratuitous ARP for IPv4 and one unsolicited neighbor advertisement for
 * IPv6. One available family is sufficient; clients retain their address race.
 * No routes, firewall rules, interfaces, or running sessions are changed.
 */
export function freestyleNetworkAnnouncementCommand(addresses: readonly string[]): string {
  const script = `import ipaddress,json,socket,struct,subprocess,sys
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
  return `python3 -c ${shellQuote(script)} ${shellQuote(JSON.stringify(addresses))}`;
}

/**
 * The shared private-address setup every lifecycle path runs. It fails closed:
 * a machine with no usable address has no route to its daemon or its ports.
 * Create, restore, and attach surface that failure; a wake reports it without
 * failing, having nothing to roll back (see FreestyleProvider.resume).
 */
export function announceFreestyleNetwork(vm: Pick<Vm, "exec">, addresses: readonly string[]) {
  const valid = [...new Set(addresses.filter((address) => isIP(address) !== 0))];
  if (valid.length === 0) {
    return Effect.fail(new ProviderError("freestyle", "Private network has no valid assigned address"));
  }
  return Effect.tryPromise({
    try: () => vm.exec({ command: freestyleNetworkAnnouncementCommand(valid), linuxUser: "root", timeoutMs: 5_000 }),
    catch: (cause) => new ProviderError("freestyle", "announce private network", cause),
  }).pipe(Effect.flatMap((result) => result.statusCode === 0
    ? Effect.void
    : Effect.fail(new ProviderError("freestyle", "Private network announcement failed", result.stderr))));
}
