#![deny(missing_docs)]

use byteorder::{ByteOrder, NetworkEndian};
use core::fmt;

use super::{Error, Result};
use crate::wire::HardwareAddress;
use crate::wire::ip::pretty_print_ip_payload;

pub use super::IpProtocol as Protocol;

/// Minimum MTU required of all links supporting IPv6. See [RFC 8200 § 5].
///
/// [RFC 8200 § 5]: https://tools.ietf.org/html/rfc8200#section-5
pub const MIN_MTU: usize = 1280;

/// Size of IPv6 adderess in octets.
///
/// [RFC 8200 § 2]: https://www.rfc-editor.org/rfc/rfc4291#section-2
pub const ADDR_SIZE: usize = 16;

/// The link-local [all nodes multicast address].
///
/// [all nodes multicast address]: https://tools.ietf.org/html/rfc4291#section-2.7.1
pub const LINK_LOCAL_ALL_NODES: Address = Address::new(0xff02, 0, 0, 0, 0, 0, 0, 1);

/// The link-local [all routers multicast address].
///
/// [all routers multicast address]: https://tools.ietf.org/html/rfc4291#section-2.7.1
pub const LINK_LOCAL_ALL_ROUTERS: Address = Address::new(0xff02, 0, 0, 0, 0, 0, 0, 2);

/// The link-local [all MLVDv2-capable routers multicast address].
///
/// [all MLVDv2-capable routers multicast address]: https://tools.ietf.org/html/rfc3810#section-11
pub const LINK_LOCAL_ALL_MLDV2_ROUTERS: Address = Address::new(0xff02, 0, 0, 0, 0, 0, 0, 0x16);

/// The link-local [all RPL nodes multicast address].
///
/// [all RPL nodes multicast address]: https://www.rfc-editor.org/rfc/rfc6550.html#section-20.19
pub const LINK_LOCAL_ALL_RPL_NODES: Address = Address::new(0xff02, 0, 0, 0, 0, 0, 0, 0x1a);

/// The [scope] of an address.
///
/// [scope]: https://www.rfc-editor.org/rfc/rfc4291#section-2.7
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MulticastScope {
    /// Interface Local scope
    InterfaceLocal = 0x1,
    /// Link local scope
    LinkLocal = 0x2,
    /// Administratively configured
    AdminLocal = 0x4,
    /// Single site scope
    SiteLocal = 0x5,
    /// Organization scope
    OrganizationLocal = 0x8,
    /// Global scope
    Global = 0xE,
    /// Unknown scope
    Unknown = 0xFF,
}

impl From<u8> for MulticastScope {
    fn from(value: u8) -> Self {
        match value {
            0x1 => Self::InterfaceLocal,
            0x2 => Self::LinkLocal,
            0x4 => Self::AdminLocal,
            0x5 => Self::SiteLocal,
            0x8 => Self::OrganizationLocal,
            0xE => Self::Global,
            _ => Self::Unknown,
        }
    }
}

pub use core::net::Ipv6Addr as Address;

pub(crate) trait AddressExt {
    /// Create an IPv6 address based on the provided prefix and hardware identifier.
    fn from_link_prefix(
        link_prefix: &Cidr,
        interface_identifier: HardwareAddress,
    ) -> Option<Address>;

    /// Query whether the IPv6 address is an [unicast address].
    ///
    /// [unicast address]: https://tools.ietf.org/html/rfc4291#section-2.5
    ///
    /// `x_` prefix is to avoid a collision with the still-unstable method in `core::ip`.
    fn x_is_unicast(&self) -> bool;

    /// Query whether the IPv6 address is a [global unicast address].
    ///
    /// [global unicast address]: https://datatracker.ietf.org/doc/html/rfc3587
    fn is_global_unicast(&self) -> bool;

    /// Query whether the IPv6 address is in the [link-local] scope.
    ///
    /// [link-local]: https://tools.ietf.org/html/rfc4291#section-2.5.6
    fn is_link_local(&self) -> bool;

    /// Helper function used to mask an address given a prefix.
    ///
    /// # Panics
    /// This function panics if `mask` is greater than 128.
    fn mask(&self, mask: u8) -> [u8; ADDR_SIZE];

    /// The solicited node for the given unicast address.
    ///
    /// # Panics
    /// This function panics if the given address is not
    /// unicast.
    fn solicited_node(&self) -> Address;

    /// Return the scope of the address.
    ///
    /// `x_` prefix is to avoid a collision with the still-unstable method in `core::ip`.
    fn x_multicast_scope(&self) -> MulticastScope;

    /// Query whether the IPv6 address is a [solicited-node multicast address].
    ///
    /// [Solicited-node multicast address]: https://datatracker.ietf.org/doc/html/rfc4291#section-2.7.1
    fn is_solicited_node_multicast(&self) -> bool;

    /// If `self` is a CIDR-compatible subnet mask, return `Some(prefix_len)`,
    /// where `prefix_len` is the number of leading zeroes. Return `None` otherwise.
    fn prefix_len(&self) -> Option<u8>;
}

