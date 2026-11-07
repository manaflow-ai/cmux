//! Implementation of Next Header Compression from [RFC 6282 § 4].
//!
//! [RFC 6282 § 4]: https://datatracker.ietf.org/doc/html/rfc6282#section-4
use super::{DISPATCH_EXT_HEADER, DISPATCH_UDP_HEADER, Error, NextHeader, Result};
use crate::{
    phy::ChecksumCapabilities,
    wire::{IpProtocol, ip::checksum, ipv6, udp::Repr as UdpRepr},
};
use byteorder::{ByteOrder, NetworkEndian};
use ipv6::Address;

macro_rules! get_field {
    ($name:ident, $mask:expr, $shift:expr) => {
        fn $name(&self) -> u8 {
            let data = self.buffer.as_ref();
            let raw = &data[0];
            ((raw >> $shift) & $mask) as u8
        }
    };
}

macro_rules! set_field {
    ($name:ident, $mask:expr, $shift:expr) => {
        fn $name(&mut self, val: u8) {
            let data = self.buffer.as_mut();
            let mut raw = data[0];
            raw = (raw & !($mask << $shift)) | (val << $shift);
            data[0] = raw;
        }
    };
}

#[derive(Debug, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
/// A read/write wrapper around a 6LoWPAN_NHC Header.
/// [RFC 6282 § 4.2] specifies the format of the header.
///
/// The header has the following format:
/// ```txt
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | 1 | 1 | 1 | 0 |    EID    |NH |
/// +---+---+---+---+---+---+---+---+
/// ```
///
/// With:
/// - EID: the extension header ID
/// - NH: Next Header
///
/// [RFC 6282 § 4.2]: https://datatracker.ietf.org/doc/html/rfc6282#section-4.2
pub enum NhcPacket {
    ExtHeader,
    UdpHeader,
}

impl NhcPacket {
    /// Returns the type of the Next Header header.
    /// This can either be an Extension header or an 6LoWPAN Udp header.
    ///
    /// # Errors
    /// Returns `[Error::Unrecognized]` when neither the Extension Header dispatch or the Udp
    /// dispatch is recognized.
    pub fn dispatch(buffer: impl AsRef<[u8]>) -> Result<Self> {
        let raw = buffer.as_ref();
        if raw.is_empty() {
            return Err(Error);
        }

        if raw[0] >> 4 == DISPATCH_EXT_HEADER {
            // We have a compressed IPv6 Extension Header.
            Ok(Self::ExtHeader)
        } else if raw[0] >> 3 == DISPATCH_UDP_HEADER {
            // We have a compressed UDP header.
            Ok(Self::UdpHeader)
        } else {
            Err(Error)
        }
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum ExtHeaderId {
    HopByHopHeader,
    RoutingHeader,
    FragmentHeader,
    DestinationOptionsHeader,
    MobilityHeader,
    Header,
    Reserved,
}

impl From<ExtHeaderId> for IpProtocol {
    fn from(val: ExtHeaderId) -> Self {
        match val {
            ExtHeaderId::HopByHopHeader => Self::HopByHop,
            ExtHeaderId::RoutingHeader => Self::Ipv6Route,
            ExtHeaderId::FragmentHeader => Self::Ipv6Frag,
            ExtHeaderId::DestinationOptionsHeader => Self::Ipv6Opts,
            ExtHeaderId::MobilityHeader => Self::Unknown(0),
            ExtHeaderId::Header => Self::Unknown(0),
            ExtHeaderId::Reserved => Self::Unknown(0),
        }
    }
}

/// A read/write wrapper around a 6LoWPAN NHC Extension header.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct ExtHeaderPacket<T: AsRef<[u8]>> {
    buffer: T,
}

impl<T: AsRef<[u8]>> ExtHeaderPacket<T> {
    /// Input a raw octet buffer with a 6LoWPAN NHC Extension Header structure.
    pub const fn new_unchecked(buffer: T) -> Self {
        ExtHeaderPacket { buffer }
    }

    /// Shorthand for a combination of [new_unchecked] and [check_len].
    ///
    /// [new_unchecked]: #method.new_unchecked
    /// [check_len]: #method.check_len
    pub fn new_checked(buffer: T) -> Result<Self> {
        let packet = Self::new_unchecked(buffer);
        packet.check_len()?;

        if packet.eid_field() > 7 {
            return Err(Error);
        }

        Ok(packet)
    }

