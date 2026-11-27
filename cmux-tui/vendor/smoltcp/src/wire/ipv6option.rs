use super::{Error, Result};
#[cfg(feature = "proto-rpl")]
use super::{RplHopByHopPacket, RplHopByHopRepr};

use byteorder::{ByteOrder, NetworkEndian};
use core::fmt;

enum_with_unknown! {
    /// IPv6 Extension Header Option Type
    pub enum Type(u8) {
        /// 1 byte of padding
        Pad1 = 0,
        /// Multiple bytes of padding
        PadN = 1,
        /// Router Alert
        RouterAlert = 5,
        /// RPL Option
        Rpl  = 0x63,
    }
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            Type::Pad1 => write!(f, "Pad1"),
            Type::PadN => write!(f, "PadN"),
            Type::Rpl => write!(f, "RPL"),
            Type::RouterAlert => write!(f, "RouterAlert"),
            Type::Unknown(id) => write!(f, "{id}"),
        }
    }
}

enum_with_unknown! {
    /// A high-level representation of an IPv6 Router Alert Header Option.
    ///
    /// Router Alert options always contain exactly one `u16`; see [RFC 2711 § 2.1].
    ///
    /// [RFC 2711 § 2.1]: https://tools.ietf.org/html/rfc2711#section-2.1
    pub enum RouterAlert(u16) {
        MulticastListenerDiscovery = 0,
        Rsvp = 1,
        ActiveNetworks = 2,
    }
}

impl RouterAlert {
    /// Per [RFC 2711 § 2.1], Router Alert options always have 2 bytes of data.
    ///
    /// [RFC 2711 § 2.1]: https://tools.ietf.org/html/rfc2711#section-2.1
    pub const DATA_LEN: u8 = 2;
}

/// Action required when parsing the given IPv6 Extension
/// Header Option Type fails
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Clone, Copy, Hash)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub enum FailureType {
    /// Skip this option and continue processing the packet
    Skip = 0b00000000,
    /// Discard the containing packet
    Discard = 0b01000000,
    /// Discard the containing packet and notify the sender
    DiscardSendAll = 0b10000000,
    /// Discard the containing packet and only notify the sender
    /// if the sender is a unicast address
    DiscardSendUnicast = 0b11000000,
}

impl From<u8> for FailureType {
    fn from(value: u8) -> FailureType {
        match value & 0b11000000 {
            0b00000000 => FailureType::Skip,
            0b01000000 => FailureType::Discard,
            0b10000000 => FailureType::DiscardSendAll,
            0b11000000 => FailureType::DiscardSendUnicast,
            _ => unreachable!(),
        }
    }
}

impl From<FailureType> for u8 {
    fn from(value: FailureType) -> Self {
        match value {
            FailureType::Skip => 0b00000000,
            FailureType::Discard => 0b01000000,
            FailureType::DiscardSendAll => 0b10000000,
            FailureType::DiscardSendUnicast => 0b11000000,
        }
    }
}

impl fmt::Display for FailureType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            FailureType::Skip => write!(f, "skip"),
            FailureType::Discard => write!(f, "discard"),
            FailureType::DiscardSendAll => write!(f, "discard and send error"),
            FailureType::DiscardSendUnicast => write!(f, "discard and send error if unicast"),
        }
    }
}

impl From<Type> for FailureType {
    fn from(other: Type) -> FailureType {
        let raw: u8 = other.into();
        Self::from(raw & 0b11000000u8)
    }
}

/// A read/write wrapper around an IPv6 Extension Header Option.
#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Ipv6Option<T: AsRef<[u8]>> {
    buffer: T,
}

// Format of Option
//
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+- - - - - - - - -
// |  Option Type  |  Opt Data Len |  Option Data
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+- - - - - - - - -
//
//
// See https://tools.ietf.org/html/rfc8200#section-4.2 for details.
mod field {
    #![allow(non_snake_case)]

    use crate::wire::field::*;

