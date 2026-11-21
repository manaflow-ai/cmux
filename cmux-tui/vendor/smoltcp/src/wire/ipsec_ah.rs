use byteorder::{ByteOrder, NetworkEndian};

use super::{Error, IpProtocol, Result};

/// A read/write wrapper around an IPSec Authentication Header packet buffer.
#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Packet<T: AsRef<[u8]>> {
    buffer: T,
}

//     0                   1                   2                   3
//     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
//   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//   | Next Header   |  Payload Len  |          RESERVED             |
//   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//   |                 Security Parameters Index (SPI)               |
//   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//   |                    Sequence Number Field                      |
//   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//   |                                                               |
//   +                Integrity Check Value-ICV (variable)           |
//   |                                                               |
//   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
mod field {
    #![allow(non_snake_case)]

    use crate::wire::field::Field;

    pub const NEXT_HEADER: usize = 0;
    pub const PAYLOAD_LEN: usize = 1;
    pub const RESERVED: Field = 2..4;
    pub const SPI: Field = 4..8;
    pub const SEQUENCE_NUMBER: Field = 8..12;

    pub const fn ICV(payload_len: u8) -> Field {
        // The `payload_len` is the length of this Authentication Header in 4-octet units, minus 2.
        let header_len = (payload_len as usize + 2) * 4;

        SEQUENCE_NUMBER.end..header_len
    }
}

impl<T: AsRef<[u8]>> Packet<T> {
    /// Imbue a raw octet buffer with IPsec Authentication Header packet structure.
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
    /// Returns `Err(Error)` if the buffer is too short or shorter than payload length.
    ///
    /// The result of this check is invalidated by calling [set_payload_len].
    ///
    /// [set_payload_len]: #method.set_payload_len
    #[allow(clippy::if_same_then_else)]
    pub fn check_len(&self) -> Result<()> {
        let data = self.buffer.as_ref();
        let len = data.len();
        if len < field::SEQUENCE_NUMBER.end {
            return Err(Error);
        }

        // payload_len == 0 makes ICV a reversed range (12..8); reject it.
        let icv = field::ICV(data[field::PAYLOAD_LEN]);
        if icv.end < icv.start || len < icv.end {
            Err(Error)
        } else {
            Ok(())
        }
    }

    /// Consume the packet, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Return next header protocol type
    /// The value is taken from the list of IP protocol numbers.
    pub fn next_header(&self) -> IpProtocol {
        let data = self.buffer.as_ref();
        IpProtocol::from(data[field::NEXT_HEADER])
    }

    /// Return the length of this Authentication Header in 4-octet units, minus 2
    pub fn payload_len(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::PAYLOAD_LEN]
    }

    /// Return the security parameters index
    pub fn security_parameters_index(&self) -> u32 {
        let field = &self.buffer.as_ref()[field::SPI];
        NetworkEndian::read_u32(field)
    }

    /// Return sequence number
    pub fn sequence_number(&self) -> u32 {
        let field = &self.buffer.as_ref()[field::SEQUENCE_NUMBER];
        NetworkEndian::read_u32(field)
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> Packet<&'a T> {
    /// Return a pointer to the integrity check value
    #[inline]
    pub fn integrity_check_value(&self) -> &'a [u8] {
        let data = self.buffer.as_ref();
        &data[field::ICV(data[field::PAYLOAD_LEN])]
    }
}

