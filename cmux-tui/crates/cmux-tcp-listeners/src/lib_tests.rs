use super::*;

fn table(records: &[Vec<u8>]) -> Vec<u8> {
    let mut header = vec![0u8; XINPGEN_SIZE];
    header[0..4].copy_from_slice(&(XINPGEN_SIZE as u32).to_le_bytes());
    let mut out = header.clone();
    for r in records {
        out.extend_from_slice(r);
    }
    out.extend_from_slice(&header);
    out
}

fn record(state: i32, port: u16) -> Vec<u8> {
    let mut r = vec![0u8; XTCPCB64_SIZE];
    r[0..4].copy_from_slice(&(XTCPCB64_SIZE as u32).to_le_bytes());
    r[XT_LPORT..XT_LPORT + 2].copy_from_slice(&port.to_be_bytes());
    r[XT_VFLAG] = INP_IPV4;
    r[XT_LADDR + 12..XT_LADDR + 16].copy_from_slice(&[127, 0, 0, 1]);
    r[XT_STATE..XT_STATE + 4].copy_from_slice(&state.to_le_bytes());
    r
}

#[test]
fn ports_are_listen_only_deduped_and_sorted() {
    let data = table(&[
        record(TCPS_LISTEN, 5173),
        record(4, 9000), // ESTABLISHED: not a listener
        record(TCPS_LISTEN, 3000),
        record(TCPS_LISTEN, 5173),
    ]);
    let listeners = parse_pcblist64(&data).expect("a well-formed table");
    assert_eq!(ports(&listeners), vec![3000, 5173]);
    assert_eq!(listeners[0].addr, IpAddr::V4(Ipv4Addr::LOCALHOST));
}

#[test]
fn another_layout_is_unreadable() {
    assert!(parse_pcblist64(&[0u8; 8]).is_none());
    assert_eq!(parse_pcblist64(&table(&[])), Some(Vec::new()));
}

#[cfg(target_os = "macos")]
#[test]
fn live_table_shows_a_bound_loopback_listener() {
    let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = socket.local_addr().unwrap().port();
    let table = system_listeners().expect("pcblist64 readable");
    assert!(ports(&table).contains(&port));
}