impl AddressExt for Address {
    fn from_link_prefix(
        link_prefix: &Cidr,
        interface_identifier: HardwareAddress,
    ) -> Option<Address> {
        if let Some(eui64) = interface_identifier.as_eui_64() {
            if link_prefix.prefix_len() != 64 {
                return None;
            }
            let mut bytes = [0; 16];
            bytes[0..8].copy_from_slice(&link_prefix.address().octets()[0..8]);
            bytes[8..16].copy_from_slice(&eui64);
            Some(Address::from_octets(bytes))
        } else {
            None
        }
    }

    fn x_is_unicast(&self) -> bool {
        !(self.is_multicast() || self.is_unspecified())
    }

    fn is_global_unicast(&self) -> bool {
        (self.octets()[0] >> 5) == 0b001
    }

    fn is_link_local(&self) -> bool {
        self.octets()[0..8] == [0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    }

    fn mask(&self, mask: u8) -> [u8; ADDR_SIZE] {
        assert!(mask <= 128);
        let mut bytes = [0u8; ADDR_SIZE];
        let idx = (mask as usize) / 8;
        let modulus = (mask as usize) % 8;
        let octets = self.octets();
        let (first, second) = octets.split_at(idx);
        bytes[0..idx].copy_from_slice(first);
        if idx < ADDR_SIZE {
            let part = second[0];
            bytes[idx] = part & (!(0xff >> modulus) as u8);
        }
        bytes
    }

    fn solicited_node(&self) -> Address {
        assert!(self.x_is_unicast());
        let o = self.octets();
        Address::from([
            0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xFF, o[13],
            o[14], o[15],
        ])
    }

    fn x_multicast_scope(&self) -> MulticastScope {
        if self.is_multicast() {
            return MulticastScope::from(self.octets()[1] & 0b1111);
        }

        if self.is_link_local() {
            MulticastScope::LinkLocal
        } else if self.is_unique_local() || self.is_global_unicast() {
            // ULA are considered global scope
            // https://www.rfc-editor.org/rfc/rfc6724#section-3.1
            MulticastScope::Global
        } else {
            MulticastScope::Unknown
        }
    }

    fn is_solicited_node_multicast(&self) -> bool {
        self.octets()[0..13]
            == [
                0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xFF,
            ]
    }

    fn prefix_len(&self) -> Option<u8> {
        let mut ones = true;
        let mut prefix_len = 0;
        for byte in self.octets() {
            let mut mask = 0x80;
            for _ in 0..8 {
                let one = byte & mask != 0;
                if ones {
                    // Expect 1s until first 0
                    if one {
                        prefix_len += 1;
                    } else {
                        ones = false;
                    }
                } else if one {
                    // 1 where 0 was expected
                    return None;
                }
                mask >>= 1;
            }
        }
        Some(prefix_len)
    }
}

/// A specification of an IPv6 CIDR block, containing an address and a variable-length
/// subnet masking prefix length.
#[derive(Debug, Hash, PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
pub struct Cidr {
    address: Address,
    prefix_len: u8,
}

impl Cidr {
    /// The [solicited node prefix].
    ///
    /// [solicited node prefix]: https://tools.ietf.org/html/rfc4291#section-2.7.1
    pub const SOLICITED_NODE_PREFIX: Cidr = Cidr {
        address: Address::new(0xff02, 0, 0, 0, 0, 1, 0xff00, 0),
        prefix_len: 104,
    };

    /// The link-local address prefix.
    pub const LINK_LOCAL_PREFIX: Cidr = Cidr {
        address: Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
        prefix_len: 10,
    };

    /// Create an IPv6 CIDR block from the given address and prefix length.
    ///
    /// # Panics
    /// This function panics if the prefix length is larger than 128.
    pub const fn new(address: Address, prefix_len: u8) -> Cidr {
        assert!(prefix_len <= 128);
        Cidr {
            address,
            prefix_len,
        }
    }

    /// Create an IPv6 CIDR based on the provided prefix and hardware identifier.
    pub fn from_link_prefix(
        link_prefix: &Cidr,
        interface_identifier: HardwareAddress,
    ) -> Option<Self> {
        Address::from_link_prefix(link_prefix, interface_identifier)
            .map(|address| Self::new(address, link_prefix.prefix_len()))
    }

    /// Return the address of this IPv6 CIDR block.
    pub const fn address(&self) -> Address {
        self.address
    }

    /// Return the prefix length of this IPv6 CIDR block.
    pub const fn prefix_len(&self) -> u8 {
        self.prefix_len
    }

    /// Query whether the subnetwork described by this IPv6 CIDR block contains
    /// the given address.
    pub fn contains_addr(&self, addr: &Address) -> bool {
        // right shift by 128 is not legal
        if self.prefix_len == 0 {
            return true;
        }

        self.address.mask(self.prefix_len) == addr.mask(self.prefix_len)
    }

