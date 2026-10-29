use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::Hub;
use crate::rpc::{Message, method};
use crate::server::{WsAuth, bind_ws, peer_auth::PeerAuth, serve_ws_until};
use futures_util::StreamExt;
use serde_json::json;
use std::sync::Arc;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, protocol::Role};

#[tokio::test]
async fn restart_drains_peer_web_and_redeeming_ticket_clients_with_1012() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ws-restart");
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let hub = Hub::new(config, store);
    let peer_auth = PeerAuth::create(dir.path()).unwrap();
    let peer_token =
        std::fs::read_to_string(crate::server::peer_auth::token_path(dir.path())).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    // A process another test spawns holds a copy of this socket from its clone until its exec.
    // Hold one throughout, so admission must close even while such a copy is open.
    #[cfg(target_os = "linux")]
    let _inherited = std::os::fd::AsFd::as_fd(&listener).try_clone_to_owned().unwrap();
    let shutdown = WsShutdown::default();
    let serving = tokio::spawn(serve_ws_until(
        hub.clone(),
        listener,
        "tok".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(peer_auth)) },
        shutdown.clone(),
    ));
    let mut clients = Vec::new();
    for peer in [false, true] {
        let mut request = format!("ws://{addr}").into_client_request().unwrap();
        request.headers_mut().insert("authorization", "Bearer tok".parse().unwrap());
        if peer {
            request
                .headers_mut()
                .insert(crate::server::peer_auth::HEADER, peer_token.parse().unwrap());
        }
        let (mut ws, _) = tokio_tungstenite::connect_async(request).await.unwrap();
        let init = Message::request(1, method::INITIALIZE, json!({"protocolVersion":1}));
        ws.send(Frame::Text(init.to_line().into())).await.unwrap();
        let reply = tokio::time::timeout(Duration::from_secs(5), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let Frame::Text(reply) = reply else { panic!("expected initialize reply") };
        let reply: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(
            reply["result"]["_meta"]["acpmux"]["origin"],
            if peer { "peer" } else { "remote" }
        );
        clients.push(ws);
    }
    let (ticket, _) = hub
        .pairing
        .mint(
            crate::pairing::Role::Client,
            900,
            None,
            format!("ws://{addr}"),
            "test".into(),
            hub.person.instance().to_owned(),
        )
        .unwrap();
    let mut request = format!("ws://{addr}").into_client_request().unwrap();
    request.headers_mut().insert(crate::pairing::TICKET_HEADER, ticket.secret.parse().unwrap());
    let (ticket_ws, _) = tokio_tungstenite::connect_async(request).await.unwrap();
    clients.push(ticket_ws);
    shutdown.restart();
    for mut ws in clients {
        let frame = tokio::time::timeout(Duration::from_secs(5), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let Frame::Close(Some(close)) = frame else {
            panic!("expected restart Close, got {frame:?}")
        };
        assert_eq!(close.code, CloseCode::Restart);
        assert!(
            tokio::net::TcpStream::connect(addr).await.is_err(),
            "admission closed before 1012"
        );
    }
    tokio::time::timeout(Duration::from_secs(5), serving).await.unwrap().unwrap().unwrap();
}

#[tokio::test(start_paused = true)]
async fn restart_interrupts_a_blocked_writer_and_bounds_the_close() {
    let (ours, _unread) = tokio::io::duplex(64);
    let socket = WebSocketStream::from_raw_socket(ours, Role::Server, None).await;
    let (sink, _source) = socket.split();
    let (out, outbound) = mpsc::channel(1);
    let (_stop, stopped) = oneshot::channel();
    let shutdown = WsShutdown::default();
    out.send("x".repeat(1 << 20)).await.unwrap();
    let task = tokio::spawn(write(sink, outbound, stopped, shutdown.clone()));
    tokio::task::yield_now().await;
    shutdown.close_clients();
    let before = tokio::time::Instant::now();
    task.await.unwrap();
    assert_eq!(before.elapsed(), CLOSE_BUDGET);
}

#[tokio::test]
async fn late_writer_sees_restart_but_normal_connection_close_has_no_restart_code() {
    for restarting in [true, false] {
        let (ours, theirs) = tokio::io::duplex(4096);
        let socket = WebSocketStream::from_raw_socket(ours, Role::Server, None).await;
        let (sink, _source) = socket.split();
        let mut client = WebSocketStream::from_raw_socket(theirs, Role::Client, None).await;
        let (_out, outbound) = mpsc::channel(1);
        let (stop, stopped) = oneshot::channel();
        let shutdown = WsShutdown::default();
        if restarting {
            shutdown.close_clients();
        } else {
            stop.send(()).unwrap();
        }
        let task = tokio::spawn(write(sink, outbound, stopped, shutdown));
        let frame = tokio::time::timeout(Duration::from_secs(5), client.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        match frame {
            Frame::Close(Some(close)) if restarting => assert_eq!(close.code, CloseCode::Restart),
            Frame::Close(None) if !restarting => {}
            other => panic!("wrong close: {other:?}"),
        }
        task.await.unwrap();
    }
}

#[tokio::test]
async fn ordinary_shutdown_uses_a_normal_close_code() {
    let (ours, theirs) = tokio::io::duplex(4096);
    let socket = WebSocketStream::from_raw_socket(ours, Role::Server, None).await;
    let (sink, _source) = socket.split();
    let mut client = WebSocketStream::from_raw_socket(theirs, Role::Client, None).await;
    let (_out, outbound) = mpsc::channel(1);
    let (_stop, stopped) = oneshot::channel();
    let shutdown = WsShutdown::default();
    shutdown.normal_shutdown();
    let task = tokio::spawn(write(sink, outbound, stopped, shutdown));
    let frame = tokio::time::timeout(Duration::from_secs(5), client.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(matches!(frame, Frame::Close(None)), "ordinary shutdown sent {frame:?}");
    task.await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn shared_restart_waits_for_each_listener_and_keeps_client_signals_local() {
    let shared = WsShutdown::default();
    let (tcp, tcp_guard) = shared.listener();
    let (tailnet, tailnet_guard) = shared.listener();
    shared.restart();
    tcp.requested().await;
    tailnet.requested().await;
    tcp.close_clients();
    assert!(*tcp.closing.borrow());
    assert!(!*tailnet.closing.borrow(), "tailnet admission must close before its clients");
    drop(tcp_guard);
    assert!(tokio::time::timeout(Duration::from_millis(10), shared.drained()).await.is_err());
    tailnet.close_clients();
    drop(tailnet_guard);
    shared.drained().await;
    let (late, _guard) = shared.listener();
    assert!(late.is_requested(), "late listener cannot admit after shutdown");
}