    /// Ensure that no accessor method will panic if called.
    /// Returns `Err(Error)` if the buffer is too short.
    pub fn check_len(&self) -> Result<()> {
        let buffer = self.buffer.as_ref();

        if buffer.is_empty() {
            return Err(Error);
        }

        let mut len = 2;
        len += self.next_header_size();

        if len <= buffer.len() {
            Ok(())
        } else {
            Err(Error)
        }
    }

    /// Consumes the frame, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    get_field!(dispatch_field, 0b1111, 4);
    get_field!(eid_field, 0b111, 1);
    get_field!(nh_field, 0b1, 0);

    /// Return the Extension Header ID.
    pub fn extension_header_id(&self) -> ExtHeaderId {
        match self.eid_field() {
            0 => ExtHeaderId::HopByHopHeader,
            1 => ExtHeaderId::RoutingHeader,
            2 => ExtHeaderId::FragmentHeader,
            3 => ExtHeaderId::DestinationOptionsHeader,
            4 => ExtHeaderId::MobilityHeader,
            5 | 6 => ExtHeaderId::Reserved,
            7 => ExtHeaderId::Header,
            _ => unreachable!(),
        }
    }

    /// Return the length field.
    pub fn length(&self) -> u8 {
        self.buffer.as_ref()[1 + self.next_header_size()]
    }

    /// Parse the next header field.
    pub fn next_header(&self) -> NextHeader {
        if self.nh_field() == 1 {
            NextHeader::Compressed
        } else {
            // The full 8 bits for Next Header are carried in-line.
            NextHeader::Uncompressed(IpProtocol::from(self.buffer.as_ref()[1]))
        }
    }

    /// Return the size of the Next Header field.
    fn next_header_size(&self) -> usize {
        // If nh is set, then the Next Header is compressed using LOWPAN_NHC
        match self.nh_field() {
            0 => 1,
            1 => 0,
            _ => unreachable!(),
        }
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> ExtHeaderPacket<&'a T> {
    /// Return a pointer to the payload.
    pub fn payload(&self) -> &'a [u8] {
        let start = 2 + self.next_header_size();
        let len = self.length() as usize;
        &self.buffer.as_ref()[start..][..len]
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> ExtHeaderPacket<T> {
    /// Return a mutable pointer to the payload.
    pub fn payload_mut(&mut self) -> &mut [u8] {
        let start = 2 + self.next_header_size();
        let len = self.length() as usize;
        &mut self.buffer.as_mut()[start..][..len]
    }

    /// Set the dispatch field to `0b1110`.
    fn set_dispatch_field(&mut self) {
        let data = self.buffer.as_mut();
        data[0] = (data[0] & !(0b1111 << 4)) | (DISPATCH_EXT_HEADER << 4);
    }

    set_field!(set_eid_field, 0b111, 1);
    set_field!(set_nh_field, 0b1, 0);

    /// Set the Extension Header ID field.
    fn set_extension_header_id(&mut self, ext_header_id: ExtHeaderId) {
        let id = match ext_header_id {
            ExtHeaderId::HopByHopHeader => 0,
            ExtHeaderId::RoutingHeader => 1,
            ExtHeaderId::FragmentHeader => 2,
            ExtHeaderId::DestinationOptionsHeader => 3,
            ExtHeaderId::MobilityHeader => 4,
            ExtHeaderId::Reserved => 5,
            ExtHeaderId::Header => 7,
        };

        self.set_eid_field(id);
    }

    /// Set the Next Header.
    fn set_next_header(&mut self, next_header: NextHeader) {
        match next_header {
            NextHeader::Compressed => self.set_nh_field(0b1),
            NextHeader::Uncompressed(nh) => {
                self.set_nh_field(0b0);

                let start = 1;
                let data = self.buffer.as_mut();
                data[start] = nh.into();
            }
        }
    }

    /// Set the length.
    fn set_length(&mut self, length: u8) {
        let start = 1 + self.next_header_size();

        let data = self.buffer.as_mut();
        data[start] = length;
    }
}

/// A high-level representation of an 6LoWPAN NHC Extension header.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct ExtHeaderRepr {
    pub ext_header_id: ExtHeaderId,
    pub next_header: NextHeader,
    pub length: u8,
}

impl ExtHeaderRepr {
    /// Parse a 6LoWPAN NHC Extension Header packet and return a high-level representation.
    pub fn parse<T: AsRef<[u8]> + ?Sized>(packet: &ExtHeaderPacket<&T>) -> Result<Self> {
        // Ensure basic accessors will work.
        packet.check_len()?;

        if packet.dispatch_field() != DISPATCH_EXT_HEADER {
            return Err(Error);
        }

        Ok(Self {
            ext_header_id: packet.extension_header_id(),
            next_header: packet.next_header(),
            length: packet.length(),
        })
    }