    /// Query whether the subnetwork described by this IPV6 CIDR block contains
    /// the subnetwork described by the given IPv6 CIDR block.
    pub fn contains_subnet(&self, subnet: &Cidr) -> bool {
        self.prefix_len <= subnet.prefix_len && self.contains_addr(&subnet.address)
    }
}

impl fmt::Display for Cidr {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // https://tools.ietf.org/html/rfc4291#section-2.3
        write!(f, "{}/{}", self.address, self.prefix_len)
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Cidr {
    fn format(&self, f: defmt::Formatter) {
        defmt::write!(f, "{}/{=u8}", self.address, self.prefix_len);
    }
}

/// A read/write wrapper around an Internet Protocol version 6 packet buffer.
#[derive(Debug, PartialEq, Eq, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Packet<T: AsRef<[u8]>> {
    buffer: T,
}

// Ranges and constants describing the IPv6 header
//
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |Version| Traffic Class |           Flow Label                  |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |         Payload Length        |  Next Header  |   Hop Limit   |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |                                                               |
// +                                                               +
// |                                                               |
// +                         Source Address                        +
// |                                                               |
// +                                                               +
// |                                                               |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |                                                               |
// +                                                               +
// |                                                               |
// +                      Destination Address                      +
// |                                                               |
// +                                                               +
// |                                                               |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//
// See https://tools.ietf.org/html/rfc2460#section-3 for details.
mod field {
    use crate::wire::field::*;
    // 4-bit version number, 8-bit traffic class, and the
    // 20-bit flow label.
    pub const VER_TC_FLOW: Field = 0..4;
    // 16-bit value representing the length of the payload.
    // Note: Options are included in this length.
    pub const LENGTH: Field = 4..6;
    // 8-bit value identifying the type of header following this
    // one. Note: The same numbers are used in IPv4.
    pub const NXT_HDR: usize = 6;
    // 8-bit value decremented by each node that forwards this
    // packet. The packet is discarded when the value is 0.
    pub const HOP_LIMIT: usize = 7;
    // IPv6 address of the source node.
    pub const SRC_ADDR: Field = 8..24;
    // IPv6 address of the destination node.
    pub const DST_ADDR: Field = 24..40;
}

/// Length of an IPv6 header.
pub const HEADER_LEN: usize = field::DST_ADDR.end;

impl<T: AsRef<[u8]>> Packet<T> {
    /// Create a raw octet buffer with an IPv6 packet structure.
    #[inline]
    pub const fn new_unchecked(buffer: T) -> Packet<T> {
        Packet { buffer }
    }

    /// Shorthand for a combination of [new_unchecked] and [check_len].
    ///
    /// [new_unchecked]: #method.new_unchecked
    /// [check_len]: #method.check_len
    #[inline]
    pub fn new_checked(buffer: T) -> Result<Packet<T>> {
        let packet = Self::new_unchecked(buffer);
        packet.check_len()?;
        Ok(packet)
    }

    /// Ensure that no accessor method will panic if called.
    /// Returns `Err(Error)` if the buffer is too short.
    ///
    /// The result of this check is invalidated by calling [set_payload_len].
    ///
    /// [set_payload_len]: #method.set_payload_len
    #[inline]
    pub fn check_len(&self) -> Result<()> {
        let len = self.buffer.as_ref().len();
        if len < field::DST_ADDR.end || len < self.total_len() {
            Err(Error)
        } else {
            Ok(())
        }
    }

    /// Consume the packet, returning the underlying buffer.
    #[inline]
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Return the header length.
    #[inline]
    pub const fn header_len(&self) -> usize {
        // This is not a strictly necessary function, but it makes
        // code more readable.
        field::DST_ADDR.end
    }

    /// Return the version field.
    #[inline]
    pub fn version(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::VER_TC_FLOW.start] >> 4
    }

    /// Return the traffic class.
    #[inline]
    pub fn traffic_class(&self) -> u8 {
        let data = self.buffer.as_ref();
        ((NetworkEndian::read_u16(&data[0..2]) & 0x0ff0) >> 4) as u8
    }

    /// Return the flow label field.
    #[inline]
    pub fn flow_label(&self) -> u32 {
        let data = self.buffer.as_ref();
        NetworkEndian::read_u24(&data[1..4]) & 0x000fffff
    }

    /// Return the payload length field.
    #[inline]
    pub fn payload_len(&self) -> u16 {
        let data = self.buffer.as_ref();
        NetworkEndian::read_u16(&data[field::LENGTH])
    }

    /// Return the payload length added to the known header length.
    #[inline]
    pub fn total_len(&self) -> usize {
        self.header_len() + self.payload_len() as usize
    }

    /// Return the next header field.
    #[inline]
    pub fn next_header(&self) -> Protocol {
        let data = self.buffer.as_ref();
        Protocol::from(data[field::NXT_HDR])
    }

