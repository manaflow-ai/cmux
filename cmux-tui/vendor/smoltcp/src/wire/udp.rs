use byteorder::{ByteOrder, NetworkEndian};
use core::fmt;

use super::{Error, Result};
use crate::phy::ChecksumCapabilities;
use crate::wire::ip::checksum;
use crate::wire::{IpAddress, IpProtocol};

/// A read/write wrapper around an User Datagram Protocol packet buffer.
#[derive(Debug, PartialEq, Eq, Clone)]
pub struct Packet<T: AsRef<[u8]>> {
    buffer: T,
}

mod field {
    #![allow(non_snake_case)]

    use crate::wire::field::*;

    pub const SRC_PORT: Field = 0..2;
    pub const DST_PORT: Field = 2..4;
    pub const LENGTH: Field = 4..6;
    pub const CHECKSUM: Field = 6..8;

    pub const fn PAYLOAD(length: u16) -> Field {
        CHECKSUM.end..(length as usize)
    }
}

pub const HEADER_LEN: usize = field::CHECKSUM.end;

#[allow(clippy::len_without_is_empty)]
impl<T: AsRef<[u8]>> Packet<T> {
    /// Imbue a raw octet buffer with UDP packet structure.
    pub const fn new_unchecked(buffer: T) -> Packet<T> {
        Packet { buffer }
    }

    /// Shorthand for a combination of [new_unchecked] and [check_len].
    ///
    /// [new_unchecked]: #method.new_unchecked
    /// [check_len]: #method.check_len
    pub fn new_checked(buffer: T) -> Result<Packet<T>> {
        let packet = Self::new_unchecked(buffer);
        packet.check_len()?;
        Ok(packet)
    }

    /// Ensure that no accessor method will panic if called.
    /// Returns `Err(Error)` if the buffer is too short.
    /// Returns `Err(Error)` if the length field has a value smaller
    /// than the header length.
    ///
    /// The result of this check is invalidated by calling [set_len].
    ///
    /// [set_len]: #method.set_len
    pub fn check_len(&self) -> Result<()> {
        let buffer_len = self.buffer.as_ref().len();
        if buffer_len < HEADER_LEN {
            Err(Error)
        } else {
            let field_len = self.len() as usize;
            if buffer_len < field_len || field_len < HEADER_LEN {
                Err(Error)
            } else {
                Ok(())
            }
        }
    }

    /// Consume the packet, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Return the source port field.
    #[inline]
    pub fn src_port(&self) -> u16 {
        let data = self.buffer.as_ref();
        NetworkEndian::read_u16(&data[field::SRC_PORT])
    }

    /// Return the destination port field.
    #[inline]
    pub fn dst_port(&self) -> u16 {
        let data = self.buffer.as_ref();
        NetworkEndian::read_u16(&data[field::DST_PORT])
    }

    /// Return the length field.
    #[inline]
    pub fn len(&self) -> u16 {
        let data = self.buffer.as_ref();
        NetworkEndian::read_u16(&data[field::LENGTH])
    }

    /// Return the checksum field.
    #[inline]
    pub fn checksum(&self) -> u16 {
        let data = self.buffer.as_ref();
        NetworkEndian::read_u16(&data[field::CHECKSUM])
    }

    /// Validate the partial packet checksum.
    ///
    /// # Panics
    /// This function panics unless `src_addr` and `dst_addr` belong to the same family,
    /// and that family is IPv4 or IPv6.
    ///
    /// # Fuzzing
    /// This function always returns `true` when fuzzing.
    pub fn verify_partial_checksum(&self, src_addr: &IpAddress, dst_addr: &IpAddress) -> bool {
        if cfg!(fuzzing) {
            return true;
        }

        checksum::pseudo_header(src_addr, dst_addr, IpProtocol::Udp, self.len() as u32)
            == self.checksum()
    }

