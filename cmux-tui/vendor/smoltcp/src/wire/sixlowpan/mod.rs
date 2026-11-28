//! Implementation of [RFC 6282] which specifies a compression format for IPv6 datagrams over
//! IEEE802.154-based networks.
//!
//! [RFC 6282]: https://datatracker.ietf.org/doc/html/rfc6282

use super::{Error, Result};
use crate::wire::IpProtocol;
use crate::wire::ieee802154::Address as LlAddress;
use crate::wire::ipv6;

pub mod frag;
pub mod iphc;
pub mod nhc;

const ADDRESS_CONTEXT_LENGTH: usize = 8;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct AddressContext(pub [u8; ADDRESS_CONTEXT_LENGTH]);

/// The representation of an unresolved address. 6LoWPAN compression of IPv6 addresses can be with
/// and without context information. The decompression with context information is not yet
/// implemented.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum UnresolvedAddress<'a> {
    WithoutContext(AddressMode<'a>),
    WithContext((usize, AddressMode<'a>)),
    Reserved,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum AddressMode<'a> {
    /// The full address is carried in-line.
    FullInline(&'a [u8]),
    /// The first 64-bits of the address are elided. The value of those bits
    /// is the link-local prefix padded with zeros. The remaining 64 bits are
    /// carried in-line.
    InLine64bits(&'a [u8]),
    /// The first 112 bits of the address are elided. The value of the first
    /// 64 bits is the link-local prefix padded with zeros. The following 64 bits
    /// are 0000:00ff:fe00:XXXX, where XXXX are the 16 bits carried in-line.
    InLine16bits(&'a [u8]),
    /// The address is fully elided. The first 64 bits of the address are
    /// the link-local prefix padded with zeros. The remaining 64 bits are
    /// computed from the encapsulating header (e.g., 802.15.4 or IPv6 source address)
    /// as specified in Section 3.2.2.
    FullyElided,
    /// The address takes the form ffXX::00XX:XXXX:XXXX
    Multicast48bits(&'a [u8]),
    /// The address takes the form ffXX::00XX:XXXX.
    Multicast32bits(&'a [u8]),
    /// The address takes the form ff02::00XX.
    Multicast8bits(&'a [u8]),
    /// The unspecified address.
    Unspecified,
    NotSupported,
}

const LINK_LOCAL_PREFIX: [u8; 2] = [0xfe, 0x80];
const EUI64_MIDDLE_VALUE: [u8; 2] = [0xff, 0xfe];

impl<'a> UnresolvedAddress<'a> {
    pub fn resolve(
        self,
        ll_address: Option<LlAddress>,
        addr_context: &[AddressContext],
    ) -> Result<ipv6::Address> {
        let mut bytes = [0; 16];

        let copy_context = |index: usize, bytes: &mut [u8]| -> Result<()> {
            if index >= addr_context.len() {
                return Err(Error);
            }

            let context = addr_context[index];
            bytes[..ADDRESS_CONTEXT_LENGTH].copy_from_slice(&context.0);

            Ok(())
        };

        match self {
            UnresolvedAddress::WithoutContext(mode) => match mode {
                AddressMode::FullInline(addr) => {
                    Ok(ipv6::Address::from_octets(addr.try_into().unwrap()))
                }
                AddressMode::InLine64bits(inline) => {
                    bytes[0..2].copy_from_slice(&LINK_LOCAL_PREFIX[..]);
                    bytes[8..].copy_from_slice(inline);
                    Ok(ipv6::Address::from_octets(bytes))
                }
                AddressMode::InLine16bits(inline) => {
                    bytes[0..2].copy_from_slice(&LINK_LOCAL_PREFIX[..]);
                    bytes[11..13].copy_from_slice(&EUI64_MIDDLE_VALUE[..]);
                    bytes[14..].copy_from_slice(inline);
                    Ok(ipv6::Address::from_octets(bytes))
                }
                AddressMode::FullyElided => {
                    bytes[0..2].copy_from_slice(&LINK_LOCAL_PREFIX[..]);
                    match ll_address {
                        Some(LlAddress::Short(ll)) => {
                            bytes[11..13].copy_from_slice(&EUI64_MIDDLE_VALUE[..]);
                            bytes[14..].copy_from_slice(&ll);
                        }
                        Some(addr @ LlAddress::Extended(_)) => match addr.as_eui_64() {
                            Some(addr) => bytes[8..].copy_from_slice(&addr),
                            None => return Err(Error),
                        },
                        Some(LlAddress::Absent) => return Err(Error),
                        None => return Err(Error),
                    }
                    Ok(ipv6::Address::from_octets(bytes))
                }
                AddressMode::Multicast48bits(inline) => {
                    bytes[0] = 0xff;
                    bytes[1] = inline[0];
                    bytes[11..].copy_from_slice(&inline[1..][..5]);
                    Ok(ipv6::Address::from_octets(bytes))
                }
                AddressMode::Multicast32bits(inline) => {
                    bytes[0] = 0xff;
                    bytes[1] = inline[0];
                    bytes[13..].copy_from_slice(&inline[1..][..3]);
                    Ok(ipv6::Address::from_octets(bytes))
                }
                AddressMode::Multicast8bits(inline) => {
                    bytes[0] = 0xff;
                    bytes[1] = 0x02;
                    bytes[15] = inline[0];
                    Ok(ipv6::Address::from_octets(bytes))
                }
                _ => Err(Error),
            },
            UnresolvedAddress::WithContext(mode) => match mode {
                (_, AddressMode::Unspecified) => Ok(ipv6::Address::UNSPECIFIED),
                (index, AddressMode::InLine64bits(inline)) => {
                    copy_context(index, &mut bytes[..])?;
                    bytes[16 - inline.len()..].copy_from_slice(inline);
                    Ok(ipv6::Address::from_octets(bytes))
                }
                (index, AddressMode::InLine16bits(inline)) => {
                    copy_context(index, &mut bytes[..])?;
                    bytes[16 - inline.len()..].copy_from_slice(inline);
                    Ok(ipv6::Address::from_octets(bytes))
                }
                (index, AddressMode::FullyElided) => {
                    match ll_address {
                        Some(LlAddress::Short(ll)) => {
                            bytes[11..13].copy_from_slice(&EUI64_MIDDLE_VALUE[..]);
                            bytes[14..].copy_from_slice(&ll);
                        }
                        Some(addr @ LlAddress::Extended(_)) => match addr.as_eui_64() {
                            Some(addr) => bytes[8..].copy_from_slice(&addr),
                            None => return Err(Error),
                        },
                        Some(LlAddress::Absent) => return Err(Error),
                        None => return Err(Error),
                    }

                    copy_context(index, &mut bytes[..])?;

                    Ok(ipv6::Address::from_octets(bytes))
                }
                _ => Err(Error),
            },
            UnresolvedAddress::Reserved => Err(Error),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum SixlowpanPacket {
    FragmentHeader,
    IphcHeader,
}

const DISPATCH_FIRST_FRAGMENT_HEADER: u8 = 0b11000;
const DISPATCH_FRAGMENT_HEADER: u8 = 0b11100;
const DISPATCH_IPHC_HEADER: u8 = 0b011;
const DISPATCH_UDP_HEADER: u8 = 0b11110;
const DISPATCH_EXT_HEADER: u8 = 0b1110;

impl SixlowpanPacket {
    /// Returns the type of the 6LoWPAN header.
    /// This can either be a fragment header or an IPHC header.
    ///
    /// # Errors
    /// Returns `[Error::Unrecognized]` when neither the Fragment Header dispatch or the IPHC
    /// dispatch is recognized.
    pub fn dispatch(buffer: impl AsRef<[u8]>) -> Result<Self> {
        let raw = buffer.as_ref();

        if raw.is_empty() {
            return Err(Error);
        }

        if raw[0] >> 3 == DISPATCH_FIRST_FRAGMENT_HEADER || raw[0] >> 3 == DISPATCH_FRAGMENT_HEADER
        {
            Ok(Self::FragmentHeader)
        } else if raw[0] >> 5 == DISPATCH_IPHC_HEADER {
            Ok(Self::IphcHeader)
        } else {
            Err(Error)
        }
    }
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum NextHeader {
    Compressed,
    Uncompressed(IpProtocol),
}

impl core::fmt::Display for NextHeader {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            NextHeader::Compressed => write!(f, "compressed"),
            NextHeader::Uncompressed(protocol) => write!(f, "{protocol}"),
        }
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for NextHeader {
    fn format(&self, fmt: defmt::Formatter) {
        match self {
            NextHeader::Compressed => defmt::write!(fmt, "compressed"),
            NextHeader::Uncompressed(protocol) => defmt::write!(fmt, "{}", protocol),
        }
    }
}

#[cfg(test)]
#[path = "test_tests.rs"]
mod test;
