use super::{Error, Result};
use core::fmt;

use crate::wire::Ipv6Address as Address;

enum_with_unknown! {
    /// IPv6 Extension Routing Header Routing Type
    pub enum Type(u8) {
        /// Source Route (DEPRECATED)
        ///
        /// See <https://tools.ietf.org/html/rfc5095> for details.
        Type0 = 0,
        /// Nimrod (DEPRECATED 2009-05-06)
        Nimrod = 1,
        /// Type 2 Routing Header for Mobile IPv6
        ///
        /// See <https://tools.ietf.org/html/rfc6275#section-6.4> for details.
        Type2 = 2,
        /// RPL Source Routing Header
        ///
        /// See <https://tools.ietf.org/html/rfc6554> for details.
        Rpl = 3,
        /// RFC3692-style Experiment 1
        ///
        /// See <https://tools.ietf.org/html/rfc4727> for details.
        Experiment1 = 253,
        /// RFC3692-style Experiment 2
        ///
        /// See <https://tools.ietf.org/html/rfc4727> for details.
        Experiment2 = 254,
        /// Reserved for future use
        Reserved = 252
    }
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            Type::Type0 => write!(f, "Type0"),
            Type::Nimrod => write!(f, "Nimrod"),
            Type::Type2 => write!(f, "Type2"),
            Type::Rpl => write!(f, "Rpl"),
            Type::Experiment1 => write!(f, "Experiment1"),
            Type::Experiment2 => write!(f, "Experiment2"),
            Type::Reserved => write!(f, "Reserved"),
            Type::Unknown(id) => write!(f, "{id}"),
        }
    }
}

/// A read/write wrapper around an IPv6 Routing Header buffer.
#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Header<T: AsRef<[u8]>> {
    buffer: T,
}

// Format of the Routing Header
//
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |  Next Header  |  Hdr Ext Len  |  Routing Type | Segments Left |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |                                                               |
// .                                                               .
// .                       type-specific data                      .
// .                                                               .
// |                                                               |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//
//
// See https://tools.ietf.org/html/rfc8200#section-4.4 for details.
//
// **NOTE**: The fields start counting after the header length field.
mod field {
    #![allow(non_snake_case)]

    use crate::wire::field::*;

    // Minimum size of the header.
    pub const MIN_HEADER_SIZE: usize = 2;

    // 8-bit identifier of a particular Routing header variant.
    pub const TYPE: usize = 0;
    // 8-bit unsigned integer. The number of route segments remaining.
    pub const SEG_LEFT: usize = 1;

    // The Type 2 Routing Header has the following format:
    //
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |  Next Header  | Hdr Ext Len=2 | Routing Type=2|Segments Left=1|
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                            Reserved                           |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // +                                                               +
    // |                                                               |
    // +                         Home Address                          +
    // |                                                               |
    // +                                                               +
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    // 16-byte field containing the home address of the destination mobile node.
    pub const HOME_ADDRESS: Field = 6..22;

    // The RPL Source Routing Header has the following format:
    //
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |  Next Header  |  Hdr Ext Len  | Routing Type  | Segments Left |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // | CmprI | CmprE |  Pad  |               Reserved                |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // .                                                               .
    // .                        Addresses[1..n]                        .
    // .                                                               .
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    // 8-bit field containing the CmprI and CmprE values.
    pub const CMPR: usize = 2;
    // 8-bit field containing the Pad value.
    pub const PAD: usize = 3;
    // Variable length field containing addresses
    pub const ADDRESSES: usize = 6;
}

/// Core getter methods relevant to any routing type.
impl<T: AsRef<[u8]>> Header<T> {
    /// Create a raw octet buffer with an IPv6 Routing Header structure.
    pub const fn new_unchecked(buffer: T) -> Header<T> {
        Header { buffer }
    }

    /// Shorthand for a combination of [new_unchecked] and [check_len].
    ///
    /// [new_unchecked]: #method.new_unchecked
    /// [check_len]: #method.check_len
    pub fn new_checked(buffer: T) -> Result<Header<T>> {
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
        let len = self.buffer.as_ref().len();
        if len < field::MIN_HEADER_SIZE {
            return Err(Error);
        }

        match self.routing_type() {
            Type::Type2 if len < field::HOME_ADDRESS.end => return Err(Error),
            Type::Rpl if len < field::ADDRESSES => return Err(Error),
            _ => (),
        }

        Ok(())
    }

    /// Consume the header, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Return the routing type field.
    #[inline]
    pub fn routing_type(&self) -> Type {
        let data = self.buffer.as_ref();
        Type::from(data[field::TYPE])
    }

