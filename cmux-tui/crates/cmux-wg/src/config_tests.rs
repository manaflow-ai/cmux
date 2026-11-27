use super::*;

const KEY_A: &str = "GDYq0RJ4LWL6jJhLMAlM1oHcCTdSiXPMZ4X5D8WzGdw=";
const KEY_B: &str = "Bo2I0OcpKnXtElGwH6EXV3MwDQctaIrFJ4tDX44DoWs=";

/// A full packet at the default MTU, wrapped, fits a GCP VPC's 1460-byte
/// path over IPv4 and IPv6. At 1420 it was a 1480-byte IPv4 datagram, which
/// the kernel refused (EMSGSIZE) inside a UDP GSO message.
#[test]
fn the_default_mtu_fits_a_gcp_path_after_wireguard_overhead() {
    assert!(DEFAULT_MTU <= 1380, "default MTU {DEFAULT_MTU} is over 1380");
    for overhead in [OVERHEAD_V4, OVERHEAD_V6] {
        assert!(DEFAULT_MTU + overhead <= SMALLEST_CLOUD_PATH_MTU);
    }
    let unset = format!(
        "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
    );
    assert_eq!(WgConfig::parse_wg_quick(&unset).unwrap().mtu, DEFAULT_MTU);
}

#[test]
fn the_inner_mtu_is_the_path_less_the_overhead_never_below_the_floor() {
    assert_eq!(inner_mtu_for_path(1500, false), 1440);
    assert_eq!(inner_mtu_for_path(1500, true), 1420);
    assert_eq!(inner_mtu_for_path(1460, false), 1400);
    assert_eq!(inner_mtu_for_path(1460, true), 1380);
    assert_eq!(inner_mtu_for_path(600, true), MIN_MTU);
    assert_eq!(inner_mtu_for_path(0, false), MIN_MTU);
}

#[test]
fn rejects_missing_and_malformed_fields() {
    let missing_key = format!(
        "[Interface]\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
    );
    assert_eq!(WgConfig::parse_wg_quick(&missing_key).unwrap_err(), ConfigError::MissingPrivateKey);

    let bad_key = format!(
        "[Interface]\nPrivateKey=short\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
    );
    let error = WgConfig::parse_wg_quick(&bad_key).unwrap_err();
    assert!(matches!(error, ConfigError::InvalidValue { key: "PrivateKey", .. }));
    assert!(!error.to_string().contains("short"));

    let two_peers = format!(
        "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.2.0.0/24\n"
    );
    assert_eq!(WgConfig::parse_wg_quick(&two_peers).unwrap_err(), ConfigError::MultiplePeers);

    let small_mtu = format!(
        "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32\nMTU=100\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
    );
    assert!(matches!(
        WgConfig::parse_wg_quick(&small_mtu),
        Err(ConfigError::InvalidValue { key: "MTU", .. })
    ));

    let bad_endpoint = format!(
        "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\nEndpoint=fd00::1:51820\n"
    );
    assert!(matches!(
        WgConfig::parse_wg_quick(&bad_endpoint),
        Err(ConfigError::InvalidValue { key: "Endpoint", .. })
    ));

    let bad_prefix = format!(
        "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/40\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
    );
    assert!(matches!(
        WgConfig::parse_wg_quick(&bad_prefix),
        Err(ConfigError::InvalidValue { key: "Address", .. })
    ));

    let stray = format!("PrivateKey={KEY_A}\n");
    assert_eq!(WgConfig::parse_wg_quick(&stray).unwrap_err(), ConfigError::MalformedLine(1));

    let three_addresses = format!(
        "[Interface]\nPrivateKey={KEY_A}\nAddress=10.1.0.2/32, 10.1.0.3/32, 10.1.0.4/32\n[Peer]\nPublicKey={KEY_B}\nAllowedIPs=10.1.0.0/24\n"
    );
    assert_eq!(
        WgConfig::parse_wg_quick(&three_addresses).unwrap_err(),
        ConfigError::TooManyAddresses { maximum: 2 }
    );
}
