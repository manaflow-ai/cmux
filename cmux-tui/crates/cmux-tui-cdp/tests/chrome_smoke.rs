#[test]
#[ignore = "requires a configured Chrome or Chromium binary; invoke explicitly with --ignored"]
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

fn configured_browser_binary(
    enabled: Option<&str>,
    binary: Option<std::ffi::OsString>,
) -> anyhow::Result<std::path::PathBuf> {
    if enabled != Some("1") {
        anyhow::bail!(
            "Chrome smoke requires CMUX_MUX_BROWSER_TEST=1; run this ignored test explicitly when a browser is configured"
        );
    }
    let binary = binary.filter(|value| !value.is_empty()).ok_or_else(|| {
        anyhow::anyhow!(
            "Chrome smoke requires CMUX_MUX_BROWSER_TEST_CHROME to name a Chrome or Chromium binary"
        )
    })?;
    Ok(binary.into())
}
