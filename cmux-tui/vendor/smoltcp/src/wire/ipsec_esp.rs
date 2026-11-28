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
#[path = "ipsec_esp_test_tests.rs"]
mod test;
