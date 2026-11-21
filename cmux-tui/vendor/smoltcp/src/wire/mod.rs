/*! Low-level packet access and construction.

The `wire` module deals with the packet *representation*. It provides two levels
of functionality.

 * First, it provides functions to extract fields from sequences of octets,
   and to insert fields into sequences of octets. This happens `Packet` family of
   structures, e.g. [EthernetFrame] or [Ipv4Packet].
 * Second, in cases where the space of valid field values is much smaller than the space
   of possible field values, it provides a compact, high-level representation
   of packet data that can be parsed from and emitted into a sequence of octets.
   This happens through the `Repr` family of structs and enums, e.g. [ArpRepr] or [Ipv4Repr].

[EthernetFrame]: struct.EthernetFrame.html
[Ipv4Packet]: struct.Ipv4Packet.html
[ArpRepr]: enum.ArpRepr.html
[Ipv4Repr]: struct.Ipv4Repr.html

The functions in the `wire` module are designed for use together with `-Cpanic=abort`.

The `Packet` family of data structures guarantees that, if the `Packet::check_len()` method
returned `Ok(())`, then no accessor or setter method will panic; however, the guarantee
provided by `Packet::check_len()` may no longer hold after changing certain fields,
which are listed in the documentation for the specific packet.

The `Packet::new_checked` method is a shorthand for a combination of `Packet::new_unchecked`
and `Packet::check_len`.
When parsing untrusted input, it is *necessary* to use `Packet::new_checked()`;
so long as the buffer is not modified, no accessor will fail.
When emitting output, though, it is *incorrect* to use `Packet::new_checked()`;
the length check is likely to succeed on a zeroed buffer, but fail on a buffer
filled with data from a previous packet, such as when reusing buffers, resulting
in nondeterministic panics with some network devices but not others.
The buffer length for emission is not calculated by the `Packet` layer.

In the `Repr` family of data structures, the `Repr::parse()` method never panics
as long as `Packet::new_checked()` (or `Packet::check_len()`) has succeeded, and
the `Repr::emit()` method never panics as long as the underlying buffer is exactly
`Repr::buffer_len()` octets long.

# Examples

To emit an IP packet header into an octet buffer, and then parse it back:

```rust
# #[cfg(feature = "proto-ipv4")]
# {
use smoltcp::phy::ChecksumCapabilities;
use smoltcp::wire::*;
let repr = Ipv4Repr {
    src_addr:    Ipv4Address::new(10, 0, 0, 1),
    dst_addr:    Ipv4Address::new(10, 0, 0, 2),
    next_header: IpProtocol::Tcp,
    payload_len: 10,
    hop_limit:   64,
};
let mut buffer = vec![0; repr.buffer_len() + repr.payload_len];
{ // emission
    let mut packet = Ipv4Packet::new_unchecked(&mut buffer);
    repr.emit(&mut packet, &ChecksumCapabilities::default());
}
{ // parsing
    let packet = Ipv4Packet::new_checked(&buffer)
                            .expect("truncated packet");
    let parsed = Ipv4Repr::parse(&packet, &ChecksumCapabilities::default())
                          .expect("malformed packet");
    assert_eq!(repr, parsed);
}
# }
```
*/

mod field {
    pub type Field = ::core::ops::Range<usize>;
    pub type Rest = ::core::ops::RangeFrom<usize>;
}

pub mod pretty_print;

