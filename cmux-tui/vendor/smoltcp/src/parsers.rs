#![cfg_attr(
    not(all(feature = "proto-ipv6", feature = "proto-ipv4")),
    allow(dead_code)
)]

use core::result;
use core::str::FromStr;

#[cfg(feature = "medium-ethernet")]
use crate::wire::EthernetAddress;
use crate::wire::{IpAddress, IpCidr, IpEndpoint};
#[cfg(feature = "proto-ipv4")]
use crate::wire::{Ipv4Address, Ipv4Cidr};
#[cfg(feature = "proto-ipv6")]
use crate::wire::{Ipv6Address, Ipv6Cidr};

type Result<T> = result::Result<T, ()>;

struct Parser<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(data: &'a str) -> Parser<'a> {
        Parser {
            data: data.as_bytes(),
            pos: 0,
        }
    }

    fn lookahead_char(&self, ch: u8) -> bool {
        if self.pos < self.data.len() {
            self.data[self.pos] == ch
        } else {
            false
        }
    }

    fn advance(&mut self) -> Result<u8> {
        match self.data.get(self.pos) {
            Some(&chr) => {
                self.pos += 1;
                Ok(chr)
            }
            None => Err(()),
        }
    }

    fn try_do<F, T>(&mut self, f: F) -> Option<T>
    where
        F: FnOnce(&mut Parser<'a>) -> Result<T>,
    {
        let pos = self.pos;
        match f(self) {
            Ok(res) => Some(res),
            Err(()) => {
                self.pos = pos;
                None
            }
        }
    }

    fn accept_eof(&mut self) -> Result<()> {
        if self.data.len() == self.pos {
            Ok(())
        } else {
            Err(())
        }
    }

    fn until_eof<F, T>(&mut self, f: F) -> Result<T>
    where
        F: FnOnce(&mut Parser<'a>) -> Result<T>,
    {
        let res = f(self)?;
        self.accept_eof()?;
        Ok(res)
    }

    fn accept_char(&mut self, chr: u8) -> Result<()> {
        if self.advance()? == chr {
            Ok(())
        } else {
            Err(())
        }
    }

    fn accept_str(&mut self, string: &[u8]) -> Result<()> {
        for byte in string.iter() {
            self.accept_char(*byte)?;
        }
        Ok(())
    }

    fn accept_digit(&mut self, hex: bool) -> Result<u8> {
        let digit = self.advance()?;
        if digit.is_ascii_digit() {
            Ok(digit - b'0')
        } else if hex && (b'a'..=b'f').contains(&digit) {
            Ok(digit - b'a' + 10)
        } else if hex && (b'A'..=b'F').contains(&digit) {
            Ok(digit - b'A' + 10)
        } else {
            Err(())
        }
    }

    fn accept_number(&mut self, max_digits: usize, max_value: u32, hex: bool) -> Result<u32> {
        let mut value = self.accept_digit(hex)? as u32;
        for _ in 1..max_digits {
            match self.try_do(|p| p.accept_digit(hex)) {
                Some(digit) => {
                    value *= if hex { 16 } else { 10 };
                    value += digit as u32;
                }
                None => break,
            }
        }
        if value < max_value {
            Ok(value)
        } else {
            Err(())
        }
    }

    #[cfg(feature = "medium-ethernet")]
    fn accept_mac_joined_with(&mut self, separator: u8) -> Result<EthernetAddress> {
        let mut octets = [0u8; 6];
        for (n, octet) in octets.iter_mut().enumerate() {
            *octet = self.accept_number(2, 0x100, true)? as u8;
            if n != 5 {
                self.accept_char(separator)?;
            }
        }
        Ok(EthernetAddress(octets))
    }

    #[cfg(feature = "medium-ethernet")]
    fn accept_mac(&mut self) -> Result<EthernetAddress> {
        if let Some(mac) = self.try_do(|p| p.accept_mac_joined_with(b'-')) {
            return Ok(mac);
        }
        if let Some(mac) = self.try_do(|p| p.accept_mac_joined_with(b':')) {
            return Ok(mac);
        }
        Err(())
    }

    #[cfg(feature = "proto-ipv6")]
    fn accept_ipv4_mapped_ipv6_part(&mut self, parts: &mut [u16], idx: &mut usize) -> Result<()> {
        let octets = self.accept_ipv4_octets()?;

        parts[*idx] = ((octets[0] as u16) << 8) | (octets[1] as u16);
        *idx += 1;
        parts[*idx] = ((octets[2] as u16) << 8) | (octets[3] as u16);
        *idx += 1;

        Ok(())
    }

    #[cfg(feature = "proto-ipv6")]
    fn accept_ipv6_part(
        &mut self,
        (head, tail): (&mut [u16; 8], &mut [u16; 6]),
        (head_idx, tail_idx): (&mut usize, &mut usize),
        mut use_tail: bool,
    ) -> Result<()> {
        let double_colon = match self.try_do(|p| p.accept_str(b"::")) {
            Some(_) if !use_tail && *head_idx < 7 => {
                // Found a double colon. Start filling out the
                // tail and set the double colon flag in case
                // this is the last character we can parse.
                use_tail = true;
                true
            }
            Some(_) => {
                // This is a bad address. Only one double colon is
                // allowed and an address is only 128 bits.
                return Err(());
            }
            None => {
                if *head_idx != 0 || use_tail && *tail_idx != 0 {
                    // If this is not the first number or the position following
                    // a double colon, we expect there to be a single colon.
                    self.accept_char(b':')?;
                }
                false
            }
        };

        match self.try_do(|p| p.accept_number(4, 0x10000, true)) {
            Some(part) if !use_tail && *head_idx < 8 => {
                // Valid u16 to be added to the address
                head[*head_idx] = part as u16;
                *head_idx += 1;

                if *head_idx == 6 && head[0..*head_idx] == [0, 0, 0, 0, 0, 0xffff] {
                    self.try_do(|p| {
                        p.accept_char(b':')?;
                        p.accept_ipv4_mapped_ipv6_part(head, head_idx)
                    });
                }
                Ok(())
            }
            Some(part) if *tail_idx < 6 => {
                // Valid u16 to be added to the address
                tail[*tail_idx] = part as u16;
                *tail_idx += 1;

                if *tail_idx == 1 && tail[0] == 0xffff && head[0..8] == [0, 0, 0, 0, 0, 0, 0, 0] {
                    self.try_do(|p| {
                        p.accept_char(b':')?;
                        p.accept_ipv4_mapped_ipv6_part(tail, tail_idx)
                    });
                }
                Ok(())
            }
            Some(_) => {
                // Tail or head section is too long
                Err(())
            }
            None if double_colon => {
                // The address ends with "::". E.g. 1234:: or ::
                Ok(())
            }
            None => {
                // Invalid address
                Err(())
            }
        }?;

        if *head_idx + *tail_idx > 8 {
            // The head and tail indexes add up to a bad address length.
            Err(())
        } else if !self.lookahead_char(b':') {
            if *head_idx < 8 && !use_tail {
                // There was no double colon found, and the head is too short
                return Err(());
            }
            Ok(())
        } else {
            // Continue recursing
            self.accept_ipv6_part((head, tail), (head_idx, tail_idx), use_tail)
        }
    }

    #[cfg(feature = "proto-ipv6")]
    fn accept_ipv6(&mut self) -> Result<Ipv6Address> {
        // IPv6 addresses may contain a "::" to indicate a series of
        // 16 bit sections that evaluate to 0. E.g.
        //
        // fe80:0000:0000:0000:0000:0000:0000:0001
        //
        // May be written as
        //
        // fe80::1
        //
        // As a result, we need to find the first section of colon
        // delimited u16's before a possible "::", then the
        // possible second section after the "::", and finally
        // combine the second optional section to the end of the
        // final address.
        //
        // See https://tools.ietf.org/html/rfc4291#section-2.2
        // for details.
        let (mut addr, mut tail) = ([0u16; 8], [0u16; 6]);
        let (mut head_idx, mut tail_idx) = (0, 0);

        self.accept_ipv6_part(
            (&mut addr, &mut tail),
            (&mut head_idx, &mut tail_idx),
            false,
        )?;

        // We need to copy the tail portion (the portion following the "::") to the
        // end of the address.
        addr[8 - tail_idx..].copy_from_slice(&tail[..tail_idx]);

        Ok(Ipv6Address::from(addr))
    }

    fn accept_ipv4_octets(&mut self) -> Result<[u8; 4]> {
        let mut octets = [0u8; 4];
        for (n, octet) in octets.iter_mut().enumerate() {
            *octet = self.accept_number(3, 0x100, false)? as u8;
            if n != 3 {
                self.accept_char(b'.')?;
            }
        }
        Ok(octets)
    }

    #[cfg(feature = "proto-ipv4")]
    fn accept_ipv4(&mut self) -> Result<Ipv4Address> {
        let octets = self.accept_ipv4_octets()?;
        Ok(Ipv4Address::from_octets(octets))
    }

    fn accept_ip(&mut self) -> Result<IpAddress> {
        #[cfg(feature = "proto-ipv4")]
        #[allow(clippy::single_match)]
        match self.try_do(|p| p.accept_ipv4()) {
            Some(ipv4) => return Ok(IpAddress::Ipv4(ipv4)),
            None => (),
        }

        #[cfg(feature = "proto-ipv6")]
        #[allow(clippy::single_match)]
        match self.try_do(|p| p.accept_ipv6()) {
            Some(ipv6) => return Ok(IpAddress::Ipv6(ipv6)),
            None => (),
        }

        Err(())
    }

    #[cfg(feature = "proto-ipv4")]
    fn accept_ipv4_endpoint(&mut self) -> Result<IpEndpoint> {
        let ip = self.accept_ipv4()?;

        let port = if self.accept_eof().is_ok() {
            0
        } else {
            self.accept_char(b':')?;
            self.accept_number(5, 65535, false)?
        };

        Ok(IpEndpoint {
            addr: IpAddress::Ipv4(ip),
            port: port as u16,
        })
    }

    #[cfg(feature = "proto-ipv6")]
    fn accept_ipv6_endpoint(&mut self) -> Result<IpEndpoint> {
        if self.lookahead_char(b'[') {
            self.accept_char(b'[')?;
            let ip = self.accept_ipv6()?;
            self.accept_char(b']')?;
            self.accept_char(b':')?;
            let port = self.accept_number(5, 65535, false)?;

            Ok(IpEndpoint {
                addr: IpAddress::Ipv6(ip),
                port: port as u16,
            })
        } else {
            let ip = self.accept_ipv6()?;
            Ok(IpEndpoint {
                addr: IpAddress::Ipv6(ip),
                port: 0,
            })
        }
    }

    fn accept_ip_endpoint(&mut self) -> Result<IpEndpoint> {
        #[cfg(feature = "proto-ipv4")]
        #[allow(clippy::single_match)]
        match self.try_do(|p| p.accept_ipv4_endpoint()) {
            Some(ipv4) => return Ok(ipv4),
            None => (),
        }

        #[cfg(feature = "proto-ipv6")]
        #[allow(clippy::single_match)]
        match self.try_do(|p| p.accept_ipv6_endpoint()) {
            Some(ipv6) => return Ok(ipv6),
            None => (),
        }

        Err(())
    }
}

#[cfg(feature = "medium-ethernet")]
impl FromStr for EthernetAddress {
    type Err = ();

    /// Parse a string representation of an Ethernet address.
    fn from_str(s: &str) -> Result<EthernetAddress> {
        Parser::new(s).until_eof(|p| p.accept_mac())
    }
}

impl FromStr for IpAddress {
    type Err = ();

    /// Parse a string representation of an IP address.
    fn from_str(s: &str) -> Result<IpAddress> {
        Parser::new(s).until_eof(|p| p.accept_ip())
    }
}

#[cfg(feature = "proto-ipv4")]
impl FromStr for Ipv4Cidr {
    type Err = ();

    /// Parse a string representation of an IPv4 CIDR.
    fn from_str(s: &str) -> Result<Ipv4Cidr> {
        Parser::new(s).until_eof(|p| {
            let ip = p.accept_ipv4()?;
            p.accept_char(b'/')?;
            let prefix_len = p.accept_number(2, 33, false)? as u8;
            Ok(Ipv4Cidr::new(ip, prefix_len))
        })
    }
}

#[cfg(feature = "proto-ipv6")]
impl FromStr for Ipv6Cidr {
    type Err = ();

    /// Parse a string representation of an IPv6 CIDR.
    fn from_str(s: &str) -> Result<Ipv6Cidr> {
        // https://tools.ietf.org/html/rfc4291#section-2.3
        Parser::new(s).until_eof(|p| {
            let ip = p.accept_ipv6()?;
            p.accept_char(b'/')?;
            let prefix_len = p.accept_number(3, 129, false)? as u8;
            Ok(Ipv6Cidr::new(ip, prefix_len))
        })
    }
}

impl FromStr for IpCidr {
    type Err = ();

    /// Parse a string representation of an IP CIDR.
    fn from_str(s: &str) -> Result<IpCidr> {
        #[cfg(feature = "proto-ipv4")]
        #[allow(clippy::single_match)]
        match Ipv4Cidr::from_str(s) {
            Ok(cidr) => return Ok(IpCidr::Ipv4(cidr)),
            Err(_) => (),
        }

        #[cfg(feature = "proto-ipv6")]
        #[allow(clippy::single_match)]
        match Ipv6Cidr::from_str(s) {
            Ok(cidr) => return Ok(IpCidr::Ipv6(cidr)),
            Err(_) => (),
        }

        Err(())
    }
}

impl FromStr for IpEndpoint {
    type Err = ();

    fn from_str(s: &str) -> Result<IpEndpoint> {
        Parser::new(s).until_eof(|p| p.accept_ip_endpoint())
    }
}

#[cfg(test)]
mod test {
    use super::*;

    macro_rules! check_cidr_test_array {
        ($tests:expr, $from_str:path, $variant:path) => {
            for &(s, cidr) in &$tests {
                assert_eq!($from_str(s), cidr);
                assert_eq!(IpCidr::from_str(s), cidr.map($variant));

                if let Ok(cidr) = cidr {
                    assert_eq!($from_str(&format!("{}", cidr)), Ok(cidr));
                    assert_eq!(IpCidr::from_str(&format!("{}", cidr)), Ok($variant(cidr)));
                }
            }
        };
    }

    #[test]
    #[cfg(all(feature = "proto-ipv4", feature = "medium-ethernet"))]
    fn test_mac() {
        assert_eq!(EthernetAddress::from_str(""), Err(()));
        assert_eq!(
            EthernetAddress::from_str("02:00:00:00:00:00"),
            Ok(EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x00]))
        );
        assert_eq!(
            EthernetAddress::from_str("01:23:45:67:89:ab"),
            Ok(EthernetAddress([0x01, 0x23, 0x45, 0x67, 0x89, 0xab]))
        );
        assert_eq!(
            EthernetAddress::from_str("cd:ef:10:00:00:00"),
            Ok(EthernetAddress([0xcd, 0xef, 0x10, 0x00, 0x00, 0x00]))
        );
        assert_eq!(
            EthernetAddress::from_str("00:00:00:ab:cd:ef"),
            Ok(EthernetAddress([0x00, 0x00, 0x00, 0xab, 0xcd, 0xef]))
        );
        assert_eq!(
            EthernetAddress::from_str("00-00-00-ab-cd-ef"),
            Ok(EthernetAddress([0x00, 0x00, 0x00, 0xab, 0xcd, 0xef]))
        );
        assert_eq!(
            EthernetAddress::from_str("AB-CD-EF-00-00-00"),
            Ok(EthernetAddress([0xab, 0xcd, 0xef, 0x00, 0x00, 0x00]))
        );
        assert_eq!(EthernetAddress::from_str("100:00:00:00:00:00"), Err(()));
        assert_eq!(EthernetAddress::from_str("002:00:00:00:00:00"), Err(()));
        assert_eq!(EthernetAddress::from_str("02:00:00:00:00:000"), Err(()));
        assert_eq!(EthernetAddress::from_str("02:00:00:00:00:0x"), Err(()));
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_ip_ipv4() {
        assert_eq!(IpAddress::from_str(""), Err(()));
        assert_eq!(
            IpAddress::from_str("1.2.3.4"),
            Ok(IpAddress::Ipv4(Ipv4Address::new(1, 2, 3, 4)))
        );
        assert_eq!(IpAddress::from_str("x"), Err(()));
    }

    #[test]
    #[cfg(feature = "proto-ipv6")]
    fn test_ip_ipv6() {
        assert_eq!(IpAddress::from_str(""), Err(()));
        assert_eq!(
            IpAddress::from_str("fe80::1"),
            Ok(IpAddress::Ipv6(Ipv6Address::new(
                0xfe80, 0, 0, 0, 0, 0, 0, 1
            )))
        );
        assert_eq!(IpAddress::from_str("x"), Err(()));
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_cidr_ipv4() {
        let tests = [
            (
                "127.0.0.1/8",
                Ok(Ipv4Cidr::new(Ipv4Address::new(127, 0, 0, 1), 8u8)),
            ),
            (
                "192.168.1.1/24",
                Ok(Ipv4Cidr::new(Ipv4Address::new(192, 168, 1, 1), 24u8)),
            ),
            (
                "8.8.8.8/32",
                Ok(Ipv4Cidr::new(Ipv4Address::new(8, 8, 8, 8), 32u8)),
            ),
            (
                "8.8.8.8/0",
                Ok(Ipv4Cidr::new(Ipv4Address::new(8, 8, 8, 8), 0u8)),
            ),
            ("", Err(())),
            ("1", Err(())),
            ("127.0.0.1", Err(())),
            ("127.0.0.1/", Err(())),
            ("127.0.0.1/33", Err(())),
            ("127.0.0.1/111", Err(())),
            ("/32", Err(())),
        ];

        check_cidr_test_array!(tests, Ipv4Cidr::from_str, IpCidr::Ipv4);
    }

    #[test]
    #[cfg(feature = "proto-ipv6")]
    fn test_cidr_ipv6() {
        let tests = [
            (
                "fe80::1/64",
                Ok(Ipv6Cidr::new(
                    Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
                    64u8,
                )),
            ),
            (
                "fe80::/64",
                Ok(Ipv6Cidr::new(
                    Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
                    64u8,
                )),
            ),
            ("::1/128", Ok(Ipv6Cidr::new(Ipv6Address::LOCALHOST, 128u8))),
            ("::/128", Ok(Ipv6Cidr::new(Ipv6Address::UNSPECIFIED, 128u8))),
            (
                "fe80:0:0:0:0:0:0:1/64",
                Ok(Ipv6Cidr::new(
                    Ipv6Address::new(0xfe80, 0, 0, 0, 0, 0, 0, 1),
                    64u8,
                )),
            ),
            ("fe80:0:0:0:0:0:0:1|64", Err(())),
            ("fe80::|64", Err(())),
            ("fe80::1::/64", Err(())),
        ];
        check_cidr_test_array!(tests, Ipv6Cidr::from_str, IpCidr::Ipv6);
    }

    #[test]
    #[cfg(feature = "proto-ipv4")]
    fn test_endpoint_ipv4() {
        assert_eq!(IpEndpoint::from_str(""), Err(()));
        assert_eq!(IpEndpoint::from_str("x"), Err(()));
        assert_eq!(
            IpEndpoint::from_str("127.0.0.1"),
            Ok(IpEndpoint {
                addr: IpAddress::v4(127, 0, 0, 1),
                port: 0
            })
        );
        assert_eq!(
            IpEndpoint::from_str("127.0.0.1:12345"),
            Ok(IpEndpoint {
                addr: IpAddress::v4(127, 0, 0, 1),
                port: 12345
            })
        );
    }

    #[test]
    #[cfg(feature = "proto-ipv6")]
    fn test_endpoint_ipv6() {
        assert_eq!(IpEndpoint::from_str(""), Err(()));
        assert_eq!(IpEndpoint::from_str("x"), Err(()));
        assert_eq!(
            IpEndpoint::from_str("fe80::1"),
            Ok(IpEndpoint {
                addr: IpAddress::v6(0xfe80, 0, 0, 0, 0, 0, 0, 1),
                port: 0
            })
        );
        assert_eq!(
            IpEndpoint::from_str("[fe80::1]:12345"),
            Ok(IpEndpoint {
                addr: IpAddress::v6(0xfe80, 0, 0, 0, 0, 0, 0, 1),
                port: 12345
            })
        );
        assert_eq!(
            IpEndpoint::from_str("[::]:12345"),
            Ok(IpEndpoint {
                addr: IpAddress::v6(0, 0, 0, 0, 0, 0, 0, 0),
                port: 12345
            })
        );
    }
}