impl<T: AsRef<[u8]>> AsRef<[u8]> for Packet<T> {
    fn as_ref(&self) -> &[u8] {
        self.buffer.as_ref()
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Packet<T> {
    /// Set next header protocol field
    fn set_next_header(&mut self, value: IpProtocol) {
        let data = self.buffer.as_mut();
        data[field::NEXT_HEADER] = value.into()
    }

    /// Set payload length field
    fn set_payload_len(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        data[field::PAYLOAD_LEN] = value
    }

    /// Clear reserved field
    fn clear_reserved(&mut self) {
        let data = self.buffer.as_mut();
        data[field::RESERVED].fill(0)
    }

    /// Set security parameters index field
    fn set_security_parameters_index(&mut self, value: u32) {
        let data = self.buffer.as_mut();
        NetworkEndian::write_u32(&mut data[field::SPI], value)
    }

    /// Set sequence number
    fn set_sequence_number(&mut self, value: u32) {
        let data = self.buffer.as_mut();
        NetworkEndian::write_u32(&mut data[field::SEQUENCE_NUMBER], value)
    }

    /// Return a mutable pointer to the integrity check value.
    #[inline]
    pub fn integrity_check_value_mut(&mut self) -> &mut [u8] {
        let data = self.buffer.as_mut();
        let range = field::ICV(data[field::PAYLOAD_LEN]);
        &mut data[range]
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Repr<'a> {
    next_header: IpProtocol,
    security_parameters_index: u32,
    sequence_number: u32,
    integrity_check_value: &'a [u8],
}

impl<'a> Repr<'a> {
    /// Parse an IPSec Authentication Header packet and return a high-level representation.
    pub fn parse<T: AsRef<[u8]> + ?Sized>(packet: &Packet<&'a T>) -> Result<Repr<'a>> {
        packet.check_len()?;
        Ok(Repr {
            next_header: packet.next_header(),
            security_parameters_index: packet.security_parameters_index(),
            sequence_number: packet.sequence_number(),
            integrity_check_value: packet.integrity_check_value(),
        })
    }

    /// Return the length of a packet that will be emitted from this high-level representation.
    pub const fn buffer_len(&self) -> usize {
        self.integrity_check_value.len() + field::SEQUENCE_NUMBER.end
    }

    /// Emit a high-level representation into an IPSec Authentication Header.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized>(&self, packet: &mut Packet<&'a mut T>) {
        packet.set_next_header(self.next_header);

        let payload_len = ((field::SEQUENCE_NUMBER.end + self.integrity_check_value.len()) / 4) - 2;
        packet.set_payload_len(payload_len as u8);

        packet.clear_reserved();
        packet.set_security_parameters_index(self.security_parameters_index);
        packet.set_sequence_number(self.sequence_number);
        packet
            .integrity_check_value_mut()
            .copy_from_slice(self.integrity_check_value);
    }
}

#[cfg(test)]
mod test {
    use super::*;

    static PACKET_BYTES1: [u8; 24] = [
        0x32, 0x04, 0x00, 0x00, 0x81, 0x79, 0xb7, 0x05, 0x00, 0x00, 0x00, 0x01, 0x27, 0xcf, 0xc0,
        0xa5, 0xe4, 0x3d, 0x69, 0xb3, 0x72, 0x8e, 0xc5, 0xb0,
    ];

    static PACKET_BYTES2: [u8; 24] = [
        0x32, 0x04, 0x00, 0x00, 0xba, 0x8b, 0xd0, 0x60, 0x00, 0x00, 0x00, 0x01, 0xaf, 0xd2, 0xe7,
        0xa1, 0x73, 0xd3, 0x29, 0x0b, 0xfe, 0x6b, 0x63, 0x73,
    ];

    #[test]
    fn test_deconstruct() {
        let packet = Packet::new_unchecked(&PACKET_BYTES1[..]);
        assert_eq!(packet.next_header(), IpProtocol::IpSecEsp);
        assert_eq!(packet.payload_len(), 4);
        assert_eq!(packet.security_parameters_index(), 0x8179b705);
        assert_eq!(packet.sequence_number(), 1);
        assert_eq!(
            packet.integrity_check_value(),
            &[
                0x27, 0xcf, 0xc0, 0xa5, 0xe4, 0x3d, 0x69, 0xb3, 0x72, 0x8e, 0xc5, 0xb0
            ]
        );
    }

    #[test]
    fn test_construct() {
        let mut bytes = vec![0xa5; 24];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet.set_next_header(IpProtocol::IpSecEsp);
        packet.set_payload_len(4);
        packet.clear_reserved();
        packet.set_security_parameters_index(0xba8bd060);
        packet.set_sequence_number(1);
        const ICV: [u8; 12] = [
            0xaf, 0xd2, 0xe7, 0xa1, 0x73, 0xd3, 0x29, 0x0b, 0xfe, 0x6b, 0x63, 0x73,
        ];
        packet.integrity_check_value_mut().copy_from_slice(&ICV);
        assert_eq!(bytes, PACKET_BYTES2);
    }
    #[test]
    fn test_check_len() {
        assert!(matches!(Packet::new_checked(&PACKET_BYTES1[..10]), Err(_)));
        assert!(matches!(Packet::new_checked(&PACKET_BYTES1[..22]), Err(_)));
        assert!(matches!(Packet::new_checked(&PACKET_BYTES1[..]), Ok(_)));

        // payload_len == 0: reversed ICV range must be rejected, not panic.
        let reversed = [
            0x3b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        ];
        assert!(matches!(Packet::new_checked(&reversed[..]), Err(_)));
        assert!(matches!(
            Repr::parse(&Packet::new_unchecked(&reversed[..])),
            Err(_)
        ));
    }

    fn packet_repr<'a>() -> Repr<'a> {
        Repr {
            next_header: IpProtocol::IpSecEsp,
            security_parameters_index: 0xba8bd060,
            sequence_number: 1,
            integrity_check_value: &[
                0xaf, 0xd2, 0xe7, 0xa1, 0x73, 0xd3, 0x29, 0x0b, 0xfe, 0x6b, 0x63, 0x73,
            ],
        }
    }

    #[test]
    fn test_parse() {
        let packet = Packet::new_unchecked(&PACKET_BYTES2[..]);
        assert_eq!(Repr::parse(&packet).unwrap(), packet_repr());
    }

    #[test]
    fn test_emit() {
        let mut bytes = vec![0x17; 24];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet_repr().emit(&mut packet);
        assert_eq!(bytes, PACKET_BYTES2);
    }

    #[test]
    fn test_buffer_len() {
        let header = Packet::new_unchecked(&PACKET_BYTES1[..]);
        let repr = Repr::parse(&header).unwrap();
        assert_eq!(repr.buffer_len(), PACKET_BYTES1.len());
    }
}
