//! Temporary diagnostic (removed before merge).
use cmux_rd_link::{Endpoint, EndpointEvent, KeyPair, Role, Route};
use cmux_transport::PathKind;
use std::net::SocketAddr;

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}
const HOST: &str = "10.77.0.1:4103";
const VIEWER: &str = "10.77.0.2:4103";

#[test]
fn debug_restore() {
    let (v, h) = (KeyPair::generate().unwrap(), KeyPair::generate().unwrap());
    let mut viewer = Endpoint::new(Role::Initiator, b"s1", &v, h.public, 0).unwrap();
    let mut host = Endpoint::new(Role::Responder, b"s1", &h, v.public, 0).unwrap();
    viewer.add_path(Route::Udp(addr(HOST)), PathKind::DirectLan, 0);
    let mut now = 0u64;
    for ms in 0..14_000u64 {
        now += 1_000;
        let up = ms < 1_000 || ms >= 11_000;
        let vo = viewer.poll_transmit(now).unwrap();
        let nv = vo.len();
        let mut hev = 0;
        for t in vo {
            if up {
                hev += host.on_packet(Route::Udp(addr(VIEWER)), &t.packet, now).unwrap().len();
            }
        }
        let ho = host.poll_transmit(now).unwrap();
        let nh = ho.len();
        let mut vev = Vec::new();
        for t in ho {
            if up && t.route == Route::Udp(addr(VIEWER)) {
                vev.extend(viewer.on_packet(Route::Udp(addr(HOST)), &t.packet, now).unwrap());
            }
        }
        let ve = viewer.take_events();
        let he = host.take_events();
        let interesting =
            (ms >= 10_900 && ms < 11_400) || !ve.is_empty() || !he.is_empty() || ms % 1000 == 0;
        if interesting && (nv + nh > 0 || !ve.is_empty() || !he.is_empty() || ms % 1000 == 0) {
            let pc: Vec<_> =
                ve.iter().filter(|e| matches!(e, EndpointEvent::PathChanged { .. })).collect();
            let hpc: Vec<_> =
                he.iter().filter(|e| matches!(e, EndpointEvent::PathChanged { .. })).collect();
            eprintln!(
                "ms={ms} up={up} est={}/{} v_out={nv} h_out={nh} host_ev={hev} v_onpkt_ev={} v_pc={pc:?} h_pc={hpc:?} v_next={:?}",
                viewer.link().is_established(),
                host.link().is_established(),
                vev.len(),
                viewer.next_deadline_us().map(|d| d as i64 - now as i64)
            );
        }
    }
    panic!("dump");
}