    /// Validate the packet checksum.
    ///
    /// # Panics
    /// This function panics unless `src_addr` and `dst_addr` belong to the same family,
    /// and that family is IPv4 or IPv6.
    ///
    /// # Fuzzing
    /// This function always returns `true` when fuzzing.
    pub fn verify_checksum(&self, src_addr: &IpAddress, dst_addr: &IpAddress) -> bool {
        if cfg!(fuzzing) {
            return true;
        }

        // From the RFC:
        // > An all zero transmitted checksum value means that the transmitter
        // > generated no checksum (for debugging or for higher level protocols
        // > that don't care).
        if self.checksum() == 0 {
            return true;
        }

        let data = self.buffer.as_ref();
        checksum::combine(&[
            checksum::pseudo_header(src_addr, dst_addr, IpProtocol::Udp, self.len() as u32),
            checksum::data(&data[..self.len() as usize]),
        ]) == !0
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> Packet<&'a T> {
    /// Return a pointer to the payload.
    #[inline]
    pub fn payload(&self) -> &'a [u8] {
        let length = self.len();
        let data = self.buffer.as_ref();
        &data[field::PAYLOAD(length)]
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Packet<T> {
    /// Set the source port field.
    #[inline]
    pub fn set_src_port(&mut self, value: u16) {
        let data = self.buffer.as_mut();
        NetworkEndian::write_u16(&mut data[field::SRC_PORT], value)
    }

    /// Set the destination port field.
    #[inline]
    pub fn set_dst_port(&mut self, value: u16) {
        let data = self.buffer.as_mut();
        NetworkEndian::write_u16(&mut data[field::DST_PORT], value)
    }

    /// Set the length field.
    #[inline]
    pub fn set_len(&mut self, value: u16) {
        let data = self.buffer.as_mut();
        NetworkEndian::write_u16(&mut data[field::LENGTH], value)
    }

    /// Set the checksum field.
    #[inline]
    pub fn set_checksum(&mut self, value: u16) {
        let data = self.buffer.as_mut();
        NetworkEndian::write_u16(&mut data[field::CHECKSUM], value)
    }

    /// Compute and fill in the header checksum.
    ///
    /// # Panics
    /// This function panics unless `src_addr` and `dst_addr` belong to the same family,
    /// and that family is IPv4 or IPv6.
    pub fn fill_checksum(&mut self, src_addr: &IpAddress, dst_addr: &IpAddress) {
        self.set_checksum(0);
        let checksum = {
            let data = self.buffer.as_ref();
            !checksum::combine(&[
                checksum::pseudo_header(src_addr, dst_addr, IpProtocol::Udp, self.len() as u32),
                checksum::data(&data[..self.len() as usize]),
            ])
        };
        // UDP checksum value of 0 means no checksum; if the checksum really is zero,
        // use all-ones, which indicates that the remote end must verify the checksum.
        // Arithmetically, RFC 1071 checksums of all-zeroes and all-ones behave identically,
        // so no action is necessary on the remote end.
        self.set_checksum(if checksum == 0 { 0xffff } else { checksum })
    }

    /// Return a mutable pointer to the payload.
    #[inline]
    pub fn payload_mut(&mut self) -> &mut [u8] {
        let length = self.len();
        let data = self.buffer.as_mut();
        &mut data[field::PAYLOAD(length)]
    }
}

impl<T: AsRef<[u8]>> AsRef<[u8]> for Packet<T> {
    fn as_ref(&self) -> &[u8] {
        self.buffer.as_ref()
    }
}

/// A high-level representation of an User Datagram Protocol packet.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct Repr {
    pub src_port: u16,
    pub dst_port: u16,
}

impl Repr {
    /// Parse an User Datagram Protocol packet and return a high-level representation.
    pub fn parse<T>(
        packet: &Packet<&T>,
        src_addr: &IpAddress,
        dst_addr: &IpAddress,
        checksum_caps: &ChecksumCapabilities,
    ) -> Result<Repr>
    where
        T: AsRef<[u8]> + ?Sized,
    {
        packet.check_len()?;

        // Destination port cannot be omitted (but source port can be).
        if packet.dst_port() == 0 {
            return Err(Error);
        }
        // Valid checksum is expected...
        if checksum_caps.udp.rx() && !packet.verify_checksum(src_addr, dst_addr) {
            match (src_addr, dst_addr) {
                // ... except on UDP-over-IPv4, where it can be omitted.
                #[cfg(feature = "proto-ipv4")]
                (&IpAddress::Ipv4(_), &IpAddress::Ipv4(_)) if packet.checksum() == 0 => (),
                _ => return Err(Error),
            }
        }

        Ok(Repr {
            src_port: packet.src_port(),
            dst_port: packet.dst_port(),
        })
    }

