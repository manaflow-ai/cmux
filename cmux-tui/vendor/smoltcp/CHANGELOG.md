# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- None yet!

## [0.14.0] - 2026-08-07

- wire: Expose the `checksum` module publicly, so downstream crates can compute RFC 1071 Internet checksums over discontiguous buffers. ([#1172](https://github.com/smoltcp-rs/smoltcp/pull/1172))
- tcp: don't rate-limit ACKs for out-of-window data segments. ([#1162](https://github.com/smoltcp-rs/smoltcp/pull/1162))
- tcp: more rfc-compliant out-of-window rx handling. ([#1164](https://github.com/smoltcp-rs/smoltcp/pull/1164))
- tcp: better handling of MSS ([#1161](https://github.com/smoltcp-rs/smoltcp/pull/1161))
- tcp: congestion control api redesign to better support loss-based algorithms ([#1154](https://github.com/smoltcp-rs/smoltcp/pull/1154))
- tcp: make reno RFC compliant ([#1156](https://github.com/smoltcp-rs/smoltcp/pull/1156))
- tcp: make CUBIC RFC compliant ([#1157](https://github.com/smoltcp-rs/smoltcp/pull/1157))
- tcp: fast retransmit improvements ([#1155](https://github.com/smoltcp-rs/smoltcp/pull/1155))
- Implement core::error::Error for errors ([#1175](https://github.com/smoltcp-rs/smoltcp/pull/1175))
- ip: Optimize the internet checksum calculation ([#1176](https://github.com/smoltcp-rs/smoltcp/pull/1176))
- Upgrade `defmt` to version 1
- tcp: add single-pass zero-allocation TcpOptionSummary parser ([#1194](https://github.com/smoltcp-rs/smoltcp/pull/1194))
- phy: add TCP segmentation offload support ([#1148](https://github.com/smoltcp-rs/smoltcp/pull/1148))

## [0.13.1] - 2026-05-01

- tcp: Fix panic when a listening socket receives a SYN from the unspecified addr.
- tcp: fix SACK sequence number overflow, which could cause a panic when compiling with overflow checks enabled.
- ipv4: Check IPv4 IHL to be at least 20 bytes.

## [0.13.0] - 2026-03-20

Highlights of this release are IPv6 SLAAC support, TCP improvements (zero window probes, retransmit fixes, RFC compliance), raw socket enhancements, and a bump to Rust Edition 2024.

- Minimum Supported Rust Version (MSRV) bumped to 1.91.
- Rust Edition bumped to 2024. ([#1084](https://github.com/smoltcp-rs/smoltcp/pull/1084))
- `heapless` dependency bumped to v0.9. ([#1083](https://github.com/smoltcp-rs/smoltcp/pull/1083))
- iface
    - IPv6 SLAAC (Stateless Address Autoconfiguration), gated behind a new `slaac` feature flag. ([#1039](https://github.com/smoltcp-rs/smoltcp/pull/1039))
    - Add `slaac_updated_at` method to check when SLAAC addresses were last updated. ([#1130](https://github.com/smoltcp-rs/smoltcp/pull/1130))
    - Add getters for the default IPv4/IPv6 route and `is_ipv4_gateway`/`is_ipv6_gateway` helpers. ([#1129](https://github.com/smoltcp-rs/smoltcp/pull/1129))
    - Exhaust egress socket state on `poll`, so sockets don't have to wait for the next poll to send queued data. ([#1059](https://github.com/smoltcp-rs/smoltcp/pull/1059))
    - Remove always-Ok `Result`s in `consume()`. ([#1093](https://github.com/smoltcp-rs/smoltcp/pull/1093))
    - Honor `any_ip` when checking local address. ([#1119](https://github.com/smoltcp-rs/smoltcp/pull/1119))
    - Add `iface_max_route_count-0` feature flag to disable the routing table entirely. ([#1057](https://github.com/smoltcp-rs/smoltcp/pull/1057))
    - Improve IPv4 source address selection for multi-subnet interfaces. ([#1074](https://github.com/smoltcp-rs/smoltcp/pull/1074))
    - Fix `poll_at` returning stale timestamps due to `silent_until` expiry check. ([#1127](https://github.com/smoltcp-rs/smoltcp/pull/1127))
    - Fix fragment payload sizes not being a multiple of eight octets. ([#1116](https://github.com/smoltcp-rs/smoltcp/pull/1116))
    - Fix incorrect packet length after defragmentation. ([#1094](https://github.com/smoltcp-rs/smoltcp/pull/1094))
    - Fix compilation of IPv6+Multicast without Ethernet. ([#1043](https://github.com/smoltcp-rs/smoltcp/pull/1043))
    - Log and drop IPv6 packets requiring fragmentation (IPv6 routers must not fragment). ([#1038](https://github.com/smoltcp-rs/smoltcp/pull/1038))
- tcp
    - Add zero window probe support. ([#1026](https://github.com/smoltcp-rs/smoltcp/pull/1026))
    - Close socket if the local IP is no longer assigned to the interface. ([#1113](https://github.com/smoltcp-rs/smoltcp/pull/1113))
    - Reject bytes outside the receive window. ([#1079](https://github.com/smoltcp-rs/smoltcp/pull/1079))
    - Don't accept RST packets on listening sockets. ([#1058](https://github.com/smoltcp-rs/smoltcp/pull/1058))
    - Don't send TCP RST when packet is handled by a raw socket. ([#1069](https://github.com/smoltcp-rs/smoltcp/pull/1069))
    - Send challenge ACK for duplicate ACK in LAST-ACK state. ([#1126](https://github.com/smoltcp-rs/smoltcp/pull/1126))
    - Fix retransmit exponential backoff, align to RFC 6298. ([#1023](https://github.com/smoltcp-rs/smoltcp/pull/1023))
    - Restart retransmit timer on new data ACK. ([#1018](https://github.com/smoltcp-rs/smoltcp/pull/1018))
    - Fix FIN retransmit in CLOSING state. ([#1026](https://github.com/smoltcp-rs/smoltcp/pull/1026))
    - Add `pause_synack` feature flag to allow user code to withhold SYN|ACK. ([#1063](https://github.com/smoltcp-rs/smoltcp/pull/1063))
- socket
    - ICMP: support binding to a TCP port. ([#1089](https://github.com/smoltcp-rs/smoltcp/pull/1089))
    - ICMP: add `no-auto-icmp-echo-reply` feature flag to disable automatic echo replies. ([#1106](https://github.com/smoltcp-rs/smoltcp/pull/1106))
    - Raw: allow receiving all protocols and IP versions (unfiltered mode). ([#1067](https://github.com/smoltcp-rs/smoltcp/pull/1067))
    - Raw: fix panic when payload buffer exceeds packet size during fragmentation. ([#1077](https://github.com/smoltcp-rs/smoltcp/pull/1077))
    - DHCPv4: reuse DHCPOFFER transaction ID in DHCPREQUEST. ([#1061](https://github.com/smoltcp-rs/smoltcp/pull/1061))
    - DHCPv4: fix panic when T1 < T2 < lease duration is not respected by server. ([#1029](https://github.com/smoltcp-rs/smoltcp/pull/1029))
    - DNS: fix compilation when `socket-dns` is enabled but `socket-udp` isn't. ([#1041](https://github.com/smoltcp-rs/smoltcp/pull/1041))
    - Implement `AnySocket` for the `Socket` enum. ([#1092](https://github.com/smoltcp-rs/smoltcp/pull/1092))
- phy
    - `Tracer`: update public API to allow custom inspection and printing of packets. ([#1076](https://github.com/smoltcp-rs/smoltcp/pull/1076))
    - `TunTapInterface`: no longer automatically enables `medium-ethernet` feature. ([#1055](https://github.com/smoltcp-rs/smoltcp/pull/1055))
- wire
    - Add generic IPv4/IPv6 packet parsing support to `IpRepr`. ([#1087](https://github.com/smoltcp-rs/smoltcp/pull/1087))
    - Make `Cidr` initialization `const`. ([#1036](https://github.com/smoltcp-rs/smoltcp/pull/1036))
    - Add conversion from `Endpoint` into `SocketAddr`. ([#1124](https://github.com/smoltcp-rs/smoltcp/pull/1124))
    - Use newly stable IP methods from `core::net`. ([#1115](https://github.com/smoltcp-rs/smoltcp/pull/1115))
    - Fix `RawHardwareAddress` panic when parsing to specific link-layer address. ([#1027](https://github.com/smoltcp-rs/smoltcp/pull/1027))
    - Fix multicast panic when `max_resp_code` is zero. ([#1047](https://github.com/smoltcp-rs/smoltcp/pull/1047))
    - Fix partial checksum in tcpdump/pcap. ([#1015](https://github.com/smoltcp-rs/smoltcp/pull/1015))

## [0.12.0] - 2024-11-28

Almost a year in the making, the highlights of the release are the migration to `core::net` IP types, IPv6 multicast, TCP improvements, and many fixes. Smoltcp now connects your gadgets to the Internet better than ever.

- Minimum Supported Rust Version (MSRV) bumped to 1.80.
- iface
    - IPv6 multicast ([#914](https://github.com/smoltcp-rs/smoltcp/pull/914), [#976](https://github.com/smoltcp-rs/smoltcp/pull/976), [#988](https://github.com/smoltcp-rs/smoltcp/pull/988), [#1009](https://github.com/smoltcp-rs/smoltcp/pull/1009), [#1012](https://github.com/smoltcp-rs/smoltcp/pull/1012))
    - Add `poll_egress()` and `poll_ingress_single()` methods for finer-grained control of what and how many packets are processed. ([#954](https://github.com/smoltcp-rs/smoltcp/pull/954), [#991](https://github.com/smoltcp-rs/smoltcp/pull/991), [#993](https://github.com/smoltcp-rs/smoltcp/pull/993))
    - Multicast join/leave no longer requires access to device+timestamp. ([#985](https://github.com/smoltcp-rs/smoltcp/pull/985))
    - Reset expiry of entries in the neighbor cache on packet reception ([#966](https://github.com/smoltcp-rs/smoltcp/pull/966))
    - Honor `any_ip` for ARP ([#880](https://github.com/smoltcp-rs/smoltcp/pull/880))
    - Honor `any_ip` for IPv6 ([#900](https://github.com/smoltcp-rs/smoltcp/pull/900))
    - Use own source address for ARP and NDISC Solicitations ([#984](https://github.com/smoltcp-rs/smoltcp/pull/984))
    - fix panic when discarding HBH Option with multicast destination address ([#996](https://github.com/smoltcp-rs/smoltcp/pull/996))
    - fix panic with 6lowpan frag datagram_size < 40 ([#997](https://github.com/smoltcp-rs/smoltcp/pull/997))
    - fix panic if no suitable IPv6 src_addr is found ([#895](https://github.com/smoltcp-rs/smoltcp/pull/895))
    - Fix specific length IP packets not being fragmented ([#1008](https://github.com/smoltcp-rs/smoltcp/pull/1008))
- tcp
    - Add support for congestion control ([#907](https://github.com/smoltcp-rs/smoltcp/pull/907))
    - Add support for simultaneous open ([#1001](https://github.com/smoltcp-rs/smoltcp/pull/1001))
    - Add support for Timestamp option ([#939](https://github.com/smoltcp-rs/smoltcp/pull/939))
    - Send immediate ACKs after RMSS bytes of data ([#1002](https://github.com/smoltcp-rs/smoltcp/pull/1002))
    - Do not ignore FIN if segment is partially outside the window. ([#977](https://github.com/smoltcp-rs/smoltcp/pull/977))
    - Correctly set internal sACK flag for client sockets ([#995](https://github.com/smoltcp-rs/smoltcp/pull/995))
    - Only reset remote_last_ts if some data is enqueued ([#917](https://github.com/smoltcp-rs/smoltcp/pull/917))
    - Don't delay ACKs for significant window updates ([#935](https://github.com/smoltcp-rs/smoltcp/pull/935))
    - Add `listen_endpoint` getter ([#1005](https://github.com/smoltcp-rs/smoltcp/pull/1005))
- socket
    - UDP,ICMP,raw: Add `send_queue`/`recv_queue` ([#1003](https://github.com/smoltcp-rs/smoltcp/pull/1003))
    - ICMP: split ICMPv4/v6 accept and process ([#887](https://github.com/smoltcp-rs/smoltcp/pull/887))
    - UDP: Store local and use local address in metadata ([#904](https://github.com/smoltcp-rs/smoltcp/pull/904))
    - DNS: fix panic if server list is too long ([#986](https://github.com/smoltcp-rs/smoltcp/pull/986))
    - DNS: fix panic if no valid source address is found ([#987](https://github.com/smoltcp-rs/smoltcp/pull/987))
- phy
    - Change mutability of `RxToken`'s `consume` argument. ([#924](https://github.com/smoltcp-rs/smoltcp/pull/924))
    - Add support for NetBSD ([#883](https://github.com/smoltcp-rs/smoltcp/pull/883))
    - Add minimum support for iOS ([#896](https://github.com/smoltcp-rs/smoltcp/pull/896))
    - Add BPF support for FreeBSD ([#906](https://github.com/smoltcp-rs/smoltcp/pull/906))
    - disable checksums on loopback ([#919](https://github.com/smoltcp-rs/smoltcp/pull/919))
- wire
    - Use core::net types for IP addresses. ([#937](https://github.com/smoltcp-rs/smoltcp/pull/937), [#994](https://github.com/smoltcp-rs/smoltcp/pull/994))
    - Add missing exports in wire for DNS ([#891](https://github.com/smoltcp-rs/smoltcp/pull/891))
    - rename Scope to MulticastScope ([#898](https://github.com/smoltcp-rs/smoltcp/pull/898))
    - Re-export `dhcpv4::Flags` and `dhcpv4::OpCode` ([#901](https://github.com/smoltcp-rs/smoltcp/pull/901))
    - Make Address:v6() constructor const ([#975](https://github.com/smoltcp-rs/smoltcp/pull/975))
    - Ipv6RoutingHeader::clear_reserved: fix offsets for Type 2 routing headers. ([#882](https://github.com/smoltcp-rs/smoltcp/pull/882))

## [0.11.0] - 2023-12-23

### Additions

- wire/ipsec: add basic IPsec parsing/emitting ([#821](https://github.com/smoltcp-rs/smoltcp/pull/821)).
- phy: add support for `TUNSETIFF` on MIPS, PPC and SPARC ([#839](https://github.com/smoltcp-rs/smoltcp/pull/839)).
- socket/tcp: accept FIN on zero window ([#845](https://github.com/smoltcp-rs/smoltcp/pull/845)).
- wire/ipv6: add `is_unique_local()` to IPv6 addresses ([#862](https://github.com/smoltcp-rs/smoltcp/pull/862)).
- wire/ipv6: add `is_global_unicast()` to IPv6 addresses ([#864](https://github.com/smoltcp-rs/smoltcp/pull/864)).
- iface/neigh: add `fill_with_expiration` ([#871](https://github.com/smoltcp-rs/smoltcp/pull/871)).

### Fixes

- icmpv6: truncate packet to MTU ([#807](https://github.com/smoltcp-rs/smoltcp/pull/807), [#808](https://github.com/smoltcp-rs/smoltcp/pull/810)).
- wire/rpl: DAO-ACK DODAG ID was wrongly read ([#824](https://github.com/smoltcp-rs/smoltcp/pull/824)).
- socket/tcp: don't panic when calling `listen` again on the same local endpoint ([#841](https://github.com/smoltcp-rs/smoltcp/pull/841)).
- wire/dhcpv4: don't panic when parsing addresses with incorrect amount of bytes ([#843](https://github.com/smoltcp-rs/smoltcp/pull/843)).
- iface/ndisc: prevent ndisc when the medium is IP ([#865](https://github.com/smoltcp-rs/smoltcp/pull/865)).
- wire/ieee802154: better parsing of security fields. Correctly parse frame type (3 bits instead of 2 bits) ([#868](https://github.com/smoltcp-rs/smoltcp/pull/864)).
- wire/ieee802154: better handle address fields for new frame version ([#870](https://github.com/smoltcp-rs/smoltcp/pull/870)).
- iface/tcp: don't send TCP RST with unspecified addresses ([#867](https://github.com/smoltcp-rs/smoltcp/pull/867)).
- iface: don't handle empty packets (this would panic when reading the IP version) ([#866](https://github.com/smoltcp-rs/smoltcp/pull/866)).
- socket/dhcp: Add an upper bound to the renew/rebind timeout in `RetryConfig` ([#835](https://github.com/smoltcp-rs/smoltcp/pull/835)).

### Changes

- iface: rewrite `IpPacket` such that IPv6 packets can contain owned extension headers ([#802](https://github.com/smoltcp-rs/smoltcp/pull/802)).
- iface: remove generic `T: [u8]` in functions. This reduced the server example by 10KB ([#810](https://github.com/smoltcp-rs/smoltcp/pull/810)).
- SocketSet: add comment about using static lifetime for SocketSets with owned storage ([#813](https://github.com/smoltcp-rs/smoltcp/pull/813)).
- phy/RawSocket: open raw socket with `O_NONBLOCK` ([#817](https://github.com/smoltcp-rs/smoltcp/pull/817)).
- tests/rstest: use rstest for fixture based testing ([#823](https://github.com/smoltcp-rs/smoltcp/pull/823)).
- docs/readme: update readme about IEEE802.15.4 and 6LoWPAN ([#826](https://github.com/smoltcp-rs/smoltcp/pull/826)).
- wire/ipv6-hbh: IPv6 HBH has owned options instead of references ([#827](https://github.com/smoltcp-rs/smoltcp/pull/827)).
- wire/sixlowpan: 6LoWPAN is split into multiple modules ([#828](https://github.com/smoltcp-rs/smoltcp/pull/828)).
- sockets: match the behaviour of `peek_slice` and `recv_slice` ([#834](https://github.com/smoltcp-rs/smoltcp/pull/834)).
- dependencies: update to headpless v0.8 ([#853](https://github.com/smoltcp-rs/smoltcp/pull/853)).
- config: make `config` constants public ([#855](https://github.com/smoltcp-rs/smoltcp/pull/855)).
- phy/ieee802154: clarify `mtu+=2` for IEEE802.15.4 ([#857](https://github.com/smoltcp-rs/smoltcp/pull/857)).
- sockets: `recv_slice` returns `RcvError::Truncated` when the length of the slice is smaller than the data received by the socket ([#859](https://github.com/smoltcp-rs/smoltcp/pull/859)).
- iface/ipv6: `get_source_address` uses [RFC 6724](https://www.rfc-editor.org/rfc/rfc6724) for address selection ([#864](https://github.com/smoltcp-rs/smoltcp/pull/864)).
- pcap: use IEEE 802.15.4 without FCS for PCAP link types ([#874](https://github.com/smoltcp-rs/smoltcp/pull/874)).
- iface: rename `IpPacket`/`Ipv4Packet`/`Ipv6Packet` to `Pacet`/`PacketV4`/`PacketV4`. This is to remove the ambiguity with `IpPacket` in `src/wire/` ([#873](https://github.com/smoltcp-rs/smoltcp/pull/873)).
- wire/ndisc: rewrite parse function (3.1KiB -> 1.9KiB) ([#878](https://github.com/smoltcp-rs/smoltcp/pull/878))
- iface: Check IPv6 address after processing HBH ([#861](https://github.com/smoltcp-rs/smoltcp/pull/861))

## [0.10.0] - 2023-06-26

- Add optional packet metadata. Allows tracking packets by ID across the whole stack, between the `Device` impl and sockets. One application is timestamping packets with the PHY's collaboration, allowing implementing PTP (#628)
- Work-in-progress implementation of RPL (Routing Protocol for Low-Power and Lossy Networks), commonly used for IEEE 802.15.4 / 6LoWPAN networks. Wire is mostly complete, full functionality will be in 0.11 hopefully! (#627, #766, #767, #772, #773, #777, #790, #798, #804)
- dhcp: Add support for rebinding (#744)

- iface:
    - add support for sending to subnet-local broadcast addrs (like 192.168.1.255). (#801)
    - Creating an interface requires passing in the time. (#799)
    - fix wrong payload length of first IPv4 fragment (#791, #792)
    - Don't discard from unspecified IPv4 src addresses (#787)

- tcp:
    - do not count window updates as duplicate acks. (#748)
    - consider segments partially overlapping the window as acceptable (#749)
    - Perform a reset() after an abort() (#788)

- 6lowpan:
    - Hop-by-Hop Header compression (#765)
    - Routing Header compression (#770)

- wire:
    - reexport DNS opcode, rcode, flag. (#763, #806)
    - refactor IPv6 Extension Headers to make them more consistent and easier to parse. (#781)
    - check length field of NDISC redirected head (#784)

- Modify `hardware_addr` and `neighbor_cache` to be not `Option`, add `HardwareAddress::Ip` (#745)
- Add file descriptor support for tuntap devices, needed for the Android VPN API. (#776)
- implement Display and Error for error types (#750, #756, #757)
- Better defmt for Instant, Duration and Ipv6Address (#754, #758)
- Add Hash trait for enum_with_unknown macro (#755)

## [0.9.1] - 2023-02-08

- iface: make MulticastError public. (#747)
- Fix parsing of ieee802154 link layer address for NDISC options (#746)

## [0.9.0] - 2023-02-06

- Minimum Supported Rust Version (MSRV) **bumped** from 1.56 to 1.65
- Added DNS client support.
    - Add DnsSocket (#465)
    - Add support for one-shot mDNS resolution (#669)
- Added support for packet fragmentation and reassembly, both for IPv4 and 6LoWPAN. (#591, #580, #624, #634, #645, #653, #684)
- Major error handling overhaul.
    - Previously, _smoltcp_ had a single `Error` enum that all methods returned. Now methods that can fail have their own error enums, with only the actual errors they can return. (#617, #667, #730)
    - Consuming `phy::Device` tokens is now infallible.
        - In the case of "buffer full", `phy::Device` implementations must return `None` from the `transmit`/`receive` methods. (Previously, they could either do that, or return tokens and then return `Error::Exhausted` when consuming them. The latter wasted computation since it'd make _smoltcp_ pointlessly spend effort preparing the packet, and is now disallowed).
        - For all other phy errors, `phy::Device` implementations should drop the packet and handle the error themselves. (Either log it and forget it, or buffer/count it and offer methods to let the user retrieve the error queue/counts.) Returning the error to have it bubble up to `Interface::poll()` is no longer supported.
- phy: the `trait Device` now uses Generic Associated Types (GAT) for the TX and RX tokens. The main impact of this is `Device` impls can now borrow data (because previously, the`for<'a> T: Device<'a>` bounds required to workaround the lack of GATs essentially implied `T: 'static`.) (#572)
- iface: The `Interface` API has been significantly simplified and cleaned up.
    - The builder has been removed (#736)
    - SocketSet and Device are now borrowed in methods that need them, instead of owning them. (#619)
    - `Interface` now owns the list of addresses (#719), routes, neighbor cache (#722), 6LoWPAN address contexts, and fragmentation buffers (#736) instead of borrowing them with `managed`.
    - A new compile-time configuration mechanism has been added, to configure the size of the (now owned) buffers (#742)
- iface: Change neighbor discovery timeout from 3s to 1s, to match Linux's behavior. (#620)
- iface: Remove implicit sized bound on device generics (#679)
- iface/6lowpan: Add address context information for resolving 6LoWPAN addresses (#687)
- iface/6lowpan: fix incorrect SAM value in IPHC when address is not compressed (#630)
- iface/6lowpan: packet parsing fuzz fixes (#636)
- socket: Add send_with to udp, raw, and icmp sockets. These methods enable reserving a packet buffer with a greater size than you need, and then shrinking the size once you know it. (#625)
- socket: Make `trait AnySocket` object-safe (#718)
- socket/dhcpv4: add waker support (#623)
- socket/dhcpv4: indicate new config if there's a packet buffer provided (#685)
- socket/dhcpv4: Use renewal time from DHCP server ACK, if given (#683)
- socket/dhcpv4: allow for extra configuration
    - setting arbitrary options in the request. (#650)
    - retrieving arbitrary options from the response. (#650)
    - setting custom parameter request list. (#650)
    - setting custom timing for retries. (#650)
    - Allow specifying different server/client DHCP ports (#738)
- socket/raw: Add `peek` and `peek_slice` methods (#734)
- socket/raw: When sending packets, send the source IP address unmodified (it was previously replaced with the interface's address if it was unspecified). (#616)
- socket/tcp: Do not reset socket-level settings, such as keepalive, on reset (#603)
- socket/tcp: ensure we always accept the segment at offset=0 even if the assembler is full. (#735, #452)
- socket/tcp: Refactored assembler, now more robust and faster (#726, #735)
- socket/udp: accept packets with checksum field set to `0`, since that means the checksum is not computed (#632)
- wire: make many functions const (#693)
- wire/dhcpv4: remove Option enum (#656)
- wire/dhcpv4: use heapless Vec for DNS server list (#678)
- wire/icmpv4: add support for TimeExceeded packets (#609)
- wire/ip: Remove `IpRepr::Unspecified`, `IpVersion::Unspecified`, `IpAddress::Unspecified` (#579, #616)
- wire/ip: support parsing unspecified IPv6 IpEndpoints from string (like `[::]:12345`) (#732)
- wire/ipv6: Make Public Ipv6RoutingType (#691)
- wire/ndisc: do not error on unrecognized options. (#737)
- Switch to Rust 2021 edition. (#729)
- Remove obsolete Cargo feature `rust-1_28` (#725)

## [0.8.2] - 2022-11-27

- tcp: Fix return value of nagle_enable ([#642](https://github.com/smoltcp-rs/smoltcp/pull/642))
- tcp: Only clear retransmit timer when all packets are acked ([#662](https://github.com/smoltcp-rs/smoltcp/pull/662))
- tcp: Send incomplete fin packets even if nagle enabled ([#665](https://github.com/smoltcp-rs/smoltcp/pull/665))
- phy: Fix mtu calculation for raw_socket ([#611](https://github.com/smoltcp-rs/smoltcp/pull/611))
- wire: Fix ipv6 contains_addr function ([#605](https://github.com/smoltcp-rs/smoltcp/pull/605))

## [0.8.1] - 2022-05-12

- Remove unused `rand_core` dep. ([#589](https://github.com/smoltcp-rs/smoltcp/pull/589))
- Use socklen_t instead of u32 for RawSocket bind() parameter. Fixes build on 32bit Android. ([#593](https://github.com/smoltcp-rs/smoltcp/pull/593))
- Propagate phy::RawSocket send errors to caller ([#588](https://github.com/smoltcp-rs/smoltcp/pull/588))
- Fix Interface set_hardware_addr, get_hardware_addr for ieee802154/6lowpan. ([#584](https://github.com/smoltcp-rs/smoltcp/pull/584))

## [0.8.0] - 2021-12-11

- Minimum Supported Rust Version (MSRV) **bumped** from 1.40 to 1.56
- Add support for IEEE 802.15.4 + 6LoWPAN medium ([#469](https://github.com/smoltcp-rs/smoltcp/pull/469))
- Add support for IP medium ([#401](https://github.com/smoltcp-rs/smoltcp/pull/401))
- Add `defmt` logging support ([#455](https://github.com/smoltcp-rs/smoltcp/pull/455))
- Add RNG infrastructure ([#547](https://github.com/smoltcp-rs/smoltcp/pull/547), [#573](https://github.com/smoltcp-rs/smoltcp/pull/573))
- Add `Context` struct that must be passed to some socket methods ([#500](https://github.com/smoltcp-rs/smoltcp/pull/500))
- Remove `SocketSet`, sockets are owned by `Interface` now. ([#557](https://github.com/smoltcp-rs/smoltcp/pull/557), [#571](https://github.com/smoltcp-rs/smoltcp/pull/571))
- TCP: Add Nagle's Algorithm. ([#500](https://github.com/smoltcp-rs/smoltcp/pull/500))
- TCP crash and correctness fixes:
    - Add Nagle's Algorithm. ([#500](https://github.com/smoltcp-rs/smoltcp/pull/500))
    - Window scaling fixes. ([#500](https://github.com/smoltcp-rs/smoltcp/pull/500))
    - Fix delayed ack causing ack not to be sent after 3 packets. ([#530](https://github.com/smoltcp-rs/smoltcp/pull/530))
    - Fix RTT estimation for RTTs longer than 1 second ([#538](https://github.com/smoltcp-rs/smoltcp/pull/538))
    - Fix infinite loop when remote side sets a MSS of 0 ([#538](https://github.com/smoltcp-rs/smoltcp/pull/538))
    - Fix infinite loop when retransmit when remote window is 0 ([#538](https://github.com/smoltcp-rs/smoltcp/pull/538))
    - Fix crash when receiving a FIN in SYN_SENT state ([#538](https://github.com/smoltcp-rs/smoltcp/pull/538))
    - Fix overflow crash when receiving a wrong ACK seq in SYN_RECEIVED state ([#538](https://github.com/smoltcp-rs/smoltcp/pull/538))
    - Fix overflow crash when initial sequence number is u32::MAX ([#538](https://github.com/smoltcp-rs/smoltcp/pull/538))
    - Fix infinite loop on challenge ACKs ([#542](https://github.com/smoltcp-rs/smoltcp/pull/542))
    - Reply with RST to invalid packets in SynReceived state.  ([#542](https://github.com/smoltcp-rs/smoltcp/pull/542))
    - Do not abort socket when receiving some invalid packets.  ([#542](https://github.com/smoltcp-rs/smoltcp/pull/542))
    - Make initial sequence number random.  ([#547](https://github.com/smoltcp-rs/smoltcp/pull/547))
    - Reply with RST to ACKs with invalid ackno in SYN_SENT. ([#522](https://github.com/smoltcp-rs/smoltcp/pull/522))
- ARP fixes to deal better with broken networks:
    - Fill cache only from ARP packets, not any packets. ([#544](https://github.com/smoltcp-rs/smoltcp/pull/544))
    - Fill cache only from ARP packets directed at us. ([#544](https://github.com/smoltcp-rs/smoltcp/pull/544))
    - Reject ARP packets with a source address not in the local network. ([#536](https://github.com/smoltcp-rs/smoltcp/pull/536), [#544](https://github.com/smoltcp-rs/smoltcp/pull/544))
    - Ignore unknown ARP packets. ([#544](https://github.com/smoltcp-rs/smoltcp/pull/544))
    - Flush neighbor cache on IP change ([#564](https://github.com/smoltcp-rs/smoltcp/pull/564))
- UDP: Add `close()` method to unbind socket. ([#475](https://github.com/smoltcp-rs/smoltcp/pull/475), [#482](https://github.com/smoltcp-rs/smoltcp/pull/482))
- DHCP client improvements:
    - Refactored implementation to improve reliability and RFC compliance ([#459](https://github.com/smoltcp-rs/smoltcp/pull/459))
    - Convert to socket ([#459](https://github.com/smoltcp-rs/smoltcp/pull/459))
    - Added `max_lease_duration` option ([#459](https://github.com/smoltcp-rs/smoltcp/pull/459))
    - Do not set the BROADCAST flag ([#548](https://github.com/smoltcp-rs/smoltcp/pull/548))
    - Add option to ignore NAKs ([#548](https://github.com/smoltcp-rs/smoltcp/pull/548))
- DHCP wire:
    - Fix DhcpRepr::buffer_len not accounting for lease time, router and subnet options ([#478](https://github.com/smoltcp-rs/smoltcp/pull/478))
    - Emit DNS servers in DhcpRepr ([#510](https://github.com/smoltcp-rs/smoltcp/pull/510))
    - Fix incorrect bit for BROADCAST flag ([#548](https://github.com/smoltcp-rs/smoltcp/pull/548))
- Improve resilience against packet ingress processing errors ([#281](https://github.com/smoltcp-rs/smoltcp/pull/281), [#483](https://github.com/smoltcp-rs/smoltcp/pull/483))
- Implement `std::error::Error` for `smoltcp::Error` ([#485](https://github.com/smoltcp-rs/smoltcp/pull/485))
- Update `managed` from 0.7 to 0.8 ([442](https://github.com/smoltcp-rs/smoltcp/pull/442))
- Fix incorrect timestamp in PCAP captures ([#513](https://github.com/smoltcp-rs/smoltcp/pull/513))
- Use microseconds instead of milliseconds in Instant and Duration ([#514](https://github.com/smoltcp-rs/smoltcp/pull/514))
- Expose inner `Device` in `PcapWriter` ([#524](https://github.com/smoltcp-rs/smoltcp/pull/524))
- Fix assert with any_ip + broadcast dst_addr. ([#533](https://github.com/smoltcp-rs/smoltcp/pull/533), [#534](https://github.com/smoltcp-rs/smoltcp/pull/534))
- Simplify PcapSink trait ([#535](https://github.com/smoltcp-rs/smoltcp/pull/535))
- Fix wrong operation order in FuzzInjector ([#525](https://github.com/smoltcp-rs/smoltcp/pull/525), [#535](https://github.com/smoltcp-rs/smoltcp/pull/535))

## [0.7.5] - 2021-06-28

- dhcpv4: emit DNS servers in repr ([#505](https://github.com/smoltcp-rs/smoltcp/pull/505))

## [0.7.4] - 2021-06-11

- tcp: fix "subtract sequence numbers with underflow" on remote window shrink. ([#490](https://github.com/smoltcp-rs/smoltcp/pull/490))
- tcp: fix subtract with overflow when receiving a SYNACK with unincremented ACK number. ([#491](https://github.com/smoltcp-rs/smoltcp/pull/491))
- tcp: use nonzero initial sequence number to workaround misbehaving servers. ([#492](https://github.com/smoltcp-rs/smoltcp/pull/492))

## [0.7.3] - 2021-05-29

- Fix "unused attribute" error in recent nightlies.

## [0.7.2] - 2021-05-29

- iface: check for ipv4 subnet broadcast addrs everywhere ([#462](https://github.com/smoltcp-rs/smoltcp/pull/462))
- dhcp: always send parameter_request_list. ([#456](https://github.com/smoltcp-rs/smoltcp/pull/456))
- dhcp: Clear expiration time on reset. ([#456](https://github.com/smoltcp-rs/smoltcp/pull/456))
- phy: fix FaultInjector returning a too big buffer when simulating a drop on tx ([#463](https://github.com/smoltcp-rs/smoltcp/pull/463))
- tcp rtte: fix "attempt to multiply with overflow". ([#476](https://github.com/smoltcp-rs/smoltcp/pull/476))
- tcp: LastAck should only change to Closed on ack of fin. ([#477](https://github.com/smoltcp-rs/smoltcp/pull/477))
- wire/dhcpv4: account for lease time, router and subnet options in DhcpRepr::buffer_len ([#478](https://github.com/smoltcp-rs/smoltcp/pull/478))

## [0.7.1] - 2021-03-27

- ndisc: Fix NeighborSolicit incorrectly asking for src addr instead of dst addr ([419](https://github.com/smoltcp-rs/smoltcp/pull/419))
- dhcpv4: respect lease time from the server instead of renewing every 60 seconds. ([437](https://github.com/smoltcp-rs/smoltcp/pull/437))
- Fix build errors due to invalid combinations of features ([416](https://github.com/smoltcp-rs/smoltcp/pull/416), [447](https://github.com/smoltcp-rs/smoltcp/pull/447))
- wire/ipv4: make some functions const ([420](https://github.com/smoltcp-rs/smoltcp/pull/420))
- phy: fix BPF on OpenBSD ([421](https://github.com/smoltcp-rs/smoltcp/pull/421), [427](https://github.com/smoltcp-rs/smoltcp/pull/427))
- phy: enable RawSocket, TapInterface on Android ([435](https://github.com/smoltcp-rs/smoltcp/pull/435))
- phy: fix phy_wait for waits longer than 1 second ([449](https://github.com/smoltcp-rs/smoltcp/pull/449))

## [0.7.0] - 2021-01-20

- Minimum Supported Rust Version (MSRV) **bumped** from 1.36 to 1.40

### New features
- tcp: Allow distinguishing between graceful (FIN) and ungraceful (RST) close. On graceful close, `recv()` now returns `Error::Finished`. On ungraceful close, `Error::Illegal` is returned, as before. ([351](https://github.com/smoltcp-rs/smoltcp/pull/351))
- sockets: Add support for attaching async/await Wakers to sockets. Wakers are woken on socket state changes. ([394](https://github.com/smoltcp-rs/smoltcp/pull/394))
- tcp: Set retransmission timeout based on an RTT estimation, instead of the previously fixed 100ms. This improves performance on high-latency links, such as mobile networks. ([406](https://github.com/smoltcp-rs/smoltcp/pull/406))
- tcp: add Delayed ACK support. On by default, with a 10ms delay. ([404](https://github.com/smoltcp-rs/smoltcp/pull/404))
- ip: Process broadcast packets directed to the subnet's broadcast address, such as 192.168.1.255. Previously broadcast packets were
only processed when directed to the 255.255.255.255 address. ([377](https://github.com/smoltcp-rs/smoltcp/pull/377))

### Fixes
- udp,raw,icmp: Fix packet buffer panic caused by large payload ([332](https://github.com/smoltcp-rs/smoltcp/pull/332))
- dhcpv4: use offered ip in requested ip option ([310](https://github.com/smoltcp-rs/smoltcp/pull/310))
- dhcpv4: Re-export dhcp::clientv4::Config
- dhcpv4: Enable `proto-dhcpv4` feature by default. ([327](https://github.com/smoltcp-rs/smoltcp/pull/327))
- ethernet,arp: Allow for ARP retry during egress ([368](https://github.com/smoltcp-rs/smoltcp/pull/368))
- ethernet,arp: Only limit the neighbor cache rate after sending a request packet ([369](https://github.com/smoltcp-rs/smoltcp/pull/369))
- tcp: use provided ip for TcpSocket::connect instead of 0.0.0.0 ([329](https://github.com/smoltcp-rs/smoltcp/pull/329))
- tcp: Accept data packets in FIN_WAIT_2 state. ([350](https://github.com/smoltcp-rs/smoltcp/pull/350))
- tcp: Always send updated ack number in `ack_reply()`. ([353](https://github.com/smoltcp-rs/smoltcp/pull/353))
- tcp: allow sending ACKs in FinWait2 state. ([388](https://github.com/smoltcp-rs/smoltcp/pull/388))
- tcp: fix racey simultaneous close not sending FIN. ([398](https://github.com/smoltcp-rs/smoltcp/pull/398))
- tcp: Do not send window updates in states that shouldn't do so ([360](https://github.com/smoltcp-rs/smoltcp/pull/360))
- tcp: Return RST to unexpected ACK in SYN-SENT state. ([367](https://github.com/smoltcp-rs/smoltcp/pull/367))
- tcp: Take MTU into account during TcpSocket dispatch. ([384](https://github.com/smoltcp-rs/smoltcp/pull/384))
- tcp: don't send data outside the remote window ([387](https://github.com/smoltcp-rs/smoltcp/pull/387))
- phy: Take Ethernet header into account for MTU of RawSocket and TapInterface. ([393](https://github.com/smoltcp-rs/smoltcp/pull/393))
- phy: add null terminator to c-string passed to libc API ([372](https://github.com/smoltcp-rs/smoltcp/pull/372))

### Quality of Life&trade; improvements
- Update to Rust 2018 edition ([396](https://github.com/smoltcp-rs/smoltcp/pull/396))
- Migrate CI to Github Actions ([390](https://github.com/smoltcp-rs/smoltcp/pull/390))
- Fix clippy lints, enforce clippy in CI ([395](https://github.com/smoltcp-rs/smoltcp/pull/395), [402](https://github.com/smoltcp-rs/smoltcp/pull/402), [403](https://github.com/smoltcp-rs/smoltcp/pull/403), [405](https://github.com/smoltcp-rs/smoltcp/pull/405), [407](https://github.com/smoltcp-rs/smoltcp/pull/407))
- Use #[non_exhaustive] for enums and structs ([409](https://github.com/smoltcp-rs/smoltcp/pull/409), [411](https://github.com/smoltcp-rs/smoltcp/pull/411))
- Simplify lifetime parameters of sockets, SocketSet, EthernetInterface ([410](https://github.com/smoltcp-rs/smoltcp/pull/410), [413](https://github.com/smoltcp-rs/smoltcp/pull/413))

[Unreleased]: https://github.com/smoltcp-rs/smoltcp/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/smoltcp-rs/smoltcp/compare/v0.13.1...v0.14.0
[0.13.1]: https://github.com/smoltcp-rs/smoltcp/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/smoltcp-rs/smoltcp/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/smoltcp-rs/smoltcp/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/smoltcp-rs/smoltcp/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/smoltcp-rs/smoltcp/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/smoltcp-rs/smoltcp/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/smoltcp-rs/smoltcp/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/smoltcp-rs/smoltcp/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/smoltcp-rs/smoltcp/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/smoltcp-rs/smoltcp/compare/v0.7.0...v0.8.0
[0.7.5]: https://github.com/smoltcp-rs/smoltcp/compare/v0.7.4...v0.7.5
[0.7.4]: https://github.com/smoltcp-rs/smoltcp/compare/v0.7.3...v0.7.4
[0.7.3]: https://github.com/smoltcp-rs/smoltcp/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/smoltcp-rs/smoltcp/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/smoltcp-rs/smoltcp/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/smoltcp-rs/smoltcp/compare/v0.6.0...v0.7.0
