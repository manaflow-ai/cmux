//! Path candidates a peer advertises inside the WireGuard session.
//!
//! A mesh peer knows one address for the other side at first: the pairing's
//! endpoint, or the source of its first authenticated datagram. The other
//! side's other addresses (its LAN, its Thunderbolt Bridge, its tailnet
//! address) come from the other side itself: it lists the addresses its
//! socket answers on in one tiny overlay UDP packet to [`CANDIDATE_PORT`].
//! WireGuard encrypts and authenticates that packet like any other, so
//! only the paired peer can name candidates, and the receiver still sends a
//! candidate nothing but probes until a probe on it is answered.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

/// Overlay UDP port that carries candidate lists. Probes use 4102.
pub const CANDIDATE_PORT: u16 = 4104;
/// Most candidates one list carries; the rest are dropped by the sender.
pub const MAX_CANDIDATES: usize = 8;
const MAGIC: [u8; 4] = *b"cmxc";
const V4: u8 = 4;
const V6: u8 = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CandidateError {
    Length(usize),
    Magic,
    Count(usize),
    Family(u8),
}

/// Encode up to [`MAX_CANDIDATES`] addresses: magic, a count, then per
/// address its family (4 or 6), its address bytes and its port.
pub fn encode_candidates(addresses: &[SocketAddr]) -> Vec<u8> {
    let addresses = addresses.get(..MAX_CANDIDATES).unwrap_or(addresses);
    let mut bytes = Vec::with_capacity(5 + addresses.len() * 19);
    bytes.extend_from_slice(&MAGIC);
    bytes.push(addresses.len() as u8);
    for address in addresses {
        match address.ip() {
            IpAddr::V4(ip) => {
                bytes.push(V4);
                bytes.extend_from_slice(&ip.octets());
            }
            IpAddr::V6(ip) => {
                bytes.push(V6);
                bytes.extend_from_slice(&ip.octets());
            }
        }
        bytes.extend_from_slice(&address.port().to_be_bytes());
    }
    bytes
}

/// Decode a candidate list. A list longer than [`MAX_CANDIDATES`], with
/// trailing bytes, or with an unknown family is refused whole.
pub fn decode_candidates(bytes: &[u8]) -> Result<Vec<SocketAddr>, CandidateError> {
    let length = || CandidateError::Length(bytes.len());
    let (header, mut rest) = bytes.split_at_checked(5).ok_or_else(length)?;
    let (magic, count) = header.split_at_checked(4).ok_or_else(length)?;
    if magic != MAGIC {
        return Err(CandidateError::Magic);
    }
    let count = usize::from(count.first().copied().ok_or_else(length)?);
    if count > MAX_CANDIDATES {
        return Err(CandidateError::Count(count));
    }
    let mut addresses = Vec::with_capacity(count);
    for _ in 0..count {
        let (&family, tail) = rest.split_first().ok_or_else(length)?;
        let size = match family {
            V4 => 4,
            V6 => 16,
            other => return Err(CandidateError::Family(other)),
        };
        let (ip, tail) = tail.split_at_checked(size).ok_or_else(length)?;
        let (port, tail) = tail.split_first_chunk::<2>().ok_or_else(length)?;
        let ip = match <[u8; 16]>::try_from(ip) {
            Ok(v6) => IpAddr::V6(Ipv6Addr::from(v6)),
            Err(_) => {
                let v4: [u8; 4] = ip.try_into().map_err(|_| length())?;
                IpAddr::V4(Ipv4Addr::from(v4))
            }
        };
        addresses.push(SocketAddr::new(ip, u16::from_be_bytes(*port)));
        rest = tail;
    }
    if !rest.is_empty() {
        return Err(length());
    }
    Ok(addresses)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_list_round_trips_and_is_bounded() {
        let list: Vec<SocketAddr> = vec![
            "192.168.1.20:4101".parse().unwrap(),
            "[fd7a:115c:a1e0::1]:4101".parse().unwrap(),
            "169.254.3.4:4101".parse().unwrap(),
        ];
        assert_eq!(decode_candidates(&encode_candidates(&list)), Ok(list.clone()));
        let many: Vec<SocketAddr> =
            (0..20).map(|n| SocketAddr::new([10, 0, 0, n].into(), 1)).collect();
        assert_eq!(decode_candidates(&encode_candidates(&many)).unwrap().len(), MAX_CANDIDATES);
    }

    #[test]
    fn malformed_lists_are_refused() {
        let list = encode_candidates(&["10.0.0.1:1".parse().unwrap()]);
        assert_eq!(decode_candidates(&list[..4]), Err(CandidateError::Length(4)));
        assert_eq!(decode_candidates(&list[..list.len() - 1]), Err(CandidateError::Length(11)));
        let mut magic = list.clone();
        magic[0] = b'x';
        assert_eq!(decode_candidates(&magic), Err(CandidateError::Magic));
        let mut family = list.clone();
        family[5] = 9;
        assert_eq!(decode_candidates(&family), Err(CandidateError::Family(9)));
        let mut count = list.clone();
        count[4] = 200;
        assert_eq!(decode_candidates(&count), Err(CandidateError::Count(200)));
        let mut trailing = list;
        trailing.push(0);
        assert_eq!(decode_candidates(&trailing), Err(CandidateError::Length(13)));
    }
}