    /// Return the segments left field.
    #[inline]
    pub fn segments_left(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::SEG_LEFT]
    }
}

/// Getter methods for the Type 2 Routing Header routing type.
impl<T: AsRef<[u8]>> Header<T> {
    /// Return the IPv6 Home Address
    ///
    /// # Panics
    /// This function may panic if this header is not the Type2 Routing Header routing type.
    pub fn home_address(&self) -> Address {
        let data = self.buffer.as_ref();
        Address::from_octets(data[field::HOME_ADDRESS].try_into().unwrap())
    }
}

/// Getter methods for the RPL Source Routing Header routing type.
impl<T: AsRef<[u8]>> Header<T> {
    /// Return the number of prefix octets elided from addresses[1..n-1].
    ///
    /// # Panics
    /// This function may panic if this header is not the RPL Source Routing Header routing type.
    pub fn cmpr_i(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::CMPR] >> 4
    }

    /// Return the number of prefix octets elided from the last address (`addresses[n]`).
    ///
    /// # Panics
    /// This function may panic if this header is not the RPL Source Routing Header routing type.
    pub fn cmpr_e(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::CMPR] & 0xf
    }

    /// Return the number of octets used for padding after `addresses[n]`.
    ///
    /// # Panics
    /// This function may panic if this header is not the RPL Source Routing Header routing type.
    pub fn pad(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::PAD] >> 4
    }

    /// Return the address vector in bytes
    ///
    /// # Panics
    /// This function may panic if this header is not the RPL Source Routing Header routing type.
    pub fn addresses(&self) -> &[u8] {
        let data = self.buffer.as_ref();
        &data[field::ADDRESSES..]
    }
}

/// Core setter methods relevant to any routing type.
impl<T: AsRef<[u8]> + AsMut<[u8]>> Header<T> {
    /// Set the routing type.
    #[inline]
    pub fn set_routing_type(&mut self, value: Type) {
        let data = self.buffer.as_mut();
        data[field::TYPE] = value.into();
    }

    /// Set the segments left field.
    #[inline]
    pub fn set_segments_left(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        data[field::SEG_LEFT] = value;
    }

    /// Initialize reserved fields to 0.
    ///
    /// # Panics
    /// This function may panic if the routing type is not set.
    #[inline]
    pub fn clear_reserved(&mut self) {
        let routing_type = self.routing_type();
        let data = self.buffer.as_mut();

        match routing_type {
            Type::Type2 => {
                data[2] = 0;
                data[3] = 0;
                data[4] = 0;
                data[5] = 0;
            }
            Type::Rpl => {
                // Retain the higher order 4 bits of the padding field
                data[field::PAD] &= 0xF0;
                data[4] = 0;
                data[5] = 0;
            }

            _ => panic!("Unrecognized routing type when clearing reserved fields."),
        }
    }
}

/// Setter methods for the RPL Source Routing Header routing type.
impl<T: AsRef<[u8]> + AsMut<[u8]>> Header<T> {
    /// Set the Ipv6 Home Address
    ///
    /// # Panics
    /// This function may panic if this header is not the Type 2 Routing Header routing type.
    pub fn set_home_address(&mut self, value: Address) {
        let data = self.buffer.as_mut();
        data[field::HOME_ADDRESS].copy_from_slice(&value.octets());
    }
}

/// Setter methods for the RPL Source Routing Header routing type.
impl<T: AsRef<[u8]> + AsMut<[u8]>> Header<T> {
    /// Set the number of prefix octets elided from addresses[1..n-1].
    ///
    /// # Panics
    /// This function may panic if this header is not the RPL Source Routing Header routing type.
    pub fn set_cmpr_i(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        let raw = (value << 4) | (data[field::CMPR] & 0xF);
        data[field::CMPR] = raw;
    }

    /// Set the number of prefix octets elided from the last address (`addresses[n]`).
    ///
    /// # Panics
    /// This function may panic if this header is not the RPL Source Routing Header routing type.
    pub fn set_cmpr_e(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        let raw = (value & 0xF) | (data[field::CMPR] & 0xF0);
        data[field::CMPR] = raw;
    }

    /// Set the number of octets used for padding after `addresses[n]`.
    ///
    /// # Panics
    /// This function may panic if this header is not the RPL Source Routing Header routing type.
    pub fn set_pad(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        data[field::PAD] = value << 4;
    }

