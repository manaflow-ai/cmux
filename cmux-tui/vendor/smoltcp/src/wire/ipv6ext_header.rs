#![allow(unused)]

use super::IpProtocol;
use super::{Error, Result};

mod field {
    #![allow(non_snake_case)]

    use crate::wire::field::*;

    pub const MIN_HEADER_SIZE: usize = 8;

    pub const NXT_HDR: usize = 0;
    pub const LENGTH: usize = 1;
    // Variable-length field.
    //
    // Length of the header is in 8-octet units, not including the first 8 octets.
    // The first two octets are the next header type and the header length.
    pub const fn PAYLOAD(length_field: u8) -> Field {
        let bytes = length_field as usize * 8 + 8;
        2..bytes
    }
}

/// A read/write wrapper around an IPv6 Extension Header buffer.
#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Header<T: AsRef<[u8]>> {
    buffer: T,
}

/// Core getter methods relevant to any IPv6 extension header.
impl<T: AsRef<[u8]>> Header<T> {
    /// Create a raw octet buffer with an IPv6 Extension Header structure.
    pub const fn new_unchecked(buffer: T) -> Self {
        Header { buffer }
    }

    /// Shorthand for a combination of [new_unchecked] and [check_len].
    ///
    /// [new_unchecked]: #method.new_unchecked
    /// [check_len]: #method.check_len
    pub fn new_checked(buffer: T) -> Result<Self> {
        let header = Self::new_unchecked(buffer);
        header.check_len()?;
        Ok(header)
    }

    /// Ensure that no accessor method will panic if called.
    /// Returns `Err(Error)` if the buffer is too short.
    ///
    /// The result of this check is invalidated by calling [set_header_len].
    ///
    /// [set_header_len]: #method.set_header_len
    pub fn check_len(&self) -> Result<()> {
        let data = self.buffer.as_ref();

        let len = data.len();
        if len < field::MIN_HEADER_SIZE {
            return Err(Error);
        }

        let of = field::PAYLOAD(data[field::LENGTH]);
        if len < of.end {
            return Err(Error);
        }

        Ok(())
    }

    /// Consume the header, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Return the next header field.
    pub fn next_header(&self) -> IpProtocol {
        let data = self.buffer.as_ref();
        IpProtocol::from(data[field::NXT_HDR])
    }

    /// Return the header length field.
    pub fn header_len(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::LENGTH]
    }
}

impl<'h, T: AsRef<[u8]> + ?Sized> Header<&'h T> {
    /// Return the payload of the IPv6 extension header.
    pub fn payload(&self) -> &'h [u8] {
        let data = self.buffer.as_ref();
        &data[field::PAYLOAD(data[field::LENGTH])]
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Header<T> {
    /// Set the next header field.
    #[inline]
    pub fn set_next_header(&mut self, value: IpProtocol) {
        let data = self.buffer.as_mut();
        data[field::NXT_HDR] = value.into();
    }

    /// Set the extension header data length. The length of the header is
    /// in 8-octet units, not including the first 8 octets.
    #[inline]
    pub fn set_header_len(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        data[field::LENGTH] = value;
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized> Header<&mut T> {
    /// Return a mutable pointer to the payload data.
    #[inline]
    pub fn payload_mut(&mut self) -> &mut [u8] {
        let data = self.buffer.as_mut();
        let len = data[field::LENGTH];
        &mut data[field::PAYLOAD(len)]
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Repr<'a> {
    pub next_header: IpProtocol,
    pub length: u8,
    pub data: &'a [u8],
}

impl<'a> Repr<'a> {
    /// Parse an IPv6 Extension Header Header and return a high-level representation.
    pub fn parse<T>(header: &Header<&'a T>) -> Result<Self>
    where
        T: AsRef<[u8]> + ?Sized,
    {
        header.check_len()?;
        Ok(Self {
            next_header: header.next_header(),
            length: header.header_len(),
            data: header.payload(),
        })
    }

    /// Return the length, in bytes, of a header that will be emitted from this high-level
    /// representation.
    pub const fn header_len(&self) -> usize {
        2
    }

    /// Emit a high-level representation into an IPv6 Extension Header.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized>(&self, header: &mut Header<&mut T>) {
        header.set_next_header(self.next_header);
        header.set_header_len(self.length);
    }
}

#[cfg(test)]
#[path = "ipv6ext_header_test_tests.rs"]
mod test;