    // 8-bit identifier of the type of option.
    pub const TYPE: usize = 0;
    // 8-bit unsigned integer. Length of the DATA field of this option, in octets.
    pub const LENGTH: usize = 1;
    // Variable-length field. Option-Type-specific data.
    pub const fn DATA(length: u8) -> Field {
        2..length as usize + 2
    }
}

impl<T: AsRef<[u8]>> Ipv6Option<T> {
    /// Create a raw octet buffer with an IPv6 Extension Header Option structure.
    pub const fn new_unchecked(buffer: T) -> Ipv6Option<T> {
        Ipv6Option { buffer }
    }

    /// Shorthand for a combination of [new_unchecked] and [check_len].
    ///
    /// [new_unchecked]: #method.new_unchecked
    /// [check_len]: #method.check_len
    pub fn new_checked(buffer: T) -> Result<Ipv6Option<T>> {
        let opt = Self::new_unchecked(buffer);
        opt.check_len()?;
        Ok(opt)
    }

    /// Ensure that no accessor method will panic if called.
    /// Returns `Err(Error)` if the buffer is too short.
    ///
    /// The result of this check is invalidated by calling [set_data_len].
    ///
    /// [set_data_len]: #method.set_data_len
    pub fn check_len(&self) -> Result<()> {
        let data = self.buffer.as_ref();
        let len = data.len();

        if len < field::LENGTH {
            return Err(Error);
        }

        if self.option_type() == Type::Pad1 {
            return Ok(());
        }

        if len == field::LENGTH {
            return Err(Error);
        }

        let df = field::DATA(data[field::LENGTH]);

        if len < df.end {
            return Err(Error);
        }

        Ok(())
    }

    /// Consume the ipv6 option, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }

    /// Return the option type.
    #[inline]
    pub fn option_type(&self) -> Type {
        let data = self.buffer.as_ref();
        Type::from(data[field::TYPE])
    }

    /// Return the length of the data.
    ///
    /// # Panics
    /// This function panics if this is an 1-byte padding option.
    #[inline]
    pub fn data_len(&self) -> u8 {
        let data = self.buffer.as_ref();
        data[field::LENGTH]
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> Ipv6Option<&'a T> {
    /// Return the option data.
    ///
    /// # Panics
    /// This function panics if this is an 1-byte padding option.
    #[inline]
    pub fn data(&self) -> &'a [u8] {
        let len = self.data_len();
        let data = self.buffer.as_ref();
        &data[field::DATA(len)]
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]>> Ipv6Option<T> {
    /// Set the option type.
    #[inline]
    pub fn set_option_type(&mut self, value: Type) {
        let data = self.buffer.as_mut();
        data[field::TYPE] = value.into();
    }

    /// Set the option data length.
    ///
    /// # Panics
    /// This function panics if this is an 1-byte padding option.
    #[inline]
    pub fn set_data_len(&mut self, value: u8) {
        let data = self.buffer.as_mut();
        data[field::LENGTH] = value;
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized> Ipv6Option<&mut T> {
    /// Return a mutable pointer to the option data.
    ///
    /// # Panics
    /// This function panics if this is an 1-byte padding option.
    #[inline]
    pub fn data_mut(&mut self) -> &mut [u8] {
        let len = self.data_len();
        let data = self.buffer.as_mut();
        &mut data[field::DATA(len)]
    }
}

impl<T: AsRef<[u8]> + ?Sized> fmt::Display for Ipv6Option<&T> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match Repr::parse(self) {
            Ok(repr) => write!(f, "{repr}"),
            Err(err) => {
                write!(f, "IPv6 Extension Option ({err})")?;
                Ok(())
            }
        }
    }
}

/// A high-level representation of an IPv6 Extension Header Option.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
#[non_exhaustive]
pub enum Repr<'a> {
    Pad1,
    PadN(u8),
    RouterAlert(RouterAlert),
    #[cfg(feature = "proto-rpl")]
    Rpl(RplHopByHopRepr),
    Unknown {
        type_: Type,
        length: u8,
        data: &'a [u8],
    },
}