    /// Set address data
    ///
    /// # Panics
    /// This function may panic if this header is not the RPL Source Routing Header routing type.
    pub fn set_addresses(&mut self, value: &[u8]) {
        let data = self.buffer.as_mut();
        let addresses = &mut data[field::ADDRESSES..];
        addresses.copy_from_slice(value);
    }
}

impl<T: AsRef<[u8]> + ?Sized> fmt::Display for Header<&T> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match Repr::parse(self) {
            Ok(repr) => write!(f, "{repr}"),
            Err(err) => {
                write!(f, "IPv6 Routing ({err})")?;
                Ok(())
            }
        }
    }
}

/// A high-level representation of an IPv6 Routing Header.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
#[non_exhaustive]
pub enum Repr<'a> {
    Type2 {
        /// Number of route segments remaining.
        segments_left: u8,
        /// The home address of the destination mobile node.
        home_address: Address,
    },
    Rpl {
        /// Number of route segments remaining.
        segments_left: u8,
        /// Number of prefix octets from each segment, except the last segment, that are elided.
        cmpr_i: u8,
        /// Number of prefix octets from the last segment that are elided.
        cmpr_e: u8,
        /// Number of octets that are used for padding after `address[n]` at the end of the
        /// RPL Source Route Header.
        pad: u8,
        /// Vector of addresses, numbered 1 to `n`.
        addresses: &'a [u8],
    },
}

impl<'a> Repr<'a> {
    /// Parse an IPv6 Routing Header and return a high-level representation.
    pub fn parse<T>(header: &'a Header<&'a T>) -> Result<Repr<'a>>
    where
        T: AsRef<[u8]> + ?Sized,
    {
        header.check_len()?;
        match header.routing_type() {
            Type::Type2 => Ok(Repr::Type2 {
                segments_left: header.segments_left(),
                home_address: header.home_address(),
            }),
            Type::Rpl => Ok(Repr::Rpl {
                segments_left: header.segments_left(),
                cmpr_i: header.cmpr_i(),
                cmpr_e: header.cmpr_e(),
                pad: header.pad(),
                addresses: header.addresses(),
            }),

            _ => Err(Error),
        }
    }

    /// Return the length, in bytes, of a header that will be emitted from this high-level
    /// representation.
    pub const fn buffer_len(&self) -> usize {
        match self {
            // Routing Type + Segments Left + Reserved + Home Address
            Repr::Type2 { home_address, .. } => 2 + 4 + home_address.octets().len(),
            Repr::Rpl { addresses, .. } => 2 + 4 + addresses.len(),
        }
    }

    /// Emit a high-level representation into an IPv6 Routing Header.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized>(&self, header: &mut Header<&mut T>) {
        match *self {
            Repr::Type2 {
                segments_left,
                home_address,
            } => {
                header.set_routing_type(Type::Type2);
                header.set_segments_left(segments_left);
                header.clear_reserved();
                header.set_home_address(home_address);
            }
            Repr::Rpl {
                segments_left,
                cmpr_i,
                cmpr_e,
                pad,
                addresses,
            } => {
                header.set_routing_type(Type::Rpl);
                header.set_segments_left(segments_left);
                header.set_cmpr_i(cmpr_i);
                header.set_cmpr_e(cmpr_e);
                header.set_pad(pad);
                header.clear_reserved();
                header.set_addresses(addresses);
            }
        }
    }
}

