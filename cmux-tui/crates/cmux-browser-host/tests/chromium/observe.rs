//! frame.observe's sensitive-field scan reads within the page-read budget
//! (page-agent.js `readBudget`, browser-host.md frame.observe): when the
//! scan stops at the budget, the read is refused with the read-cut marker
//! (the runtime prints core.readCutNote). It is never scrubbed for only the
//! part the scan reached. A module of the `chromium` test target.

use super::*;

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn an_observe_read_whose_field_scan_is_cut_is_refused() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let driver = CdpDriver::attach_browser(
        chromium.connection().clone(),
        cmux_browser_host::host::agent_bundle(),
        Arc::new(|_| {}),
    )
    .expect("attach to Chromium");
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };
    let target = call("tabs.open", json!({}))["targetId"].as_str().unwrap().to_owned();
    call(
        "tab.navigate",
        json!({"targetId": target, "url": format!("http://127.0.0.1:{port}/second"), "waitUntil": "load"}),
    );
    // 300,000 elements before the password field: the scan reaches the field
    // only past the budget's 250,000 nodes. The echo shows its value.
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => {
          const echo = document.createElement('p'); echo.id = 'echo'; echo.textContent = 's3cret-pass';
          document.body.append(echo);
          const many = document.createDocumentFragment();
          for (let i = 0; i < 300000; i++) many.append(document.createElement('i'));
          document.body.append(many);
          const pw = document.createElement('input'); pw.type = 'password'; pw.value = 's3cret-pass';
          document.body.append(pw);
        }"}),
    );
    let observe = |method: &str, args: Value| {
        driver
            .call(
                "frame.observe",
                &json!({"targetId": target, "method": method, "args": args, "timeoutMs": 30000}),
            )
            .unwrap_or_else(|error| panic!("observe {method}: {error}"))
    };
    let handles = observe("queryAll", json!(["#echo"]));
    let echo = handles[0].clone();
    assert!(echo.is_string(), "{handles}");

    // An unscoped read (the whole frame) whose scan stops is refused.
    let cut = observe("snapshot", json!([{}]));
    assert!(!cut.to_string().contains("s3cret"), "a cut scan leaked the value: {cut}");
    let marker = &cut["__cmuxReplyCut"];
    assert_eq!(marker["truncated"], "nodes", "the read is refused with the cut marker: {cut}");
    assert_eq!(marker["maxNodes"], 250_000, "{cut}");
    assert_eq!(marker["scope"], "frame", "the runtime tells the agent to scope the read: {cut}");

    // Within the budget the scan reaches the field and the read is scrubbed.
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source":
            "() => { for (const i of [...document.getElementsByTagName('i')]) i.remove(); }"}),
    );
    assert_eq!(observe("read", json!([echo, "textContent"])), "********");
    call("tabs.close", json!({"targetId": target}));
}

/// A 300,000-element page with one region at its start (for snapshot, read
/// and describe of that region).
fn large_page_with_a_region() -> &'static str {
    "() => {
      const region = document.createElement('section'); region.id = 'region';
      region.innerHTML = '<p id=echo>s3cret-pass</p><input type=password id=pw value=attr-secret-1>' +
        '<button id=b aria-labelledby=farlabel>x</button>';
      document.body.append(region);
      region.querySelector('#pw').value = 's3cret-pass';
      const many = document.createDocumentFragment();
      for (let i = 0; i < 300000; i++) many.append(document.createElement('i'));
      document.body.append(many);
      // Outside the region, past the budget: a label the region's button
      // takes its name from, with a card field in it.
      const far = document.createElement('label'); far.id = 'farlabel';
      far.innerHTML = 'Card <input autocomplete=cc-number id=cc>';
      document.body.append(far);
      far.querySelector('#cc').value = '4111-outside-9';
      const other = document.createElement('p'); other.id = 'other'; other.textContent = 'outside-text-7';
      document.body.append(other);
    }"
}

