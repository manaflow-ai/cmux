use super::ConnectInfoSource as _;
use super::{MAX_REPLY, channel};
use cmux_link::connect_info::ConnectInfoError;
use cmux_link::dial::Service;
use std::io;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixStream;

const HOST: &str = "host_00000000000000000001";

async fn request(stream: &mut UnixStream) -> serde_json::Value {
    serde_json::from_str(&super::super::lines::read_line(stream, MAX_REPLY).await.unwrap()).unwrap()
}

async fn reply(stream: &mut UnixStream, value: serde_json::Value) {
    stream.write_all(format!("{value}\n").as_bytes()).await.unwrap();
}

#[tokio::test]
async fn cloud_broker_mints_each_token_once_and_sends_only_the_requested_host_and_services() {
    let (link, mut parent) = UnixStream::pair().unwrap();
    let (source, driver) = channel(link);
    let driven = tokio::spawn(driver.run());
    let server = tokio::spawn(async move {
        for id in 1..=2 {
            assert_eq!(
                request(&mut parent).await,
                serde_json::json!({
                    "version": 1, "id": id, "op": "cloud.machine.link_token", "host": HOST,
                    "services": ["ssh"]
                })
            );
            reply(&mut parent, serde_json::json!({
                "version": 1, "id": id, "value": {"token": format!("one-use-{id}"),
                    "expires_at": 1792430000000_i64, "epoch": 1, "host": HOST, "services": ["ssh"]}
            })).await;
        }
    });
    let first = source.mint_token(HOST, &[Service::Ssh]).await.unwrap();
    let second = source.mint_token(HOST, &[Service::Ssh]).await.unwrap();
    assert_ne!(first.token, second.token);
    assert!(!format!("{first:?}").contains("one-use-1"));
    server.await.unwrap();
    assert!(driven.await.unwrap().is_ok());
}

#[tokio::test]
async fn cloud_broker_refuses_owner_sessions_duplicate_services_and_non_cloud_ids_before_io() {
    let (link, _parent) = UnixStream::pair().unwrap();
    let (source, driver) = channel(link);
    let driven = tokio::spawn(driver.run());
    for services in [vec![], vec![Service::OwnerSession], vec![Service::Ssh, Service::Ssh]] {
        assert!(matches!(
            source.mint_token(HOST, &services).await,
            Err(ConnectInfoError::Forbidden)
        ));
    }
    assert!(matches!(source.fetch("inst_other").await, Err(ConnectInfoError::Forbidden)));
    drop(source);
    assert!(driven.await.unwrap().is_ok());
}

#[tokio::test]
async fn cloud_broker_wrong_reply_id_or_ambiguous_answer_closes_the_channel() {
    for response in [
        serde_json::json!({"version": 1, "id": 2, "error": {"code": "auth.forbidden"}}),
        serde_json::json!({"version": 1, "id": 1, "value": {}, "error": {"code": "auth.forbidden"}}),
        serde_json::json!({"version": 1, "id": 1, "error": {"code": "auth.forbidden"}, "unexpected": true}),
    ] {
        let (link, mut parent) = UnixStream::pair().unwrap();
        let (source, driver) = channel(link);
        let driven = tokio::spawn(driver.run());
        let server = tokio::spawn(async move {
            request(&mut parent).await;
            reply(&mut parent, response).await;
        });
        assert!(matches!(source.fetch(HOST).await, Err(ConnectInfoError::Unavailable(_))));
        server.await.unwrap();
        assert!(driven.await.unwrap().is_err());
    }
}

#[tokio::test]
async fn cloud_broker_refuses_tokens_for_another_host_or_service() {
    for (host, services) in [
        ("host_00000000000000000002", vec!["ssh"]),
        (HOST, vec!["daemon"]),
        (HOST, vec!["ssh", "owner_session"]),
        (HOST, vec!["ssh", "ssh"]),
    ] {
        let (link, mut parent) = UnixStream::pair().unwrap();
        let (source, driver) = channel(link);
        let driven = tokio::spawn(driver.run());
        let server = tokio::spawn(async move {
            request(&mut parent).await;
            reply(
                &mut parent,
                serde_json::json!({
                    "version": 1, "id": 1, "value": {"token": "private-token",
                        "expires_at": 1792430000000_i64, "epoch": 1, "host": host,
                        "services": services}
                }),
            )
            .await;
        });
        assert!(matches!(
            source.mint_token(HOST, &[Service::Ssh]).await,
            Err(ConnectInfoError::Unavailable(_))
        ));
        server.await.unwrap();
        assert!(driven.await.unwrap().is_err());
    }
}

#[tokio::test]
async fn cloud_broker_cancellation_ends_an_inflight_exchange_and_cannot_reuse_a_late_token() {
    let (link, mut parent) = UnixStream::pair().unwrap();
    let (source, driver) = channel(link);
    let driven = tokio::spawn(driver.run());
    let call = tokio::spawn(async move { source.mint_token(HOST, &[Service::Ssh]).await });
    request(&mut parent).await;
    call.abort();
    let _ = call.await;
    assert!(driven.await.unwrap().is_err());
    assert_eq!(parent.read_u8().await.unwrap_err().kind(), io::ErrorKind::UnexpectedEof);
}

#[tokio::test]
async fn cloud_broker_unsolicited_or_oversized_input_ends_the_driver() {
    let (link, mut parent) = UnixStream::pair().unwrap();
    let (_source, driver) = channel(link);
    let driven = tokio::spawn(driver.run());
    parent.write_all(b"x").await.unwrap();
    assert!(driven.await.unwrap().is_err());

    let (link, mut parent) = UnixStream::pair().unwrap();
    let (source, driver) = channel(link);
    let driven = tokio::spawn(driver.run());
    let server = tokio::spawn(async move {
        request(&mut parent).await;
        let _ = parent.write_all(&vec![b'x'; MAX_REPLY + 1]).await;
    });
    assert!(matches!(source.fetch(HOST).await, Err(ConnectInfoError::Unavailable(_))));
    server.await.unwrap();
    assert!(driven.await.unwrap().is_err());
}
