use super::*;
use crate::policy::DomainPattern;

struct FakeDriver {
    filter: Mutex<Option<crate::driver::RequestFilter>>,
    calls: Mutex<Vec<(String, Value)>>,
    focused_url: Value,
    page_text: String,
    /// What the capture-mask check reports after a capture.
    mask_held: std::sync::atomic::AtomicBool,
    /// net.fetch: a redirect hop the engine checks with the request filter
    /// (a refused hop fails the fetch), then this reply.
    fetch_hop: Mutex<Option<String>>,
    fetch_reply: Mutex<Value>,
}

impl Driver for FakeDriver {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        self.calls.lock().unwrap().push((method.to_owned(), params.clone()));
        match method {
            "frame.evaluate" => {
                let source = params["source"].as_str().unwrap_or("");
                if source.contains("cmux-capture-held") {
                    Ok(json!(self.mask_held.load(std::sync::atomic::Ordering::SeqCst)))
                } else if source.contains("cmux-capture-mask") {
                    Ok(json!(1))
                } else {
                    Ok(self.focused_url.clone())
                }
            }
            "tab.info" => Ok(json!({"title": self.page_text, "url": "https://peer.test/page"})),
            "cookies.get" => Ok(json!([
                {"name": "p", "value": "1", "domain": ".peer.test", "path": "/"},
                {"name": "a", "value": "1", "domain": "a.test", "path": "/"}
            ])),
            "tab.navigate" => Err(DriverError::invalid(format!("failed: {}", self.page_text))),
            "net.fetch" => {
                if let Some(hop) = self.fetch_hop.lock().unwrap().clone() {
                    let filter = self.filter.lock().unwrap().clone();
                    let refused = filter.as_ref().and_then(|f| {
                        f(&crate::driver::RequestInfo {
                            target: params["targetId"].as_str().unwrap_or(""),
                            url: &hop,
                            kind: crate::driver::RequestKind::Subresource,
                        })
                    });
                    if refused.is_some() {
                        return Err(DriverError::new(
                            ErrorCode::Evaluation,
                            "fetch: Failed to fetch",
                        ));
                    }
                }
                Ok(self.fetch_reply.lock().unwrap().clone())
            }
            _ => Ok(Value::Null),
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        Vec::new()
    }

    fn set_request_filter(&self, filter: Option<crate::driver::RequestFilter>) -> bool {
        *self.filter.lock().unwrap() = filter;
        true
    }
}

/// The runtime's synchronous natives (main's ABI): `secrets(op, args)` and
/// `policy(op, args)`.
fn secrets(gate: &Gate, op: &str, args: Value) -> Result<Value, String> {
    gate.native("secrets", json!({"op": op, "args": args}))
}

fn policy(gate: &Gate, op: &str, args: Value) -> Result<Value, String> {
    gate.native("policy", json!({"op": op, "args": args}))
}

fn agent_secret(gate: &Gate, domain: &str) {
    secrets(gate, "set", json!({"name": "pw", "value": "s3cret-value", "domains": [domain]}))
        .unwrap();
}

fn make_gate(focused_url: Value, raw_cdp: bool) -> (Gate, Arc<FakeDriver>) {
    let driver = Arc::new(FakeDriver {
        filter: Mutex::new(None),
        calls: Mutex::new(Vec::new()),
        focused_url,
        page_text: "token s3cret-value here".into(),
        mask_held: std::sync::atomic::AtomicBool::new(true),
        fetch_hop: Mutex::new(None),
        fetch_reply: Mutex::new(Value::Null),
    });
    (Gate::new(driver.clone(), Grants { raw_cdp, ..Grants::default() }), driver)
}

fn methods(driver: &FakeDriver) -> Vec<String> {
    driver.calls.lock().unwrap().iter().map(|(m, _)| m.clone()).collect()
}