/// ff's condition on the refusal: a read scoped to a ref (snapshot of a
/// root, read or describe of an element) scans only that part for sensitive
/// fields (plus what it names by id, its labels and slotted nodes), so it
/// works on a page larger than the budget and is still scrubbed.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_scoped_observe_read_of_a_large_page_scans_its_part_and_is_scrubbed() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let driver = CdpDriver::attach_browser(
        chromium.connection().clone(),
        cmux_browser_host::host::agent_bundle(),
        Arc::new(|_| {}),
    )
    .expect("attach to Chromium");
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };
    let target = call("tabs.open", json!({}))["targetId"].as_str().unwrap().to_owned();
    call(
        "tab.navigate",
        json!({"targetId": target, "url": format!("http://127.0.0.1:{port}/second"), "waitUntil": "load"}),
    );
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": large_page_with_a_region()}),
    );
    let observe = |method: &str, args: Value| {
        driver
            .call(
                "frame.observe",
                &json!({"targetId": target, "method": method, "args": args, "timeoutMs": 30000}),
            )
            .unwrap_or_else(|error| panic!("observe {method}: {error}"))
    };
    let handle = |selector: &str| observe("queryAll", json!([selector]))[0].clone();
    let (region, echo) = (handle("#region"), handle("#echo"));

    let snapshot = observe("snapshot", json!([{"root": region}])).to_string();
    assert!(!snapshot.contains("__cmuxReplyCut"), "a scoped snapshot reads: {snapshot}");
    for secret in ["s3cret", "attr-secret", "4111-outside"] {
        assert!(!snapshot.contains(secret), "{secret} leaked: {snapshot}");
    }
    assert!(snapshot.contains("********"), "{snapshot}");
    assert!(!snapshot.contains("outside-text-7"), "only the region is read: {snapshot}");
    assert_eq!(observe("read", json!([echo, "textContent"])), "********");
    let described = observe("describe", json!([echo])).to_string();
    assert!(!described.contains("s3cret") && described.contains("********"), "{described}");
    let region_text = observe("read", json!([region, "textContent"])).to_string();
    assert!(!region_text.contains("s3cret"), "{region_text}");
    assert!(!region_text.contains("outside-text-7"), "{region_text}");

    // The whole frame is refused, and tells the agent to scope the read.
    let whole = observe("snapshot", json!([{}]));
    assert_eq!(whole["__cmuxReplyCut"]["scope"], "frame", "{whole}");
    call("tabs.close", json!({"targetId": target}));
}

/// The same through the whole host and runtime (`cmux-browser-host eval`):
/// snapshot() of the large page fails with a note that says how to scope
/// the read; snapshot of a locator works.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn the_refused_whole_page_read_tells_the_agent_to_scope_it() {
    let binary = std::env::var("CMUX_BROWSER_HOST_TEST_CHROME")
        .ok()
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let dir = std::env::temp_dir().join(format!("cmux-host-scope-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("host.sock");
    let _host = HostGuard::start(&socket, &binary);
    let code = format!(
        "await page.goto({:?}); await page.evaluate({});
         try {{ await snapshot(); console.log('WHOLE:read'); }} catch (e) {{ console.log('WHOLE:' + e.message); }}
         const s = await snapshot(page.locator('#region'));
         console.log('SCOPED:' + (s.tree.includes('s3cret') ? 'leaked' : 'clean') + ':' + s.tree.includes('********'));",
        format!("http://127.0.0.1:{port}/second"),
        large_page_with_a_region()
    );
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
        .args(["eval", "--engine", "headless", "--socket"])
        .arg(&socket)
        .arg("-")
        .current_dir(&dir)
        .env("CMUX_BROWSER_HOST_CHROMIUM", &binary)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("run cmux-browser-host eval");
    child.stdin.take().unwrap().write_all(code.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    let out =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(out.contains("WHOLE:Error: the page is too large to read whole"), "{out}");
    assert!(out.contains("scope the read"), "{out}");
    assert!(out.contains("SCOPED:clean:true"), "{out}");
    let _ = std::fs::remove_dir_all(&dir);
}
