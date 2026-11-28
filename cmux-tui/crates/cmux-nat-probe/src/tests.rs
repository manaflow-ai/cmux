use super::*;

#[test]
fn a_binding_request_has_the_cookie_and_id() {
    let req = stun_request([7; 12]);
    assert_eq!(&req[0..4], &[0x00, 0x01, 0x00, 0x00]);
    assert_eq!(u32::from_be_bytes(req[4..8].try_into().unwrap()), STUN_MAGIC);
    assert_eq!(&req[8..20], &[7; 12]);
}

fn response(txid: [u8; 12], attrs: &[u8]) -> Vec<u8> {
    let mut out = vec![0x01, 0x01];
    out.extend_from_slice(&(attrs.len() as u16).to_be_bytes());
    out.extend_from_slice(&STUN_MAGIC.to_be_bytes());
    out.extend_from_slice(&txid);
    out.extend_from_slice(attrs);
    out
}

#[test]
fn xor_mapped_v4_decodes() {
    // 203.0.113.9:41437, XORed with the cookie.
    let port = 41437u16 ^ 0x2112;
    let ip = [203 ^ 0x21, 0 ^ 0x12, 113 ^ 0xA4, 9 ^ 0x42];
    let mut attr = vec![0x00, 0x20, 0x00, 0x08, 0x00, 0x01];
    attr.extend_from_slice(&port.to_be_bytes());
    attr.extend_from_slice(&ip);
    let txid = [3; 12];
    assert_eq!(
        stun_mapped(&response(txid, &attr), txid),
        Some("203.0.113.9:41437".parse().unwrap())
    );
}

#[test]
fn xor_mapped_v6_decodes() {
    let addr: SocketAddr = "[2602:f470:40::e190]:39867".parse().unwrap();
    let txid = [9; 12];
    let IpAddr::V6(v6) = addr.ip() else { unreachable!() };
    let mut key = STUN_MAGIC.to_be_bytes().to_vec();
    key.extend_from_slice(&txid);
    let mut attr = vec![0x00, 0x20, 0x00, 0x14, 0x00, 0x02];
    attr.extend_from_slice(&(addr.port() ^ 0x2112).to_be_bytes());
    for (k, b) in v6.octets().iter().enumerate() {
        attr.push(b ^ key[k]);
    }
    assert_eq!(stun_mapped(&response(txid, &attr), txid), Some(addr));
}

#[test]
fn plain_mapped_is_the_fallback_and_another_txid_is_ignored() {
    let mut attr = vec![0x00, 0x01, 0x00, 0x08, 0x00, 0x01];
    attr.extend_from_slice(&5000u16.to_be_bytes());
    attr.extend_from_slice(&[198, 51, 100, 1]);
    let txid = [1; 12];
    let buf = response(txid, &attr);
    assert_eq!(stun_mapped(&buf, txid), Some("198.51.100.1:5000".parse().unwrap()));
    assert_eq!(stun_mapped(&buf, [2; 12]), None);
    assert_eq!(stun_mapped(&buf[..10], txid), None);
}

#[test]
fn packets_round_trip_and_a_foreign_token_is_dropped() {
    for kind in [Kind::Punch { heard: false }, Kind::Punch { heard: true }, Kind::Ping, Kind::Pong]
    {
        let p = Packet { kind, token: 0xfeed, seq: 42, sent_us: 123_456 };
        assert_eq!(Packet::decode(&p.encode(), 0xfeed), Some(p));
        assert_eq!(Packet::decode(&p.encode(), 0xbeef), None);
    }
    assert_eq!(Packet::decode(b"CNP1", 0xfeed), None);
}

#[test]
fn quantiles_by_nearest_rank() {
    let v: Vec<f64> = (1..=20).map(f64::from).collect();
    assert_eq!(quantile(&v, 0.5), Some(10.0));
    assert_eq!(quantile(&v, 0.95), Some(19.0));
    assert_eq!(quantile(&[], 0.5), None);
    assert_eq!(quantile(&[4.0], 0.95), Some(4.0));
}

#[test]
fn loopback_and_link_local_are_not_candidates() {
    assert!(!usable_candidate(&"127.0.0.1:5".parse().unwrap()));
    assert!(!usable_candidate(&"[fe80::1]:5".parse().unwrap()));
    assert!(!usable_candidate(&"10.0.0.2:0".parse().unwrap()));
    assert!(usable_candidate(&"10.0.0.2:5".parse().unwrap()));
    assert!(usable_candidate(&"[2602:f470::1]:5".parse().unwrap()));
}

#[test]
fn tailscale_ping_lines_parse_direct_and_relayed() {
    let text = "pong from fs-27 (100.97.205.18) via DERP(sfo) in 45ms\n\
                ping \"100.97.205.18\" timed out\n\
                pong from fs-27 (100.97.205.18) via 208.72.218.135:41641 in 3.5ms\n\
                pong from fs-27 (100.97.205.18) via [2602:f470::1]:41641 in 4ms\n";
    let got = parse_tailscale_ping(text);
    assert_eq!(got.rtt_ms, vec![45.0, 3.5, 4.0]);
    assert_eq!(got.direct, vec![false, true, true]);
    assert_eq!(got.last_via.as_deref(), Some("[2602:f470::1]:41641"));
    assert_eq!(parse_tailscale_ping("no pongs"), TailscalePings::default());
}
