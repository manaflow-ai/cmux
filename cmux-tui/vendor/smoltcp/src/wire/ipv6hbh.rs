use super::{Error, Ipv6Option, Ipv6OptionRepr, Ipv6OptionsIterator, Result};
use crate::config;
use crate::wire::ipv6option::RouterAlert;
use heapless::Vec;

/// A read/write wrapper around an IPv6 Hop-by-Hop Header buffer.
pub struct Header<T: AsRef<[u8]>> {
    buffer: T,
}

impl<T: AsRef<[u8]>> Header<T> {
    /// Create a raw octet buffer with an IPv6 Hop-by-Hop Header structure.
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
        if self.buffer.as_ref().is_empty() {
            return Err(Error);
        }

        Ok(())
    }

    /// Consume the header, returning the underlying buffer.
    pub fn into_inner(self) -> T {
        self.buffer
    }
}

impl<'a, T: AsRef<[u8]> + ?Sized> Header<&'a T> {
    /// Return the options of the IPv6 Hop-by-Hop header.
    pub fn options(&self) -> &'a [u8] {
        self.buffer.as_ref()
    }
}

impl<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized> Header<&mut T> {
    /// Return a mutable pointer to the options of the IPv6 Hop-by-Hop header.
    pub fn options_mut(&mut self) -> &mut [u8] {
        self.buffer.as_mut()
    }
}

/// A high-level representation of an IPv6 Hop-by-Hop Header.
#[derive(Debug, PartialEq, Eq, Clone)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct Repr<'a> {
    pub options: Vec<Ipv6OptionRepr<'a>, { config::IPV6_HBH_MAX_OPTIONS }>,
}

impl<'a> Repr<'a> {
    /// Parse an IPv6 Hop-by-Hop Header and return a high-level representation.
    pub fn parse<T>(header: &'a Header<&'a T>) -> Result<Repr<'a>>
    where
        T: AsRef<[u8]> + ?Sized,
    {
        header.check_len()?;

        let mut options = Vec::new();

        let iter = Ipv6OptionsIterator::new(header.options());

        for option in iter {
            let option = option?;

            if let Err(e) = options.push(option) {
                net_trace!("error when parsing hop-by-hop options: {}", e);
                break;
            }
        }

        Ok(Self { options })
    }

    /// Return the length, in bytes, of a header that will be emitted from this high-level
    /// representation.
    pub fn buffer_len(&self) -> usize {
        self.options.iter().map(|o| o.buffer_len()).sum()
    }

    /// Emit a high-level representation into an IPv6 Hop-by-Hop Header.
    pub fn emit<T: AsRef<[u8]> + AsMut<[u8]> + ?Sized>(&self, header: &mut Header<&mut T>) {
        let mut buffer = header.options_mut();

        for opt in &self.options {
            opt.emit(&mut Ipv6Option::new_unchecked(
                &mut buffer[..opt.buffer_len()],
            ));
            buffer = &mut buffer[opt.buffer_len()..];
        }
    }

    /// The hop-by-hop header containing a MLDv2 router alert option
    pub fn mldv2_router_alert() -> Self {
        let mut options = Vec::new();
        options
            .push(Ipv6OptionRepr::RouterAlert(
                RouterAlert::MulticastListenerDiscovery,
            ))
            .unwrap();
        Self { options }
    }

    /// Append a PadN option to the vector of hop-by-hop options
    pub fn push_padn_option(&mut self, n: u8) {
        self.options.push(Ipv6OptionRepr::PadN(n)).unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::Error;

    // A Hop-by-Hop Option header with a PadN option of option data length 4.
    static REPR_PACKET_PAD4: [u8; 6] = [0x1, 0x4, 0x0, 0x0, 0x0, 0x0];

    // A Hop-by-Hop Option header with a PadN option of option data length 12.
    static REPR_PACKET_PAD12: [u8; 14] = [
        0x1, 0x0C, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
    ];

    #[test]
    fn test_check_len() {
        // zero byte buffer
        assert_eq!(
            Err(Error),
            Header::new_unchecked(&REPR_PACKET_PAD4[..0]).check_len()
        );
        // valid
        assert_eq!(Ok(()), Header::new_unchecked(&REPR_PACKET_PAD4).check_len());
        // valid
        assert_eq!(
            Ok(()),
            Header::new_unchecked(&REPR_PACKET_PAD12).check_len()
        );
    }

    #[test]
    fn test_repr_parse_valid() {
        let header = Header::new_unchecked(&REPR_PACKET_PAD4);
        let repr = Repr::parse(&header).unwrap();

        let mut options = Vec::new();
        options.push(Ipv6OptionRepr::PadN(4)).unwrap();
        assert_eq!(repr, Repr { options });

        let header = Header::new_unchecked(&REPR_PACKET_PAD12);
        let repr = Repr::parse(&header).unwrap();

        let mut options = Vec::new();
        options.push(Ipv6OptionRepr::PadN(12)).unwrap();
        assert_eq!(repr, Repr { options });
    }

    #[test]
    fn test_repr_emit() {
        let mut options = Vec::new();
        options.push(Ipv6OptionRepr::PadN(4)).unwrap();
        let repr = Repr { options };

        let mut bytes = [0u8; 6];
        let mut header = Header::new_unchecked(&mut bytes);
        repr.emit(&mut header);

        assert_eq!(header.into_inner(), &REPR_PACKET_PAD4[..]);

        let mut options = Vec::new();
        options.push(Ipv6OptionRepr::PadN(12)).unwrap();
        let repr = Repr { options };

        let mut bytes = [0u8; 14];
        let mut header = Header::new_unchecked(&mut bytes);
        repr.emit(&mut header);

        assert_eq!(header.into_inner(), &REPR_PACKET_PAD12[..]);
    }
}
