//! The PoP's own hop/1 messages (BIND, BIND_OK, ERROR) and the plain
//! WireGuard class map. DATA, NACK, PARITY, PING and PONG belong to the leg
//! (`cmux_transport::hop`).

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use cmux_transport::classify::WG_DATA_MIN_LEN;
use cmux_transport::{DatagramClass, classify};

pub const MAGIC: u8 = 0xC1;
pub const T_BIND: u8 = 4;
pub const T_BIND_OK: u8 = 5;
pub const T_ERROR: u8 = 8;

/// ERROR codes.
pub const E_BAD_TICKET: u16 = 1;
pub const E_NO_ALLOCATION: u16 = 2;
pub const E_CAPACITY: u16 = 3;

/// Record classes (docs/cmux-next/relay-pop-hop.md).
pub const CLASS_CONTROL: u8 = 0;
pub const CLASS_STATE: u8 = 1;
pub const CLASS_INPUT: u8 = 2;
pub const CLASS_BULK: u8 = 3;

/// Encrypted data datagrams up to this size are input (mobile-link's
/// class_queue `INPUT_MAX`): a keystroke, a pure ACK, a small request.
pub const INPUT_MAX: usize = 400;

pub fn is_hop(datagram: &[u8]) -> bool {
    datagram.first() == Some(&MAGIC)
}

pub fn hop_type(datagram: &[u8]) -> Option<u8> {
    match datagram {
        [MAGIC, kind, ..] => Some(*kind),
        _ => None,
    }
}

/// The class a plain (untagged) WireGuard datagram gets on a hop/1 leg, by
/// its shape, as mobile-link's TURN class queue infers it.
pub fn plain_class(datagram: &[u8]) -> u8 {
    match classify(datagram) {
        DatagramClass::WireGuardData if datagram.len() > INPUT_MAX => CLASS_BULK,
        DatagramClass::WireGuardData if datagram.len() > WG_DATA_MIN_LEN => CLASS_INPUT,
        DatagramClass::Unknown if datagram.len() > INPUT_MAX => CLASS_BULK,
        DatagramClass::Unknown => CLASS_INPUT,
        _ => CLASS_CONTROL,
    }
}

pub fn encode_bind(ticket: &[u8]) -> Vec<u8> {
    let len = u16::try_from(ticket.len()).unwrap_or(u16::MAX);
    let mut out = vec![MAGIC, T_BIND];
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(ticket.get(..usize::from(len)).unwrap_or(ticket));
    out
}

pub fn decode_bind(datagram: &[u8]) -> Option<&[u8]> {
    let [MAGIC, T_BIND, l0, l1, rest @ ..] = datagram else {
        return None;
    };
    rest.get(..usize::from(u16::from_be_bytes([*l0, *l1])))
}

pub fn encode_bind_ok(relayed: SocketAddr, lifetime_s: u32) -> Vec<u8> {
    let mut out = vec![MAGIC, T_BIND_OK];
    match relayed.ip() {
        IpAddr::V4(ip) => {
            out.push(4);
            out.extend_from_slice(&ip.octets());
        }
        IpAddr::V6(ip) => {
            out.push(6);
            out.extend_from_slice(&ip.octets());
        }
    }
    out.extend_from_slice(&relayed.port().to_be_bytes());
    out.extend_from_slice(&lifetime_s.to_be_bytes());
    out
}

pub fn decode_bind_ok(datagram: &[u8]) -> Option<(SocketAddr, u32)> {
    let [MAGIC, T_BIND_OK, family, rest @ ..] = datagram else {
        return None;
    };
    let (ip, rest): (IpAddr, &[u8]) = match family {
        4 => {
            let (o, rest) = rest.split_first_chunk::<4>()?;
            (Ipv4Addr::from(*o).into(), rest)
        }
        6 => {
            let (o, rest) = rest.split_first_chunk::<16>()?;
            (Ipv6Addr::from(*o).into(), rest)
        }
        _ => return None,
    };
    let (port, rest) = rest.split_first_chunk::<2>()?;
    let (life, _) = rest.split_first_chunk::<4>()?;
    Some((SocketAddr::new(ip, u16::from_be_bytes(*port)), u32::from_be_bytes(*life)))
}

pub fn encode_error(code: u16) -> Vec<u8> {
    let [a, b] = code.to_be_bytes();
    vec![MAGIC, T_ERROR, a, b]
}

pub fn decode_error(datagram: &[u8]) -> Option<u16> {
    match datagram {
        [MAGIC, T_ERROR, a, b, ..] => Some(u16::from_be_bytes([*a, *b])),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bind_and_bind_ok_round_trip() {
        assert_eq!(decode_bind(&encode_bind(b"tk")), Some(&b"tk"[..]));
        for a in ["198.18.0.4:40000", "[2001:db8::1]:9"] {
            let a: SocketAddr = a.parse().unwrap();
            assert_eq!(decode_bind_ok(&encode_bind_ok(a, 600)), Some((a, 600)));
        }
        assert_eq!(decode_error(&encode_error(E_BAD_TICKET)), Some(E_BAD_TICKET));
        assert_eq!(decode_bind(&[MAGIC, T_BIND, 0, 9, 1]), None);
    }

    #[test]
    fn plain_wireguard_is_classed_by_shape() {
        let mut init = vec![1, 0, 0, 0];
        init.resize(148, 0);
        assert_eq!(plain_class(&init), CLASS_CONTROL);
        let mut keepalive = vec![4, 0, 0, 0];
        keepalive.resize(32, 0);
        assert_eq!(plain_class(&keepalive), CLASS_CONTROL);
        let mut key = vec![4, 0, 0, 0];
        key.resize(96, 0);
        assert_eq!(plain_class(&key), CLASS_INPUT);
        key.resize(1200, 0);
        assert_eq!(plain_class(&key), CLASS_BULK);
    }
}