    /// Return the hop limit field.
    #[inline]
    pub fn hop_limit(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::HOP_LIMIT]
    }

    /// Return the source address field.
    #[inline]
    pub fn src_addr(&self) -> Address {
        let data = self.buffer.as_ref();
        Address::from_octets(data[field::SRC_ADDR].try_into().unwrap())
    }

    /// Return the destination address field.
    #[inline]
    pub fn dst_addr(&self) -> Address {
        let data = self.buffer.as_ref();
        Address::from_octets(data[field::DST_ADDR].try_into().unwrap())
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> Packet<&'a T> {
    /// Return a pointer to the payload.
    #[inline]
    pub fn payload(&self) -> &'a [u8] {
        let data = self.buffer.as_ref();
        let range = self.header_len()..self.total_len();
        &data[range]
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Packet<T> {
    /// Set the version field.
    #[inline]
    pub fn set_version(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        // Make sure to retain the lower order bits which contain
        // the higher order bits of the traffic class
        data[0] = (data[0] & 0x0f) | ((value & 0x0f) << 4);
    }

    /// Set the traffic class field.
    #[inline]
    pub fn set_traffic_class(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        // Put the higher order 4-bits of value in the lower order
        // 4-bits of the first byte
        data[0] = (data[0] & 0xf0) | ((value & 0xf0) >> 4);
        // Put the lower order 4-bits of value in the higher order
        // 4-bits of the second byte
        data[1] = (data[1] & 0x0f) | ((value & 0x0f) << 4);
    }

    /// Set the flow label field.
    #[inline]
    pub fn set_flow_label(&mut self, value: u32) {
        let data = self.buffer.as_mut();
        // Retain the lower order 4-bits of the traffic class
        let raw = (((data[1] & 0xf0) as u32) << 16) | (value & 0x0fffff);
        NetworkEndian::write_u24(&mut data[1..4], raw);
    }

    /// Set the payload length field.
    #[inline]
    pub fn set_payload_len(&mut self, value: u16) {
        let data = self.buffer.as_mut();
        NetworkEndian::write_u16(&mut data[field::LENGTH], value);
    }

    /// Set the next header field.
    #[inline]
    pub fn set_next_header(&mut self, value: Protocol) {
        let data = self.buffer.as_mut();
        data[field::NXT_HDR] = value.into();
    }

    /// Set the hop limit field.
    #[inline]
    pub fn set_hop_limit(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        data[field::HOP_LIMIT] = value;
    }

    /// Set the source address field.
    #[inline]
    pub fn set_src_addr(&mut self, value: Address) {
        let data = self.buffer.as_mut();
        data[field::SRC_ADDR].copy_from_slice(&value.octets());
    }

    /// Set the destination address field.
    #[inline]
    pub fn set_dst_addr(&mut self, value: Address) {
        let data = self.buffer.as_mut();
        data[field::DST_ADDR].copy_from_slice(&value.octets());
    }

    /// Return a mutable pointer to the payload.
    #[inline]
    pub fn payload_mut(&mut self) -> &mut [u8] {
        let range = self.header_len()..self.total_len();
        let data = self.buffer.as_mut();
        &mut data[range]
    }
}

impl<T: AsRef<[u8]> + ?Sized> fmt::Display for Packet<&T> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match Repr::parse(self) {
            Ok(repr) => write!(f, "{repr}"),
            Err(err) => {
                write!(f, "IPv6 ({err})")?;
                Ok(())
            }
        }
    }
}

impl<T: AsRef<[u8]>> AsRef<[u8]> for Packet<T> {
    fn as_ref(&self) -> &[u8] {
        self.buffer.as_ref()
    }
}

/// A high-level representation of an Internet Protocol version 6 packet header.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct Repr {
    /// IPv6 address of the source node.
    pub src_addr: Address,
    /// IPv6 address of the destination node.
    pub dst_addr: Address,
    /// Protocol contained in the next header.
    pub next_header: Protocol,
    /// Length of the payload including the extension headers.
    pub payload_len: usize,
    /// The 8-bit hop limit field.
    pub hop_limit: u8,
}

impl Repr {
    /// Parse an Internet Protocol version 6 packet and return a high-level representation.
    pub fn parse<T: AsRef<[u8]> + ?Sized>(packet: &Packet<&T>) -> Result<Repr> {
        // Ensure basic accessors will work
        packet.check_len()?;
        if packet.version() != 6 {
            return Err(Error);
        }
        Ok(Repr {
            src_addr: packet.src_addr(),
            dst_addr: packet.dst_addr(),
            next_header: packet.next_header(),
            payload_len: packet.payload_len() as usize,
            hop_limit: packet.hop_limit(),
        })
    }

    /// Return the length of a header that will be emitted from this high-level representation.
    pub const fn buffer_len(&self) -> usize {
        // This function is not strictly necessary, but it can make client code more readable.
        field::DST_ADDR.end
    }

