use std::net::Ipv4Addr;

use cmux_proxy::workspace_ip_from_name;

#[test]
fn mapping_examples() {
    assert_eq!(workspace_ip_from_name("workspace-1"), Some(Ipv4Addr::new(127, 18, 0, 1)));
    assert_eq!(workspace_ip_from_name("workspace-256"), Some(Ipv4Addr::new(127, 18, 1, 0)));
    assert_eq!(workspace_ip_from_name("ws-3"), Some(Ipv4Addr::new(127, 18, 0, 3)));
    assert_eq!(workspace_ip_from_name("abc"), None);
}

