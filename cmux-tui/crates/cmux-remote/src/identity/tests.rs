use super::*;

#[test]
fn credential_free_routes_preserve_only_reconnect_material() {
    assert_eq!(credential_free_daemon_name("daemon:dev".into()), "daemon:dev");

    let websocket = url::Url::parse(
        &credential_free_route_hint(
            "wss://user:password@example.test/private?ticket=secret#fragment",
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(websocket.as_str(), "wss://example.test/");

    let ssh = url::Url::parse(
        &credential_free_route_hint(
            "ssh://alice:password@example.test:2222/private?ticket=secret#fragment",
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(ssh.username(), "alice");
    assert_eq!(ssh.password(), None);
    assert_eq!(ssh.host_str(), Some("example.test"));
    assert_eq!(ssh.port(), Some(2222));
    assert!(matches!(ssh.path(), "" | "/"));
    assert!(ssh.query().is_none());
    assert!(ssh.fragment().is_none());

    let unix = url::Url::parse(
        &credential_free_route_hint("unix:///tmp/cmux-remote.sock?ticket=secret#fragment").unwrap(),
    )
    .unwrap();
    assert_eq!(unix.path(), "/tmp/cmux-remote.sock");
    assert!(unix.query().is_none());
    assert!(unix.fragment().is_none());

    let iroh = url::Url::parse(
        &credential_free_route_hint(
            "iroh://node-id?direct=127.0.0.1%3A7777&relay=\
                 https%3A%2F%2Fuser%3Apassword%40relay.test%2Fprivate%3Fticket%3Dsecret&\
                 ticket=drop-me",
        )
        .unwrap(),
    )
    .unwrap();
    let routing = iroh.query_pairs().into_owned().collect::<HashMap<_, _>>();
    assert_eq!(routing["direct"], "127.0.0.1:7777");
    assert_eq!(routing["relay"], "https://relay.test/");
    assert!(!routing.contains_key("ticket"));
}
