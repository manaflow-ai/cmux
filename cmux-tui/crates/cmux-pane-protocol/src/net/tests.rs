use super::*;

#[tokio::test]
async fn accepted_and_dialed_sockets_are_tuned() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (dialed, accepted) = tokio::join!(connect(address), accept(&listener));
    let dialed = dialed.unwrap();
    let (accepted, _) = accepted.unwrap();
    assert!(dialed.nodelay().unwrap());
    assert!(accepted.nodelay().unwrap());
    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    {
        assert_eq!(notsent_lowat(&dialed).unwrap(), NOTSENT_LOWAT);
        assert_eq!(notsent_lowat(&accepted).unwrap(), NOTSENT_LOWAT);
    }
}