#[test]
fn blocked_navigation_never_reaches_the_driver() {
    let (gate, driver) = make_gate(Value::Null, false);
    let layer = Layer {
        allowed: Some(vec![DomainPattern::parse("example.com").unwrap()]),
        prohibited: Vec::new(),
        block_ips: false,
    };
    gate.set_owner_policy(layer, true).unwrap();
    let error = gate
        .driver_call("tab.navigate", json!({"targetId": "T", "url": "https://evil.test/"}))
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    assert_eq!(
        error.message,
        "page.goto: https://evil.test/ is blocked: not in session.allowedDomains (example.com)"
    );
    let opened = gate.driver_call("tabs.open", json!({"url": "file:///etc/passwd"})).unwrap_err();
    assert!(
        opened.message.starts_with("tabs.open: file:///etc/passwd is blocked: file: URLs"),
        "{}",
        opened.message
    );
    assert!(methods(&driver).is_empty());
}

#[test]
fn vm_code_cannot_widen_a_locked_policy() {
    let (gate, _) = make_gate(Value::Null, false);
    let layer = Layer {
        allowed: Some(vec![DomainPattern::parse("example.com").unwrap()]),
        prohibited: Vec::new(),
        block_ips: false,
    };
    gate.set_owner_policy(layer, true).unwrap();
    // The VM "allows" another domain: the base layer still refuses it.
    policy(&gate, "set", json!({"allowed": ["evil.test", "example.com"]})).unwrap();
    assert!(
        gate.driver_call("tab.navigate", json!({"targetId": "T", "url": "https://evil.test/"}))
            .is_err()
    );
    let got = policy(&gate, "get", json!({})).unwrap();
    assert_eq!(got["locked"], true);
    assert!(gate.set_owner_policy(Layer::default(), false).is_err());
}

#[test]
fn vm_code_never_reaches_the_host_world() {
    let (gate, driver) = make_gate(Value::Null, false);
    let error = gate
        .driver_call(
            "frame.evaluate",
            json!({"targetId": "T", "world": "host", "source": "() => 1"}),
        )
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    assert!(methods(&driver).is_empty());
}

#[test]
fn raw_cdp_and_content_rules_need_the_host() {
    let (gate, driver) = make_gate(Value::Null, false);
    assert_eq!(
        gate.driver_call("cdp", json!({"targetId": "T", "method": "DOM.getDocument"}))
            .unwrap_err()
            .code,
        ErrorCode::Forbidden
    );
    assert_eq!(
        gate.driver_call(
            "session.configure",
            json!({"contentRules": [{"action": {"type": "ignore-previous-rules"}}]})
        )
        .unwrap_err()
        .code,
        ErrorCode::Forbidden
    );
    assert!(methods(&driver).is_empty());
}

#[test]
fn secret_handles_resolve_only_in_matching_frames() {
    let (gate, driver) = make_gate(json!("https://login.example.com/form"), false);
    agent_secret(&gate, "*.example.com");
    gate.driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
        .unwrap();
    let calls = driver.calls.lock().unwrap();
    assert_eq!(calls.last().unwrap().1["text"], "s3cret-value", "the driver gets the value");
    drop(calls);

    let (other, other_driver) = make_gate(json!("https://evil.test/"), false);
    agent_secret(&other, "*.example.com");
    let error = other
        .driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    assert!(!error.message.contains("s3cret"));
    assert_eq!(methods(&other_driver), vec!["frame.evaluate"], "nothing was typed");

    let (unknown, _) = make_gate(Value::Null, false);
    agent_secret(&unknown, "example.com");
    assert!(
        unknown
            .driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
            .is_err(),
        "unverifiable focus refuses"
    );

    let (raw, _) = make_gate(json!("https://example.com/"), true);
    agent_secret(&raw, "example.com");
    let refused = raw
        .driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
        .unwrap_err();
    assert!(refused.message.contains("raw CDP"), "{}", refused.message);
}

#[test]
fn results_and_errors_going_back_into_the_vm_are_masked() {
    let (gate, _) = make_gate(Value::Null, false);
    gate.load_secret("pw", "s3cret-value", &["example.com".into()], false).unwrap();
    let info = gate.driver_call("tab.info", json!({"targetId": "T"})).unwrap();
    assert_eq!(info["title"], "token <secret:pw> here");
    let error = gate
        .driver_call("tab.navigate", json!({"targetId": "T", "url": "https://example.com/"}))
        .unwrap_err();
    assert_eq!(error.message, "failed: token <secret:pw> here");
    assert_eq!(gate.mask("x s3cret-value"), "x <secret:pw>");
}