    /// Return the length of a header that will be emitted from this high-level representation.
    pub fn buffer_len(&self) -> usize {
        let mut len = 1; // The minimal header size

        if self.next_header != NextHeader::Compressed {
            len += 1;
        }

        len += 1; // The length

        len
    }

    /// Emit a high-level representation into a 6LoWPAN NHC Extension Header packet.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]>>(&self, packet: &mut ExtHeaderPacket<T>) {
        packet.set_dispatch_field();
        packet.set_extension_header_id(self.ext_header_id);
        packet.set_next_header(self.next_header);
        packet.set_length(self.length);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::wire::{Ipv6RoutingHeader, Ipv6RoutingRepr};

    #[cfg(feature = "proto-rpl")]
    use crate::wire::{
        Ipv6Option, Ipv6OptionRepr, Ipv6OptionsIterator, RplHopByHopRepr, RplInstanceId,
    };

    #[cfg(feature = "proto-rpl")]
    const RPL_HOP_BY_HOP_PACKET: [u8; 9] = [0xe0, 0x3a, 0x06, 0x63, 0x04, 0x00, 0x1e, 0x03, 0x00];

    const ROUTING_SR_PACKET: [u8; 32] = [
        0xe3, 0x1e, 0x03, 0x03, 0x99, 0x30, 0x00, 0x00, 0x05, 0x00, 0x05, 0x00, 0x05, 0x00, 0x05,
        0x06, 0x00, 0x06, 0x00, 0x06, 0x00, 0x06, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00,
        0x00, 0x00,
    ];

    #[test]
    #[cfg(feature = "proto-rpl")]
    fn test_rpl_hop_by_hop_option_deconstruct() {
        let header = ExtHeaderPacket::new_checked(&RPL_HOP_BY_HOP_PACKET).unwrap();
        assert_eq!(
            header.next_header(),
            NextHeader::Uncompressed(IpProtocol::Icmpv6)
        );
        assert_eq!(header.extension_header_id(), ExtHeaderId::HopByHopHeader);

        let options = header.payload();
        let mut options = Ipv6OptionsIterator::new(options);
        let rpl_repr = options.next().unwrap();
        let rpl_repr = rpl_repr.unwrap();

        match rpl_repr {
            Ipv6OptionRepr::Rpl(rpl) => {
                assert_eq!(
                    rpl,
                    RplHopByHopRepr {
                        down: false,
                        rank_error: false,
                        forwarding_error: false,
                        instance_id: RplInstanceId::from(0x1e),
                        sender_rank: 0x0300,
                    }
                );
            }
            _ => unreachable!(),
        }
    }

    #[test]
    #[cfg(feature = "proto-rpl")]
    fn test_rpl_hop_by_hop_option_emit() {
        let repr = Ipv6OptionRepr::Rpl(RplHopByHopRepr {
            down: false,
            rank_error: false,
            forwarding_error: false,
            instance_id: RplInstanceId::from(0x1e),
            sender_rank: 0x0300,
        });

        let ext_hdr = ExtHeaderRepr {
            ext_header_id: ExtHeaderId::HopByHopHeader,
            next_header: NextHeader::Uncompressed(IpProtocol::Icmpv6),
            length: repr.buffer_len() as u8,
        };

        let mut buffer = vec![0u8; ext_hdr.buffer_len() + repr.buffer_len()];
        ext_hdr.emit(&mut ExtHeaderPacket::new_unchecked(
            &mut buffer[..ext_hdr.buffer_len()],
        ));
        repr.emit(&mut Ipv6Option::new_unchecked(
            &mut buffer[ext_hdr.buffer_len()..],
        ));

        assert_eq!(&buffer[..], RPL_HOP_BY_HOP_PACKET);
    }

