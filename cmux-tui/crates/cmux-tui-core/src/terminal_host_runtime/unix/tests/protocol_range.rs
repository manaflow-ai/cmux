//! hq RFD 0224 phase 2: a host serves `PROTOCOL_MIN_VERSION..=PROTOCOL_VERSION`, so a rolled-back
//! (N-1) daemon still adopts it, a newer (N+1) daemon falls to N, and no overlap is a typed
//! `version.incompatible` refusal.

use super::*;
use crate::terminal_host_protocol::{PROTOCOL_MIN_VERSION, VERSION_INCOMPATIBLE};

const SAFETY_BOUND: Duration = Duration::from_secs(30);

fn owner_hello(host: &HostShared, min_version: u16, max_version: u16) -> ClientHello {
    ClientHello {
        min_version,
        max_version,
        role: ClientRole::Admin,
        requested_rights: CapabilityRights::ADMIN,
        terminal_id: host.terminal_id,
        token: host.owner_token,
    }
}

#[test]
fn owner_handshake_selects_newest_common_version() {
    let host = test_host_shared();
    let n = PROTOCOL_VERSION;
    assert!(PROTOCOL_MIN_VERSION <= n - 1);
    let selected = |min, max| authenticate_client(&host, &owner_hello(&host, min, max));
    assert_eq!(selected(n - 1, n - 1).unwrap().selected_version, n - 1, "N-1");
    assert_eq!(selected(n, n + 1).unwrap().selected_version, n, "N+1");
    assert_eq!(selected(n - 1, n).unwrap().selected_version, n);
    let newer = selected(n + 1, n + 2).unwrap_err().to_string();
    assert!(newer.contains(VERSION_INCOMPATIBLE), "{newer}");
    let older = selected(1, PROTOCOL_MIN_VERSION - 1).unwrap_err().to_string();
    assert!(
        older.contains(VERSION_INCOMPATIBLE) && older.contains("acpmux host self-update"),
        "{older}"
    );
}

#[test]
fn renderer_handshake_serves_previous_version() {
    let host = test_host_shared();
    let n = PROTOCOL_VERSION;
    let hello = |min, max| ClientHello {
        min_version: min,
        max_version: max,
        role: ClientRole::Renderer,
        requested_rights: CapabilityRights::READ,
        terminal_id: host.terminal_id,
        token: host
            .capabilities
            .mint(host.terminal_id, CapabilityRights::READ, SAFETY_BOUND)
            .unwrap(),
    };
    assert_eq!(authenticate_client(&host, &hello(n - 1, n - 1)).unwrap().selected_version, n - 1);
    assert_eq!(authenticate_client(&host, &hello(n, n + 1)).unwrap().selected_version, n);
    assert!(authenticate_client(&host, &hello(n + 1, n + 2)).is_err());
}

/// A real served connection: an N-1 hello gets an N-1 HostHello, and every frame after the
/// handshake carries the negotiated version.
#[test]
fn served_session_uses_negotiated_previous_version() {
    let host = test_host_shared();
    let older = PROTOCOL_VERSION - 1;
    let (server_stream, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(SAFETY_BOUND)).unwrap();
    let server_host = host.clone();
    thread::spawn(move || {
        let _ = serve_client(server_host, server_stream);
    });
    let mut frame = owner_hello(&host, older, older).into_frame(1);
    frame.version = older;
    write_frame(&mut client, &frame).unwrap();
    let host_hello = read_required_frame(&mut client, "host hello").unwrap();
    assert_eq!(host_hello.kind, MessageKind::HostHello);
    assert_eq!(host_hello.version, older);
    assert_eq!(HostHello::decode(&host_hello.payload).unwrap().selected_version, older);
    let snapshot = read_required_frame(&mut client, "snapshot").unwrap();
    assert_eq!(snapshot.kind, MessageKind::Snapshot);
    assert_eq!(snapshot.version, older);
}

/// No overlap: the host closes without a HostHello (the wire older daemons already read as a
/// refusal).
#[test]
fn no_common_version_closes_without_host_hello() {
    let host = test_host_shared();
    let newer = PROTOCOL_VERSION + 1;
    let (server_stream, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(SAFETY_BOUND)).unwrap();
    let server_host = host.clone();
    let server = thread::spawn(move || serve_client(server_host, server_stream));
    let mut frame = owner_hello(&host, newer, newer + 1).into_frame(1);
    frame.version = PROTOCOL_VERSION;
    write_frame(&mut client, &frame).unwrap();
    let error = server.join().unwrap().unwrap_err().to_string();
    assert!(error.contains(VERSION_INCOMPATIBLE), "{error}");
    assert!(read_required_frame(&mut client, "host hello").is_err());
}
