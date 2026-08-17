#[test]
fn chrome_smoke_requires_configured_browser() -> anyhow::Result<()> {
    let binary = configured_browser_binary(
        std::env::var("CMUX_MUX_BROWSER_TEST").ok().as_deref(),
        std::env::var_os("CMUX_MUX_BROWSER_TEST_CHROME"),
    )?;
    let chrome = cmux_tui_cdp::Chrome::launch(binary.into()).unwrap();
    let (tx, _rx) = std::sync::mpsc::sync_channel(cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY);
    let client = cmux_tui_cdp::CdpClient::connect(chrome.web_socket_url(), tx).unwrap();
    client.set_discover_targets(true).unwrap();
    let target = client.create_target("about:blank").unwrap();
    let session = client.attach_to_target(&target).unwrap();
    client.page_enable(&session).unwrap();
    Ok(())
}

#[test]
fn missing_browser_configuration_is_an_error_when_explicitly_requested() {
    assert!(configured_browser_binary(None, None).is_err());
    assert!(configured_browser_binary(Some("1"), None).is_err());
}
