//! Implementation of the fragment headers from [RFC 4944 § 5.3].
//!
//! [RFC 4944 § 5.3]: https://datatracker.ietf.org/doc/html/rfc4944#section-5.3

use super::{DISPATCH_FIRST_FRAGMENT_HEADER, DISPATCH_FRAGMENT_HEADER};
use crate::wire::{Error, Result};
use crate::wire::{Ieee802154Address, Ieee802154Repr};
use byteorder::{ByteOrder, NetworkEndian};

/// Key used for identifying all the link fragments that belong to the same packet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Key {
    pub(crate) ll_src_addr: Ieee802154Address,
    pub(crate) ll_dst_addr: Ieee802154Address,
    pub(crate) datagram_size: u16,
    pub(crate) datagram_tag: u16,
}

/// A read/write wrapper around a 6LoWPAN Fragment header.
/// [RFC 4944 § 5.3] specifies the format of the header.
///
/// A First Fragment header has the following format:
/// ```txt
///                      1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |1 1 0 0 0|    datagram_size    |         datagram_tag          |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// Subsequent fragment headers have the following format:
/// ```txt
///                      1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |1 1 1 0 0|    datagram_size    |         datagram_tag          |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |datagram_offset|
/// +-+-+-+-+-+-+-+-+
/// ```
///
/// [RFC 4944 § 5.3]: https://datatracker.ietf.org/doc/html/rfc4944#section-5.3
#[derive(Debug, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Packet<T: AsRef<[u8]>> {
    buffer: T,
}

pub const FIRST_FRAGMENT_HEADER_SIZE: usize = 4;
pub const NEXT_FRAGMENT_HEADER_SIZE: usize = 5;

mod field {
    use crate::wire::field::*;

    pub const DISPATCH: usize = 0;
    pub const DATAGRAM_SIZE: Field = 0..2;
    pub const DATAGRAM_TAG: Field = 2..4;
    pub const DATAGRAM_OFFSET: usize = 4;

    pub const FIRST_FRAGMENT_REST: Rest = super::FIRST_FRAGMENT_HEADER_SIZE..;
    pub const NEXT_FRAGMENT_REST: Rest = super::NEXT_FRAGMENT_HEADER_SIZE..;
}

impl<T: AsRef<[u8]>> Packet<T> {
    /// Input a raw octet buffer with a 6LoWPAN Fragment header structure.
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

        let dispatch = packet.dispatch();

        if dispatch != DISPATCH_FIRST_FRAGMENT_HEADER && dispatch != DISPATCH_FRAGMENT_HEADER {
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

        match self.dispatch() {
            DISPATCH_FIRST_FRAGMENT_HEADER if buffer.len() >= FIRST_FRAGMENT_HEADER_SIZE => Ok(()),
            DISPATCH_FIRST_FRAGMENT_HEADER if buffer.len() < FIRST_FRAGMENT_HEADER_SIZE => {
                Err(Error)
            }
            DISPATCH_FRAGMENT_HEADER if buffer.len() >= NEXT_FRAGMENT_HEADER_SIZE => Ok(()),
            DISPATCH_FRAGMENT_HEADER if buffer.len() < NEXT_FRAGMENT_HEADER_SIZE => Err(Error),
            _ => Err(Error),
        }
    }

    /// Consumes the frame, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Return the dispatch field.
    pub fn dispatch(&self) -> u8 {
        let raw = self.buffer.as_ref();
        raw[field::DISPATCH] >> 3
    }

    /// Return the total datagram size.
    pub fn datagram_size(&self) -> u16 {
        let raw = self.buffer.as_ref();
        NetworkEndian::read_u16(&raw[field::DATAGRAM_SIZE]) & 0b111_1111_1111
    }

    /// Return the datagram tag.
    pub fn datagram_tag(&self) -> u16 {
        let raw = self.buffer.as_ref();
        NetworkEndian::read_u16(&raw[field::DATAGRAM_TAG])
    }

    /// Return the datagram offset.
    pub fn datagram_offset(&self) -> u8 {
        match self.dispatch() {
            DISPATCH_FIRST_FRAGMENT_HEADER => 0,
            DISPATCH_FRAGMENT_HEADER => {
                let raw = self.buffer.as_ref();
                raw[field::DATAGRAM_OFFSET]
            }
            _ => unreachable!(),
        }
    }

    /// Returns `true` when this header is from the first fragment of a link.
    pub fn is_first_fragment(&self) -> bool {
        self.dispatch() == DISPATCH_FIRST_FRAGMENT_HEADER
    }

