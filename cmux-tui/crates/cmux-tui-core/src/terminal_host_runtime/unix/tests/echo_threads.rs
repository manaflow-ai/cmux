//! p02-threads task 210: an accepted terminal-host client is served by echo
//! path threads, and its output loop writes its own socket through the
//! checked own-descriptor path.

use super::super::super::shared::host_accept::serve_accepted;
use super::*;
use crate::echo_thread::ECHO_PATH_QOS;

fn declared(name: &str) -> Vec<cmux_threads::ThreadQos> {
    cmux_threads::snapshot()
        .into_iter()
        .filter(|row| row.name == name)
        .map(|row| row.declared)
        .collect()
}

#[test]
fn an_accepted_client_is_served_by_echo_path_threads() {
    let host = exited_host_fixture();
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    serve_accepted(&host, server_stream).unwrap();

    let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
    hello.flags = FLAG_SMART_RENDERER;
    write_frame(&mut client_stream, &hello).unwrap();
    for (label, kind) in [
        ("host hello", MessageKind::HostHello),
        ("snapshot", MessageKind::Snapshot),
        ("colors", MessageKind::Colors),
        ("ready", MessageKind::Ready),
    ] {
        assert_eq!(read_required_frame(&mut client_stream, label).unwrap().kind, kind);
    }
    // Client-input starts right after Ready; both threads serve until Exit.
    for name in ["terminal-host-client", "terminal-host-client-input"] {
        let deadline = Instant::now() + Duration::from_secs(5);
        let rows = loop {
            let rows = declared(name);
            if !rows.is_empty() || Instant::now() >= deadline {
                break rows;
            }
            thread::yield_now();
        };
        assert!(!rows.is_empty(), "{name} is registered while it serves");
        assert!(rows.iter().all(|qos| *qos == ECHO_PATH_QOS), "{name}: {rows:?}");
    }

    let cursor = host.smart.publish(Frame::new(MessageKind::Output, b"echo".to_vec()));
    host.smart.mark_applied(cursor);
    let output = read_required_frame(&mut client_stream, "output").unwrap();
    assert_eq!((output.kind, output.payload.as_slice()), (MessageKind::Output, &b"echo"[..]));
    let echo_thread_file =
        file!().replace("terminal_host_runtime/unix/tests/echo_threads.rs", "echo_thread.rs");
    let sites = cmux_threads::blocking::snapshot();
    assert!(
        sites.sites.iter().all(|site| site.file != echo_thread_file),
        "the output loop writes its own socket without a violation: {sites:?}"
    );

    let cursor = host.smart.publish(Frame::new(MessageKind::Exit, Vec::new()));
    host.smart.mark_applied(cursor);
    assert_eq!(read_required_frame(&mut client_stream, "exit").unwrap().kind, MessageKind::Exit);
    let _ = client_stream.shutdown(std::net::Shutdown::Both);
}
