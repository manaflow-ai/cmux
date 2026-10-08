#[test]
#[ignore = "requires a configured Chrome or Chromium binary; invoke explicitly with --ignored"]
fn chrome_smoke_requires_configured_browser() -> anyhow::Result<()> {
    let binary = configured_browser_binary(
        std::env::var("CMUX_MUX_BROWSER_TEST").ok().as_deref(),
        std::env::var_os("CMUX_MUX_BROWSER_TEST_CHROME"),
    )?;
    let chrome = TestChrome::launch(&binary)?;
    let (tx, _rx) = std::sync::mpsc::sync_channel(cmux_tui_cdp::CDP_EVENT_QUEUE_CAPACITY);
    let client = cmux_tui_cdp::CdpClient::connect(&chrome.web_socket_url, tx)?;
    client.set_discover_targets(true)?;
    let target = client.create_target("about:blank")?;
    let session = client.attach_to_target(&target)?;
    client.page_enable(&session)?;
    Ok(())
}

/// A headless Chrome for this test only. cmux itself launches no browser
/// (cx-2u5k: no cmux process opens a loopback DevTools port).
struct TestChrome {
    child: std::process::Child,
    profile: std::path::PathBuf,
    web_socket_url: String,
}

impl TestChrome {
    fn launch(binary: &std::path::Path) -> anyhow::Result<TestChrome> {
        use std::io::BufRead;
        let profile =
            std::env::temp_dir().join(format!("cmux-tui-cdp-smoke-{}", std::process::id()));
        std::fs::create_dir_all(&profile)?;
        let mut child = std::process::Command::new(binary)
            .args([
                "--headless=new",
                "--remote-debugging-port=0",
                "--no-first-run",
                "--no-default-browser-check",
                &format!("--user-data-dir={}", profile.display()),
                "about:blank",
            ])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()?;
        let stderr = child.stderr.take().ok_or_else(|| anyhow::anyhow!("no Chrome stderr"))?;
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in std::io::BufReader::new(stderr).lines().map_while(Result::ok) {
                if let Some(url) = line.split("DevTools listening on ").nth(1) {
                    let _ = tx.send(url.trim().to_owned());
                }
            }
        });
        let mut chrome = TestChrome { child, profile, web_socket_url: String::new() };
        chrome.web_socket_url = rx
            .recv_timeout(std::time::Duration::from_secs(20))
            .map_err(|_| anyhow::anyhow!("Chrome published no DevTools endpoint within 20 s"))?;
        Ok(chrome)
    }
}

impl Drop for TestChrome {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.profile);
    }
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

#[test]
fn missing_browser_configuration_is_an_error_when_explicitly_requested() {
    assert!(configured_browser_binary(None, None).is_err());
    assert!(configured_browser_binary(Some("1"), None).is_err());
    assert!(configured_browser_binary(Some("1"), Some(std::ffi::OsString::new())).is_err());
}
