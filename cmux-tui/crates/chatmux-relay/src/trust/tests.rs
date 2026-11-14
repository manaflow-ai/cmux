use super::*;

fn paired_config() -> Config {
    Config {
        backend: "https://api.chatmux.dev".to_owned(),
        device_id: "dev_1234".to_owned(),
        token: "credential-1".to_owned(),
        ..Config::default()
    }
}

#[test]
fn observe_and_supervised_do_not_retain_autonomous_authority() {
    let mut config = paired_config();
    config.trust = Some("observe".to_owned());
    config.yolo_confirmed_at = yolo_confirmation_receipt(&config, 1_755_000_000_000);
    assert_eq!(effective_local_trust(&config), Trust::Observe);
    // A receipt for the same identity stays valid but grants nothing
    // until autonomous is requested again.
    assert!(has_yolo_confirmation(&config));
}
