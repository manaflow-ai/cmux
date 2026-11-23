//! Implementation of IP Header Compression from [RFC 6282 § 3.1].
//! It defines the compression of IPv6 headers.
//!
//! [RFC 6282 § 3.1]: https://datatracker.ietf.org/doc/html/rfc6282#section-3.1

use super::{
    AddressContext, AddressMode, DISPATCH_IPHC_HEADER, Error, NextHeader, Result, UnresolvedAddress,
};
use crate::wire::{IpProtocol, ieee802154::Address as LlAddress, ipv6, ipv6::AddressExt};
use byteorder::{ByteOrder, NetworkEndian};

mod field {
    use crate::wire::field::*;

    pub const IPHC_FIELD: Field = 0..2;
}

macro_rules! get_field {
    ($name:ident, $mask:expr, $shift:expr) => {
        fn $name(&self) -> u8 {
            let data = self.buffer.as_ref();
            let raw = NetworkEndian::read_u16(&data[field::IPHC_FIELD]);
            ((raw >> $shift) & $mask) as u8
        }
    };
}

macro_rules! set_field {
    ($name:ident, $mask:expr, $shift:expr) => {
        fn $name(&mut self, val: u8) {
            let data = &mut self.buffer.as_mut()[field::IPHC_FIELD];
            let mut raw = NetworkEndian::read_u16(data);

            raw = (raw & !($mask << $shift)) | ((val as u16) << $shift);
            NetworkEndian::write_u16(data, raw);
        }
    };
}

/// A read/write wrapper around a 6LoWPAN IPHC header.
/// [RFC 6282 § 3.1] specifies the format of the header.
///
/// The header always start with the following base format (from [RFC 6282 § 3.1.1]):
/// ```txt
///    0                                       1
///    0   1   2   3   4   5   6   7   8   9   0   1   2   3   4   5
///  +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
///  | 0 | 1 | 1 |  TF   |NH | HLIM  |CID|SAC|  SAM  | M |DAC|  DAM  |
///  +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
/// ```
/// With:
/// - TF: Traffic Class and Flow Label
/// - NH: Next Header
/// - HLIM: Hop Limit
/// - CID: Context Identifier Extension
/// - SAC: Source Address Compression
/// - SAM: Source Address Mode
/// - M: Multicast Compression
/// - DAC: Destination Address Compression
/// - DAM: Destination Address Mode
///
/// Depending on the flags in the base format, the following fields are added to the header:
/// - Traffic Class and Flow Label
/// - Next Header
/// - Hop Limit
/// - IPv6 source address
/// - IPv6 destination address
///
/// [RFC 6282 § 3.1]: https://datatracker.ietf.org/doc/html/rfc6282#section-3.1
/// [RFC 6282 § 3.1.1]: https://datatracker.ietf.org/doc/html/rfc6282#section-3.1.1
#[derive(Debug, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Packet<T: AsRef<[u8]>> {
    buffer: T,
}