#[cfg(all(feature = "proto-ipv4", feature = "medium-ethernet"))]
mod arp;
#[cfg(feature = "proto-dhcpv4")]
pub(crate) mod dhcpv4;
#[cfg(feature = "proto-dns")]
pub(crate) mod dns;
#[cfg(feature = "medium-ethernet")]
mod ethernet;
#[cfg(any(feature = "proto-ipv4", feature = "proto-ipv6"))]
mod icmp;
#[cfg(feature = "proto-ipv4")]
mod icmpv4;
#[cfg(feature = "proto-ipv6")]
mod icmpv6;
#[cfg(feature = "medium-ieee802154")]
pub mod ieee802154;
#[cfg(feature = "proto-ipv4")]
mod igmp;
pub(crate) mod ip;
#[cfg(feature = "proto-ipv4")]
pub(crate) mod ipv4;
#[cfg(feature = "proto-ipv6")]
pub(crate) mod ipv6;
#[cfg(feature = "proto-ipv6")]
mod ipv6ext_header;
#[cfg(feature = "proto-ipv6")]
mod ipv6fragment;
#[cfg(feature = "proto-ipv6")]
mod ipv6hbh;
#[cfg(feature = "proto-ipv6")]
mod ipv6option;
#[cfg(feature = "proto-ipv6")]
mod ipv6routing;
#[cfg(feature = "proto-ipv6")]
mod mld;
#[cfg(all(
    feature = "proto-ipv6",
    any(feature = "medium-ethernet", feature = "medium-ieee802154")
))]
mod ndisc;
#[cfg(all(
    feature = "proto-ipv6",
    any(feature = "medium-ethernet", feature = "medium-ieee802154")
))]
mod ndiscoption;
#[cfg(feature = "proto-rpl")]
mod rpl;
#[cfg(all(feature = "proto-sixlowpan", feature = "medium-ieee802154"))]
mod sixlowpan;
mod tcp;
mod udp;

#[cfg(feature = "proto-ipsec-ah")]
mod ipsec_ah;

#[cfg(feature = "proto-ipsec-esp")]
mod ipsec_esp;

use core::fmt;

use crate::phy::Medium;

pub use self::pretty_print::PrettyPrinter;

#[cfg(feature = "medium-ethernet")]
pub use self::ethernet::{
    Address as EthernetAddress, EtherType as EthernetProtocol, Frame as EthernetFrame,
    HEADER_LEN as ETHERNET_HEADER_LEN, Repr as EthernetRepr,
};

#[cfg(all(feature = "proto-ipv4", feature = "medium-ethernet"))]
pub use self::arp::{
    Hardware as ArpHardware, Operation as ArpOperation, Packet as ArpPacket, Repr as ArpRepr,
};

#[cfg(feature = "proto-rpl")]
pub use self::rpl::{
    InstanceId as RplInstanceId, Repr as RplRepr, data::HopByHopOption as RplHopByHopRepr,
    data::Packet as RplHopByHopPacket, options::Packet as RplOptionPacket,
    options::Repr as RplOptionRepr,
};

#[cfg(all(feature = "proto-sixlowpan", feature = "medium-ieee802154"))]
pub use self::sixlowpan::{
    AddressContext as SixlowpanAddressContext, NextHeader as SixlowpanNextHeader, SixlowpanPacket,
    frag::{Key as SixlowpanFragKey, Packet as SixlowpanFragPacket, Repr as SixlowpanFragRepr},
    iphc::{Packet as SixlowpanIphcPacket, Repr as SixlowpanIphcRepr},
    nhc::{
        ExtHeaderId as SixlowpanExtHeaderId, ExtHeaderPacket as SixlowpanExtHeaderPacket,
        ExtHeaderRepr as SixlowpanExtHeaderRepr, NhcPacket as SixlowpanNhcPacket,
        UdpNhcPacket as SixlowpanUdpNhcPacket, UdpNhcRepr as SixlowpanUdpNhcRepr,
    },
};

#[cfg(feature = "medium-ieee802154")]
pub use self::ieee802154::{
    Address as Ieee802154Address, AddressingMode as Ieee802154AddressingMode,
    Frame as Ieee802154Frame, FrameType as Ieee802154FrameType,
    FrameVersion as Ieee802154FrameVersion, Pan as Ieee802154Pan, Repr as Ieee802154Repr,
};

pub use self::ip::checksum;
pub use self::ip::{
    Address as IpAddress, Cidr as IpCidr, Endpoint as IpEndpoint,
    ListenEndpoint as IpListenEndpoint, Protocol as IpProtocol, Repr as IpRepr,
    Version as IpVersion,
};

#[cfg(feature = "proto-ipv4")]
pub use self::ipv4::{
    Address as Ipv4Address, Cidr as Ipv4Cidr, HEADER_LEN as IPV4_HEADER_LEN, Key as Ipv4FragKey,
    MIN_MTU as IPV4_MIN_MTU, MULTICAST_ALL_ROUTERS as IPV4_MULTICAST_ALL_ROUTERS,
    MULTICAST_ALL_SYSTEMS as IPV4_MULTICAST_ALL_SYSTEMS, Packet as Ipv4Packet, Repr as Ipv4Repr,
};

