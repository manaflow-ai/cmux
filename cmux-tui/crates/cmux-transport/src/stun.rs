//! RFC 5389 binding requests and success responses: just enough STUN to
//! learn this endpoint's reflexive address from the same UDP socket that
//! carries WireGuard.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use crate::classify::{STUN_HEADER_LEN, STUN_MAGIC_COOKIE};

const BINDING_REQUEST: u16 = 0x0001;
const BINDING_SUCCESS: u16 = 0x0101;
const ATTR_MAPPED_ADDRESS: u16 = 0x0001;
const ATTR_XOR_MAPPED_ADDRESS: u16 = 0x0020;
const FAMILY_V4: u8 = 0x01;
const FAMILY_V6: u8 = 0x02;

pub type TransactionId = [u8; 12];

/// A binding request with no attributes. The caller picks a random
/// transaction id and keeps it to match the answer.
pub fn binding_request(transaction: TransactionId) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(STUN_HEADER_LEN);
    bytes.extend_from_slice(&BINDING_REQUEST.to_be_bytes());
    bytes.extend_from_slice(&0u16.to_be_bytes());
    bytes.extend_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
    bytes.extend_from_slice(&transaction);
    bytes
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StunError {
    NotStun,
    NotBindingSuccess,
    WrongTransaction,
    Truncated,
    NoAddress,
}

/// Parses a binding success response for `transaction` and returns the
/// reflexive address. XOR-MAPPED-ADDRESS wins over MAPPED-ADDRESS.
pub fn parse_binding_success(
    datagram: &[u8],
    transaction: &TransactionId,
) -> Result<SocketAddr, StunError> {
    if crate::classify::classify(datagram) != crate::classify::DatagramClass::Stun {
        return Err(StunError::NotStun);
    }
    if u16::from_be_bytes([datagram[0], datagram[1]]) != BINDING_SUCCESS {
        return Err(StunError::NotBindingSuccess);
    }
    if datagram[8..20] != transaction[..] {
        return Err(StunError::WrongTransaction);
    }
    let mut mapped = None;
    let mut offset = STUN_HEADER_LEN;
    while offset + 4 <= datagram.len() {
        let kind = u16::from_be_bytes([datagram[offset], datagram[offset + 1]]);
        let len = usize::from(u16::from_be_bytes([datagram[offset + 2], datagram[offset + 3]]));
        let value_start = offset + 4;
        let value_end = value_start + len;
        if value_end > datagram.len() {
            return Err(StunError::Truncated);
        }
        let value = &datagram[value_start..value_end];
        match kind {
            ATTR_XOR_MAPPED_ADDRESS => return decode_address(value, Some(transaction)),
            ATTR_MAPPED_ADDRESS => mapped = Some(decode_address(value, None)?),
            _ => {}
        }
        // Attributes are padded to a multiple of four bytes.
        offset = value_start + len.div_ceil(4) * 4;
    }
    mapped.ok_or(StunError::NoAddress)
}

fn decode_address(value: &[u8], xor: Option<&TransactionId>) -> Result<SocketAddr, StunError> {
    if value.len() < 4 {
        return Err(StunError::Truncated);
    }
    let cookie = STUN_MAGIC_COOKIE.to_be_bytes();
    let mut port = u16::from_be_bytes([value[2], value[3]]);
    if xor.is_some() {
        port ^= u16::from_be_bytes([cookie[0], cookie[1]]);
    }
    let ip = match value[1] {
        FAMILY_V4 if value.len() >= 8 => {
            let mut octets = [value[4], value[5], value[6], value[7]];
            if xor.is_some() {
                for (octet, mask) in octets.iter_mut().zip(cookie) {
                    *octet ^= mask;
                }
            }
            IpAddr::V4(Ipv4Addr::from(octets))
        }
        FAMILY_V6 if value.len() >= 20 => {
            let mut octets = [0u8; 16];
            octets.copy_from_slice(&value[4..20]);
            if let Some(transaction) = xor {
                let mask: Vec<u8> = cookie.iter().chain(transaction.iter()).copied().collect();
                for (octet, mask) in octets.iter_mut().zip(mask) {
                    *octet ^= mask;
                }
            }
            IpAddr::V6(Ipv6Addr::from(octets))
        }
        _ => return Err(StunError::Truncated),
    };
    Ok(SocketAddr::new(ip, port))
}