#[test]
fn natives_expose_names_never_values() {
    let (gate, _) = make_gate(Value::Null, false);
    let set =
        secrets(&gate, "set", json!({"name": "api", "value": "k-123", "domains": ["example.com"]}));
    assert_eq!(set.unwrap(), json!({"name": "api", "domains": ["example.com"], "totp": false}));
    gate.load_secret("pw", "s3cret-value", &["example.com".into()], false).unwrap();
    let list = secrets(&gate, "list", json!({})).unwrap();
    assert!(!list.to_string().contains("s3cret") && !list.to_string().contains("k-123"));
    assert_eq!(list[0]["agentKnown"], true);
    assert_eq!(list[1]["agentKnown"], false);
    assert_eq!(secrets(&gate, "has", json!({"name": "api"})).unwrap(), json!(true));
    assert_eq!(secrets(&gate, "delete", json!({"name": "api"})).unwrap(), json!(true));
    assert_eq!(secrets(&gate, "has", json!({"name": "api"})).unwrap(), json!(false));
    assert!(
        secrets(&gate, "set", json!({"name": "bad name", "value": "v", "domains": ["a.test"]}))
            .is_err()
    );
}

#[test]
fn owner_secrets_are_not_typed_until_tabs_can_be_sealed() {
    let (gate, driver) = make_gate(json!("https://example.com/"), false);
    gate.load_secret("pw", "s3cret-value", &["example.com".into()], false).unwrap();
    let error = gate
        .driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    assert!(error.message.contains("sealed"), "{}", error.message);
    assert!(!methods(&driver).contains(&"input.insertText".to_string()));
}

#[test]
fn vm_code_cannot_replace_or_delete_owner_secrets() {
    let (gate, _) = make_gate(Value::Null, false);
    gate.load_secret("pw", "s3cret-value", &["example.com".into()], false).unwrap();
    assert!(
        secrets(&gate, "set", json!({"name": "pw", "value": "other", "domains": ["evil.test"]}))
            .is_err()
    );
    assert!(secrets(&gate, "delete", json!({"name": "pw"})).is_err());
    // clear removes the agent's secrets only.
    secrets(&gate, "set", json!({"name": "api", "value": "k-123", "domains": ["a.test"]})).unwrap();
    secrets(&gate, "clear", json!({})).unwrap();
    let names: Vec<String> = secrets(&gate, "list", json!({}))
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names, vec!["pw".to_owned()]);
    assert_eq!(gate.mask("s3cret-value"), "<secret:pw>", "the owner secret is intact");
}

#[test]
fn null_content_rules_are_refused_too() {
    let (gate, driver) = make_gate(Value::Null, false);
    let error = gate.driver_call("session.configure", json!({"contentRules": null})).unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    assert!(methods(&driver).is_empty());
}

#[test]
fn error_names_are_masked() {
    struct NamedError;
    impl Driver for NamedError {
        fn call(&self, _: &str, _: &Value) -> Result<Value, DriverError> {
            let mut error = DriverError::new(ErrorCode::Evaluation, "boom");
            error.error_name = Some("s3cret-value".into());
            Err(error)
        }
        fn capabilities(&self) -> Vec<&'static str> {
            Vec::new()
        }
    }
    let gate = Gate::new(Arc::new(NamedError), Grants::default());
    gate.load_secret("pw", "s3cret-value", &["example.com".into()], false).unwrap();
    let error = gate.driver_call("tab.info", json!({"targetId": "T"})).unwrap_err();
    assert_eq!(error.error_name.as_deref(), Some("<secret:pw>"));
}

fn sub(url: &str) -> crate::driver::RequestInfo<'_> {
    crate::driver::RequestInfo { target: "T", url, kind: crate::driver::RequestKind::Subresource }
}

