use super::*;

#[test]
fn the_relay_is_a_braid_carrier_on_the_last_rung() {
    let tls = RelayTls::default();
    let url = Url::parse("wss://relay.example.test/v1/relay").unwrap();
    let rung = RelaySocketRung {
        endpoint: &url,
        authorization: None,
        maximum_message_bytes: 1024,
        tls: &tls,
    };
    assert_eq!(rung.kind(), CarrierKind::WssRelay);
    assert_eq!(rung.kind().rung(), cmux_braid_carrier::Rung::LastResort);
    let endpoint = carrier_endpoint(&url);
    assert_eq!(endpoint.address, "relay.example.test:443");
    assert!(endpoint.on_443());
    let plain = carrier_endpoint(&Url::parse("ws://127.0.0.1:8080/x").unwrap());
    assert_eq!((plain.address.as_str(), plain.port()), ("127.0.0.1:8080", Some(8080)));
    let v6 = carrier_endpoint(&Url::parse("ws://[::1]/x").unwrap());
    assert_eq!((v6.address.as_str(), v6.host.as_str()), ("[::1]:80", "::1"));
}

#[test]
fn a_relay_failure_survives_the_carrier_error() {
    let refused = io::Error::other(RelayOpenFailure(RelaySocketConnectError::Authentication));
    assert!(matches!(from_io(refused), RelaySocketConnectError::Authentication));
    let other = from_io(io::Error::new(io::ErrorKind::TimedOut, "slow"));
    let RelaySocketConnectError::Provider(error) = other else { panic!("not a provider error") };
    assert!(error.to_string().contains("slow"), "{error}");
    assert!(error.is_retryable_carrier_failure(), "{error}");
}

#[tokio::test]
async fn the_relay_rung_opens_only_relay_endpoints() {
    let tls = RelayTls::default();
    let url = Url::parse("ws://127.0.0.1:9/").unwrap();
    let rung = RelaySocketRung {
        endpoint: &url,
        authorization: None,
        maximum_message_bytes: 8,
        tls: &tls,
    };
    let mut endpoint = carrier_endpoint(&url);
    endpoint.kind = CarrierKind::LocalHub;
    let Err(error) = rung.open(&endpoint).await else {
        panic!("opened another carrier's endpoint")
    };
    assert!(error.to_string().contains("another carrier"), "{error}");
}