impl<'a> Repr<'a> {
    /// Parse an IPv6 Extension Header Option and return a high-level representation.
    pub fn parse<T>(opt: &Ipv6Option<&'a T>) -> Result<Repr<'a>>
    where
        T: AsRef<[u8]> + ?Sized,
    {
        opt.check_len()?;
        match opt.option_type() {
            Type::Pad1 => Ok(Repr::Pad1),
            Type::PadN => Ok(Repr::PadN(opt.data_len())),
            Type::RouterAlert => {
                if opt.data_len() == RouterAlert::DATA_LEN {
                    let raw = NetworkEndian::read_u16(opt.data());
                    Ok(Repr::RouterAlert(RouterAlert::from(raw)))
                } else {
                    Err(Error)
                }
            }
            #[cfg(feature = "proto-rpl")]
            Type::Rpl => Ok(Repr::Rpl(RplHopByHopRepr::parse(
                &RplHopByHopPacket::new_checked(opt.data())?,
            ))),
            #[cfg(not(feature = "proto-rpl"))]
            Type::Rpl => Ok(Repr::Unknown {
                type_: Type::Rpl,
                length: opt.data_len(),
                data: opt.data(),
            }),

            unknown_type @ Type::Unknown(_) => Ok(Repr::Unknown {
                type_: unknown_type,
                length: opt.data_len(),
                data: opt.data(),
            }),
        }
    }

    /// Return the length of a header that will be emitted from this high-level representation.
    pub const fn buffer_len(&self) -> usize {
        match *self {
            Repr::Pad1 => 1,
            Repr::PadN(length) => field::DATA(length).end,
            Repr::RouterAlert(_) => field::DATA(RouterAlert::DATA_LEN).end,
            #[cfg(feature = "proto-rpl")]
            Repr::Rpl(opt) => field::DATA(opt.buffer_len() as u8).end,
            Repr::Unknown { length, .. } => field::DATA(length).end,
        }
    }

    /// Emit a high-level representation into an IPv6 Extension Header Option.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized>(&self, opt: &mut Ipv6Option<&'a mut T>) {
        match *self {
            Repr::Pad1 => opt.set_option_type(Type::Pad1),
            Repr::PadN(len) => {
                opt.set_option_type(Type::PadN);
                opt.set_data_len(len);
                // Ensure all padding bytes are set to zero.
                for x in opt.data_mut().iter_mut() {
                    *x = 0
                }
            }
            Repr::RouterAlert(router_alert) => {
                opt.set_option_type(Type::RouterAlert);
                opt.set_data_len(RouterAlert::DATA_LEN);
                NetworkEndian::write_u16(opt.data_mut(), router_alert.into());
            }
            #[cfg(feature = "proto-rpl")]
            Repr::Rpl(rpl) => {
                opt.set_option_type(Type::Rpl);
                opt.set_data_len(4);
                rpl.emit(&mut crate::wire::RplHopByHopPacket::new_unchecked(
                    opt.data_mut(),
                ));
            }
            Repr::Unknown {
                type_,
                length,
                data,
            } => {
                opt.set_option_type(type_);
                opt.set_data_len(length);
                opt.data_mut().copy_from_slice(&data[..length as usize]);
            }
        }
    }
}

/// A iterator for IPv6 options.
#[derive(Debug)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Ipv6OptionsIterator<'a> {
    pos: usize,
    length: usize,
    data: &'a [u8],
    hit_error: bool,
}

