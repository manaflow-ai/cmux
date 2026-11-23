use super::*;

#[test]
fn a_step_line_streams_as_its_event_with_every_field() {
    let line = json!({"device": "studio-mac", "step": "app", "state": "ok",
                      "detail": "NIGHTLY 2100 is current", "fix": ""});
    assert_eq!(
        step_event(line),
        json!({"event": "device-setup-step", "device": "studio-mac", "step": "app",
               "state": "ok", "detail": "NIGHTLY 2100 is current", "fix": ""})
    );
}

#[test]
fn identify_lists_device_setup_v1_once_a_runner_is_installed() {
    device_setup::on_device_setup(device_setup::tests::fake);
    assert!(
        super::super::capabilities::advertised_capabilities(false)
            .contains(&device_setup::CAPABILITY)
    );
}