    #[test]
    fn test_source_routing_deconstruct() {
        let header = ExtHeaderPacket::new_checked(&ROUTING_SR_PACKET).unwrap();
        assert_eq!(header.next_header(), NextHeader::Compressed);
        assert_eq!(header.extension_header_id(), ExtHeaderId::RoutingHeader);

        let routing_hdr = Ipv6RoutingHeader::new_checked(header.payload()).unwrap();
        let repr = Ipv6RoutingRepr::parse(&routing_hdr).unwrap();
        assert_eq!(
            repr,
            Ipv6RoutingRepr::Rpl {
                segments_left: 3,
                cmpr_i: 9,
                cmpr_e: 9,
                pad: 3,
                addresses: &[
                    0x05, 0x00, 0x05, 0x00, 0x05, 0x00, 0x05, 0x06, 0x00, 0x06, 0x00, 0x06, 0x00,
                    0x06, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00
                ],
            }
        );
    }

    #[test]
    fn test_source_routing_emit() {
        let routing_hdr = Ipv6RoutingRepr::Rpl {
            segments_left: 3,
            cmpr_i: 9,
            cmpr_e: 9,
            pad: 3,
            addresses: &[
                0x05, 0x00, 0x05, 0x00, 0x05, 0x00, 0x05, 0x06, 0x00, 0x06, 0x00, 0x06, 0x00, 0x06,
                0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00,
            ],
        };

        let ext_hdr = ExtHeaderRepr {
            ext_header_id: ExtHeaderId::RoutingHeader,
            next_header: NextHeader::Compressed,
            length: routing_hdr.buffer_len() as u8,
        };

        let mut buffer = vec![0u8; ext_hdr.buffer_len() + routing_hdr.buffer_len()];
        ext_hdr.emit(&mut ExtHeaderPacket::new_unchecked(
            &mut buffer[..ext_hdr.buffer_len()],
        ));
        routing_hdr.emit(&mut Ipv6RoutingHeader::new_unchecked(
            &mut buffer[ext_hdr.buffer_len()..],
        ));

        assert_eq!(&buffer[..], ROUTING_SR_PACKET);
    }
}

/// A read/write wrapper around a 6LoWPAN_NHC UDP frame.
/// [RFC 6282 § 4.3] specifies the format of the header.
///
/// The base header has the following format:
/// ```txt
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | 1 | 1 | 1 | 1 | 0 | C |   P   |
/// +---+---+---+---+---+---+---+---+
/// With:
/// - C: checksum, specifies if the checksum is elided.
/// - P: ports, specifies if the ports are elided.
/// ```
///
/// [RFC 6282 § 4.3]: https://datatracker.ietf.org/doc/html/rfc6282#section-4.3
#[derive(Debug, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct UdpNhcPacket<T: AsRef<[u8]>> {
    buffer: T,
}

impl<T: AsRef<[u8]>> UdpNhcPacket<T> {
    /// Input a raw octet buffer with a LOWPAN_NHC frame structure for UDP.
    pub const fn new_unchecked(buffer: T) -> Self {
        Self { buffer }
    }

    /// Shorthand for a combination of [new_unchecked] and [check_len].
    ///
    /// [new_unchecked]: #method.new_unchecked
    /// [check_len]: #method.check_len
    pub fn new_checked(buffer: T) -> Result<Self> {
        let packet = Self::new_unchecked(buffer);
        packet.check_len()?;
        Ok(packet)
    }

    /// Ensure that no accessor method will panic if called.
    /// Returns `Err(Error::Truncated)` if the buffer is too short.
    pub fn check_len(&self) -> Result<()> {
        let buffer = self.buffer.as_ref();

        if buffer.is_empty() {
            return Err(Error);
        }

        let index = 1 + self.ports_size() + self.checksum_size();
        if index > buffer.len() {
            return Err(Error);
        }

        Ok(())
    }

