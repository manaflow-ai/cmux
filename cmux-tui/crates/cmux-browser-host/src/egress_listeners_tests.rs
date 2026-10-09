use super::*;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

const ME: u32 = 501;

fn listener(addr: IpAddr, uid: u32) -> Listener {
    Listener { addr, port: 5173, uid, v4_too: false }
}

/// A listener of this user, found by libproc, with its holder.
fn held(addr: IpAddr, name: &str) -> Held {
    Held { listener: listener(addr, ME), exe: Some(format!("/usr/local/bin/{name}")) }
}

fn v4() -> SocketAddr {
    SocketAddr::from((Ipv4Addr::LOCALHOST, 5173))
}

fn v6() -> SocketAddr {
    SocketAddr::from((Ipv6Addr::LOCALHOST, 5173))
}

/// The case lsof missed: a dev server of this user listens on [::1]:P, and
/// a process of another user (root) on 127.0.0.1:P. A connection to
/// 127.0.0.1:P reaches the hidden one: refused. Only listeners whose
/// address covers the target count.
#[test]
fn a_hidden_listener_beside_a_visible_one_is_refused() {
    let own = [held(IpAddr::V6(Ipv6Addr::LOCALHOST), "node")];
    let table = [listener(IpAddr::V4(Ipv4Addr::LOCALHOST), 0)];
    assert!(verdict(v4(), &table, &own, ME, true).is_some());
    assert!(verdict(v4(), &table, &own, ME, false).is_some(), "before the dial too");
    // The same pair seen from [::1]:P reaches the dev server: allowed.
    assert!(verdict(v6(), &table, &own, ME, true).is_none());
}

/// The kernel can filter the table to the caller's own sockets (a sandboxed
/// or app-launched process sees one record of many). The hidden listener is
/// then absent from the table: the connect still refuses, because no
/// listener of this user covers the target.
#[test]
fn a_filtered_table_still_refuses_the_hidden_listener_after_connect() {
    let own = [held(IpAddr::V6(Ipv6Addr::LOCALHOST), "node")];
    assert!(verdict(v4(), &[], &own, ME, true).is_some());
    assert!(verdict(v6(), &[], &own, ME, true).is_none());
}

/// A wildcard listener covers the loopback address of its family; a
/// dual-stack IPv6 wildcard covers IPv4 too.
#[test]
fn wildcards_cover_their_family_and_dual_stack_covers_ipv4() {
    let any4 = listener(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0);
    assert!(verdict(v4(), &[any4], &[], ME, true).is_some());
    let any6_v6only = listener(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0);
    assert!(verdict(v4(), &[any6_v6only], &[], ME, false).is_none());
    let any6_dual = Listener { v4_too: true, ..listener(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0) };
    assert!(verdict(v4(), &[any6_dual], &[], ME, false).is_some());
    let own_any4 = [held(IpAddr::V4(Ipv4Addr::UNSPECIFIED), "node")];
    assert!(verdict(v4(), &[], &own_any4, ME, true).is_none());
}

/// Nothing listens: allowed before the dial, refused after a connect (a
/// listener exists that this host did not see).
#[test]
fn no_covering_listener() {
    assert!(verdict(v4(), &[], &[], ME, false).is_none());
    assert!(verdict(v4(), &[], &[], ME, true).is_some());
}

/// This user's listener: allowed for a dev server, refused for a cmux
/// service or a Chromium-based browser, when its holder cannot be read, and
/// when the table shows it but libproc finds no holder.
#[test]
fn own_listeners_are_checked_by_executable() {
    let addr = IpAddr::V4(Ipv4Addr::LOCALHOST);
    assert!(verdict(v4(), &[], &[held(addr, "node")], ME, true).is_none());
    for name in ["cmux DEV tag", "Google Chrome", "cmux-tui", "acpmux", "msedge"] {
        assert!(verdict(v4(), &[], &[held(addr, name)], ME, true).is_some(), "{name}");
    }
    let unreadable = Held { listener: listener(addr, ME), exe: None };
    assert!(verdict(v4(), &[], &[unreadable], ME, true).is_some(), "unreadable");
    let in_table = [listener(addr, ME)];
    assert!(verdict(v4(), &in_table, &[], ME, false).is_some(), "no holder");
}

fn xinpgen(count: u32) -> Vec<u8> {
    let mut header = vec![0u8; XINPGEN_SIZE];
    header[0..4].copy_from_slice(&(XINPGEN_SIZE as u32).to_le_bytes());
    header[4..8].copy_from_slice(&count.to_le_bytes());
    header
}

/// One `xtcpcb64` record at the offsets measured on macOS 26.5 and 27.0.1.
fn record(state: i32, vflag: u8, laddr: [u8; 16], flags: u32) -> Vec<u8> {
    let mut r = vec![0u8; XTCPCB64_SIZE];
    r[0..4].copy_from_slice(&(XTCPCB64_SIZE as u32).to_le_bytes());
    r[XT_LPORT..XT_LPORT + 2].copy_from_slice(&5173u16.to_be_bytes());
    r[XT_FLAGS..XT_FLAGS + 4].copy_from_slice(&flags.to_le_bytes());
    r[XT_VFLAG] = vflag;
    r[XT_LADDR..XT_LADDR + 16].copy_from_slice(&laddr);
    r[XT_UID..XT_UID + 4].copy_from_slice(&501u32.to_le_bytes());
    r[XT_STATE..XT_STATE + 4].copy_from_slice(&state.to_le_bytes());
    r
}