#[test]
fn an_active_policy_installs_a_request_filter_on_the_driver() {
    let (gate, driver) = make_gate(Value::Null, false);
    let layer = Layer {
        allowed: Some(vec![DomainPattern::parse("example.com").unwrap()]),
        prohibited: Vec::new(),
        block_ips: false,
    };
    gate.set_owner_policy(layer, false).unwrap();
    let filter = driver.filter.lock().unwrap().clone().expect("a request filter");
    assert!(filter(&sub("https://example.com/app.js")).is_none());
    assert!(
        filter(&sub("https://evil.test/beacon?d=1")).unwrap().contains("session.allowedDomains")
    );
    assert!(filter(&sub("data:text/plain,x")).is_none());
    // Narrowing from the VM updates the filter.
    policy(&gate, "set", json!({"prohibited": ["example.com"]})).unwrap();
    let filter = driver.filter.lock().unwrap().clone().unwrap();
    assert!(filter(&sub("https://example.com/")).is_some());
}

#[test]
fn secrets_load_takes_main_s_map_shape() {
    let (gate, _) = make_gate(Value::Null, false);
    let loaded = secrets(
        &gate,
        "load",
        json!({"object": {"example.com": {"api": "k-1", "otp": {"value": "JBSWY3DPEHPK3PXP", "totp": true}}, "*.example.org": {"api": "k-1"}}}),
    )
    .unwrap();
    let api = loaded.as_array().unwrap().iter().find(|s| s["name"] == "api").unwrap().clone();
    // Patterns come in key order of the parsed map (serde_json sorts keys).
    assert_eq!(
        api,
        json!({"name": "api", "domains": ["*.example.org", "example.com"], "totp": false})
    );
    assert!(loaded.to_string().contains("\"totp\":true"));
    assert!(!loaded.to_string().contains("k-1"));
}

#[test]
fn policy_ops_answer_get_check_set_and_site() {
    let (gate, _) = make_gate(Value::Null, false);
    assert_eq!(
        policy(&gate, "get", json!({})).unwrap(),
        json!({"allowed": null, "prohibited": [], "blockIPs": false, "locked": false})
    );
    assert_eq!(policy(&gate, "check", json!({"url": "https://a.test/"})).unwrap(), Value::Null);
    let set = policy(
        &gate,
        "set",
        json!({"prohibited": ["a.test"], "title": "session.prohibitedDomains"}),
    )
    .unwrap();
    assert_eq!(set["prohibited"], json!(["a.test"]));
    let reason = policy(&gate, "check", json!({"url": "https://a.test/x"})).unwrap();
    assert!(reason.as_str().unwrap().contains("session.prohibitedDomains"), "{reason}");
    policy(&gate, "set", json!({"blockIPs": true, "title": "session.blockIPAddresses"})).unwrap();
    assert_eq!(policy(&gate, "get", json!({})).unwrap()["blockIPs"], true);
    policy(
        &gate,
        "set",
        json!({"allowed": ["b.test"], "lock": true, "title": "session.allowedDomains"}),
    )
    .unwrap();
    let locked = policy(&gate, "set", json!({"allowed": null, "title": "session.allowedDomains"}))
        .unwrap_err();
    assert_eq!(locked, "session.allowedDomains: the domain policy is locked for this session");
    for (host, site) in [
        ("www.example.com", "example.com"),
        ("a.b.example.co.uk", "example.co.uk"),
        ("x.co.at", "x.co.at"),
        ("localhost", "localhost"),
        ("127.0.0.1", "127.0.0.1"),
    ] {
        assert_eq!(policy(&gate, "site", json!({"host": host})).unwrap(), json!(site), "{host}");
    }
    assert!(policy(&gate, "nope", json!({})).is_err());
}

