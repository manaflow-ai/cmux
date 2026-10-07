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

    let cut = observe("read", json!([echo, "textContent"]));
    assert!(!cut.to_string().contains("s3cret"), "a cut scan leaked the value: {cut}");
    let marker = &cut["__cmuxReplyCut"];
    assert_eq!(marker["truncated"], "nodes", "the read is refused with the cut marker: {cut}");
    assert_eq!(marker["maxNodes"], 250_000, "{cut}");

    // Within the budget the scan reaches the field and the read is scrubbed.
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source":
            "() => { for (const i of [...document.getElementsByTagName('i')]) i.remove(); }"}),
    );
    assert_eq!(observe("read", json!([echo, "textContent"])), "********");
    call("tabs.close", json!({"targetId": target}));
}
