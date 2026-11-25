use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use super::*;

#[tokio::test]
async fn loopback_route_dials_and_forwards_bytes() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut byte = [0u8; 1];
        stream.read_exact(&mut byte).await.unwrap();
        stream.write_all(&byte).await.unwrap();
    });
    let routes = RouteManager::default();
    let response = routes
        .create(
            ClientScope::local(),
            WorkspaceId("workspace".into()),
            "127.0.0.1".into(),
            port,
            RoutePolicy::LoopbackOnly,
        )
        .await
        .unwrap();
    let WorkspaceResponse::RouteCreated { route, .. } = response else { panic!() };
    let mut stream = routes.dial(route).await.unwrap();
    stream.write_all(b"x").await.unwrap();
    let mut byte = [0u8; 1];
    stream.read_exact(&mut byte).await.unwrap();
    assert_eq!(&byte, b"x");
    server.await.unwrap();
}

/// A client may hold any number of routes (the old cap refused the 1025th).
#[tokio::test]
async fn routes_past_the_old_cap_are_created_and_closed() {
    let routes = RouteManager::default();
    for port in 1..=1100u16 {
        let response = routes
            .create(
                ClientScope::local(),
                WorkspaceId("workspace".into()),
                "127.0.0.1".into(),
                port,
                RoutePolicy::LoopbackOnly,
            )
            .await
            .unwrap();
        assert!(matches!(response, WorkspaceResponse::RouteCreated { .. }));
    }
    assert_eq!(routes.routes.read().await.len(), 1100);
    routes.close_client(&ClientScope::local()).await;
    assert!(routes.routes.read().await.is_empty());
}
