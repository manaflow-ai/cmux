use super::*;

/// The `/json/version` answers of node's inspector and of Chrome; a dev
/// server's answer is not one.
#[test]
fn devtools_answers_are_recognized() {
    let node =
        b"HTTP/1.0 200 OK\r\n\r\n{\"Browser\": \"node.js/v22.0.0\", \"Protocol-Version\": \"1.1\"}";
    assert!(answers_like_devtools(node));
    let chrome = b"HTTP/1.1 200 OK\r\n\r\n{\"Browser\": \"Chrome/141\", \"V8-Version\": \"14.1\", \"webSocketDebuggerUrl\": \"ws://x\"}";
    assert!(answers_like_devtools(chrome));
    assert!(!answers_like_devtools(b"HTTP/1.1 404 Not Found\r\n\r\nCannot GET /json/version"));
    assert!(!answers_like_devtools(b""));
}

/// Nothing listens: the probe answers `false` at once.
#[test]
fn a_closed_port_is_not_devtools() {
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    assert_eq!(refusal(SocketAddr::from(([127, 0, 0, 1], port)), &[1]), None);
}
