use super::*;

#[tokio::test]
async fn client_and_server_halves_agree_on_the_wire() {
    let (mut client, mut server) = tokio::io::duplex(256);
    let target: SocketAddr = "[fd7a::10]:1337".parse().unwrap();
    let server_side = async {
        assert_eq!(server_greet(&mut server, None, false).await.unwrap(), Greeting::Authenticated);
        let request = server_read_request(&mut server).await.unwrap();
        assert_eq!(request.command, COMMAND_CONNECT);
        assert_eq!(request.target, Target::Ip(target));
        server_reply(&mut server, REPLY_SUCCEEDED, Some("100.64.0.1:50000".parse().unwrap()))
            .await
            .unwrap();
    };
    let client_side = async { client_connect(&mut client, target, None).await.unwrap() };
    tokio::join!(server_side, client_side);
}

#[tokio::test]
async fn a_client_with_the_token_is_admitted() {
    let (mut client, mut server) = tokio::io::duplex(256);
    let target: SocketAddr = "10.149.25.1:6901".parse().unwrap();
    let server_side = async {
        assert_eq!(
            server_greet(&mut server, Some(b"secret-token"), true).await.unwrap(),
            Greeting::Authenticated
        );
        let request = server_read_request(&mut server).await.unwrap();
        assert_eq!(request.target, Target::Ip(target));
        server_reply(&mut server, REPLY_SUCCEEDED, None).await.unwrap();
    };
    let client_side =
        async { client_connect(&mut client, target, Some(b"secret-token")).await.unwrap() };
    tokio::join!(server_side, client_side);
}

#[tokio::test]
async fn a_hub_with_a_token_refuses_wrong_and_missing_tokens() {
    let target: SocketAddr = "10.149.25.1:6901".parse().unwrap();
    for offered in [Some(&b"wrong-token!"[..]), Some(&b"short"[..]), None] {
        let (mut client, mut server) = tokio::io::duplex(256);
        let (admitted, connected) = tokio::join!(
            server_greet(&mut server, Some(b"secret-token"), false),
            client_connect(&mut client, target, offered),
        );
        assert_eq!(admitted.unwrap(), Greeting::Refused, "{offered:?} must not be admitted");
        assert!(connected.is_err(), "{offered:?} must not connect");
    }
}

/// A hub with a token that leaves an open lane (ssh, which authenticates itself) greets a
/// tokenless client as `Open`, so the hub can narrow it; a wrong token is still refused.
#[tokio::test]
async fn a_tokenless_client_is_open_only_where_the_hub_allows_it() {
    let target: SocketAddr = "10.149.25.1:22".parse().unwrap();
    let (mut client, mut server) = tokio::io::duplex(256);
    let server_side = async {
        assert_eq!(
            server_greet(&mut server, Some(b"secret-token"), true).await.unwrap(),
            Greeting::Open
        );
        let request = server_read_request(&mut server).await.unwrap();
        assert_eq!(request.target, Target::Ip(target));
        server_reply(&mut server, REPLY_SUCCEEDED, None).await.unwrap();
    };
    let client_side = async { client_connect(&mut client, target, None).await.unwrap() };
    tokio::join!(server_side, client_side);

    let (mut client, mut server) = tokio::io::duplex(256);
    let (admitted, connected) = tokio::join!(
        server_greet(&mut server, Some(b"secret-token"), true),
        client_connect(&mut client, target, Some(b"wrong-token!")),
    );
    assert_eq!(admitted.unwrap(), Greeting::Refused);
    assert!(connected.is_err());
}

#[tokio::test]
async fn a_hub_without_a_token_refuses_username_password() {
    let (mut client, mut server) = tokio::io::duplex(256);
    let target: SocketAddr = "10.149.25.1:6901".parse().unwrap();
    let (admitted, connected) = tokio::join!(
        server_greet(&mut server, None, false),
        client_connect(&mut client, target, Some(b"secret-token")),
    );
    assert_eq!(admitted.unwrap(), Greeting::Refused);
    assert!(connected.is_err());
}