impl<T: AsRef<[u8]>> Packet<T> {
    /// Input a raw octet buffer with a 6LoWPAN IPHC header structure.
    pub const fn new_unchecked(buffer: T) -> Self {
        Packet { buffer }
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
    /// Returns `Err(Error)` if the buffer is too short.
    pub fn check_len(&self) -> Result<()> {
        let buffer = self.buffer.as_ref();
        if buffer.len() < 2 {
            return Err(Error);
        }

        let mut offset = self.ip_fields_start()
            + self.traffic_class_size()
            + self.next_header_size()
            + self.hop_limit_size();
        offset += self.src_address_size();
        offset += self.dst_address_size();

        if offset as usize > buffer.len() {
            return Err(Error);
        }

        Ok(())
    }

    /// Consumes the frame, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Return the Next Header field.
    pub fn next_header(&self) -> NextHeader {
        let nh = self.nh_field();

        if nh == 1 {
            // The next header field is compressed.
            // It is also encoded using LOWPAN_NHC.
            NextHeader::Compressed
        } else {
            // The full 8 bits for Next Header are carried in-line.
            let start = (self.ip_fields_start() + self.traffic_class_size()) as usize;

            let data = self.buffer.as_ref();
            let nh = data[start..start + 1][0];
            NextHeader::Uncompressed(IpProtocol::from(nh))
        }
    }

    /// Return the Hop Limit.
    pub fn hop_limit(&self) -> u8 {
        match self.hlim_field() {
            0b00 => {
                let start = (self.ip_fields_start()
                    + self.traffic_class_size()
                    + self.next_header_size()) as usize;

                let data = self.buffer.as_ref();
                data[start..start + 1][0]
            }
            0b01 => 1,
            0b10 => 64,
            0b11 => 255,
            _ => unreachable!(),
        }
    }

    /// Return the Source Context Identifier.
    pub fn src_context_id(&self) -> Option<u8> {
        if self.cid_field() == 1 {
            let data = self.buffer.as_ref();
            Some(data[2] >> 4)
        } else {
            None
        }
    }

    /// Return the Destination Context Identifier.
    pub fn dst_context_id(&self) -> Option<u8> {
        if self.cid_field() == 1 {
            let data = self.buffer.as_ref();
            Some(data[2] & 0x0f)
        } else {
            None
        }
    }

    /// Return the ECN field (when it is inlined).
    pub fn ecn_field(&self) -> Option<u8> {
        match self.tf_field() {
            0b00..=0b10 => {
                let start = self.ip_fields_start() as usize;
                Some(self.buffer.as_ref()[start..][0] & 0b1100_0000)
            }
            0b11 => None,
            _ => unreachable!(),
        }
    }

    /// Return the DSCP field (when it is inlined).
    pub fn dscp_field(&self) -> Option<u8> {
        match self.tf_field() {
            0b00 | 0b10 => {
                let start = self.ip_fields_start() as usize;
                Some(self.buffer.as_ref()[start..][0] & 0b111111)
            }
            0b01 | 0b11 => None,
            _ => unreachable!(),
        }
    }

    /// Return the flow label field (when it is inlined).
    pub fn flow_label_field(&self) -> Option<u16> {
        match self.tf_field() {
            0b00 => {
                let start = self.ip_fields_start() as usize;
                Some(NetworkEndian::read_u16(
                    &self.buffer.as_ref()[start..][2..4],
                ))
            }
            0b01 => {
                let start = self.ip_fields_start() as usize;
                Some(NetworkEndian::read_u16(
                    &self.buffer.as_ref()[start..][1..3],
                ))
            }
            0b10 | 0b11 => None,
            _ => unreachable!(),
        }
    }

    /// Return the Source Address.
    pub fn src_addr(&self) -> Result<UnresolvedAddress<'_>> {
        let start = (self.ip_fields_start()
            + self.traffic_class_size()
            + self.next_header_size()
            + self.hop_limit_size()) as usize;

        let data = self.buffer.as_ref();
        match (self.sac_field(), self.sam_field()) {
            (0, 0b00) => Ok(UnresolvedAddress::WithoutContext(AddressMode::FullInline(
                &data[start..][..16],
            ))),
            (0, 0b01) => Ok(UnresolvedAddress::WithoutContext(
                AddressMode::InLine64bits(&data[start..][..8]),
            )),
            (0, 0b10) => Ok(UnresolvedAddress::WithoutContext(
                AddressMode::InLine16bits(&data[start..][..2]),
            )),
            (0, 0b11) => Ok(UnresolvedAddress::WithoutContext(AddressMode::FullyElided)),
            (1, 0b00) => Ok(UnresolvedAddress::WithContext((
                0,
                AddressMode::Unspecified,
            ))),
            (1, 0b01) => {
                if let Some(id) = self.src_context_id() {
                    Ok(UnresolvedAddress::WithContext((
                        id as usize,
                        AddressMode::InLine64bits(&data[start..][..8]),
                    )))
                } else {
                    Err(Error)
                }
            }
            (1, 0b10) => {
                if let Some(id) = self.src_context_id() {
                    Ok(UnresolvedAddress::WithContext((
                        id as usize,
                        AddressMode::InLine16bits(&data[start..][..2]),
                    )))
                } else {
                    Err(Error)
                }
            }
            (1, 0b11) => {
                if let Some(id) = self.src_context_id() {
                    Ok(UnresolvedAddress::WithContext((
                        id as usize,
                        AddressMode::FullyElided,
                    )))
                } else {
                    Err(Error)
                }
            }
            _ => Err(Error),
        }
    }

    /// Return the Destination Address.
    pub fn dst_addr(&self) -> Result<UnresolvedAddress<'_>> {
        let start = (self.ip_fields_start()
            + self.traffic_class_size()
            + self.next_header_size()
            + self.hop_limit_size()
            + self.src_address_size()) as usize;