    /// Consumes the frame, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    get_field!(dispatch_field, 0b11111, 3);
    get_field!(checksum_field, 0b1, 2);
    get_field!(ports_field, 0b11, 0);

    /// Returns the index of the start of the next header compressed fields.
    const fn nhc_fields_start(&self) -> usize {
        1
    }

    /// Return the source port number.
    pub fn src_port(&self) -> u16 {
        match self.ports_field() {
            0b00 | 0b01 => {
                // The full 16 bits are carried in-line.
                let data = self.buffer.as_ref();
                let start = self.nhc_fields_start();

                NetworkEndian::read_u16(&data[start..start + 2])
            }
            0b10 => {
                // The first 8 bits are elided.
                let data = self.buffer.as_ref();
                let start = self.nhc_fields_start();

                0xf000 + data[start] as u16
            }
            0b11 => {
                // The first 12 bits are elided.
                let data = self.buffer.as_ref();
                let start = self.nhc_fields_start();

                0xf0b0 + (data[start] >> 4) as u16
            }
            _ => unreachable!(),
        }
    }

    /// Return the destination port number.
    pub fn dst_port(&self) -> u16 {
        match self.ports_field() {
            0b00 => {
                // The full 16 bits are carried in-line.
                let data = self.buffer.as_ref();
                let idx = self.nhc_fields_start();

                NetworkEndian::read_u16(&data[idx + 2..idx + 4])
            }
            0b01 => {
                // The first 8 bits are elided.
                let data = self.buffer.as_ref();
                let idx = self.nhc_fields_start();

                0xf000 + data[idx] as u16
            }
            0b10 => {
                // The full 16 bits are carried in-line.
                let data = self.buffer.as_ref();
                let idx = self.nhc_fields_start();

                NetworkEndian::read_u16(&data[idx + 1..idx + 1 + 2])
            }
            0b11 => {
                // The first 12 bits are elided.
                let data = self.buffer.as_ref();
                let start = self.nhc_fields_start();

                0xf0b0 + (data[start] & 0xff) as u16
            }
            _ => unreachable!(),
        }
    }

    /// Return the checksum.
    pub fn checksum(&self) -> Option<u16> {
        if self.checksum_field() == 0b0 {
            // The first 12 bits are elided.
            let data = self.buffer.as_ref();
            let start = self.nhc_fields_start() + self.ports_size();
            Some(NetworkEndian::read_u16(&data[start..start + 2]))
        } else {
            // The checksum is elided and needs to be recomputed on the 6LoWPAN termination point.
            None
        }
    }

    // Return the size of the checksum field.
    pub(crate) fn checksum_size(&self) -> usize {
        match self.checksum_field() {
            0b0 => 2,
            0b1 => 0,
            _ => unreachable!(),
        }
    }