    /// Emit a high-level representation into an Internet Protocol version 6 packet.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]>>(&self, packet: &mut Packet<T>) {
        // Make no assumptions about the original state of the packet buffer.
        // Make sure to set every byte.
        packet.set_version(6);
        packet.set_traffic_class(0);
        packet.set_flow_label(0);
        #[cfg(not(feature = "segmentation-offload"))]
        let payload_len = self.payload_len as u16;
        #[cfg(feature = "segmentation-offload")]
        // If because of segmentation offload the length of the buffer exceeds what can be
        // represented in the length field of the IP header, we fall back to 0. It will be
        // filled by the device during segmentation anyways.
        let payload_len = u16::try_from(self.payload_len).unwrap_or(0);
        packet.set_payload_len(payload_len);
        packet.set_hop_limit(self.hop_limit);
        packet.set_next_header(self.next_header);
        packet.set_src_addr(self.src_addr);
        packet.set_dst_addr(self.dst_addr);
    }
}

impl fmt::Display for Repr {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "IPv6 src={} dst={} nxt_hdr={} hop_limit={}",
            self.src_addr, self.dst_addr, self.next_header, self.hop_limit
        )
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Repr {
    fn format(&self, fmt: defmt::Formatter) {
        defmt::write!(
            fmt,
            "IPv6 src={} dst={} nxt_hdr={} hop_limit={}",
            self.src_addr,
            self.dst_addr,
            self.next_header,
            self.hop_limit
        )
    }
}

use crate::wire::pretty_print::{PrettyIndent, PrettyPrint};

// TODO: This is very similar to the implementation for IPv4. Make
// a way to have less copy and pasted code here.
impl<T: AsRef<[u8]>> PrettyPrint for Packet<T> {
    fn pretty_print(
        buffer: &dyn AsRef<[u8]>,
        f: &mut fmt::Formatter,
        indent: &mut PrettyIndent,
    ) -> fmt::Result {
        let (ip_repr, payload) = match Packet::new_checked(buffer) {
            Err(err) => return write!(f, "{indent}({err})"),
            Ok(ip_packet) => match Repr::parse(&ip_packet) {
                Err(_) => return Ok(()),
                Ok(ip_repr) => {
                    write!(f, "{indent}{ip_repr}")?;
                    (ip_repr, ip_packet.payload())
                }
            },
        };

        pretty_print_ip_payload(f, indent, ip_repr, payload)
    }
}

#[cfg(test)]
pub(crate) mod test {
    use super::*;
    use crate::wire::pretty_print::PrettyPrinter;