        let data = self.buffer.as_ref();
        match (self.m_field(), self.dac_field(), self.dam_field()) {
            (0, 0, 0b00) => Ok(UnresolvedAddress::WithoutContext(AddressMode::FullInline(
                &data[start..][..16],
            ))),
            (0, 0, 0b01) => Ok(UnresolvedAddress::WithoutContext(
                AddressMode::InLine64bits(&data[start..][..8]),
            )),
            (0, 0, 0b10) => Ok(UnresolvedAddress::WithoutContext(
                AddressMode::InLine16bits(&data[start..][..2]),
            )),
            (0, 0, 0b11) => Ok(UnresolvedAddress::WithoutContext(AddressMode::FullyElided)),
            (0, 1, 0b00) => Ok(UnresolvedAddress::Reserved),
            (0, 1, 0b01) => {
                if let Some(id) = self.dst_context_id() {
                    Ok(UnresolvedAddress::WithContext((
                        id as usize,
                        AddressMode::InLine64bits(&data[start..][..8]),
                    )))
                } else {
                    Err(Error)
                }
            }
            (0, 1, 0b10) => {
                if let Some(id) = self.dst_context_id() {
                    Ok(UnresolvedAddress::WithContext((
                        id as usize,
                        AddressMode::InLine16bits(&data[start..][..2]),
                    )))
                } else {
                    Err(Error)
                }
            }
            (0, 1, 0b11) => {
                if let Some(id) = self.dst_context_id() {
                    Ok(UnresolvedAddress::WithContext((
                        id as usize,
                        AddressMode::FullyElided,
                    )))
                } else {
                    Err(Error)
                }
            }
            (1, 0, 0b00) => Ok(UnresolvedAddress::WithoutContext(AddressMode::FullInline(
                &data[start..][..16],
            ))),
            (1, 0, 0b01) => Ok(UnresolvedAddress::WithoutContext(
                AddressMode::Multicast48bits(&data[start..][..6]),
            )),
            (1, 0, 0b10) => Ok(UnresolvedAddress::WithoutContext(
                AddressMode::Multicast32bits(&data[start..][..4]),
            )),
            (1, 0, 0b11) => Ok(UnresolvedAddress::WithoutContext(
                AddressMode::Multicast8bits(&data[start..][..1]),
            )),
            (1, 1, 0b00) => Ok(UnresolvedAddress::WithContext((
                0,
                AddressMode::NotSupported,
            ))),
            (1, 1, 0b01..=0b11) => Ok(UnresolvedAddress::Reserved),
            _ => Err(Error),
        }
    }

    get_field!(dispatch_field, 0b111, 13);
    get_field!(tf_field, 0b11, 11);
    get_field!(nh_field, 0b1, 10);
    get_field!(hlim_field, 0b11, 8);
    get_field!(cid_field, 0b1, 7);
    get_field!(sac_field, 0b1, 6);
    get_field!(sam_field, 0b11, 4);
    get_field!(m_field, 0b1, 3);
    get_field!(dac_field, 0b1, 2);
    get_field!(dam_field, 0b11, 0);

    /// Return the start for the IP fields.
    fn ip_fields_start(&self) -> u8 {
        2 + self.cid_size()
    }

    /// Get the size in octets of the traffic class field.
    fn traffic_class_size(&self) -> u8 {
        match self.tf_field() {
            0b00 => 4,
            0b01 => 3,
            0b10 => 1,
            0b11 => 0,
            _ => unreachable!(),
        }
    }

    /// Get the size in octets of the next header field.
    fn next_header_size(&self) -> u8 {
        (self.nh_field() != 1) as u8
    }

    /// Get the size in octets of the hop limit field.
    fn hop_limit_size(&self) -> u8 {
        (self.hlim_field() == 0b00) as u8
    }

    /// Get the size in octets of the CID field.
    fn cid_size(&self) -> u8 {
        (self.cid_field() == 1) as u8
    }

    /// Get the size in octets of the source address.
    fn src_address_size(&self) -> u8 {
        match (self.sac_field(), self.sam_field()) {
            (0, 0b00) => 16, // The full address is carried in-line.
            (0, 0b01) => 8,  // The first 64 bits are elided.
            (0, 0b10) => 2,  // The first 112 bits are elided.
            (0, 0b11) => 0,  // The address is fully elided.
            (1, 0b00) => 0,  // The UNSPECIFIED address.
            (1, 0b01) => 8,  // Address derived using context information.
            (1, 0b10) => 2,  // Address derived using context information.
            (1, 0b11) => 0,  // Address derived using context information.
            _ => unreachable!(),
        }
    }

    /// Get the size in octets of the address address.
    fn dst_address_size(&self) -> u8 {
        match (self.m_field(), self.dac_field(), self.dam_field()) {
            (0, 0, 0b00) => 16, // The full address is carried in-line.
            (0, 0, 0b01) => 8,  // The first 64 bits are elided.
            (0, 0, 0b10) => 2,  // The first 112 bits are elided.
            (0, 0, 0b11) => 0,  // The address is fully elided.
            (0, 1, 0b00) => 0,  // Reserved.
            (0, 1, 0b01) => 8,  // Address derived using context information.
            (0, 1, 0b10) => 2,  // Address derived using context information.
            (0, 1, 0b11) => 0,  // Address derived using context information.
            (1, 0, 0b00) => 16, // The full address is carried in-line.
            (1, 0, 0b01) => 6,  // The address takes the form ffXX::00XX:XXXX:XXXX.
            (1, 0, 0b10) => 4,  // The address takes the form ffXX::00XX:XXXX.
            (1, 0, 0b11) => 1,  // The address takes the form ff02::00XX.
            (1, 1, 0b00) => 6,  // Match Unicast-Prefix-based IPv6.
            (1, 1, 0b01) => 0,  // Reserved.
            (1, 1, 0b10) => 0,  // Reserved.
            (1, 1, 0b11) => 0,  // Reserved.
            _ => unreachable!(),
        }
    }

    /// Return the length of the header.
    pub fn header_len(&self) -> usize {
        let mut len = self.ip_fields_start();
        len += self.traffic_class_size();
        len += self.next_header_size();
        len += self.hop_limit_size();
        len += self.src_address_size();
        len += self.dst_address_size();

        len as usize
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> Packet<&'a T> {
    /// Return a pointer to the payload.
    pub fn payload(&self) -> &'a [u8] {
        let mut len = self.ip_fields_start();
        len += self.traffic_class_size();
        len += self.next_header_size();
        len += self.hop_limit_size();
        len += self.src_address_size();
        len += self.dst_address_size();

        let len = len as usize;

        let data = self.buffer.as_ref();
        &data[len..]
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Packet<T> {
    /// Set the dispatch field to `0b011`.
    fn set_dispatch_field(&mut self) {
        let data = &mut self.buffer.as_mut()[field::IPHC_FIELD];
        let mut raw = NetworkEndian::read_u16(data);

        raw = (raw & !(0b111 << 13)) | (0b11 << 13);
        NetworkEndian::write_u16(data, raw);
    }

    set_field!(set_tf_field, 0b11, 11);
    set_field!(set_nh_field, 0b1, 10);
    set_field!(set_hlim_field, 0b11, 8);
    set_field!(set_cid_field, 0b1, 7);
    set_field!(set_sac_field, 0b1, 6);
    set_field!(set_sam_field, 0b11, 4);
    set_field!(set_m_field, 0b1, 3);
    set_field!(set_dac_field, 0b1, 2);
    set_field!(set_dam_field, 0b11, 0);

    fn set_field(&mut self, idx: usize, value: &[u8]) {
        let raw = self.buffer.as_mut();
        raw[idx..idx + value.len()].copy_from_slice(value);
    }

    /// Set the Next Header.
    ///
    /// **NOTE**: `idx` is the offset at which the Next Header needs to be written to.
    fn set_next_header(&mut self, nh: NextHeader, mut idx: usize) -> usize {
        match nh {
            NextHeader::Uncompressed(nh) => {
                self.set_nh_field(0);
                self.set_field(idx, &[nh.into()]);
                idx += 1;
            }
            NextHeader::Compressed => self.set_nh_field(1),
        }

        idx
    }

    /// Set the Hop Limit.
    ///
    /// **NOTE**: `idx` is the offset at which the Next Header needs to be written to.
    fn set_hop_limit(&mut self, hl: u8, mut idx: usize) -> usize {
        match hl {
            255 => self.set_hlim_field(0b11),
            64 => self.set_hlim_field(0b10),
            1 => self.set_hlim_field(0b01),
            _ => {
                self.set_hlim_field(0b00);
                self.set_field(idx, &[hl]);
                idx += 1;
            }
        }

        idx
    }

    /// Set the Source Address based on the IPv6 address and the Link-Local address.
    ///
    /// **NOTE**: `idx` is the offset at which the Next Header needs to be written to.
    fn set_src_address(
        &mut self,
        src_addr: ipv6::Address,
        ll_src_addr: Option<LlAddress>,
        mut idx: usize,
    ) -> usize {
        self.set_cid_field(0);
        self.set_sac_field(0);
        let src = src_addr.octets();
        if src_addr == ipv6::Address::UNSPECIFIED {
            self.set_sac_field(1);
            self.set_sam_field(0b00);
        } else if src_addr.is_link_local() {
            // We have a link local address.
            // The remainder of the address can be elided when the context contains
            // a 802.15.4 short address or a 802.15.4 extended address which can be
            // converted to a eui64 address.
            let is_eui_64 = ll_src_addr
                .map(|addr| {
                    addr.as_eui_64()
                        .map(|addr| addr[..] == src[8..])
                        .unwrap_or(false)
                })
                .unwrap_or(false);

            if src[8..14] == [0, 0, 0, 0xff, 0xfe, 0] {
                let ll = [src[14], src[15]];

                if ll_src_addr == Some(LlAddress::Short(ll)) {
                    // We have the context from the 802.15.4 frame.
                    // The context contains the short address.
                    // We can elide the source address.
                    self.set_sam_field(0b11);
                } else {
                    // We don't have the context from the 802.15.4 frame.
                    // We cannot elide the source address, however we can elide 112 bits.
                    self.set_sam_field(0b10);

                    self.set_field(idx, &src[14..]);
                    idx += 2;
                }
            } else if is_eui_64 {
                // We have the context from the 802.15.4 frame.
                // The context contains the extended address.
                // We can elide the source address.
                self.set_sam_field(0b11);
            } else {
                // We cannot elide the source address, however we can elide 64 bits.
                self.set_sam_field(0b01);

                self.set_field(idx, &src[8..]);
                idx += 8;
            }
        } else {
            // We cannot elide anything.
            self.set_sam_field(0b00);
            self.set_field(idx, &src);
            idx += 16;
        }

        idx
    }

    /// Set the Destination Address based on the IPv6 address and the Link-Local address.
    ///
    /// **NOTE**: `idx` is the offset at which the Next Header needs to be written to.
    fn set_dst_address(
        &mut self,
        dst_addr: ipv6::Address,
        ll_dst_addr: Option<LlAddress>,
        mut idx: usize,
    ) -> usize {
        self.set_dac_field(0);
        self.set_dam_field(0);
        self.set_m_field(0);
        let dst = dst_addr.octets();
        if dst_addr.is_multicast() {
            self.set_m_field(1);

            if dst[1] == 0x02 && dst[2..15] == [0; 13] {
                self.set_dam_field(0b11);

                self.set_field(idx, &[dst[15]]);
                idx += 1;
            } else if dst[2..13] == [0; 11] {
                self.set_dam_field(0b10);

                self.set_field(idx, &[dst[1]]);
                idx += 1;
                self.set_field(idx, &dst[13..]);
                idx += 3;
            } else if dst[2..11] == [0; 9] {
                self.set_dam_field(0b01);

                self.set_field(idx, &[dst[1]]);
                idx += 1;
                self.set_field(idx, &dst[11..]);
                idx += 5;
            } else {
                self.set_dam_field(0b11);

                self.set_field(idx, &dst);
                idx += 16;
            }
        } else if dst_addr.is_link_local() {
            let is_eui_64 = ll_dst_addr
                .map(|addr| {
                    addr.as_eui_64()
                        .map(|addr| addr[..] == dst[8..])
                        .unwrap_or(false)
                })
                .unwrap_or(false);

            if dst[8..14] == [0, 0, 0, 0xff, 0xfe, 0] {
                let ll = [dst[14], dst[15]];

                if ll_dst_addr == Some(LlAddress::Short(ll)) {
                    self.set_dam_field(0b11);
                } else {
                    self.set_dam_field(0b10);

                    self.set_field(idx, &dst[14..]);
                    idx += 2;
                }
            } else if is_eui_64 {
                self.set_dam_field(0b11);
            } else {
                self.set_dam_field(0b01);

                self.set_field(idx, &dst[8..]);
                idx += 8;
            }
        } else {
            self.set_dam_field(0b00);

            self.set_field(idx, &dst);
            idx += 16;
        }

        idx
    }

    /// Return a mutable pointer to the payload.
    pub fn payload_mut(&mut self) -> &mut [u8] {
        let mut len = self.ip_fields_start();

        len += self.traffic_class_size();
        len += self.next_header_size();
        len += self.hop_limit_size();
        len += self.src_address_size();
        len += self.dst_address_size();

        let len = len as usize;

        let data = self.buffer.as_mut();
        &mut data[len..]
    }
}

/// A high-level representation of a 6LoWPAN IPHC header.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub struct Repr {
    pub src_addr: ipv6::Address,
    pub ll_src_addr: Option<LlAddress>,
    pub dst_addr: ipv6::Address,
    pub ll_dst_addr: Option<LlAddress>,
    pub next_header: NextHeader,
    pub hop_limit: u8,
    // TODO(thvdveld): refactor the following fields into something else
    pub ecn: Option<u8>,
    pub dscp: Option<u8>,
    pub flow_label: Option<u16>,
}