    /// Returns the key for identifying the packet it belongs to.
    pub fn get_key(&self, ieee802154_repr: &Ieee802154Repr) -> Key {
        Key {
            ll_src_addr: ieee802154_repr.src_addr.unwrap(),
            ll_dst_addr: ieee802154_repr.dst_addr.unwrap(),
            datagram_size: self.datagram_size(),
            datagram_tag: self.datagram_tag(),
        }
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> Packet<&'a T> {
    /// Return the payload.
    pub fn payload(&self) -> &'a [u8] {
        match self.dispatch() {
            DISPATCH_FIRST_FRAGMENT_HEADER => {
                let raw = self.buffer.as_ref();
                &raw[field::FIRST_FRAGMENT_REST]
            }
            DISPATCH_FRAGMENT_HEADER => {
                let raw = self.buffer.as_ref();
                &raw[field::NEXT_FRAGMENT_REST]
            }
            _ => unreachable!(),
        }
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Packet<T> {
    fn set_dispatch_field(&mut self, value: u8) {
        let raw = self.buffer.as_mut();
        raw[field::DISPATCH] = (raw[field::DISPATCH] & !(0b11111 << 3)) | (value << 3);
    }

    fn set_datagram_size(&mut self, size: u16) {
        let raw = self.buffer.as_mut();
        let mut v = NetworkEndian::read_u16(&raw[field::DATAGRAM_SIZE]);
        v = (v & !0b111_1111_1111) | size;

        NetworkEndian::write_u16(&mut raw[field::DATAGRAM_SIZE], v);
    }

    fn set_datagram_tag(&mut self, tag: u16) {
        let raw = self.buffer.as_mut();
        NetworkEndian::write_u16(&mut raw[field::DATAGRAM_TAG], tag);
    }

    fn set_datagram_offset(&mut self, offset: u8) {
        let raw = self.buffer.as_mut();
        raw[field::DATAGRAM_OFFSET] = offset;
    }
}

/// A high-level representation of a 6LoWPAN Fragment header.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Repr {
    FirstFragment { size: u16, tag: u16 },
    Fragment { size: u16, tag: u16, offset: u8 },
}

impl core::fmt::Display for Repr {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Repr::FirstFragment { size, tag } => {
                write!(f, "FirstFrag size={size} tag={tag}")
            }
            Repr::Fragment { size, tag, offset } => {
                write!(f, "NthFrag size={size} tag={tag} offset={offset}")
            }
        }
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Repr {
    fn format(&self, fmt: defmt::Formatter) {
        match self {
            Repr::FirstFragment { size, tag } => {
                defmt::write!(fmt, "FirstFrag size={} tag={}", size, tag);
            }
            Repr::Fragment { size, tag, offset } => {
                defmt::write!(fmt, "NthFrag size={} tag={} offset={}", size, tag, offset);
            }
        }
    }
}

impl Repr {
    /// Parse a 6LoWPAN Fragment header.
    pub fn parse<T: AsRef<[u8]>>(packet: &Packet<T>) -> Result<Self> {
        packet.check_len()?;
        let size = packet.datagram_size();
        let tag = packet.datagram_tag();

        match packet.dispatch() {
            DISPATCH_FIRST_FRAGMENT_HEADER => Ok(Self::FirstFragment { size, tag }),
            DISPATCH_FRAGMENT_HEADER => Ok(Self::Fragment {
                size,
                tag,
                offset: packet.datagram_offset(),
            }),
            _ => Err(Error),
        }
    }

    /// Returns the length of the Fragment header.
    pub const fn buffer_len(&self) -> usize {
        match self {
            Self::FirstFragment { .. } => field::FIRST_FRAGMENT_REST.start,
            Self::Fragment { .. } => field::NEXT_FRAGMENT_REST.start,
        }
    }

    /// Emit a high-level representation into a 6LoWPAN Fragment header.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]>>(&self, packet: &mut Packet<T>) {
        match self {
            Self::FirstFragment { size, tag } => {
                packet.set_dispatch_field(DISPATCH_FIRST_FRAGMENT_HEADER);
                packet.set_datagram_size(*size);
                packet.set_datagram_tag(*tag);
            }
            Self::Fragment { size, tag, offset } => {
                packet.set_dispatch_field(DISPATCH_FRAGMENT_HEADER);
                packet.set_datagram_size(*size);
                packet.set_datagram_tag(*tag);
                packet.set_datagram_offset(*offset);
            }
        }
    }
}