#[cfg(feature = "proto-ipv4")]
pub(crate) use self::ipv4::AddressExt as Ipv4AddressExt;

#[cfg(feature = "proto-ipv6")]
pub use self::ipv6::{
    Address as Ipv6Address, Cidr as Ipv6Cidr, HEADER_LEN as IPV6_HEADER_LEN,
    LINK_LOCAL_ALL_MLDV2_ROUTERS as IPV6_LINK_LOCAL_ALL_MLDV2_ROUTERS,
    LINK_LOCAL_ALL_NODES as IPV6_LINK_LOCAL_ALL_NODES,
    LINK_LOCAL_ALL_ROUTERS as IPV6_LINK_LOCAL_ALL_ROUTERS,
    LINK_LOCAL_ALL_RPL_NODES as IPV6_LINK_LOCAL_ALL_RPL_NODES, MIN_MTU as IPV6_MIN_MTU,
    Packet as Ipv6Packet, Repr as Ipv6Repr,
};
#[cfg(feature = "proto-ipv6")]
pub(crate) use self::ipv6::{AddressExt as Ipv6AddressExt, MulticastScope as Ipv6MulticastScope};

#[cfg(feature = "proto-ipv6")]
pub use self::ipv6option::{
    FailureType as Ipv6OptionFailureType, Ipv6Option, Ipv6OptionsIterator, Repr as Ipv6OptionRepr,
    RouterAlert as Ipv6OptionRouterAlert, Type as Ipv6OptionType,
};

#[cfg(feature = "proto-ipv6")]
pub use self::ipv6ext_header::{Header as Ipv6ExtHeader, Repr as Ipv6ExtHeaderRepr};

#[cfg(feature = "proto-ipv6")]
pub use self::ipv6fragment::{Header as Ipv6FragmentHeader, Repr as Ipv6FragmentRepr};

#[cfg(feature = "proto-ipv6")]
pub use self::ipv6hbh::{Header as Ipv6HopByHopHeader, Repr as Ipv6HopByHopRepr};

#[cfg(feature = "proto-ipv6")]
pub use self::ipv6routing::{
    Header as Ipv6RoutingHeader, Repr as Ipv6RoutingRepr, Type as Ipv6RoutingType,
};

#[cfg(feature = "proto-ipv4")]
pub use self::icmpv4::{
    DstUnreachable as Icmpv4DstUnreachable, Message as Icmpv4Message, Packet as Icmpv4Packet,
    ParamProblem as Icmpv4ParamProblem, Redirect as Icmpv4Redirect, Repr as Icmpv4Repr,
    TimeExceeded as Icmpv4TimeExceeded,
};

#[cfg(feature = "proto-ipv4")]
pub use self::igmp::{IgmpVersion, Packet as IgmpPacket, Repr as IgmpRepr};

#[cfg(feature = "proto-ipv6")]
pub use self::icmpv6::{
    DstUnreachable as Icmpv6DstUnreachable, Message as Icmpv6Message, Packet as Icmpv6Packet,
    ParamProblem as Icmpv6ParamProblem, Repr as Icmpv6Repr, TimeExceeded as Icmpv6TimeExceeded,
};

#[cfg(any(feature = "proto-ipv4", feature = "proto-ipv6"))]
pub use self::icmp::Repr as IcmpRepr;

#[cfg(all(
    feature = "proto-ipv6",
    any(feature = "medium-ethernet", feature = "medium-ieee802154")
))]
pub use self::ndisc::{
    NeighborFlags as NdiscNeighborFlags, Repr as NdiscRepr, RouterFlags as NdiscRouterFlags,
};

#[cfg(all(
    feature = "proto-ipv6",
    any(feature = "medium-ethernet", feature = "medium-ieee802154")
))]
pub use self::ndiscoption::{
    NdiscOption, PrefixInfoFlags as NdiscPrefixInfoFlags,
    PrefixInformation as NdiscPrefixInformation, RedirectedHeader as NdiscRedirectedHeader,
    Repr as NdiscOptionRepr, Type as NdiscOptionType,
};

