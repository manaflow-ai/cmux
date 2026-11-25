use super::{Error, Result};
use byteorder::{ByteOrder, NetworkEndian};

/// A read/write wrapper around an IPSec Encapsulating Security Payload (ESP) packet buffer.
#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Packet<T: AsRef<[u8]>> {
    buffer: T,
}

mod field {
    use crate::wire::field::Field;

    pub const SPI: Field = 0..4;
    pub const SEQUENCE_NUMBER: Field = 4..8;
}

impl<T: AsRef<[u8]>> Packet<T> {
    /// Imbue a raw octet buffer with IPsec Encapsulating Security Payload packet structure.
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
    pub fn check_len(&self) -> Result<()> {
        let data = self.buffer.as_ref();
        let len = data.len();
        if len < field::SEQUENCE_NUMBER.end {
            Err(Error)
        } else {
            Ok(())
        }
    }

    /// Consume the packet, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
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

impl<T: AsRef<[u8]>> AsRef<[u8]> for Packet<T> {
    fn as_ref(&self) -> &[u8] {
        self.buffer.as_ref()
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Packet<T> {
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
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Repr {
    security_parameters_index: u32,
    sequence_number: u32,
}

impl Repr {
    /// Parse an IPSec Encapsulating Security Payload packet and return a high-level representation.
    pub fn parse<T: AsRef<[u8]>>(packet: &Packet<T>) -> Result<Repr> {
        packet.check_len()?;
        Ok(Repr {
            security_parameters_index: packet.security_parameters_index(),
            sequence_number: packet.sequence_number(),
        })
    }

    /// Return the length of a packet that will be emitted from this high-level representation.
    pub const fn buffer_len(&self) -> usize {
        field::SEQUENCE_NUMBER.end
    }

    /// Emit a high-level representation into an IPSec Encapsulating Security Payload.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]>>(&self, packet: &mut Packet<T>) {
        packet.set_security_parameters_index(self.security_parameters_index);
        packet.set_sequence_number(self.sequence_number);
    }
}

#[cfg(test)]
mod test {
    use super::*;

    static PACKET_BYTES: [u8; 136] = [
        0xfb, 0x51, 0x28, 0xa6, 0x00, 0x00, 0x00, 0x02, 0x5d, 0xbe, 0x2d, 0x56, 0xd4, 0x6a, 0x57,
        0xf5, 0xfc, 0x69, 0x8b, 0x3c, 0xa6, 0xb6, 0x88, 0x3a, 0x6c, 0xc1, 0x33, 0x92, 0xdb, 0x40,
        0xab, 0x11, 0x54, 0xb4, 0x0f, 0x22, 0x4d, 0x37, 0x3a, 0x06, 0x94, 0x1e, 0xd4, 0x25, 0xaf,
        0xf0, 0xb0, 0x11, 0x1f, 0x07, 0x96, 0x2a, 0xa7, 0x20, 0xb1, 0xf5, 0x52, 0xb2, 0x12, 0x46,
        0xd6, 0xa5, 0x13, 0x4e, 0x97, 0x75, 0x44, 0x19, 0xc7, 0x29, 0x35, 0xc5, 0xed, 0xa4, 0x0c,
        0xe7, 0x87, 0xec, 0x9c, 0xb1, 0x12, 0x42, 0x74, 0x7c, 0x12, 0x3c, 0x7f, 0x44, 0x9c, 0x6b,
        0x46, 0x27, 0x28, 0xd2, 0x0e, 0xb1, 0x28, 0xd3, 0xd8, 0xc2, 0xd1, 0xac, 0x25, 0xfe, 0xef,
        0xed, 0x13, 0xfd, 0x8f, 0x18, 0x9c, 0x2d, 0xb1, 0x0e, 0x50, 0xe9, 0xaa, 0x65, 0x93, 0x56,
        0x40, 0x43, 0xa3, 0x72, 0x54, 0xba, 0x1b, 0xb1, 0xaf, 0xca, 0x04, 0x15, 0xf9, 0xef, 0xb7,
        0x1d,
    ];

    #[test]
    fn test_deconstruct() {
        let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
        assert_eq!(packet.security_parameters_index(), 0xfb5128a6);
        assert_eq!(packet.sequence_number(), 2);
    }

    #[test]
    fn test_construct() {
        let mut bytes = vec![0xa5; 8];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet.set_security_parameters_index(0xfb5128a6);
        packet.set_sequence_number(2);
        assert_eq!(&bytes, &PACKET_BYTES[..8]);
    }
    #[test]
    fn test_check_len() {
        assert!(matches!(Packet::new_checked(&PACKET_BYTES[..7]), Err(_)));
        assert!(matches!(Packet::new_checked(&PACKET_BYTES[..]), Ok(_)));
    }

    fn packet_repr() -> Repr {
        Repr {
            security_parameters_index: 0xfb5128a6,
            sequence_number: 2,
        }
    }

    #[test]
    fn test_parse() {
        let packet = Packet::new_unchecked(&PACKET_BYTES[..]);
        assert_eq!(Repr::parse(&packet).unwrap(), packet_repr());
    }

    #[test]
    fn test_emit() {
        let mut bytes = vec![0x17; 8];
        let mut packet = Packet::new_unchecked(&mut bytes);
        packet_repr().emit(&mut packet);
        assert_eq!(&bytes, &PACKET_BYTES[..8]);
    }

    #[test]
    fn test_buffer_len() {
        let header = Packet::new_unchecked(&PACKET_BYTES[..]);
        let repr = Repr::parse(&header).unwrap();
        assert_eq!(repr.buffer_len(), 8);
    }
}
