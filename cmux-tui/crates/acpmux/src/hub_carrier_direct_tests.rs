use super::*;

#[test]
fn only_private_and_loopback_addresses_take_the_direct_path() {
    for yes in [
        "10.138.0.38",
        "172.16.0.1",
        "192.168.1.2",
        "127.0.0.1",
        "::1",
        "fd00::1",
        "::ffff:10.0.0.1",
    ] {
        assert!(private_address(yes.parse().unwrap()), "{yes}");
    }
    for no in ["8.8.8.8", "100.127.178.43", "fd7a:115c:a1e0::1", "2600::1", "::ffff:1.1.1.1"] {
        assert!(!private_address(no.parse().unwrap()), "{no}");
    }
}

#[test]
fn the_ipv4_lookup_returns_ipv4_addresses_on_the_asked_port() {
    let found = lookup_v4("localhost", 47791).unwrap();
    assert!(!found.is_empty());
    assert!(found.iter().all(|a| a.is_ipv4() && a.port() == 47791), "{found:?}");
    assert!(lookup_v4("127.0.0.1", 9).unwrap().contains(&"127.0.0.1:9".parse().unwrap()));
    assert!(lookup_v4("bad\0name", 9).is_err());
}

#[test]
fn the_direct_address_is_the_first_private_non_loopback_one() {
    let all = ["127.0.0.1:1", "100.64.0.2:1", "10.138.0.105:1", "10.138.0.7:1"]
        .map(|a| a.parse::<SocketAddr>().unwrap());
    assert_eq!(first_direct(all), Some("10.138.0.105:1".parse().unwrap()));
    assert_eq!(first_direct(["127.0.0.1:1".parse::<SocketAddr>().unwrap()]), None);
}

#[tokio::test]
async fn a_numeric_private_name_resolves_by_the_ipv4_fallback() {
    assert_eq!(
        resolve_v4("10.138.0.105", 47791).await,
        Some("10.138.0.105:47791".parse().unwrap())
    );
    assert_eq!(resolve_v4("127.0.0.1", 47791).await, None);
}

#[test]
fn a_miss_holds_a_machine_off_the_direct_path() {
    let direct = Direct::default();
    assert!(!direct.held_off("k"));
    direct.miss("k");
    assert!(direct.held_off("k"));
    assert!(!direct.held_off("other"));
}