#[cfg(feature = "proto-ipv6")]
pub use self::mld::{
    AddressRecord as MldAddressRecord, AddressRecordRepr as MldAddressRecordRepr,
    RecordType as MldRecordType, Repr as MldRepr,
};

pub use self::udp::{HEADER_LEN as UDP_HEADER_LEN, Packet as UdpPacket, Repr as UdpRepr};

pub use self::tcp::{
    Control as TcpControl, HEADER_LEN as TCP_HEADER_LEN, Packet as TcpPacket, Repr as TcpRepr,
    SeqNumber as TcpSeqNumber, TcpOption, TcpTimestampGenerator, TcpTimestampRepr,
};

#[cfg(feature = "proto-dhcpv4")]
pub use self::dhcpv4::{
    CLIENT_PORT as DHCP_CLIENT_PORT, DhcpOption, DhcpOptionWriter, Flags as DhcpFlags,
    MAX_DNS_SERVER_COUNT as DHCP_MAX_DNS_SERVER_COUNT, MessageType as DhcpMessageType,
    OpCode as DhcpOpCode, Packet as DhcpPacket, Repr as DhcpRepr, SERVER_PORT as DHCP_SERVER_PORT,
};

#[cfg(feature = "proto-dns")]
pub use self::dns::{
    Flags as DnsFlags, Opcode as DnsOpcode, Packet as DnsPacket, Question as DnsQuestion,
    Rcode as DnsRcode, Record as DnsRecord, RecordData as DnsRecordData, Repr as DnsRepr,
    Type as DnsQueryType,
};

#[cfg(feature = "proto-ipsec-ah")]
pub use self::ipsec_ah::{Packet as IpSecAuthHeaderPacket, Repr as IpSecAuthHeaderRepr};

#[cfg(feature = "proto-ipsec-esp")]
pub use self::ipsec_esp::{Packet as IpSecEspPacket, Repr as IpSecEspRepr};

/// Parsing a packet failed.
///
/// Either it is malformed, or it is not supported by smoltcp.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Error;

impl core::error::Error for Error {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "wire::Error")
    }
}

pub type Result<T> = core::result::Result<T, Error>;

/// Representation of an hardware address, such as an Ethernet address or an IEEE802.15.4 address.
#[cfg(any(
    feature = "medium-ip",
    feature = "medium-ethernet",
    feature = "medium-ieee802154"
))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum HardwareAddress {
    #[cfg(feature = "medium-ip")]
    Ip,
    #[cfg(feature = "medium-ethernet")]
    Ethernet(EthernetAddress),
    #[cfg(feature = "medium-ieee802154")]
    Ieee802154(Ieee802154Address),
}

#[cfg(any(
    feature = "medium-ip",
    feature = "medium-ethernet",
    feature = "medium-ieee802154"
))]
#[cfg(test)]
impl Default for HardwareAddress {
    fn default() -> Self {
        #![allow(unreachable_code)]
        #[cfg(feature = "medium-ethernet")]
        {
            return Self::Ethernet(EthernetAddress::default());
        }
        #[cfg(feature = "medium-ip")]
        {
            return Self::Ip;
        }
        #[cfg(feature = "medium-ieee802154")]
        {
            Self::Ieee802154(Ieee802154Address::default())
        }
    }
}

#[cfg(any(
    feature = "medium-ip",
    feature = "medium-ethernet",
    feature = "medium-ieee802154"
))]
impl HardwareAddress {
    pub const fn as_bytes(&self) -> &[u8] {
        match self {
            #[cfg(feature = "medium-ip")]
            HardwareAddress::Ip => unreachable!(),
            #[cfg(feature = "medium-ethernet")]
            HardwareAddress::Ethernet(addr) => addr.as_bytes(),
            #[cfg(feature = "medium-ieee802154")]
            HardwareAddress::Ieee802154(addr) => addr.as_bytes(),
        }
    }

