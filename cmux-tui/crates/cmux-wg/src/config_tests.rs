use super::*;

const KEY_A: &str = "GDYq0RJ4LWL6jJhLMAlM1oHcCTdSiXPMZ4X5D8WzGdw=";
const KEY_B: &str = "Bo2I0OcpKnXtElGwH6EXV3MwDQctaIrFJ4tDX44DoWs=";

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
