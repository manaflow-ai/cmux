use super::*;

#[test]
fn each_platform_has_its_own_deployments_hub() {
    assert_eq!(
        device_hub_of("https://cmux-platform-production.debussy.workers.dev/"),
        Some("https://cmux-device-hub.debussy.workers.dev")
    );
    assert_eq!(
        device_hub_of(" https://cmux-platform-development.debussy.workers.dev"),
        Some("https://cmux-device-hub-dev.debussy.workers.dev")
    );
    for unknown in ["", "https://evil.example", "http://127.0.0.1:1"] {
        assert_eq!(device_hub_of(unknown), None, "{unknown}");
    }
}