/// frame.observe reads a tab another session holds, so a secret one
/// session typed into a tab is masked for every session of the host, and
/// the record ends when the tab closes.
#[test]
fn a_secret_typed_into_a_tab_is_masked_for_every_session() {
    let shared = Arc::new(TabSecrets::default());
    let (typer, _) = make_gate(json!("https://example.com/login"), false);
    let typer = typer.with_tab_secrets(shared.clone());
    let (reader, _) = make_gate(Value::Null, false);
    let reader = reader.with_tab_secrets(shared);
    agent_secret(&typer, "example.com");
    let before = reader.driver_call("tab.info", json!({"targetId": "T"})).unwrap();
    assert_eq!(before["title"], "token s3cret-value here", "nothing typed into T yet");
    typer
        .driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
        .unwrap();
    let info = reader.driver_call("tab.info", json!({"targetId": "T"})).unwrap();
    assert_eq!(info["title"], "token <secret:pw> here");
    let other_tab = reader.driver_call("tab.info", json!({"targetId": "U"})).unwrap();
    assert_eq!(other_tab["title"], "token s3cret-value here", "only the typed tab");
    let error = reader
        .driver_call("tab.navigate", json!({"targetId": "T", "url": "https://example.com/"}))
        .unwrap_err();
    assert_eq!(error.message, "failed: token <secret:pw> here");
    let event = reader.mask_event("tab.gone", &json!({"targetId": "T", "t": "s3cret-value"}));
    assert_eq!(event["t"], "<secret:pw>");
    let after = reader.driver_call("tab.info", json!({"targetId": "T"})).unwrap();
    assert_eq!(after["title"], "token s3cret-value here", "the record ends with the tab");
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

#[test]
fn main_secret_insert_types_the_named_secret_and_never_a_text_with_it() {
    let (gate, driver) = make_gate(json!("https://login.example.com/form"), false);
    agent_secret(&gate, "*.example.com");
    gate.driver_call("input.insertText", json!({"targetId": "T", "secret": "pw"})).unwrap();
    let last = driver.calls.lock().unwrap().last().unwrap().1.clone();
    assert_eq!(last["text"], "s3cret-value", "the driver types the value");
    assert!(last.get("secret").is_none(), "{last}");
    let both = gate
        .driver_call("input.insertText", json!({"targetId": "T", "secret": "pw", "text": "x"}))
        .unwrap_err();
    assert_eq!(both.code, ErrorCode::Invalid, "{both}");
    let (elsewhere, _) = make_gate(json!("https://evil.test/"), false);
    agent_secret(&elsewhere, "*.example.com");
    let refused = elsewhere
        .driver_call("input.insertText", json!({"targetId": "T", "secret": "pw"}))
        .unwrap_err();
    assert_eq!(refused.code, ErrorCode::Forbidden);
}

#[test]
fn totp_codes_are_masked_while_a_server_accepts_them() {
    let (gate, _) = make_gate(Value::Null, false);
    let seed = "JBSWY3DPEHPK3PXP";
    secrets(
        &gate,
        "set",
        json!({"name": "otp", "value": seed, "domains": ["example.com"], "totp": true}),
    )
    .unwrap();
    let key = crate::secrets::base32_decode(seed).unwrap();
    let now = now_ms();
    for at in [now - 30_000, now, now + 30_000] {
        let code = crate::secrets::totp(&key, at, 6, 30);
        assert_eq!(gate.mask(&format!("code {code} sent")), "code <secret:otp> sent");
        assert_eq!(gate.mask(&format!("9{code}9")), format!("9{code}9"), "inside a longer number");
        let mut stream = gate.masker().stream();
        let mut out = stream.write(&format!("a {}", &code[..3]));
        out.push_str(&stream.write(&format!("{} b", &code[3..])));
        out.push_str(&stream.finish());
        assert_eq!(out, "a <secret:otp> b", "a code split across writes");
    }
    assert!(!gate.mask(seed).contains(seed), "the seed itself is masked");
}

#[test]
fn bytes_that_are_not_utf8_are_masked_by_their_bytes() {
    let (gate, _) = make_gate(Value::Null, false);
    agent_secret(&gate, "example.com");
    let mut blob = vec![0xff, 0x00];
    blob.extend_from_slice(b"s3cret-value");
    blob.push(0x80);
    let masked = gate.mask_bytes(&blob);
    let has = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
    assert!(!has(&masked, b"s3cret-value"));
    assert!(has(&masked, b"<secret:pw>"));
    assert_eq!((masked[0], *masked.last().unwrap()), (0xff, 0x80));
}

#[test]
fn captures_mask_secret_fields_and_are_refused_when_the_mask_is_dropped() {
    let (gate, driver) = make_gate(Value::Null, false);
    // No secret: a capture is a plain driver call.
    gate.driver_call("tab.screenshot", json!({"targetId": "T"})).unwrap();
    assert_eq!(methods(&driver), vec!["tab.screenshot"]);
    agent_secret(&gate, "example.com");
    driver.calls.lock().unwrap().clear();
    gate.driver_call("tab.screenshot", json!({"targetId": "T"})).unwrap();
    let sources: Vec<String> = driver
        .calls
        .lock()
        .unwrap()
        .iter()
        .map(|(m, p)| {
            if m == "frame.evaluate" {
                p["source"].as_str().unwrap_or("").chars().take(40).collect()
            } else {
                m.clone()
            }
        })
        .collect();
    let at = |needle: &str| sources.iter().position(|s| s.contains(needle)).unwrap_or(usize::MAX);
    assert!(at("cmux-capture-mask") < at("tab.screenshot"), "{sources:?}");
    assert!(at("tab.screenshot") < at("cmux-capture-held"), "{sources:?}");
    assert!(
        driver
            .calls
            .lock()
            .unwrap()
            .iter()
            .all(|(m, p)| m != "frame.evaluate" || p["world"] == "host"),
        "capture masking runs in the host world"
    );
    driver.mask_held.store(false, std::sync::atomic::Ordering::SeqCst);
    let refused = gate.driver_call("tab.screenshot", json!({"targetId": "T"})).unwrap_err();
    assert_eq!(refused.code, ErrorCode::Invalid, "{refused}");
    assert!(refused.message.contains("refused"), "{}", refused.message);
    let pdf = gate.driver_call("tab.pdf", json!({"targetId": "T"})).unwrap_err();
    assert_eq!(pdf.code, ErrorCode::Invalid, "{pdf}");
}

#[test]
fn cookie_calls_follow_the_domain_policy() {
    let (gate, driver) = make_gate(Value::Null, false);
    policy(
        &gate,
        "set",
        json!({"prohibited": ["peer.test"], "title": "session.prohibitedDomains"}),
    )
    .unwrap();
    let get = gate.driver_call("cookies.get", json!({"urls": ["https://peer.test/"]})).unwrap_err();
    assert_eq!(get.code, ErrorCode::Forbidden);
    assert!(
        get.message
            .starts_with("cookies.get: https://peer.test/ is blocked: prohibited by peer.test"),
        "{}",
        get.message
    );
    let listed = gate.driver_call("cookies.get", json!({})).unwrap();
    assert_eq!(
        listed,
        json!([{"name": "a", "value": "1", "domain": "a.test", "path": "/"}]),
        "blocked sites are left out"
    );
    for cookie in [
        json!({"name": "x", "value": "1", "domain": ".peer.test", "path": "/"}),
        json!({"name": "x", "value": "1", "url": "https://peer.test/"}),
    ] {
        let set = gate.driver_call("cookies.set", json!({"cookies": [cookie]})).unwrap_err();
        assert_eq!(set.code, ErrorCode::Forbidden, "{set}");
    }
    // Clearing a tab that shows a blocked site is refused.
    let clear = gate.driver_call("cookies.clear", json!({"targetId": "T"})).unwrap_err();
    assert_eq!(clear.code, ErrorCode::Forbidden, "{clear}");
    assert!(!methods(&driver).contains(&"cookies.set".to_owned()));
    assert!(!methods(&driver).contains(&"cookies.clear".to_owned()));
}

#[test]
fn inputs_are_published_after_the_checks_right_before_dispatch() {
    let (gate, driver) = make_gate(json!("https://login.example.com/form"), false);
    let seen: Arc<Mutex<Vec<(Value, usize)>>> = Arc::default();
    let (sink_seen, sink_driver) = (seen.clone(), driver);
    let sink: crate::driver::EventSink = Arc::new(move |event: crate::protocol::DriverEvent| {
        assert_eq!(event.name, "automation.input");
        // How many inputs the driver had received when the event left.
        let dispatched = sink_driver
            .calls
            .lock()
            .unwrap()
            .iter()
            .filter(|(m, _)| m.starts_with("input."))
            .count();
        sink_seen.lock().unwrap().push((event.payload, dispatched));
    });
    let gate = gate.with_input_events("lease-s", sink);
    agent_secret(&gate, "*.example.com");
    gate.driver_call("input.mouse", json!({"targetId": "T", "type": "move", "x": 1, "y": 2}))
        .unwrap();
    // Refused inputs emit nothing and take no seq.
    gate.driver_call("input.insertText", json!({"targetId": "T", "secret": "pw", "text": "x"}))
        .unwrap_err();
    gate.driver_call("input.insertText", json!({"targetId": "T", "secret": "missing"}))
        .unwrap_err();
    gate.driver_call("input.insertText", json!({"targetId": "T", "secret": "pw"})).unwrap();
    let seen = seen.lock().unwrap();
    let summary: Vec<(u64, &str, usize)> = seen
        .iter()
        .map(|(e, n)| (e["seq"].as_u64().unwrap(), e["kind"].as_str().unwrap(), *n))
        .collect();
    assert_eq!(summary, vec![(0, "move", 0), (1, "type", 1)], "published right before dispatch");
    for (event, _) in seen.iter() {
        assert_eq!(event["session_id"], "lease-s");
        assert_eq!(event["target_id"], "T");
        assert!(!event.to_string().contains("s3cret"), "{event}");
    }
}

fn b64(text: &str) -> String {
    crate::fs_sandbox::base64_encode(text.as_bytes())
}

fn fetch_text(value: &Value) -> String {
    let bytes = crate::fs_sandbox::base64_decode(value["bodyBase64"].as_str().unwrap()).unwrap();
    String::from_utf8(bytes).unwrap()
}

#[test]
fn fetch_runs_in_the_engine_with_the_body_masked() {
    let (gate, driver) = make_gate(Value::Null, false);
    agent_secret(&gate, "a.test");
    *driver.fetch_reply.lock().unwrap() = json!({"url": "https://a.test/x", "status": 200,
        "headers": [], "bodyBase64": b64("token s3cret-value here"), "remoteIPAddress": "93.184.216.34"});
    let out = gate
        .driver_call(
            "net.fetch",
            json!({"targetId": "T", "url": "https://a.test/x", "headers": []}),
        )
        .unwrap();
    assert_eq!(fetch_text(&out), "token <secret:pw> here", "secrets in the body are masked");
    assert!(out.get("remoteIPAddress").is_none(), "{out}");
    let sent =
        driver.calls.lock().unwrap().iter().find(|(m, _)| m == "net.fetch").unwrap().1.clone();
    assert_eq!(sent["maxBytes"], 64 * 1024 * 1024, "main's 64 MiB body limit");
}

#[test]
fn fetch_refuses_policy_ranges_and_forbidden_headers_before_the_engine() {
    let (gate, driver) = make_gate(Value::Null, false);
    let call = |params: Value| gate.driver_call("net.fetch", params).unwrap_err();
    // Without a tab the engine runs the fetch in a shell tab of its own.
    let header =
        call(json!({"targetId": "T", "url": "https://a.test/", "headers": [["Host", "b.test"]]}));
    assert_eq!(header.code, ErrorCode::Invalid, "{header}");
    let metadata =
        call(json!({"targetId": "T", "url": "http://169.254.169.254/latest/meta-data/"}));
    assert_eq!(metadata.code, ErrorCode::Forbidden);
    assert!(metadata.message.contains("link-local"), "{}", metadata.message);
    policy(&gate, "set", json!({"prohibited": ["peer.test"]})).unwrap();
    let prohibited = call(json!({"targetId": "T", "url": "https://peer.test/api"}));
    assert!(
        prohibited
            .message
            .starts_with("fetch: https://peer.test/api is blocked: prohibited by peer.test"),
        "{}",
        prohibited.message
    );
    assert!(!methods(&driver).contains(&"net.fetch".to_owned()), "nothing reached the engine");
    let log = policy(&gate, "log", json!({})).unwrap();
    assert!(log.as_array().unwrap().iter().any(|e| e["url"] == "https://peer.test/api"), "{log}");
}

#[test]
fn fetch_checks_every_redirect_hop_and_the_address_it_reached() {
    let (gate, driver) = make_gate(Value::Null, false);
    // No policy is set: the filter is installed for the fetch's duration.
    *driver.fetch_hop.lock().unwrap() = Some("http://169.254.169.254/latest".into());
    let hop = gate
        .driver_call("net.fetch", json!({"targetId": "T", "url": "https://a.test/r"}))
        .unwrap_err();
    assert_eq!(hop.code, ErrorCode::Forbidden, "{hop}");
    assert!(
        hop.message.starts_with("fetch: redirect to http://169.254.169.254/latest is blocked:"),
        "{}",
        hop.message
    );
    assert!(driver.filter.lock().unwrap().is_none(), "the filter goes when the fetch ends");
    *driver.fetch_hop.lock().unwrap() = None;
    *driver.fetch_reply.lock().unwrap() = json!({"url": "https://rebind.test/", "status": 200,
        "headers": [], "bodyBase64": "", "remoteIPAddress": "169.254.169.254"});
    let rebound = gate
        .driver_call("net.fetch", json!({"targetId": "T", "url": "https://rebind.test/"}))
        .unwrap_err();
    assert_eq!(rebound.code, ErrorCode::Forbidden);
    assert!(rebound.message.contains("resolved to 169.254.169.254"), "{}", rebound.message);
}

/// DNS rebinding for navigations and page requests (a9, v1 after the fact):
/// a response that came from a refused address stops the tab's load and
/// is logged; other responses change nothing.
#[test]
fn a_response_from_a_refused_address_stops_the_load() {
    let (gate, driver) = make_gate(Value::Null, false);
    let response = |url: &str, ip: &str| json!({"targetId": "T", "url": url, "resourceType": "document", "remoteIPAddress": ip});
    gate.mask_event("response", &response("https://fine.test/", "93.184.216.34"));
    gate.mask_event("response", &response("https://rebind.test/", "169.254.169.254"));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !methods(&driver).contains(&"tab.stop".to_owned()) {
        assert!(std::time::Instant::now() < deadline, "the load was never stopped");
        std::thread::yield_now();
    }
    let stops: Vec<Value> = driver
        .calls
        .lock()
        .unwrap()
        .iter()
        .filter(|(m, _)| m == "tab.stop")
        .map(|(_, p)| p.clone())
        .collect();
    assert_eq!(stops, vec![json!({"targetId": "T"})], "only the refused response stops");
    let log = policy(&gate, "log", json!({})).unwrap();
    let entry =
        log.as_array().unwrap().iter().find(|e| e["url"] == "https://rebind.test/").cloned();
    let entry = entry.unwrap_or_else(|| panic!("not logged: {log}"));
    assert_eq!(entry["blocked"], "after");
    assert!(entry["reason"].as_str().unwrap().contains("169.254.169.254"), "{entry}");
}

/// RequestFilter v2 (5c, a9): `kind` changes only logging, never allow or
/// deny. A Subresource (a script; WebSockets never reach Fetch and are
/// blocked by URL pattern) to a blocked host is refused and
/// writes no `blocked: before` line; a Document to it is refused and logged
/// (main logs navigations, not subresources).
#[test]
fn request_kind_changes_logging_only() {
    let (gate, driver) = make_gate(Value::Null, false);
    policy(&gate, "set", json!({"prohibited": ["peer.test"]})).unwrap();
    let filter = driver.filter.lock().unwrap().clone().expect("a request filter");
    let ws = crate::driver::RequestInfo {
        target: "T",
        url: "https://peer.test/app.js",
        kind: crate::driver::RequestKind::Subresource,
    };
    assert!(filter(&ws).is_some(), "a subresource to a blocked host is refused");
    let log = |gate: &Gate| policy(gate, "log", json!({})).unwrap().as_array().unwrap().clone();
    assert!(log(&gate).is_empty(), "a subresource refusal is not logged: {:?}", log(&gate));
    let document = crate::driver::RequestInfo {
        target: "T",
        url: "https://peer.test/page",
        kind: crate::driver::RequestKind::Document,
    };
    assert!(filter(&document).is_some(), "a document to it is refused too");
    let entries = log(&gate);
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(
        (entries[0]["url"].as_str(), entries[0]["blocked"].as_str()),
        (Some("https://peer.test/page"), Some("before"))
    );
    // Allowed stays allowed whatever the kind.
    let fine = crate::driver::RequestInfo { url: "https://a.test/", ..document };
    assert!(filter(&fine).is_none());
    assert!(
        filter(&crate::driver::RequestInfo {
            kind: crate::driver::RequestKind::Subresource,
            ..fine
        })
        .is_none()
    );
}
