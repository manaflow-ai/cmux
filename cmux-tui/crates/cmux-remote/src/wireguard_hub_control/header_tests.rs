//! The SOCKS5 UDP header of a local datagram decodes by checked bounds.

use super::*;

#[test]
fn headers_round_trip_for_both_address_families() {
    for peer in ["192.0.2.7:4000", "[2001:db8::1]:53"] {
        let peer: SocketAddr = peer.parse().unwrap();
        let mut datagram = encode_header(peer);
        datagram.extend_from_slice(b"payload");
        assert_eq!(decode_header(&datagram), Some((peer, &b"payload"[..])));
    }
}

#[test]
fn malformed_headers_are_none() {
    let valid = encode_header("192.0.2.7:4000".parse().unwrap());
    let mut fragment = valid.clone();
    fragment[2] = 1;
    let mut domain = valid.clone();
    domain[3] = 3;
    for (name, datagram) in [
        ("empty", Vec::new()),
        ("short prefix", valid[..3].to_vec()),
        ("fragment", fragment),
        ("domain name", domain),
        ("short address", valid[..6].to_vec()),
        ("short port", valid[..valid.len() - 1].to_vec()),
    ] {
        assert_eq!(decode_header(&datagram), None, "{name}");
    }
}
