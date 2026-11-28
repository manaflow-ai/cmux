//! What woke the guest (`wake_sockets.rs`): the kernel's TCP table read at a resume.

use serde_json::json;

use super::session::Session;
use super::wake_sockets::{WAKE_SOCKETS_MAX, WakeSocket, wake_sockets};
use super::wire::DaemonInfo;

const HEADER: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode";

fn line(local: &str, remote: &str, st: &str, rx: &str) -> String {
    format!(
        "   0: {local} {remote} {st} 00000000:{rx} 00:00000000 00000000  1000        0 12345 1 0000000000000000 20 4 30 10 -1"
    )
}

#[test]
fn a_peer_closed_pooled_connection_reads_close_wait_and_ports_only() {
    let v4 = [
        HEADER.to_string(),
        // Listening on 9001 (the carrier, say).
        line("00000000:2329", "00000000:0000", "0A", "00000000"),
        // Our HTTPS connection to the Cloud that the peer closed: CLOSE_WAIT.
        line("0A00020F:C350", "68107A0B:01BB", "08", "00000000"),
        // An idle established connection: not a waker.
        line("0A00020F:C351", "68107A0B:01BB", "01", "00000000"),
        // A client dialed in to 9001 and sent bytes nobody read yet.
        line("0A00020F:2329", "0A000001:D431", "01", "0000002A"),
    ]
    .join("\n");
    let got = wake_sockets(&[&v4, ""]);
    assert_eq!(
        got,
        vec![
            WakeSocket {
                state: "close_wait",
                local_port: 50000,
                remote_port: 443,
                unread: false,
                inbound: false
            },
            WakeSocket {
                state: "established",
                local_port: 9001,
                remote_port: 54321,
                unread: true,
                inbound: true
            },
        ]
    );
    let json = got[0].to_json().to_string();
    assert!(!json.contains("68107A0B") && !json.contains("104."), "never an address: {json}");
}

#[test]
fn tcp6_syn_recv_counts_and_bad_lines_do_not() {
    let v6 = [
        HEADER.to_string(),
        "garbage".to_string(),
        line(
            "00000000000000000000000001000000:0016",
            "0000000000000000FFFF00000A000001:E000",
            "03",
            "00000000",
        ),
    ]
    .join("\n");
    let got = wake_sockets(&["", &v6]);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].state, "syn_recv");
    assert_eq!((got[0].local_port, got[0].remote_port), (22, 57344));
}

#[test]
fn at_most_the_cap_close_wait_first() {
    let mut lines = vec![HEADER.to_string()];
    for i in 0..30u16 {
        lines.push(line(&format!("0A00020F:{:04X}", 40000 + i), "68107A0B:01BB", "01", "00000001"));
    }
    lines.push(line("0A00020F:C350", "68107A0B:01BB", "08", "00000000"));
    let got = wake_sockets(&[&lines.join("\n")]);
    assert_eq!(got.len(), WAKE_SOCKETS_MAX);
    assert_eq!(got[0].state, "close_wait");
}

#[test]
fn the_wake_block_carries_the_sockets_read_at_its_resume() {
    let mut s = Session::new(
        "vm_m0000000000000000001",
        DaemonInfo { version: "test".into(), capabilities: vec![] },
        3_600_000,
    );
    let sockets = json!([{"state": "close_wait", "local_port": 50000, "remote_port": 443, "unread": false, "inbound": false}]);
    s.resume_with_sockets(1_000, 1_790_000_000_000, Some(sockets.clone()));
    // The next resume ends this wake as a timeout; its block holds the sockets.
    s.resume_with_sockets(2_000, 1_790_000_001_000, None);
    let wake = s.reporter.wake().cloned().expect("the ended wake is queued for the report");
    assert_eq!(wake["sockets"], sockets);
    assert_eq!(wake["outcome"], "timeout");
}
