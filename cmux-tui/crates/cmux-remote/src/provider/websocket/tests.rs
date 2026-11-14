use tokio_tungstenite::tungstenite::protocol::frame::Frame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::{Data, OpCode};

use super::*;

#[tokio::test]
async fn connected_link_description_redacts_websocket_capabilities() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        let _ = socket.next().await;
    });
    let endpoint =
        Url::parse(&format!("ws://{address}/capability-path?ticket=query-secret#fragment"))
            .unwrap();

    let link = connect_websocket(&endpoint, 65_535).await.unwrap();

    assert_eq!(link.description(), sanitized_route(&endpoint));
    link.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn fragmented_oversize_message_is_rejected_by_websocket_codec() {
    const MAXIMUM: usize = 8;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        socket
            .send(TungsteniteMessage::Frame(Frame::message(
                Bytes::from_static(b"12345"),
                OpCode::Data(Data::Binary),
                false,
            )))
            .await
            .unwrap();
        socket
            .send(TungsteniteMessage::Frame(Frame::message(
                Bytes::from_static(b"67890"),
                OpCode::Data(Data::Continue),
                true,
            )))
            .await
            .unwrap();
    });
    let endpoint = Url::parse(&format!("ws://{address}/v1/link")).unwrap();
    let link = connect_websocket(&endpoint, MAXIMUM).await.unwrap();

    let error = link.receive().await.expect_err("oversize fragmented message was accepted");
    assert!(
        matches!(
            error,
            LinkError::Transport(ref reason)
                if reason.contains("Message too long") && reason.contains("> 8")
        ),
        "message reached cmux's post-reassembly size check instead of the WebSocket codec: {error}"
    );
    server.await.unwrap();
}
