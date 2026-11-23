use super::tune_ws_socket;

#[tokio::test]
async fn an_accepted_web_socket_sends_without_nagle_delay() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let _client = tokio::net::TcpStream::connect(address).await.unwrap();
    let (accepted, _) = listener.accept().await.unwrap();
    assert!(!accepted.nodelay().unwrap(), "a fresh socket has Nagle on");
    tune_ws_socket(&accepted);
    assert!(accepted.nodelay().unwrap());
}
