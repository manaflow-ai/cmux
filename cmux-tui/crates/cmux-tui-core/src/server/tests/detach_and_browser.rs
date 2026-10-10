//! Client detach, relay sub-views, agent reports and browser pointer/capability wire shapes.

use super::*;

#[test]
fn websocket_direct_writer_emits_a_tungstenite_compatible_text_frame() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (server, _) = listener.accept().unwrap();
    let mut writer = SynchronizedTcpStream::new(server);
    let write = std::thread::spawn(move || {
        writer.write_websocket_text(&"x".repeat(65_536)).unwrap();
    });
    let mut websocket =
        WebSocket::from_raw_socket(client, tungstenite::protocol::Role::Client, None);

    let message = websocket.read().unwrap();

    assert_eq!(message.into_text().unwrap().len(), 65_536);
    write.join().unwrap();
}
