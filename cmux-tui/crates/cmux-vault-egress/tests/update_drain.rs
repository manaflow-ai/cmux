//! A completed CONNECT response must not release the daemon's update drain.
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use cmux_vault_egress::{Admission, Authority, Config, Policy, Resolver};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::Instant;

async fn connect(proxy: SocketAddr) -> (TcpStream, String) {
    let mut stream = TcpStream::connect(proxy).await.unwrap();
    stream
        .write_all(b"CONNECT blind.test:443 HTTP/1.1\r\nHost: blind.test:443\r\n\r\n")
        .await
        .unwrap();
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        header.push(stream.read_u8().await.unwrap());
    }
    (stream, String::from_utf8(header).unwrap())
}

#[tokio::test]
async fn update_waits_for_upgraded_stream_and_reopens_after_deferral() {
    tokio::time::timeout(Duration::from_secs(10), async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let listener = cmux_vault_egress::bind().await.unwrap();
        let proxy = listener.local_addr().unwrap();
        let admission = Arc::new(Admission::default());
        let config = Arc::new(Config {
            policy: Arc::new(|| Arc::new(Policy::new(vec![]))),
            authority: Arc::new(Authority::generate().unwrap()),
            upstream_tls:
                cmux_vault_egress::upstream_tls_with_roots(rustls::RootCertStore::empty()).unwrap(),
            resolver: Resolver::Fixed(HashMap::from([(
                ("blind.test".to_owned(), 443),
                upstream.local_addr().unwrap(),
            )])),
        });
        let serving = tokio::spawn(cmux_vault_egress::serve_with_admission(
            listener,
            config,
            admission.clone(),
        ));
        let (mut client, response) = connect(proxy).await;
        assert!(response.starts_with("HTTP/1.1 200"));
        let (mut target, _) = upstream.accept().await.unwrap();
        let drain = admission.begin_drain();
        assert!(!drain.wait_until(Instant::now() + Duration::from_millis(10)).await);
        let (_, refused) = connect(proxy).await;
        assert!(refused.starts_with("HTTP/1.1 503"));

        // The accepted stream still carries work after CONNECT answered and the drain timed out.
        client.write_all(b"turn").await.unwrap();
        let mut data = [0; 4];
        target.read_exact(&mut data).await.unwrap();
        assert_eq!(&data, b"turn");
        target.write_all(b"done").await.unwrap();
        client.read_exact(&mut data).await.unwrap();
        assert_eq!(&data, b"done");

        drop(drain);
        let (second, response) = connect(proxy).await;
        assert!(response.starts_with("HTTP/1.1 200"), "cancelled drain reopens");
        let (second_target, _) = upstream.accept().await.unwrap();
        let drain = admission.begin_drain();
        drop((client, target, second, second_target));
        assert!(drain.wait_until(Instant::now() + Duration::from_secs(2)).await);
        drain.commit();
        let (_, refused) = connect(proxy).await;
        assert!(refused.starts_with("HTTP/1.1 503"), "committed drain stays fenced");
        serving.abort();
    })
    .await
    .unwrap();
}