impl core::fmt::Display for Repr {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(
            f,
            "IPHC src={} dst={} nxt-hdr={} hop-limit={}",
            self.src_addr, self.dst_addr, self.next_header, self.hop_limit
        )
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Repr {
    fn format(&self, fmt: defmt::Formatter) {
        defmt::write!(
            fmt,
            "IPHC src={} dst={} nxt-hdr={} hop-limit={}",
            self.src_addr,
            self.dst_addr,
            self.next_header,
            self.hop_limit
        );
    }
}

impl Repr {
    /// Parse a 6LoWPAN IPHC header and return a high-level representation.
    ///
    /// The `ll_src_addr` and `ll_dst_addr` are the link-local addresses used for resolving the
    /// IPv6 packets.
    pub fn parse<T: AsRef<[u8]> + ?Sized>(
        packet: &Packet<&T>,
        ll_src_addr: Option<LlAddress>,
        ll_dst_addr: Option<LlAddress>,
        addr_context: &[AddressContext],
    ) -> Result<Self> {
        // Ensure basic accessors will work.
        packet.check_len()?;

        if packet.dispatch_field() != DISPATCH_IPHC_HEADER {
            // This is not an LOWPAN_IPHC packet.
            return Err(Error);
        }

        let src_addr = packet.src_addr()?.resolve(ll_src_addr, addr_context)?;
        let dst_addr = packet.dst_addr()?.resolve(ll_dst_addr, addr_context)?;

        Ok(Self {
            src_addr,
            ll_src_addr,
            dst_addr,
            ll_dst_addr,
            next_header: packet.next_header(),
            hop_limit: packet.hop_limit(),
            ecn: packet.ecn_field(),
            dscp: packet.dscp_field(),
            flow_label: packet.flow_label_field(),
        })
    }