impl<'a> Ipv6OptionsIterator<'a> {
    /// Create a new `Ipv6OptionsIterator`, used to iterate over the
    /// options contained in a IPv6 Extension Header (e.g. the Hop-by-Hop
    /// header).
    pub fn new(data: &'a [u8]) -> Ipv6OptionsIterator<'a> {
        let length = data.len();
        Ipv6OptionsIterator {
            pos: 0,
            hit_error: false,
            length,
            data,
        }
    }
}

impl<'a> Iterator for Ipv6OptionsIterator<'a> {
    type Item = Result<Repr<'a>>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.pos < self.length && !self.hit_error {
            // If we still have data to parse and we have not previously
            // hit an error, attempt to parse the next option.
            match Ipv6Option::new_checked(&self.data[self.pos..]) {
                Ok(hdr) => match Repr::parse(&hdr) {
                    Ok(repr) => {
                        self.pos += repr.buffer_len();
                        Some(Ok(repr))
                    }
                    Err(e) => {
                        self.hit_error = true;
                        Some(Err(e))
                    }
                },
                Err(e) => {
                    self.hit_error = true;
                    Some(Err(e))
                }
            }
        } else {
            // If we failed to parse a previous option or hit the end of the
            // buffer, we do not continue to iterate.
            None
        }
    }
}

