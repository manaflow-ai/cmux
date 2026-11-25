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
mod test {
    use super::*;

    // A Hop-by-Hop Option header with a PadN option of option data length 4.
    static REPR_PACKET_PAD4: [u8; 8] = [0x6, 0x0, 0x1, 0x4, 0x0, 0x0, 0x0, 0x0];

    // A Hop-by-Hop Option header with a PadN option of option data length 12.
    static REPR_PACKET_PAD12: [u8; 16] = [
        0x06, 0x1, 0x1, 0x0C, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
    ];

    #[test]
    fn test_check_len() {
        // zero byte buffer
        assert_eq!(
            Err(Error),
            Header::new_unchecked(&REPR_PACKET_PAD4[..0]).check_len()
        );
        // no length field
        assert_eq!(
            Err(Error),
            Header::new_unchecked(&REPR_PACKET_PAD4[..1]).check_len()
        );
        // less than 8 bytes
        assert_eq!(
            Err(Error),
            Header::new_unchecked(&REPR_PACKET_PAD4[..7]).check_len()
        );
        // valid
        assert_eq!(Ok(()), Header::new_unchecked(&REPR_PACKET_PAD4).check_len());
        // valid
        assert_eq!(
            Ok(()),
            Header::new_unchecked(&REPR_PACKET_PAD12).check_len()
        );
        // length field value greater than number of bytes
        let header: [u8; 8] = [0x06, 0x2, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0];
        assert_eq!(Err(Error), Header::new_unchecked(&header).check_len());
    }

    #[test]
    fn test_header_deconstruct() {
        let header = Header::new_unchecked(&REPR_PACKET_PAD4);
        assert_eq!(header.next_header(), IpProtocol::Tcp);
        assert_eq!(header.header_len(), 0);
        assert_eq!(header.payload(), &REPR_PACKET_PAD4[2..]);

        let header = Header::new_unchecked(&REPR_PACKET_PAD12);
        assert_eq!(header.next_header(), IpProtocol::Tcp);
        assert_eq!(header.header_len(), 1);
        assert_eq!(header.payload(), &REPR_PACKET_PAD12[2..]);
    }

    #[test]
    fn test_overlong() {
        let mut bytes = vec![];
        bytes.extend(&REPR_PACKET_PAD4[..]);
        bytes.push(0);

        assert_eq!(
            Header::new_unchecked(&bytes).payload().len(),
            REPR_PACKET_PAD4[2..].len()
        );
        assert_eq!(
            Header::new_unchecked(&mut bytes).payload_mut().len(),
            REPR_PACKET_PAD4[2..].len()
        );

        let mut bytes = vec![];
        bytes.extend(&REPR_PACKET_PAD12[..]);
        bytes.push(0);

        assert_eq!(
            Header::new_unchecked(&bytes).payload().len(),
            REPR_PACKET_PAD12[2..].len()
        );
        assert_eq!(
            Header::new_unchecked(&mut bytes).payload_mut().len(),
            REPR_PACKET_PAD12[2..].len()
        );
    }

    #[test]
    fn test_header_len_overflow() {
        let mut bytes = vec![];
        bytes.extend(REPR_PACKET_PAD4);
        let len = bytes.len() as u8;
        Header::new_unchecked(&mut bytes).set_header_len(len + 1);

        assert_eq!(Header::new_checked(&bytes).unwrap_err(), Error);

        let mut bytes = vec![];
        bytes.extend(REPR_PACKET_PAD12);
        let len = bytes.len() as u8;
        Header::new_unchecked(&mut bytes).set_header_len(len + 1);

        assert_eq!(Header::new_checked(&bytes).unwrap_err(), Error);
    }

    #[test]
    fn test_repr_parse_valid() {
        let header = Header::new_unchecked(&REPR_PACKET_PAD4);
        let repr = Repr::parse(&header).unwrap();
        assert_eq!(
            repr,
            Repr {
                next_header: IpProtocol::Tcp,
                length: 0,
                data: &REPR_PACKET_PAD4[2..]
            }
        );

        let header = Header::new_unchecked(&REPR_PACKET_PAD12);
        let repr = Repr::parse(&header).unwrap();
        assert_eq!(
            repr,
            Repr {
                next_header: IpProtocol::Tcp,
                length: 1,
                data: &REPR_PACKET_PAD12[2..]
            }
        );
    }

    #[test]
    fn test_repr_emit() {
        let repr = Repr {
            next_header: IpProtocol::Tcp,
            length: 0,
            data: &REPR_PACKET_PAD4[2..],
        };
        let mut bytes = [0u8; 2];
        let mut header = Header::new_unchecked(&mut bytes);
        repr.emit(&mut header);
        assert_eq!(header.into_inner(), &REPR_PACKET_PAD4[..2]);

        let repr = Repr {
            next_header: IpProtocol::Tcp,
            length: 1,
            data: &REPR_PACKET_PAD12[2..],
        };
        let mut bytes = [0u8; 2];
        let mut header = Header::new_unchecked(&mut bytes);
        repr.emit(&mut header);
        assert_eq!(header.into_inner(), &REPR_PACKET_PAD12[..2]);
    }
}