/// Builds a binding success response. Test support and the reference for
/// other implementations; an endpoint never answers STUN itself.
pub fn binding_success(transaction: TransactionId, reflexive: SocketAddr) -> Vec<u8> {
    let cookie = STUN_MAGIC_COOKIE.to_be_bytes();
    let port = reflexive.port() ^ u16::from_be_bytes([cookie[0], cookie[1]]);
    let (family, address): (u8, Vec<u8>) = match reflexive.ip() {
        IpAddr::V4(ip) => (FAMILY_V4, ip.octets().iter().zip(cookie).map(|(a, m)| a ^ m).collect()),
        IpAddr::V6(ip) => {
            let mask: Vec<u8> = cookie.iter().chain(transaction.iter()).copied().collect();
            (FAMILY_V6, ip.octets().iter().zip(mask).map(|(a, m)| a ^ m).collect())
        }
    };
    let mut value = vec![0, family];
    value.extend_from_slice(&port.to_be_bytes());
    value.extend_from_slice(&address);
    let mut bytes = Vec::with_capacity(STUN_HEADER_LEN + 4 + value.len());
    bytes.extend_from_slice(&BINDING_SUCCESS.to_be_bytes());
    bytes.extend_from_slice(&u16::try_from(4 + value.len()).unwrap_or(u16::MAX).to_be_bytes());
    bytes.extend_from_slice(&cookie);
    bytes.extend_from_slice(&transaction);
    bytes.extend_from_slice(&ATTR_XOR_MAPPED_ADDRESS.to_be_bytes());
    bytes.extend_from_slice(&u16::try_from(value.len()).unwrap_or(u16::MAX).to_be_bytes());
    bytes.extend_from_slice(&value);
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    const TX: TransactionId = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

    #[test]
    fn request_is_a_bare_binding_header() {
        let request = binding_request(TX);
        assert_eq!(request.len(), 20);
        assert_eq!(&request[0..2], &[0x00, 0x01]);
        assert_eq!(&request[4..8], &[0x21, 0x12, 0xA4, 0x42]);
        assert_eq!(&request[8..20], &TX);
    }

    #[test]
    fn rfc5769_ipv4_response_vector() {
        // RFC 5769 section 2.2, attributes other than XOR-MAPPED-ADDRESS
        // replaced by nothing: 192.0.2.1:32853.
        let tx = [0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae];
        let mut bytes = vec![0x01, 0x01, 0x00, 0x0c, 0x21, 0x12, 0xa4, 0x42];
        bytes.extend_from_slice(&tx);
        bytes.extend_from_slice(&[
            0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43,
        ]);
        let addr = parse_binding_success(&bytes, &tx).expect("vector parses");
        assert_eq!(addr, "192.0.2.1:32853".parse().expect("address"));
    }

    #[test]
    fn round_trip_v4_and_v6() {
        for addr in ["203.0.113.9:41641", "[2001:db8::1]:41641"] {
            let addr: SocketAddr = addr.parse().expect("address");
            let response = binding_success(TX, addr);
            assert_eq!(parse_binding_success(&response, &TX), Ok(addr));
        }
    }

    #[test]
    fn foreign_transactions_are_refused() {
        let response = binding_success(TX, "203.0.113.9:1".parse().expect("address"));
        assert_eq!(parse_binding_success(&response, &[0; 12]), Err(StunError::WrongTransaction));
        assert_eq!(
            parse_binding_success(&binding_request(TX), &TX),
            Err(StunError::NotBindingSuccess)
        );
    }
}