impl<'a> fmt::Display for Repr<'a> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            Repr::Type2 {
                segments_left,
                home_address,
            } => {
                write!(
                    f,
                    "IPv6 Routing type={} seg_left={} home_address={}",
                    Type::Type2,
                    segments_left,
                    home_address
                )
            }
            Repr::Rpl {
                segments_left,
                cmpr_i,
                cmpr_e,
                pad,
                ..
            } => {
                write!(
                    f,
                    "IPv6 Routing type={} seg_left={} cmpr_i={} cmpr_e={} pad={}",
                    Type::Rpl,
                    segments_left,
                    cmpr_i,
                    cmpr_e,
                    pad
                )
            }
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    // A Type 2 Routing Header
    static BYTES_TYPE2: [u8; 22] = [
        0x2, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
        0x0, 0x0, 0x0, 0x1,
    ];

    // A representation of a Type 2 Routing header
    static REPR_TYPE2: Repr = Repr::Type2 {
        segments_left: 1,
        home_address: Address::LOCALHOST,
    };

    // A Source Routing Header with full IPv6 addresses in bytes
    static BYTES_SRH_FULL: [u8; 38] = [
        0x3, 0x2, 0x0, 0x0, 0x0, 0x0, 0xfd, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
        0x0, 0x0, 0x0, 0x2, 0xfd, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
        0x3, 0x1,
    ];

    // A representation of a Source Routing Header with full IPv6 addresses
    static REPR_SRH_FULL: Repr = Repr::Rpl {
        segments_left: 2,
        cmpr_i: 0,
        cmpr_e: 0,
        pad: 0,
        addresses: &[
            0xfd, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x2, 0xfd,
            0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x3, 0x1,
        ],
    };

    // A Source Routing Header with elided IPv6 addresses in bytes
    static BYTES_SRH_ELIDED: [u8; 14] = [
        0x3, 0x2, 0xfe, 0x50, 0x0, 0x0, 0x2, 0x3, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0,
    ];

    // A representation of a Source Routing Header with elided IPv6 addresses
    static REPR_SRH_ELIDED: Repr = Repr::Rpl {
        segments_left: 2,
        cmpr_i: 15,
        cmpr_e: 14,
        pad: 5,
        addresses: &[0x2, 0x3, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0],
    };

    #[test]
    fn test_check_len() {
        // less than min header size
        assert_eq!(
            Err(Error),
            Header::new_unchecked(&BYTES_TYPE2[..3]).check_len()
        );
        assert_eq!(
            Err(Error),
            Header::new_unchecked(&BYTES_SRH_FULL[..3]).check_len()
        );
        assert_eq!(
            Err(Error),
            Header::new_unchecked(&BYTES_SRH_ELIDED[..3]).check_len()
        );
        // valid
        assert_eq!(Ok(()), Header::new_unchecked(&BYTES_TYPE2[..]).check_len());
        assert_eq!(
            Ok(()),
            Header::new_unchecked(&BYTES_SRH_FULL[..]).check_len()
        );
        assert_eq!(
            Ok(()),
            Header::new_unchecked(&BYTES_SRH_ELIDED[..]).check_len()
        );
    }

    #[test]
    fn test_header_deconstruct() {
        let header = Header::new_unchecked(&BYTES_TYPE2[..]);
        assert_eq!(header.routing_type(), Type::Type2);
        assert_eq!(header.segments_left(), 1);
        assert_eq!(header.home_address(), Address::LOCALHOST);

        let header = Header::new_unchecked(&BYTES_SRH_FULL[..]);
        assert_eq!(header.routing_type(), Type::Rpl);
        assert_eq!(header.segments_left(), 2);
        assert_eq!(header.addresses(), &BYTES_SRH_FULL[6..]);

        let header = Header::new_unchecked(&BYTES_SRH_ELIDED[..]);
        assert_eq!(header.routing_type(), Type::Rpl);
        assert_eq!(header.segments_left(), 2);
        assert_eq!(header.addresses(), &BYTES_SRH_ELIDED[6..]);
    }

    #[test]
    fn test_repr_parse_valid() {
        let header = Header::new_checked(&BYTES_TYPE2[..]).unwrap();
        let repr = Repr::parse(&header).unwrap();
        assert_eq!(repr, REPR_TYPE2);

        let header = Header::new_checked(&BYTES_SRH_FULL[..]).unwrap();
        let repr = Repr::parse(&header).unwrap();
        assert_eq!(repr, REPR_SRH_FULL);

        let header = Header::new_checked(&BYTES_SRH_ELIDED[..]).unwrap();
        let repr = Repr::parse(&header).unwrap();
        assert_eq!(repr, REPR_SRH_ELIDED);
    }

    #[test]
    fn test_repr_emit() {
        let mut bytes = [0xFFu8; 22];
        let mut header = Header::new_unchecked(&mut bytes[..]);
        REPR_TYPE2.emit(&mut header);
        assert_eq!(header.into_inner(), &BYTES_TYPE2[..]);

        let mut bytes = [0xFFu8; 38];
        let mut header = Header::new_unchecked(&mut bytes[..]);
        REPR_SRH_FULL.emit(&mut header);
        assert_eq!(header.into_inner(), &BYTES_SRH_FULL[..]);

        let mut bytes = [0xFFu8; 14];
        let mut header = Header::new_unchecked(&mut bytes[..]);
        REPR_SRH_ELIDED.emit(&mut header);
        assert_eq!(header.into_inner(), &BYTES_SRH_ELIDED[..]);
    }

    #[test]
    fn test_buffer_len() {
        assert_eq!(REPR_TYPE2.buffer_len(), 22);
        assert_eq!(REPR_SRH_FULL.buffer_len(), 38);
        assert_eq!(REPR_SRH_ELIDED.buffer_len(), 14);
    }
}
