#[test]
fn chrome_smoke_is_env_gated() {
    if std::env::var("CMUX_MUX_BROWSER_TEST").ok().as_deref() != Some("1") {
        eprintln!("skipping Chrome smoke test; set CMUX_MUX_BROWSER_TEST=1 to run it");
        return;
    }

    let Some(binary) = std::env::var_os("CMUX_MUX_BROWSER_TEST_CHROME") else {
        eprintln!(
            "skipping Chrome smoke test; set CMUX_MUX_BROWSER_TEST_CHROME to a Chrome binary"
        );
        return;
    };
    let chrome = cmux_tui_cdp::Chrome::launch(binary.into()).unwrap();
    let (tx, _rx) = std::sync::mpsc::sync_channel(cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY);
    let client = cmux_tui_cdp::CdpClient::connect(chrome.web_socket_url(), tx).unwrap();
    client.set_discover_targets(true).unwrap();
    let target = client.create_target("about:blank").unwrap();
    let session = client.attach_to_target(&target).unwrap();
    client.page_enable(&session).unwrap();
}

#[test]
fn missing_browser_configuration_is_an_error_when_explicitly_requested() {
    assert!(configured_browser_binary(None, None).is_err());
    assert!(configured_browser_binary(Some("1"), None).is_err());
    assert!(configured_browser_binary(Some("1"), Some(std::ffi::OsString::new())).is_err());
}