    /// Query whether the address is an unicast address.
    pub fn is_unicast(&self) -> bool {
        match self {
            #[cfg(feature = "medium-ip")]
            HardwareAddress::Ip => unreachable!(),
            #[cfg(feature = "medium-ethernet")]
            HardwareAddress::Ethernet(addr) => addr.is_unicast(),
            #[cfg(feature = "medium-ieee802154")]
            HardwareAddress::Ieee802154(addr) => addr.is_unicast(),
        }
    }

    /// Query whether the address is a broadcast address.
    pub fn is_broadcast(&self) -> bool {
        match self {
            #[cfg(feature = "medium-ip")]
            HardwareAddress::Ip => unreachable!(),
            #[cfg(feature = "medium-ethernet")]
            HardwareAddress::Ethernet(addr) => addr.is_broadcast(),
            #[cfg(feature = "medium-ieee802154")]
            HardwareAddress::Ieee802154(addr) => addr.is_broadcast(),
        }
    }

    #[cfg(feature = "medium-ethernet")]
    pub(crate) fn ethernet_or_panic(&self) -> EthernetAddress {
        match self {
            HardwareAddress::Ethernet(addr) => *addr,
            #[allow(unreachable_patterns)]
            _ => panic!("HardwareAddress is not Ethernet."),
        }
    }

    #[cfg(feature = "medium-ieee802154")]
    pub(crate) fn ieee802154_or_panic(&self) -> Ieee802154Address {
        match self {
            HardwareAddress::Ieee802154(addr) => *addr,
            #[allow(unreachable_patterns)]
            _ => panic!("HardwareAddress is not Ethernet."),
        }
    }

    #[inline]
    pub(crate) fn medium(&self) -> Medium {
        match self {
            #[cfg(feature = "medium-ip")]
            HardwareAddress::Ip => Medium::Ip,
            #[cfg(feature = "medium-ethernet")]
            HardwareAddress::Ethernet(_) => Medium::Ethernet,
            #[cfg(feature = "medium-ieee802154")]
            HardwareAddress::Ieee802154(_) => Medium::Ieee802154,
        }
    }

    pub fn as_eui_64(&self) -> Option<[u8; 8]> {
        match self {
            #[cfg(feature = "medium-ip")]
            HardwareAddress::Ip => None,
            #[cfg(feature = "medium-ethernet")]
            HardwareAddress::Ethernet(ethernet) => ethernet.as_eui_64(),
            #[cfg(feature = "medium-ieee802154")]
            HardwareAddress::Ieee802154(ieee802154) => ieee802154.as_eui_64(),
        }
    }
}

#[cfg(any(
    feature = "medium-ip",
    feature = "medium-ethernet",
    feature = "medium-ieee802154"
))]
impl core::fmt::Display for HardwareAddress {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        match self {
            #[cfg(feature = "medium-ip")]
            HardwareAddress::Ip => write!(f, "no hardware addr"),
            #[cfg(feature = "medium-ethernet")]
            HardwareAddress::Ethernet(addr) => write!(f, "{addr}"),
            #[cfg(feature = "medium-ieee802154")]
            HardwareAddress::Ieee802154(addr) => write!(f, "{addr}"),
        }
    }
}

#[cfg(feature = "medium-ethernet")]
impl From<EthernetAddress> for HardwareAddress {
    fn from(addr: EthernetAddress) -> Self {
        HardwareAddress::Ethernet(addr)
    }
}

#[cfg(feature = "medium-ieee802154")]
impl From<Ieee802154Address> for HardwareAddress {
    fn from(addr: Ieee802154Address) -> Self {
        HardwareAddress::Ieee802154(addr)
    }
}

#[cfg(not(feature = "medium-ieee802154"))]
pub const MAX_HARDWARE_ADDRESS_LEN: usize = 6;
#[cfg(feature = "medium-ieee802154")]
pub const MAX_HARDWARE_ADDRESS_LEN: usize = 8;

/// Unparsed hardware address.
///
/// Used to make NDISC parsing agnostic of the hardware medium in use.
#[cfg(any(feature = "medium-ethernet", feature = "medium-ieee802154"))]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct RawHardwareAddress {
    len: u8,
    data: [u8; MAX_HARDWARE_ADDRESS_LEN],
}