    #[allow(unused)]
    pub(crate) const MOCK_IP_ADDR_1: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
    #[allow(unused)]
    pub(crate) const MOCK_IP_ADDR_2: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 2);
    #[allow(unused)]
    pub(crate) const MOCK_IP_ADDR_3: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 3);
    #[allow(unused)]
    pub(crate) const MOCK_IP_ADDR_4: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 4);
    #[allow(unused)]
    pub(crate) const MOCK_UNSPECIFIED: Address = Address::UNSPECIFIED;

    const LINK_LOCAL_ADDR: Address = Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
    const UNIQUE_LOCAL_ADDR: Address = Address::new(0xfd00, 0, 0, 201, 1, 1, 1, 1);
    const GLOBAL_UNICAST_ADDR: Address = Address::new(0x2001, 0xdb8, 0x3, 0, 0, 0, 0, 1);

    const TEST_SOL_NODE_MCAST_ADDR: Address = Address::new(0xff02, 0, 0, 0, 0, 1, 0xff01, 101);

    #[test]
    fn test_basic_multicast() {
        assert!(!LINK_LOCAL_ALL_ROUTERS.is_unspecified());
        assert!(LINK_LOCAL_ALL_ROUTERS.is_multicast());
        assert!(!LINK_LOCAL_ALL_ROUTERS.is_link_local());
        assert!(!LINK_LOCAL_ALL_ROUTERS.is_loopback());
        assert!(!LINK_LOCAL_ALL_ROUTERS.is_unique_local());
        assert!(!LINK_LOCAL_ALL_ROUTERS.is_global_unicast());
        assert!(!LINK_LOCAL_ALL_ROUTERS.is_solicited_node_multicast());
        assert!(!LINK_LOCAL_ALL_NODES.is_unspecified());
        assert!(LINK_LOCAL_ALL_NODES.is_multicast());
        assert!(!LINK_LOCAL_ALL_NODES.is_link_local());
        assert!(!LINK_LOCAL_ALL_NODES.is_loopback());
        assert!(!LINK_LOCAL_ALL_NODES.is_unique_local());
        assert!(!LINK_LOCAL_ALL_NODES.is_global_unicast());
        assert!(!LINK_LOCAL_ALL_NODES.is_solicited_node_multicast());
    }

    #[test]
    fn test_basic_link_local() {
        assert!(!LINK_LOCAL_ADDR.is_unspecified());
        assert!(!LINK_LOCAL_ADDR.is_multicast());
        assert!(LINK_LOCAL_ADDR.is_link_local());
        assert!(!LINK_LOCAL_ADDR.is_loopback());
        assert!(!LINK_LOCAL_ADDR.is_unique_local());
        assert!(!LINK_LOCAL_ADDR.is_global_unicast());
        assert!(!LINK_LOCAL_ADDR.is_solicited_node_multicast());
    }

    #[test]
    fn test_basic_loopback() {
        assert!(!Address::LOCALHOST.is_unspecified());
        assert!(!Address::LOCALHOST.is_multicast());
        assert!(!Address::LOCALHOST.is_link_local());
        assert!(Address::LOCALHOST.is_loopback());
        assert!(!Address::LOCALHOST.is_unique_local());
        assert!(!Address::LOCALHOST.is_global_unicast());
        assert!(!Address::LOCALHOST.is_solicited_node_multicast());
    }

    #[test]
    fn test_unique_local() {
        assert!(!UNIQUE_LOCAL_ADDR.is_unspecified());
        assert!(!UNIQUE_LOCAL_ADDR.is_multicast());
        assert!(!UNIQUE_LOCAL_ADDR.is_link_local());
        assert!(!UNIQUE_LOCAL_ADDR.is_loopback());
        assert!(UNIQUE_LOCAL_ADDR.is_unique_local());
        assert!(!UNIQUE_LOCAL_ADDR.is_global_unicast());
        assert!(!UNIQUE_LOCAL_ADDR.is_solicited_node_multicast());
    }

    #[test]
    fn test_global_unicast() {
        assert!(!GLOBAL_UNICAST_ADDR.is_unspecified());
        assert!(!GLOBAL_UNICAST_ADDR.is_multicast());
        assert!(!GLOBAL_UNICAST_ADDR.is_link_local());
        assert!(!GLOBAL_UNICAST_ADDR.is_loopback());
        assert!(!GLOBAL_UNICAST_ADDR.is_unique_local());
        assert!(GLOBAL_UNICAST_ADDR.is_global_unicast());
        assert!(!GLOBAL_UNICAST_ADDR.is_solicited_node_multicast());
    }

    #[test]
    fn test_sollicited_node_multicast() {
        assert!(!TEST_SOL_NODE_MCAST_ADDR.is_unspecified());
        assert!(TEST_SOL_NODE_MCAST_ADDR.is_multicast());
        assert!(!TEST_SOL_NODE_MCAST_ADDR.is_link_local());
        assert!(!TEST_SOL_NODE_MCAST_ADDR.is_loopback());
        assert!(!TEST_SOL_NODE_MCAST_ADDR.is_unique_local());
        assert!(!TEST_SOL_NODE_MCAST_ADDR.is_global_unicast());
        assert!(TEST_SOL_NODE_MCAST_ADDR.is_solicited_node_multicast());
    }

    #[test]
    fn test_mask() {
        let addr = Address::new(0x0123, 0x4567, 0x89ab, 0, 0, 0, 0, 1);
        assert_eq!(
            addr.mask(11),
            [0x01, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        );
        assert_eq!(
            addr.mask(15),
            [0x01, 0x22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        );
        assert_eq!(
            addr.mask(26),
            [0x01, 0x23, 0x45, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        );
        assert_eq!(
            addr.mask(128),
            [
                0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
            ]
        );
        assert_eq!(
            addr.mask(127),
            [
                0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            ]
        );
    }

    #[test]
    fn test_cidr() {
        // fe80::1/56
        // 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        // 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        let cidr = Cidr::new(LINK_LOCAL_ADDR, 56);

        let inside_subnet = [
            // fe80::2
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x02,
            ],
            // fe80::1122:3344:5566:7788
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
                0x77, 0x88,
            ],
            // fe80::ff00:0:0:0
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00,
            ],
            // fe80::ff
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0xff,
            ],
        ];

        let outside_subnet = [
            // fe80:0:0:101::1
            [
                0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x01,
            ],
            // ::1
            [
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x01,
            ],
            // ff02::1
            [
                0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x01,
            ],
            // ff02::2
            [
                0xff, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x02,
            ],
        ];

        let subnets = [
            // fe80::ffff:ffff:ffff:ffff/65
            (
                [
                    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff,
                ],
                65,
            ),
            // fe80::1/128
            (
                [
                    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x01,
                ],
                128,
            ),
            // fe80::1234:5678/96
            (
                [
                    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12,
                    0x34, 0x56, 0x78,
                ],
                96,
            ),
        ];

        let not_subnets = [
            // fe80::101:ffff:ffff:ffff:ffff/55
            (
                [
                    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff,
                ],
                55,
            ),
            // fe80::101:ffff:ffff:ffff:ffff/56
            (
                [
                    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff,
                ],
                56,
            ),
            // fe80::101:ffff:ffff:ffff:ffff/57
            (
                [
                    0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff,
                    0xff, 0xff, 0xff,
                ],
                57,
            ),
            // ::1/128
            (
                [
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x01,
                ],
                128,
            ),
        ];

        for addr in inside_subnet.iter().map(|a| Address::from_octets(*a)) {
            assert!(cidr.contains_addr(&addr));
        }

        for addr in outside_subnet.iter().map(|a| Address::from_octets(*a)) {
            assert!(!cidr.contains_addr(&addr));
        }

        for subnet in subnets.iter().map(|&(a, p)| Cidr::new(Address::from(a), p)) {
            assert!(cidr.contains_subnet(&subnet));
        }

        for subnet in not_subnets
            .iter()
            .map(|&(a, p)| Cidr::new(Address::from(a), p))
        {
            assert!(!cidr.contains_subnet(&subnet));
        }

        let cidr_without_prefix = Cidr::new(LINK_LOCAL_ADDR, 0);
        assert!(cidr_without_prefix.contains_addr(&Address::LOCALHOST));
    }

    #[test]
    fn test_from_eui_64() {
        #[cfg(feature = "medium-ethernet")]
        use crate::wire::EthernetAddress;
        #[cfg(feature = "medium-ieee802154")]
        use crate::wire::Ieee802154Address;
        let tests: std::vec::Vec<(HardwareAddress, Address)> = vec![
            #[cfg(feature = "medium-ethernet")]
            (
                HardwareAddress::Ethernet(EthernetAddress::from_bytes(&[
                    0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
                ])),
                Address::new(0x2001, 0xdb8, 0x3, 0x0, 0xa8bb, 0xccff, 0xfedd, 0xeeff),
            ),
            #[cfg(feature = "medium-ieee802154")]
            (
                HardwareAddress::Ieee802154(Ieee802154Address::from_bytes(&[
                    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                ])),
                Address::new(0x2001, 0xdb8, 0x3, 0x0, 0x0211, 0x2233, 0x4455, 0x6677),
            ),
        ];

        let prefix = Cidr::new(GLOBAL_UNICAST_ADDR.mask(64).into(), 64);
        let wrong_prefix = Cidr::new(GLOBAL_UNICAST_ADDR.mask(72).into(), 72);

        for (hardware, result) in tests {
            let generated = Address::from_link_prefix(&prefix, hardware).unwrap();
            assert!(prefix.contains_addr(&generated));
            assert_eq!(generated, result);
            assert!(Address::from_link_prefix(&wrong_prefix, hardware).is_none());

            let generated = Cidr::from_link_prefix(&prefix, hardware).unwrap();
            assert!(prefix.contains_subnet(&generated));
            assert_eq!(generated.address(), result);
            assert!(Cidr::from_link_prefix(&wrong_prefix, hardware).is_none());
        }
    }

    #[test]
    fn test_scope() {
        use super::*;
        assert_eq!(
            Address::new(0xff01, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
            MulticastScope::InterfaceLocal
        );
        assert_eq!(
            Address::new(0xff02, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
            MulticastScope::LinkLocal
        );
        assert_eq!(
            Address::new(0xff03, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
            MulticastScope::Unknown
        );
        assert_eq!(
            Address::new(0xff04, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
            MulticastScope::AdminLocal
        );
        assert_eq!(
            Address::new(0xff05, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
            MulticastScope::SiteLocal
        );
        assert_eq!(
            Address::new(0xff08, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
            MulticastScope::OrganizationLocal
        );
        assert_eq!(
            Address::new(0xff0e, 0, 0, 0, 0, 0, 0, 1).x_multicast_scope(),
            MulticastScope::Global
        );

        assert_eq!(
            LINK_LOCAL_ALL_NODES.x_multicast_scope(),
            MulticastScope::LinkLocal
        );

        // For source address selection, unicast addresses also have a scope:
        assert_eq!(
            LINK_LOCAL_ADDR.x_multicast_scope(),
            MulticastScope::LinkLocal
        );
        assert_eq!(
            GLOBAL_UNICAST_ADDR.x_multicast_scope(),
            MulticastScope::Global
        );
        assert_eq!(
            UNIQUE_LOCAL_ADDR.x_multicast_scope(),
            MulticastScope::Global
        );
    }

    static REPR_PACKET_BYTES: [u8; 52] = [
        0x60, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x11, 0x40, 0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00,
        0x0c, 0x02, 0x4e, 0xff, 0xff, 0xff, 0xff,
    ];
    static REPR_PAYLOAD_BYTES: [u8; 12] = [
        0x00, 0x01, 0x00, 0x02, 0x00, 0x0c, 0x02, 0x4e, 0xff, 0xff, 0xff, 0xff,
    ];

    const fn packet_repr() -> Repr {
        Repr {
            src_addr: Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
            dst_addr: LINK_LOCAL_ALL_NODES,
            next_header: Protocol::Udp,
            payload_len: 12,
            hop_limit: 64,
        }
    }

    #[test]
    fn test_packet_deconstruction() {
        let packet = Packet::new_unchecked(&REPR_PACKET_BYTES[..]);
        assert_eq!(packet.check_len(), Ok(()));
        assert_eq!(packet.version(), 6);
        assert_eq!(packet.traffic_class(), 0);
        assert_eq!(packet.flow_label(), 0);
        assert_eq!(packet.total_len(), 0x34);
        assert_eq!(packet.payload_len() as usize, REPR_PAYLOAD_BYTES.len());
        assert_eq!(packet.next_header(), Protocol::Udp);
        assert_eq!(packet.hop_limit(), 0x40);
        assert_eq!(packet.src_addr(), Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1));
        assert_eq!(packet.dst_addr(), LINK_LOCAL_ALL_NODES);
        assert_eq!(packet.payload(), &REPR_PAYLOAD_BYTES[..]);
    }

    #[test]
    fn test_packet_construction() {
        let mut bytes = [0xff; 52];
        let mut packet = Packet::new_unchecked(&mut bytes[..]);
        // Version, Traffic Class, and Flow Label are not
        // byte aligned. make sure the setters and getters
        // do not interfere with each other.
        packet.set_version(6);
        assert_eq!(packet.version(), 6);
        packet.set_traffic_class(0x99);
        assert_eq!(packet.version(), 6);
        assert_eq!(packet.traffic_class(), 0x99);
        packet.set_flow_label(0x54321);
        assert_eq!(packet.traffic_class(), 0x99);
        assert_eq!(packet.flow_label(), 0x54321);
        packet.set_payload_len(0xc);
        packet.set_next_header(Protocol::Udp);
        packet.set_hop_limit(0xfe);
        packet.set_src_addr(LINK_LOCAL_ALL_ROUTERS);
        packet.set_dst_addr(LINK_LOCAL_ALL_NODES);
        packet
            .payload_mut()
            .copy_from_slice(&REPR_PAYLOAD_BYTES[..]);
        let mut expected_bytes = [
            0x69, 0x95, 0x43, 0x21, 0x00, 0x0c, 0x11, 0xfe, 0xff, 0x02, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ];
        let start = expected_bytes.len() - REPR_PAYLOAD_BYTES.len();
        expected_bytes[start..].copy_from_slice(&REPR_PAYLOAD_BYTES[..]);
        assert_eq!(packet.check_len(), Ok(()));
        assert_eq!(&*packet.into_inner(), &expected_bytes[..]);
    }

    #[test]
    fn test_overlong() {
        let mut bytes = vec![];
        bytes.extend(&REPR_PACKET_BYTES[..]);
        bytes.push(0);

        assert_eq!(
            Packet::new_unchecked(&bytes).payload().len(),
            REPR_PAYLOAD_BYTES.len()
        );
        assert_eq!(
            Packet::new_unchecked(&mut bytes).payload_mut().len(),
            REPR_PAYLOAD_BYTES.len()
        );
    }

    #[test]
    fn test_total_len_overflow() {
        let mut bytes = vec![];
        bytes.extend(&REPR_PACKET_BYTES[..]);
        Packet::new_unchecked(&mut bytes).set_payload_len(0x80);

        assert_eq!(Packet::new_checked(&bytes).unwrap_err(), Error);
    }

    #[test]
    fn test_repr_parse_valid() {
        let packet = Packet::new_unchecked(&REPR_PACKET_BYTES[..]);
        let repr = Repr::parse(&packet).unwrap();
        assert_eq!(repr, packet_repr());
    }

    #[test]
    fn test_repr_parse_bad_version() {
        let mut bytes = [0; 40];
        let mut packet = Packet::new_unchecked(&mut bytes[..]);
        packet.set_version(4);
        packet.set_payload_len(0);
        let packet = Packet::new_unchecked(&*packet.into_inner());
        assert_eq!(Repr::parse(&packet), Err(Error));
    }

    #[test]
    fn test_repr_parse_smaller_than_header() {
        let mut bytes = [0; 40];
        let mut packet = Packet::new_unchecked(&mut bytes[..]);
        packet.set_version(6);
        packet.set_payload_len(39);
        let packet = Packet::new_unchecked(&*packet.into_inner());
        assert_eq!(Repr::parse(&packet), Err(Error));
    }

    #[test]
    fn test_repr_parse_smaller_than_payload() {
        let mut bytes = [0; 40];
        let mut packet = Packet::new_unchecked(&mut bytes[..]);
        packet.set_version(6);
        packet.set_payload_len(1);
        let packet = Packet::new_unchecked(&*packet.into_inner());
        assert_eq!(Repr::parse(&packet), Err(Error));
    }

    #[test]
    fn test_basic_repr_emit() {
        let repr = packet_repr();
        let mut bytes = vec![0xff; repr.buffer_len() + REPR_PAYLOAD_BYTES.len()];
        let mut packet = Packet::new_unchecked(&mut bytes);
        repr.emit(&mut packet);
        packet.payload_mut().copy_from_slice(&REPR_PAYLOAD_BYTES);
        assert_eq!(&*packet.into_inner(), &REPR_PACKET_BYTES[..]);
    }

    #[test]
    fn test_pretty_print() {
        assert_eq!(
            format!(
                "{}",
                PrettyPrinter::<Packet<&'static [u8]>>::new("\n", &&REPR_PACKET_BYTES[..])
            ),
            "\nIPv6 src=fe80::1 dst=ff02::1 nxt_hdr=UDP hop_limit=64\n \\ UDP src=1 dst=2 len=4"
        );
    }
}