impl<'a> fmt::Display for Repr<'a> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "IPv6 Option ")?;
        match *self {
            Repr::Pad1 => write!(f, "{} ", Type::Pad1),
            Repr::PadN(len) => write!(f, "{} length={} ", Type::PadN, len),
            Repr::RouterAlert(alert) => write!(f, "{} value={:?}", Type::RouterAlert, alert),
            #[cfg(feature = "proto-rpl")]
            Repr::Rpl(rpl) => write!(f, "{} {rpl}", Type::Rpl),
            Repr::Unknown { type_, length, .. } => write!(f, "{type_} length={length} "),
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    static IPV6OPTION_BYTES_PAD1: [u8; 1] = [0x0];
    static IPV6OPTION_BYTES_PADN: [u8; 3] = [0x1, 0x1, 0x0];
    static IPV6OPTION_BYTES_UNKNOWN: [u8; 5] = [0xff, 0x3, 0x0, 0x0, 0x0];
    static IPV6OPTION_BYTES_ROUTER_ALERT_MLD: [u8; 4] = [0x05, 0x02, 0x00, 0x00];
    static IPV6OPTION_BYTES_ROUTER_ALERT_RSVP: [u8; 4] = [0x05, 0x02, 0x00, 0x01];
    static IPV6OPTION_BYTES_ROUTER_ALERT_ACTIVE_NETWORKS: [u8; 4] = [0x05, 0x02, 0x00, 0x02];
    static IPV6OPTION_BYTES_ROUTER_ALERT_UNKNOWN: [u8; 4] = [0x05, 0x02, 0xbe, 0xef];
    #[cfg(feature = "proto-rpl")]
    static IPV6OPTION_BYTES_RPL: [u8; 6] = [0x63, 0x04, 0x00, 0x1e, 0x08, 0x00];

    #[test]
    fn test_check_len() {
        let bytes = [0u8];
        // zero byte buffer
        assert_eq!(
            Err(Error),
            Ipv6Option::new_unchecked(&bytes[..0]).check_len()
        );
        // pad1
        assert_eq!(
            Ok(()),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PAD1).check_len()
        );

        // padn with truncated data
        assert_eq!(
            Err(Error),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PADN[..2]).check_len()
        );
        // padn
        assert_eq!(
            Ok(()),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PADN).check_len()
        );

        // router alert with truncated data
        assert_eq!(
            Err(Error),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_MLD[..3]).check_len()
        );
        // router alert
        assert_eq!(
            Ok(()),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_MLD).check_len()
        );

        // unknown option type with truncated data
        assert_eq!(
            Err(Error),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_UNKNOWN[..4]).check_len()
        );
        assert_eq!(
            Err(Error),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_UNKNOWN[..1]).check_len()
        );
        // unknown type
        assert_eq!(
            Ok(()),
            Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_UNKNOWN).check_len()
        );

        #[cfg(feature = "proto-rpl")]
        {
            assert_eq!(
                Ok(()),
                Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_RPL).check_len()
            );
        }
    }

    #[test]
    #[should_panic(expected = "index out of bounds")]
    fn test_data_len() {
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PAD1);
        opt.data_len();
    }

    #[test]
    fn test_option_deconstruct() {
        // one octet of padding
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PAD1);
        assert_eq!(opt.option_type(), Type::Pad1);

        // two octets of padding
        let bytes: [u8; 2] = [0x1, 0x0];
        let opt = Ipv6Option::new_unchecked(&bytes);
        assert_eq!(opt.option_type(), Type::PadN);
        assert_eq!(opt.data_len(), 0);

        // three octets of padding
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PADN);
        assert_eq!(opt.option_type(), Type::PadN);
        assert_eq!(opt.data_len(), 1);
        assert_eq!(opt.data(), &[0]);

        // extra bytes in buffer
        let bytes: [u8; 10] = [0x1, 0x7, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0xff];
        let opt = Ipv6Option::new_unchecked(&bytes);
        assert_eq!(opt.option_type(), Type::PadN);
        assert_eq!(opt.data_len(), 7);
        assert_eq!(opt.data(), &[0, 0, 0, 0, 0, 0, 0]);

        // router alert
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_MLD);
        assert_eq!(opt.option_type(), Type::RouterAlert);
        assert_eq!(opt.data_len(), 2);
        assert_eq!(opt.data(), &[0, 0]);

        // unrecognized option
        let bytes: [u8; 1] = [0xff];
        let opt = Ipv6Option::new_unchecked(&bytes);
        assert_eq!(opt.option_type(), Type::Unknown(255));

        // unrecognized option without length and data
        assert_eq!(Ipv6Option::new_checked(&bytes), Err(Error));

        #[cfg(feature = "proto-rpl")]
        {
            let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_RPL);
            assert_eq!(opt.option_type(), Type::Rpl);
            assert_eq!(opt.data_len(), 4);
            assert_eq!(opt.data(), &[0x00, 0x1e, 0x08, 0x00]);
        }
    }

    #[test]
    fn test_option_parse() {
        // one octet of padding
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PAD1);
        let pad1 = Repr::parse(&opt).unwrap();
        assert_eq!(pad1, Repr::Pad1);
        assert_eq!(pad1.buffer_len(), 1);

        // two or more octets of padding
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_PADN);
        let padn = Repr::parse(&opt).unwrap();
        assert_eq!(padn, Repr::PadN(1));
        assert_eq!(padn.buffer_len(), 3);

        // router alert (MLD)
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_MLD);
        let alert = Repr::parse(&opt).unwrap();
        assert_eq!(
            alert,
            Repr::RouterAlert(RouterAlert::MulticastListenerDiscovery)
        );
        assert_eq!(alert.buffer_len(), 4);

        // router alert (RSVP)
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_RSVP);
        let alert = Repr::parse(&opt).unwrap();
        assert_eq!(alert, Repr::RouterAlert(RouterAlert::Rsvp));
        assert_eq!(alert.buffer_len(), 4);

        // router alert (active networks)
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_ACTIVE_NETWORKS);
        let alert = Repr::parse(&opt).unwrap();
        assert_eq!(alert, Repr::RouterAlert(RouterAlert::ActiveNetworks));
        assert_eq!(alert.buffer_len(), 4);

        // router alert (unknown)
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_ROUTER_ALERT_UNKNOWN);
        let alert = Repr::parse(&opt).unwrap();
        assert_eq!(alert, Repr::RouterAlert(RouterAlert::Unknown(0xbeef)));
        assert_eq!(alert.buffer_len(), 4);

        // router alert (incorrect data length)
        let opt = Ipv6Option::new_unchecked(&[0x05, 0x03, 0x00, 0x00, 0x00]);
        let alert = Repr::parse(&opt);
        assert_eq!(alert, Err(Error));

        // unrecognized option type
        let data = [0u8; 3];
        let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_UNKNOWN);
        let unknown = Repr::parse(&opt).unwrap();
        assert_eq!(
            unknown,
            Repr::Unknown {
                type_: Type::Unknown(255),
                length: 3,
                data: &data
            }
        );

        #[cfg(feature = "proto-rpl")]
        {
            let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_RPL);
            let rpl = Repr::parse(&opt).unwrap();

            assert_eq!(
                rpl,
                Repr::Rpl(crate::wire::RplHopByHopRepr {
                    down: false,
                    rank_error: false,
                    forwarding_error: false,
                    instance_id: crate::wire::RplInstanceId::from(0x1e),
                    sender_rank: 0x0800,
                })
            );
        }
    }

    #[test]
    fn test_option_emit() {
        let repr = Repr::Pad1;
        let mut bytes = [255u8; 1]; // don't assume bytes are initialized to zero
        let mut opt = Ipv6Option::new_unchecked(&mut bytes);
        repr.emit(&mut opt);
        assert_eq!(opt.into_inner(), &IPV6OPTION_BYTES_PAD1);

        let repr = Repr::PadN(1);
        let mut bytes = [255u8; 3]; // don't assume bytes are initialized to zero
        let mut opt = Ipv6Option::new_unchecked(&mut bytes);
        repr.emit(&mut opt);
        assert_eq!(opt.into_inner(), &IPV6OPTION_BYTES_PADN);

        let repr = Repr::RouterAlert(RouterAlert::MulticastListenerDiscovery);
        let mut bytes = [255u8; 4]; // don't assume bytes are initialized to zero
        let mut opt = Ipv6Option::new_unchecked(&mut bytes);
        repr.emit(&mut opt);
        assert_eq!(opt.into_inner(), &IPV6OPTION_BYTES_ROUTER_ALERT_MLD);

        let data = [0u8; 3];
        let repr = Repr::Unknown {
            type_: Type::Unknown(255),
            length: 3,
            data: &data,
        };
        let mut bytes = [254u8; 5]; // don't assume bytes are initialized to zero
        let mut opt = Ipv6Option::new_unchecked(&mut bytes);
        repr.emit(&mut opt);
        assert_eq!(opt.into_inner(), &IPV6OPTION_BYTES_UNKNOWN);

        #[cfg(feature = "proto-rpl")]
        {
            let opt = Ipv6Option::new_unchecked(&IPV6OPTION_BYTES_RPL);
            let rpl = Repr::parse(&opt).unwrap();
            let mut bytes = [0u8; 6];
            rpl.emit(&mut Ipv6Option::new_unchecked(&mut bytes));

            assert_eq!(&bytes, &IPV6OPTION_BYTES_RPL);
        }
    }

    #[test]
    fn test_failure_type() {
        let mut failure_type: FailureType = Type::Pad1.into();
        assert_eq!(failure_type, FailureType::Skip);
        failure_type = Type::PadN.into();
        assert_eq!(failure_type, FailureType::Skip);
        failure_type = Type::RouterAlert.into();
        assert_eq!(failure_type, FailureType::Skip);
        failure_type = Type::Unknown(0b01000001).into();
        assert_eq!(failure_type, FailureType::Discard);
        failure_type = Type::Unknown(0b10100000).into();
        assert_eq!(failure_type, FailureType::DiscardSendAll);
        failure_type = Type::Unknown(0b11000100).into();
        assert_eq!(failure_type, FailureType::DiscardSendUnicast);
    }

    #[test]
    fn test_options_iter() {
        let options = [
            0x00, 0x01, 0x01, 0x00, 0x01, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x11, 0x00, 0x05,
            0x02, 0x00, 0x01, 0x01, 0x08, 0x00,
        ];

        let iterator = Ipv6OptionsIterator::new(&options);
        for (i, opt) in iterator.enumerate() {
            match (i, opt) {
                (0, Ok(Repr::Pad1)) => continue,
                (1, Ok(Repr::PadN(1))) => continue,
                (2, Ok(Repr::PadN(2))) => continue,
                (3, Ok(Repr::PadN(0))) => continue,
                (4, Ok(Repr::Pad1)) => continue,
                (
                    5,
                    Ok(Repr::Unknown {
                        type_: Type::Unknown(0x11),
                        length: 0,
                        ..
                    }),
                ) => continue,
                (6, Ok(Repr::RouterAlert(RouterAlert::Rsvp))) => continue,
                (7, Err(Error)) => continue,
                (i, res) => panic!("Unexpected option `{res:?}` at index {i}"),
            }
        }
    }
}