    /// Return the length of a header that will be emitted from this high-level representation.
    pub fn buffer_len(&self) -> usize {
        let mut len = 0;
        len += 2; // The minimal header length

        len += match self.next_header {
            NextHeader::Compressed => 0, // The next header is compressed (we don't need to inline what the next header is)
            NextHeader::Uncompressed(_) => 1, // The next header field is inlined
        };

        // Hop Limit size
        len += match self.hop_limit {
            255 | 64 | 1 => 0, // We can inline the hop limit
            _ => 1,
        };

        // Add the length of the source address
        len += if self.src_addr == ipv6::Address::UNSPECIFIED {
            0
        } else if self.src_addr.is_link_local() {
            let src = self.src_addr.octets();
            let ll = [src[14], src[15]];

            let is_eui_64 = self
                .ll_src_addr
                .map(|addr| {
                    addr.as_eui_64()
                        .map(|addr| addr[..] == src[8..])
                        .unwrap_or(false)
                })
                .unwrap_or(false);

            if src[8..14] == [0, 0, 0, 0xff, 0xfe, 0] {
                if self.ll_src_addr == Some(LlAddress::Short(ll)) {
                    0
                } else {
                    2
                }
            } else if is_eui_64 {
                0
            } else {
                8
            }
        } else {
            16
        };

        // Add the size of the destination header
        let dst = self.dst_addr.octets();
        len += if self.dst_addr.is_multicast() {
            if dst[1] == 0x02 && dst[2..15] == [0; 13] {
                1
            } else if dst[2..13] == [0; 11] {
                4
            } else if dst[2..11] == [0; 9] {
                6
            } else {
                16
            }
        } else if self.dst_addr.is_link_local() {
            let is_eui_64 = self
                .ll_dst_addr
                .map(|addr| {
                    addr.as_eui_64()
                        .map(|addr| addr[..] == dst[8..])
                        .unwrap_or(false)
                })
                .unwrap_or(false);

            if dst[8..14] == [0, 0, 0, 0xff, 0xfe, 0] {
                let ll = [dst[14], dst[15]];

                if self.ll_dst_addr == Some(LlAddress::Short(ll)) {
                    0
                } else {
                    2
                }
            } else if is_eui_64 {
                0
            } else {
                8
            }
        } else {
            16
        };

        len += match (self.ecn, self.dscp, self.flow_label) {
            (Some(_), Some(_), Some(_)) => 4,
            (Some(_), None, Some(_)) => 3,
            (Some(_), Some(_), None) => 1,
            (None, None, None) => 0,
            _ => unreachable!(),
        };

        len
    }

