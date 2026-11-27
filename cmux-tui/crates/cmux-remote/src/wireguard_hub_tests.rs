use super::*;
use cmux_wg::testing::loopback_pair;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::test]
async fn cancelled_hub_dial_releases_its_connection_permit() {
    let pair = loopback_pair().await.unwrap();
    // Keep the peer's UDP socket bound but do not start a peer: the TCP
    // connect cannot finish and must be cancelled by the SOCKS client EOF.
    let net = Arc::new(WgNet::start(pair.client, pair.client_socket).await.unwrap());
    let permits = Arc::new(Semaphore::new(1));
    let (mut client, server) = UnixStream::pair().unwrap();
    let mut served = tokio::spawn({
        let net = Arc::clone(&net);
        let permits = Arc::clone(&permits);
        async move {
            let _permit = permits.acquire_owned().await.unwrap();
            serve_connection(net, server, None).await
        }
    });
    client.write_all(&[5, 1, 0]).await.unwrap();
    let mut greeting = [0; 2];
    client.read_exact(&mut greeting).await.unwrap();
    assert_eq!(greeting, [5, 0]);
    assert_eq!(permits.available_permits(), 0);
    let mut request = vec![5, 1, 0, 4];
    let std::net::IpAddr::V6(remote) = pair.server_v6 else {
        panic!("fixture must provide an IPv6 address");
    };
    request.extend_from_slice(&remote.octets());
    request.extend_from_slice(&1337u16.to_be_bytes());
    client.write_all(&request).await.unwrap();
    drop(client);

    let finished = tokio::time::timeout(Duration::from_secs(1), &mut served).await;
    let released = finished.as_ref().is_ok_and(|result| matches!(result, Ok(Ok(()))));
    if finished.is_err() {
        served.abort();
        let _ = served.await;
    }
    let available = permits.available_permits();
    Arc::try_unwrap(net).unwrap().shutdown().await;
    assert!(released, "SOCKS EOF must release the slot before the 60-second TCP timeout");
    assert_eq!(available, 1);
}