fn table(records: &[Vec<u8>]) -> Vec<u8> {
    let mut data = xinpgen(records.len() as u32);
    records.iter().for_each(|r| data.extend(r));
    data.extend(xinpgen(records.len() as u32));
    data
}

const V4_LOOP: [u8; 16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 127, 0, 0, 1];
const V6_ANY: [u8; 16] = [0; 16];
const V4_MAPPED_LOOP: [u8; 16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1];

/// LISTEN records parse (IPv4, v6-only and dual-stack IPv6 wildcards, a
/// v4-mapped address); a closed record is skipped.
#[test]
fn pcblist64_records_parse() {
    let data = table(&[
        record(TCPS_LISTEN, INP_IPV4, V4_LOOP, 0),
        record(4, INP_IPV4, V4_LOOP, 0),
        record(TCPS_LISTEN, INP_IPV6, V6_ANY, IN6P_IPV6_V6ONLY as u32),
        record(TCPS_LISTEN, INP_IPV6, V6_ANY, 0),
        record(TCPS_LISTEN, INP_IPV6, V4_MAPPED_LOOP, 0),
    ]);
    let listeners = parse_pcblist64(&data).expect("a well-formed table");
    let any6 = IpAddr::V6(Ipv6Addr::UNSPECIFIED);
    let loop4 = IpAddr::V4(Ipv4Addr::LOCALHOST);
    let got: Vec<(IpAddr, u16, u32, bool)> =
        listeners.iter().map(|l| (l.addr, l.port, l.uid, l.v4_too)).collect();
    assert_eq!(
        got,
        [
            (loop4, 5173, 501, false),
            (any6, 5173, 501, false),
            (any6, 5173, 501, true),
            (loop4, 5173, 501, false)
        ]
    );
}

/// A table whose layout is not the measured one is unreadable (`None`, and
/// the caller refuses): a record of another size, a missing trailer, a
/// short header.
#[test]
fn a_table_of_another_layout_is_unreadable() {
    let good = record(TCPS_LISTEN, INP_IPV4, V4_LOOP, 0);
    let mut long = good.clone();
    long.extend([0u8; 8]);
    long[0..4].copy_from_slice(&((XTCPCB64_SIZE + 8) as u32).to_le_bytes());
    assert!(parse_pcblist64(&table(&[long])).is_none(), "record size");
    let mut no_trailer = xinpgen(1);
    no_trailer.extend(&good);
    assert!(parse_pcblist64(&no_trailer).is_none(), "trailer");
    assert!(parse_pcblist64(&[0u8; 8]).is_none(), "short");
    assert!(parse_pcblist64(&table(&[])).is_some(), "an empty table is readable");
}

/// The live sources on this Mac: the table parses, and libproc finds a
/// listener this test binds with this process as its holder (the offsets
/// hold on the running OS; the table may be filtered to own sockets).
#[cfg(target_os = "macos")]
#[test]
fn the_live_sources_find_a_listener_and_its_holder() {
    let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = socket.local_addr().unwrap();
    assert!(system_listeners().is_some(), "pcblist64 readable");
    // SAFETY: geteuid has no preconditions.
    let own = system_own_listeners(unsafe { libc::geteuid() }).expect("libproc readable");
    let mine: Vec<&Held> = own.iter().filter(|h| h.listener.port == addr.port()).collect();
    assert_eq!(mine.len(), 1, "{mine:?}");
    assert_eq!(mine[0].listener.addr, addr.ip());
    let exe = mine[0].exe.as_deref().expect("holder readable");
    let me = std::env::current_exe().unwrap();
    let name = me.file_name().unwrap().to_str().unwrap();
    assert!(exe.ends_with(&format!("/{name}")), "{exe} is not {name}");
}

/// A dual-stack IPv6 wildcard listener (what Node binds by default) is
/// found with IPv4 coverage, so its dev server is reachable on 127.0.0.1.
#[cfg(target_os = "macos")]
#[test]
fn a_live_dual_stack_listener_covers_ipv4() {
    let socket = std::net::TcpListener::bind("[::]:0").unwrap();
    let port = socket.local_addr().unwrap().port();
    // SAFETY: geteuid has no preconditions.
    let own = system_own_listeners(unsafe { libc::geteuid() }).expect("libproc readable");
    let mine: Vec<&Held> = own.iter().filter(|h| h.listener.port == port).collect();
    assert_eq!(mine.len(), 1, "{mine:?}");
    assert!(mine[0].listener.v4_too, "{mine:?}");
    let check = crate::egress_services::system_connected_check();
    assert_eq!(check(SocketAddr::from((Ipv4Addr::LOCALHOST, port))), None);
}

/// Timing proof (run with --ignored --nocapture): one full check of a real
/// loopback listener (table, libproc sweep, executables) on this Mac.
#[cfg(target_os = "macos")]
#[test]
#[ignore]
fn timing_of_one_check() {
    let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = socket.local_addr().unwrap();
    let check = crate::egress_services::system_connected_check();
    let mut times: Vec<u128> = (0..20)
        .map(|_| {
            let start = std::time::Instant::now();
            assert!(check(addr).is_none(), "this test's own listener is allowed");
            start.elapsed().as_micros()
        })
        .collect();
    times.sort_unstable();
    println!("egress check: p50 {} us, p90 {} us, max {} us", times[10], times[18], times[19]);
}