    /// Emit a high-level representation into a 6LoWPAN IPHC header.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]>>(&self, packet: &mut Packet<T>) {
        let idx = 2;

        packet.set_dispatch_field();

        // FIXME(thvdveld): we don't set anything from the traffic flow.
        packet.set_tf_field(0b11);

        let idx = packet.set_next_header(self.next_header, idx);
        let idx = packet.set_hop_limit(self.hop_limit, idx);
        let idx = packet.set_src_address(self.src_addr, self.ll_src_addr, idx);
        packet.set_dst_address(self.dst_addr, self.ll_dst_addr, idx);
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn iphc_fields() {
        let bytes = [
            0x7a, 0x33, // IPHC
            0x3a, // Next header
        ];

        let packet = Packet::new_unchecked(bytes);

        assert_eq!(packet.dispatch_field(), 0b011);
        assert_eq!(packet.tf_field(), 0b11);
        assert_eq!(packet.nh_field(), 0b0);
        assert_eq!(packet.hlim_field(), 0b10);
        assert_eq!(packet.cid_field(), 0b0);
        assert_eq!(packet.sac_field(), 0b0);
        assert_eq!(packet.sam_field(), 0b11);
        assert_eq!(packet.m_field(), 0b0);
        assert_eq!(packet.dac_field(), 0b0);
        assert_eq!(packet.dam_field(), 0b11);

        assert_eq!(
            packet.next_header(),
            NextHeader::Uncompressed(IpProtocol::Icmpv6)
        );

        assert_eq!(packet.src_address_size(), 0);
        assert_eq!(packet.dst_address_size(), 0);
        assert_eq!(packet.hop_limit(), 64);

        assert_eq!(
            packet.src_addr(),
            Ok(UnresolvedAddress::WithoutContext(AddressMode::FullyElided))
        );
        assert_eq!(
            packet.dst_addr(),
            Ok(UnresolvedAddress::WithoutContext(AddressMode::FullyElided))
        );

        let bytes = [
            0x7e, 0xf7, // IPHC,
            0x00, // CID
        ];

        let packet = Packet::new_unchecked(bytes);

        assert_eq!(packet.dispatch_field(), 0b011);
        assert_eq!(packet.tf_field(), 0b11);
        assert_eq!(packet.nh_field(), 0b1);
        assert_eq!(packet.hlim_field(), 0b10);
        assert_eq!(packet.cid_field(), 0b1);
        assert_eq!(packet.sac_field(), 0b1);
        assert_eq!(packet.sam_field(), 0b11);
        assert_eq!(packet.m_field(), 0b0);
        assert_eq!(packet.dac_field(), 0b1);
        assert_eq!(packet.dam_field(), 0b11);

        assert_eq!(packet.next_header(), NextHeader::Compressed);

        assert_eq!(packet.src_address_size(), 0);
        assert_eq!(packet.dst_address_size(), 0);
        assert_eq!(packet.hop_limit(), 64);

        assert_eq!(
            packet.src_addr(),
            Ok(UnresolvedAddress::WithContext((
                0,
                AddressMode::FullyElided
            )))
        );
        assert_eq!(
            packet.dst_addr(),
            Ok(UnresolvedAddress::WithContext((
                0,
                AddressMode::FullyElided
            )))
        );
    }
}
