use super::*;

#[tokio::test]
async fn raw_connection_admission_is_bounded() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let listener = TcpListener::from_std(listener).unwrap();
    let config = RelayConfig { allow_open: true, ..RelayConfig::default() };
    let admission = AdmissionListener::new(listener, &config);
    assert_eq!(admission.permits.available_permits(), config.max_http_connections);
}