    /// Return the length of the packet header that will be emitted from this high-level representation.
    pub const fn header_len(&self) -> usize {
        HEADER_LEN
    }

    /// Emit a high-level representation into an User Datagram Protocol packet.
    ///
    /// This never calculates the checksum, and is intended for internal-use only,
    /// not for packets that are going to be actually sent over the network. For
    /// example, when decompressing 6lowpan.
    pub(crate) fn emit_header<T>(&self, packet: &mut Packet<&mut T>, payload_len: usize)
    where
        T: AsRef<[u8]> + AsMut<[u8]> + ?Sized,
    {
        packet.set_src_port(self.src_port);
        packet.set_dst_port(self.dst_port);
        packet.set_len((HEADER_LEN + payload_len) as u16);
        packet.set_checksum(0);
    }

    /// Emit a high-level representation into an User Datagram Protocol packet.
    pub fn emit<T>(
        &self,
        packet: &mut Packet<&mut T>,
        src_addr: &IpAddress,
        dst_addr: &IpAddress,
        payload_len: usize,
        emit_payload: impl FnOnce(&mut [u8]),
        checksum_caps: &ChecksumCapabilities,
    ) where
        T: AsRef<[u8]> + AsMut<[u8]> + ?Sized,
    {
        packet.set_src_port(self.src_port);
        packet.set_dst_port(self.dst_port);
        packet.set_len((HEADER_LEN + payload_len) as u16);
        emit_payload(packet.payload_mut());

        if checksum_caps.udp.tx() {
            packet.fill_checksum(src_addr, dst_addr)
        } else {
            // make sure we get a consistently zeroed checksum,
            // since implementations might rely on it
            packet.set_checksum(0);
        }
    }
}

impl<T: AsRef<[u8]> + ?Sized> fmt::Display for Packet<&T> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // Cannot use Repr::parse because we don't have the IP addresses.
        write!(
            f,
            "UDP src={} dst={} len={}",
            self.src_port(),
            self.dst_port(),
            self.payload().len()
        )
    }
}

#[cfg(feature = "defmt")]
impl<'a, T: AsRef<[u8]> + ?Sized> defmt::Format for Packet<&'a T> {
    fn format(&self, fmt: defmt::Formatter) {
        // Cannot use Repr::parse because we don't have the IP addresses.
        defmt::write!(
            fmt,
            "UDP src={} dst={} len={}",
            self.src_port(),
            self.dst_port(),
            self.payload().len()
        );
    }
}

impl fmt::Display for Repr {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "UDP src={} dst={}", self.src_port, self.dst_port)
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Repr {
    fn format(&self, fmt: defmt::Formatter) {
        defmt::write!(fmt, "UDP src={} dst={}", self.src_port, self.dst_port);
    }
}

use crate::wire::pretty_print::{PrettyIndent, PrettyPrint};

