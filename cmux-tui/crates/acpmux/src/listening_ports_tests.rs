use serde_json::json;

use super::*;

const TCP: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1001 1 0 100 0 0 10 0
   1: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1002 1 0 100 0 0 10 0
   2: 0100007F:1435 0100007F:D2F0 01 00000000:00000000 00:00000000 00000000  1000        0 1003 1 0 100 0 0 10 0
";
const TCP6: &str = "  sl  local_address remote_address st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:1435 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 2001 1 0 100 0 0 10 0
";

#[test]
fn proc_tables_give_listen_ports_deduped_and_sorted() {
    // 0x1435 = 5173 on loopback (v4 and v6), 0x0BB8 = 3000 on the wildcard; the
    // ESTABLISHED row is not a listener.
    assert_eq!(from_proc_tables(&[TCP.to_owned(), TCP6.to_owned()]), Some(vec![3000, 5173]));
    assert_eq!(from_proc_tables(&["header only\n".to_owned()]), Some(Vec::new()));
    assert_eq!(from_proc_tables(&["h\n 0: garbage\n".to_owned()]), None);
}

#[test]
fn answer_carries_port_numbers_only_and_refuses_an_unreadable_table() {
    assert_eq!(
        answer(Some(vec![3000, 5173])).unwrap(),
        json!({"ports": [{"port": 3000}, {"port": 5173}]})
    );
    assert_eq!(answer(Some(Vec::new())).unwrap(), json!({"ports": []}));
    let refused = answer(None).unwrap_err();
    assert_eq!(refused.to_value()["data"]["reason"], "ports.unreadable");
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn a_bound_loopback_listener_shows_here() {
    let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = socket.local_addr().unwrap().port();
    assert!(here().expect("the table reads").contains(&port));
}