#[cfg(any(feature = "medium-ethernet", feature = "medium-ieee802154"))]
impl RawHardwareAddress {
    /// Create a new `RawHardwareAddress` from a byte slice.
    ///
    /// # Panics
    /// Panics if `addr.len() > MAX_HARDWARE_ADDRESS_LEN`.
    pub fn from_bytes(addr: &[u8]) -> Self {
        let mut data = [0u8; MAX_HARDWARE_ADDRESS_LEN];
        data[..addr.len()].copy_from_slice(addr);

        Self {
            len: addr.len() as u8,
            data,
        }
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.data[..self.len as usize]
    }

    pub const fn len(&self) -> usize {
        self.len as usize
    }

    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn parse(&self, medium: Medium) -> Result<HardwareAddress> {
        match medium {
            #[cfg(feature = "medium-ethernet")]
            Medium::Ethernet => {
                if self.len() != 6 {
                    return Err(Error);
                }
                Ok(HardwareAddress::Ethernet(EthernetAddress::from_bytes(
                    self.as_bytes(),
                )))
            }
            #[cfg(feature = "medium-ieee802154")]
            Medium::Ieee802154 => {
                if self.len() != 8 {
                    return Err(Error);
                }
                Ok(HardwareAddress::Ieee802154(Ieee802154Address::from_bytes(
                    self.as_bytes(),
                )))
            }
            #[cfg(feature = "medium-ip")]
            Medium::Ip => unreachable!(),
        }
    }
}

#[cfg(any(feature = "medium-ethernet", feature = "medium-ieee802154"))]
impl core::fmt::Display for RawHardwareAddress {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        for (i, &b) in self.as_bytes().iter().enumerate() {
            if i != 0 {
                write!(f, ":")?;
            }
            write!(f, "{b:02x}")?;
        }
        Ok(())
    }
}

#[cfg(feature = "medium-ethernet")]
impl From<EthernetAddress> for RawHardwareAddress {
    fn from(addr: EthernetAddress) -> Self {
        Self::from_bytes(addr.as_bytes())
    }
}

#[cfg(feature = "medium-ieee802154")]
impl From<Ieee802154Address> for RawHardwareAddress {
    fn from(addr: Ieee802154Address) -> Self {
        Self::from_bytes(addr.as_bytes())
    }
}

#[cfg(any(feature = "medium-ethernet", feature = "medium-ieee802154"))]
impl From<HardwareAddress> for RawHardwareAddress {
    fn from(addr: HardwareAddress) -> Self {
        Self::from_bytes(addr.as_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rstest::rstest;

    #[rstest]
    #[cfg(feature = "medium-ethernet")]
    #[case((Medium::Ethernet, &[0u8; 6][..]), Ok(HardwareAddress::Ethernet(EthernetAddress([0, 0, 0, 0, 0, 0]))))]
    #[cfg(feature = "medium-ethernet")]
    #[case((Medium::Ethernet, &[1u8; 5][..]), Err(Error))]
    #[cfg(feature = "medium-ethernet")]
    #[case((Medium::Ethernet, &[1u8; 7][..]), Err(Error))]
    #[cfg(feature = "medium-ieee802154")]
    #[case((Medium::Ieee802154, &[0u8; 8][..]), Ok(HardwareAddress::Ieee802154(Ieee802154Address::Extended([0, 0, 0, 0, 0, 0, 0, 0]))))]
    #[cfg(feature = "medium-ieee802154")]
    #[case((Medium::Ieee802154, &[1u8; 2][..]), Err(Error))]
    #[cfg(feature = "medium-ieee802154")]
    #[case((Medium::Ieee802154, &[1u8; 1][..]), Err(Error))]
    fn parse_hardware_address(
        #[case] input: (Medium, &[u8]),
        #[case] expected: Result<HardwareAddress>,
    ) {
        let (medium, input) = input;

        // NOTE: we check the length since `RawHardwareAddress::parse()` panics if the length is
        // invalid. MAX_HARDWARE_ADDRESS_LEN is based on the medium, and depending on the feature
        // flags, it can be different.
        if input.len() < MAX_HARDWARE_ADDRESS_LEN {
            let raw = RawHardwareAddress::from_bytes(input);
            assert_eq!(raw.parse(medium), expected);
        }
    }
}