impl<T: AsRef<[u8]>> PrettyPrint for Packet<T> {
    fn pretty_print(
        buffer: &dyn AsRef<[u8]>,
        f: &mut fmt::Formatter,
        indent: &mut PrettyIndent,
    ) -> fmt::Result {
        match Packet::new_checked(buffer) {
            Err(err) => write!(f, "{indent}({err})"),
            Ok(packet) => write!(f, "{indent}{packet}"),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    #[cfg(feature = "proto-ipv4")]
    use crate::wire::Ipv4Address;

    #[cfg(feature = "proto-ipv4")]
    const SRC_ADDR: Ipv4Address = Ipv4Address::new(192, 168, 1, 1);
    #[cfg(feature = "proto-ipv4")]
    const DST_ADDR: Ipv4Address = Ipv4Address::new(192, 168, 1, 2);

    #[cfg(feature = "proto-ipv4")]
    static PACKET_BYTES: [u8; 12] = [
        0xbf, 0x00, 0x00, 0x35, 0x00, 0x0c, 0x12, 0x4d, 0xaa, 0x00, 0x00, 0xff,
    ];

    #[cfg(feature = "proto-ipv4")]
    static NO_CHECKSUM_PACKET: [u8; 12] = [
        0xbf, 0x00, 0x00, 0x35, 0x00, 0x0c, 0x00, 0x00, 0xaa, 0x00, 0x00, 0xff,
    ];

    #[cfg(feature = "proto-ipv4")]
    static PAYLOAD_BYTES: [u8; 4] = [0xaa, 0x00, 0x00, 0xff];

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_deconstruct() {
        let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
        assert_eq!(packet.src_port(), 48896);
        assert_eq!(packet.dst_port(), 53);
        assert_eq!(packet.len(), 12);
        assert_eq!(packet.checksum(), 0x124d);
        assert_eq!(packet.payload(), &PAYLOAD_BYTES[..]);
        assert!(packet.verify_checksum(&SRC_ADDR.into(), &DST_ADDR.into()));
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_construct() {
        let mut bytes = vec![0xa5; 12];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet.set_src_port(48896);
        packet.set_dst_port(53);
        packet.set_len(12);
        packet.set_checksum(0xffff);
        packet.payload_mut().copy_from_slice(&PAYLOAD_BYTES[..]);
        packet.fill_checksum(&SRC_ADDR.into(), &DST_ADDR.into());
        assert_eq!(&*packet.into_inner(), &PACKET_BYTES[..]);
    }

    #[test]
    fn test_impossible_len() {
        let mut bytes = vec![0; 12];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet.set_len(4);
        assert_eq!(packet.check_len(), Err(Error));
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_zero_checksum() {
        let mut bytes = vec![0; 8];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet.set_src_port(1);
        packet.set_dst_port(31881);
        packet.set_len(8);
        packet.fill_checksum(&SRC_ADDR.into(), &DST_ADDR.into());
        assert_eq!(packet.checksum(), 0xffff);
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_no_checksum() {
        let mut bytes = vec![0; 8];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet.set_src_port(1);
        packet.set_dst_port(31881);
        packet.set_len(8);
        packet.set_checksum(0);
        assert!(packet.verify_checksum(&SRC_ADDR.into(), &DST_ADDR.into()));
    }

    #[cfg(feature = "proto-ipv4")]
    fn packet_repr() -> Repr {
        Repr {
            src_port: 48896,
            dst_port: 53,
        }
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_parse() {
        let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
        let repr = Repr::parse(
            &packet,
            &SRC_ADDR.into(),
            &DST_ADDR.into(),
            &ChecksumCapabilities::default(),
        )
        .unwrap();
        assert_eq!(repr, packet_repr());
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_emit() {
        let repr = packet_repr();
        let mut bytes = vec![0xa5; repr.header_len() + PAYLOAD_BYTES.len()];
        let mut packet = Packet::new_unchecked(&mut bytes);
        repr.emit(
            &mut packet,
            &SRC_ADDR.into(),
            &DST_ADDR.into(),
            PAYLOAD_BYTES.len(),
            |payload| payload.copy_from_slice(&PAYLOAD_BYTES),
            &ChecksumCapabilities::default(),
        );
        assert_eq!(&*packet.into_inner(), &PACKET_BYTES[..]);
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_checksum_omitted() {
        let packet = Packet::new_unchecked(&NO_CHECKSUM_PACKET[..]);
        let repr = Repr::parse(
            &packet,
            &SRC_ADDR.into(),
            &DST_ADDR.into(),
            &ChecksumCapabilities::default(),
        )
        .unwrap();
        assert_eq!(repr, packet_repr());
    }
}
