use super::*;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

const ME: u32 = 501;

fn listener(addr: IpAddr, uid: u32) -> Listener {
    Listener { addr, port: 5173, uid, v4_too: false }
}

fn holder(name: &'static str) -> impl Fn(&Listener) -> Holders {
    move |_| Holders::Found(vec![format!("/usr/local/bin/{name}")])
}

fn v4() -> SocketAddr {
    SocketAddr::from((Ipv4Addr::LOCALHOST, 5173))
}

/// The case lsof missed: a dev server of this user listens on [::1]:P, and
/// a process of another user (root) on 127.0.0.1:P. A connection to
/// 127.0.0.1:P reaches the hidden one: refused. Only listeners whose
/// address covers the target count.
#[test]
fn a_hidden_listener_beside_a_visible_one_is_refused() {
    let listeners = [
        listener(IpAddr::V6(Ipv6Addr::LOCALHOST), ME),
        listener(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
    ];
    assert!(verdict(v4(), &listeners, ME, true, holder("node")).is_some());
    // The same pair seen from [::1]:P reaches the dev server: allowed.
    let v6 = SocketAddr::from((Ipv6Addr::LOCALHOST, 5173));
    assert!(verdict(v6, &listeners, ME, true, holder("node")).is_none());
}

/// A wildcard listener covers the loopback address of its family; a
/// dual-stack IPv6 wildcard covers IPv4 too.
#[test]
fn wildcards_cover_their_family_and_dual_stack_covers_ipv4() {
    let any4 = listener(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0);
    assert!(verdict(v4(), &[any4], ME, true, holder("node")).is_some());
    let any6_v6only = listener(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0);
    assert!(verdict(v4(), &[any6_v6only], ME, false, holder("node")).is_none());
    let any6_dual = Listener { v4_too: true, ..listener(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0) };
    assert!(verdict(v4(), &[any6_dual], ME, false, holder("node")).is_some());
}

/// Nothing listens: allowed before the dial, refused after a connect (a
/// listener exists that the table did not show).
#[test]
fn no_covering_listener() {
    assert!(verdict(v4(), &[], ME, false, holder("node")).is_none());
    assert!(verdict(v4(), &[], ME, true, holder("node")).is_some());
}

/// This user's listener: allowed for a dev server, refused for a cmux
/// service or a Chromium-based browser, and when its holder cannot be found
/// or read.
#[test]
fn own_listeners_are_checked_by_executable() {
    let mine = [listener(IpAddr::V4(Ipv4Addr::LOCALHOST), ME)];
    assert!(verdict(v4(), &mine, ME, true, holder("node")).is_none());
    for name in ["cmux DEV tag", "Google Chrome", "cmux-tui", "acpmux", "msedge"] {
        assert!(verdict(v4(), &mine, ME, true, holder(name)).is_some(), "{name}");
    }
    assert!(verdict(v4(), &mine, ME, true, |_| Holders::Found(Vec::new())).is_some(), "no holder");
    assert!(verdict(v4(), &mine, ME, true, |_| Holders::Unreadable).is_some(), "unreadable");
}

/// The records parse at the offsets measured on macOS 26.5 and 27.0.1
/// (offsetof in the SDK headers): a LISTEN record on 127.0.0.1:5173 of uid
/// 501, and a closed record that is skipped.
#[test]
fn pcblist64_records_parse() {
    let mut data = vec![0u8; XINPGEN_SIZE];
    data[0..4].copy_from_slice(&(XINPGEN_SIZE as u32).to_le_bytes());
    let mut record = |state: i32, port: u16| {
        let mut r = vec![0u8; XTCPCB64_SIZE];
        r[0..4].copy_from_slice(&(XTCPCB64_SIZE as u32).to_le_bytes());
        r[XT_LPORT..XT_LPORT + 2].copy_from_slice(&port.to_be_bytes());
        r[XT_VFLAG] = INP_IPV4;
        r[XT_LADDR + 12..XT_LADDR + 16].copy_from_slice(&[127, 0, 0, 1]);
        r[XT_UID..XT_UID + 4].copy_from_slice(&501u32.to_le_bytes());
        r[XT_STATE..XT_STATE + 4].copy_from_slice(&state.to_le_bytes());
        data.extend(r);
    };
    record(TCPS_LISTEN, 5173);
    record(4, 5174);
    let mut tail = vec![0u8; XINPGEN_SIZE];
    tail[0..4].copy_from_slice(&(XINPGEN_SIZE as u32).to_le_bytes());
    data.extend(tail);
    let listeners = parse_pcblist64(&data);
    assert_eq!(listeners.len(), 1);
    assert_eq!(listeners[0].addr, IpAddr::V4(Ipv4Addr::LOCALHOST));
    assert_eq!((listeners[0].port, listeners[0].uid), (5173, 501));
}

/// The live table on this Mac lists a listener this test binds, with this
/// user's uid, and finds this process as its holder (the offsets hold on
/// the running OS).
#[cfg(target_os = "macos")]
#[test]
fn the_live_table_finds_a_listener_and_its_holder() {
    let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = socket.local_addr().unwrap();
    let listeners = system_listeners().expect("pcblist64 readable");
    let mine: Vec<&Listener> = listeners.iter().filter(|l| l.port == addr.port()).collect();
    assert_eq!(mine.len(), 1, "{mine:?}");
    // SAFETY: getuid has no preconditions.
    assert_eq!(mine[0].uid, unsafe { libc::getuid() });
    match system_holders(mine[0]) {
        Holders::Found(paths) => assert!(!paths.is_empty(), "no holder found"),
        Holders::Unreadable => panic!("holders unreadable"),
    }
}

/// Timing proof (run with --ignored --nocapture): one full check of a real
/// loopback listener (table, holders, executable) on this Mac.
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