    /// Returns the total size of both port numbers.
    pub(crate) fn ports_size(&self) -> usize {
        match self.ports_field() {
            0b00 => 4, // 16 bits + 16 bits
            0b01 => 3, // 16 bits + 8 bits
            0b10 => 3, // 8 bits + 16 bits
            0b11 => 1, // 4 bits + 4 bits
            _ => unreachable!(),
        }
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> UdpNhcPacket<&'a T> {
    /// Return a pointer to the payload.
    pub fn payload(&self) -> &'a [u8] {
        let start = 1 + self.ports_size() + self.checksum_size();
        &self.buffer.as_ref()[start..]
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> UdpNhcPacket<T> {
    /// Return a mutable pointer to the payload.
    pub fn payload_mut(&mut self) -> &mut [u8] {
        let start = 1 + self.ports_size() + 2; // XXX(thvdveld): we assume we put the checksum inlined.
        &mut self.buffer.as_mut()[start..]
    }

    /// Set the dispatch field to `0b11110`.
    fn set_dispatch_field(&mut self) {
        let data = self.buffer.as_mut();
        data[0] = (data[0] & !(0b11111 << 3)) | (DISPATCH_UDP_HEADER << 3);
    }

    set_field!(set_checksum_field, 0b1, 2);
    set_field!(set_ports_field, 0b11, 0);

    fn set_ports(&mut self, src_port: u16, dst_port: u16) {
        let mut idx = 1;

        match (src_port, dst_port) {
            (0xf0b0..=0xf0bf, 0xf0b0..=0xf0bf) => {
                // We can compress both the source and destination ports.
                self.set_ports_field(0b11);
                let data = self.buffer.as_mut();
                data[idx] = (((src_port - 0xf0b0) as u8) << 4) & ((dst_port - 0xf0b0) as u8);
            }
            (0xf000..=0xf0ff, _) => {
                // We can compress the source port, but not the destination port.
                self.set_ports_field(0b10);
                let data = self.buffer.as_mut();
                data[idx] = (src_port - 0xf000) as u8;
                idx += 1;

                NetworkEndian::write_u16(&mut data[idx..idx + 2], dst_port);
            }
            (_, 0xf000..=0xf0ff) => {
                // We can compress the destination port, but not the source port.
                self.set_ports_field(0b01);
                let data = self.buffer.as_mut();
                NetworkEndian::write_u16(&mut data[idx..idx + 2], src_port);
                idx += 2;
                data[idx] = (dst_port - 0xf000) as u8;
            }
            (_, _) => {
                // We cannot compress any port.
                self.set_ports_field(0b00);
                let data = self.buffer.as_mut();
                NetworkEndian::write_u16(&mut data[idx..idx + 2], src_port);
                idx += 2;
                NetworkEndian::write_u16(&mut data[idx..idx + 2], dst_port);
            }
        };
    }

    fn set_checksum(&mut self, checksum: u16) {
        self.set_checksum_field(0b0);
        let idx = 1 + self.ports_size();
        let data = self.buffer.as_mut();
        NetworkEndian::write_u16(&mut data[idx..idx + 2], checksum);
    }
}

/// A high-level representation of a 6LoWPAN NHC UDP header.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct UdpNhcRepr(pub UdpRepr);

impl<'a> UdpNhcRepr {
    /// Parse a 6LoWPAN NHC UDP packet and return a high-level representation.
    pub fn parse<T: AsRef<[u8]> + ?Sized>(
        packet: &UdpNhcPacket<&'a T>,
        src_addr: &ipv6::Address,
        dst_addr: &ipv6::Address,
        checksum_caps: &ChecksumCapabilities,
    ) -> Result<Self> {
        packet.check_len()?;

        if packet.dispatch_field() != DISPATCH_UDP_HEADER {
            return Err(Error);
        }

        if checksum_caps.udp.rx() {
            let payload_len = packet.payload().len();
            let chk_sum = !checksum::combine(&[
                checksum::pseudo_header_v6(
                    src_addr,
                    dst_addr,
                    crate::wire::ip::Protocol::Udp,
                    payload_len as u32 + 8,
                ),
                packet.src_port(),
                packet.dst_port(),
                payload_len as u16 + 8,
                checksum::data(packet.payload()),
            ]);

            if let Some(checksum) = packet.checksum()
                && chk_sum != checksum
            {
                return Err(Error);
            }
        }

        Ok(Self(UdpRepr {
            src_port: packet.src_port(),
            dst_port: packet.dst_port(),
        }))
    }

    /// Return the length of a packet that will be emitted from this high-level representation.
    pub fn header_len(&self) -> usize {
        let mut len = 1; // The minimal header size

        len += 2; // XXX We assume we will add the checksum at the end

        // Check if we can compress the source and destination ports
        match (self.src_port, self.dst_port) {
            (0xf0b0..=0xf0bf, 0xf0b0..=0xf0bf) => len + 1,
            (0xf000..=0xf0ff, _) | (_, 0xf000..=0xf0ff) => len + 3,
            (_, _) => len + 4,
        }
    }

    /// Emit a high-level representation into a LOWPAN_NHC UDP header.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]>>(
        &self,
        packet: &mut UdpNhcPacket<T>,
        src_addr: &Address,
        dst_addr: &Address,
        payload_len: usize,
        emit_payload: impl FnOnce(&mut [u8]),
        checksum_caps: &ChecksumCapabilities,
    ) {
        packet.set_dispatch_field();
        packet.set_ports(self.src_port, self.dst_port);
        emit_payload(packet.payload_mut());

        if checksum_caps.udp.tx() {
            let chk_sum = !checksum::combine(&[
                checksum::pseudo_header_v6(
                    src_addr,
                    dst_addr,
                    crate::wire::ip::Protocol::Udp,
                    payload_len as u32 + 8,
                ),
                self.src_port,
                self.dst_port,
                payload_len as u16 + 8,
                checksum::data(packet.payload_mut()),
            ]);

            packet.set_checksum(chk_sum);
        }
    }
}

impl core::ops::Deref for UdpNhcRepr {
    type Target = UdpRepr;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl core::ops::DerefMut for UdpNhcRepr {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn ext_header_nh_inlined() {
        let bytes = [0xe2, 0x3a, 0x6, 0x3, 0x0, 0xff, 0x0, 0x0, 0x0];

        let packet = ExtHeaderPacket::new_checked(&bytes[..]).unwrap();
        assert_eq!(packet.next_header_size(), 1);
        assert_eq!(packet.length(), 6);
        assert_eq!(packet.dispatch_field(), DISPATCH_EXT_HEADER);
        assert_eq!(packet.extension_header_id(), ExtHeaderId::RoutingHeader);
        assert_eq!(
            packet.next_header(),
            NextHeader::Uncompressed(IpProtocol::Icmpv6)
        );

        assert_eq!(packet.payload(), [0x03, 0x00, 0xff, 0x00, 0x00, 0x00]);
    }

    #[test]
    fn ext_header_nh_elided() {
        let bytes = [0xe3, 0x06, 0x03, 0x00, 0xff, 0x00, 0x00, 0x00];

        let packet = ExtHeaderPacket::new_checked(&bytes[..]).unwrap();
        assert_eq!(packet.next_header_size(), 0);
        assert_eq!(packet.length(), 6);
        assert_eq!(packet.dispatch_field(), DISPATCH_EXT_HEADER);
        assert_eq!(packet.extension_header_id(), ExtHeaderId::RoutingHeader);
        assert_eq!(packet.next_header(), NextHeader::Compressed);

        assert_eq!(packet.payload(), [0x03, 0x00, 0xff, 0x00, 0x00, 0x00]);
    }

    #[test]
    fn ext_header_emit() {
        let ext_header = ExtHeaderRepr {
            ext_header_id: ExtHeaderId::RoutingHeader,
            next_header: NextHeader::Compressed,
            length: 6,
        };

        let len = ext_header.buffer_len();
        let mut buffer = [0u8; 127];
        let mut packet = ExtHeaderPacket::new_unchecked(&mut buffer[..len]);
        ext_header.emit(&mut packet);

        assert_eq!(packet.dispatch_field(), DISPATCH_EXT_HEADER);
        assert_eq!(packet.next_header(), NextHeader::Compressed);
        assert_eq!(packet.extension_header_id(), ExtHeaderId::RoutingHeader);
    }

    #[test]
    fn udp_nhc_fields() {
        let bytes = [0xf0, 0x16, 0x2e, 0x22, 0x3d, 0x28, 0xc4];

        let packet = UdpNhcPacket::new_checked(&bytes[..]).unwrap();
        assert_eq!(packet.dispatch_field(), DISPATCH_UDP_HEADER);
        assert_eq!(packet.checksum(), Some(0x28c4));
        assert_eq!(packet.src_port(), 5678);
        assert_eq!(packet.dst_port(), 8765);
    }

    #[test]
    fn udp_emit() {
        let udp = UdpNhcRepr(UdpRepr {
            src_port: 0xf0b1,
            dst_port: 0xf001,
        });

        let payload = b"Hello World!";

        let src_addr = ipv6::Address::UNSPECIFIED;
        let dst_addr = ipv6::Address::UNSPECIFIED;

        let len = udp.header_len() + payload.len();
        let mut buffer = [0u8; 127];
        let mut packet = UdpNhcPacket::new_unchecked(&mut buffer[..len]);
        udp.emit(
            &mut packet,
            &src_addr,
            &dst_addr,
            payload.len(),
            |buf| buf.copy_from_slice(&payload[..]),
            &ChecksumCapabilities::default(),
        );

        assert_eq!(packet.dispatch_field(), DISPATCH_UDP_HEADER);
        assert_eq!(packet.src_port(), 0xf0b1);
        assert_eq!(packet.dst_port(), 0xf001);
        assert_eq!(packet.payload_mut(), b"Hello World!");
    }
}
