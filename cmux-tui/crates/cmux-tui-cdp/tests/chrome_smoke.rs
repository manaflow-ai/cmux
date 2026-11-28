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
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let profile =
            std::env::temp_dir().join(format!("cmux-tui-cdp-smoke-{}-{nonce}", std::process::id()));
        std::fs::create_dir_all(&profile)?;
        let spawned = std::process::Command::new(binary)
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
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(error) => {
                let _ = std::fs::remove_dir_all(&profile);
                return Err(error.into());
            }
        };
        let stderr = child.stderr.take().ok_or_else(|| anyhow::anyhow!("no Chrome stderr"))?;
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = std::io::BufReader::new(stderr);
            let _ = tx.send(read_chrome_endpoint(&mut reader));
            // Keep draining after startup so Chrome cannot block on its stderr pipe.
            let _ = std::io::copy(&mut reader, &mut std::io::sink());
        });
        let mut chrome = TestChrome { child, profile, web_socket_url: String::new() };
        chrome.web_socket_url = rx.recv_timeout(std::time::Duration::from_secs(20)).map_err(
            |error| match error {
                std::sync::mpsc::RecvTimeoutError::Timeout => {
                    anyhow::anyhow!("Chrome published no DevTools endpoint within 20 s")
                }
                std::sync::mpsc::RecvTimeoutError::Disconnected => {
                    anyhow::anyhow!(
                        "Chrome stderr reader stopped before publishing a DevTools endpoint"
                    )
                }
            },
        )??;
        Ok(chrome)
    }
}

fn read_chrome_endpoint(reader: &mut impl std::io::BufRead) -> anyhow::Result<String> {
    let mut tail = std::collections::VecDeque::new();
    for line in reader.lines() {
        let line = line?;
        if let Some((_, url)) = line.split_once("DevTools listening on ") {
            return Ok(url.trim().to_owned());
        }
        if tail.len() == 16 {
            tail.pop_front();
        }
        tail.push_back(line.chars().take(512).collect::<String>());
    }
    anyhow::bail!(
        "Chrome closed stderr before publishing a DevTools endpoint; Chrome stderr:\n{}",
        tail.into_iter().collect::<Vec<_>>().join("\n")
    )
}

#[test]
fn chrome_early_exit_retains_bounded_stderr_instead_of_reporting_timeout() {
    let input = format!("{}browser startup failed\n", "old diagnostic\n".repeat(20));
    let error = read_chrome_endpoint(&mut input.as_bytes()).unwrap_err().to_string();
    assert!(error.contains("closed stderr"));
    assert!(error.ends_with("browser startup failed"));
    assert_eq!(error.matches("old diagnostic").count(), 15);
    assert!(!error.contains("20 s"));
}

#[test]
fn chrome_endpoint_is_read_after_startup_diagnostics() {
    let mut input =
        b"startup diagnostic\nDevTools listening on ws://127.0.0.1:1234/devtools/browser/test\n"
            .as_slice();
    assert_eq!(
        read_chrome_endpoint(&mut input).unwrap(),
        "ws://127.0.0.1:1234/devtools/browser/test"
    );
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
