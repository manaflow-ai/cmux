use super::*;
use crate::policy::DomainPattern;

struct FakeDriver {
    calls: Mutex<Vec<(String, Value)>>,
    focused_url: Value,
    page_text: String,
}

impl Driver for FakeDriver {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        self.calls.lock().unwrap().push((method.to_owned(), params.clone()));
        match method {
            "frame.evaluate" => Ok(self.focused_url.clone()),
            "tab.info" => Ok(json!({"title": self.page_text})),
            "tab.navigate" => Err(DriverError::invalid(format!("failed: {}", self.page_text))),
            _ => Ok(Value::Null),
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        Vec::new()
    }
}

fn make_gate(focused_url: Value, raw_cdp: bool) -> (Gate, Arc<FakeDriver>) {
    let driver = Arc::new(FakeDriver {
        calls: Mutex::new(Vec::new()),
        focused_url,
        page_text: "token s3cret-value here".into(),
    });
    (Gate::new(driver.clone(), Grants { raw_cdp }), driver)
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
    gate.native("policyNarrow", json!([{"allowed": ["evil.test", "example.com"]}])).unwrap();
    assert!(
        gate.driver_call("tab.navigate", json!({"targetId": "T", "url": "https://evil.test/"}))
            .is_err()
    );
    let got = gate.native("policyGet", json!([])).unwrap();
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
    gate.load_secret("pw", "s3cret-value", &["*.example.com".into()], false).unwrap();
    gate.driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
        .unwrap();
    let calls = driver.calls.lock().unwrap();
    assert_eq!(calls.last().unwrap().1["text"], "s3cret-value", "the driver gets the value");
    drop(calls);

    let (other, other_driver) = make_gate(json!("https://evil.test/"), false);
    other.load_secret("pw", "s3cret-value", &["*.example.com".into()], false).unwrap();
    let error = other
        .driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    assert!(!error.message.contains("s3cret"));
    assert_eq!(methods(&other_driver), vec!["frame.evaluate"], "nothing was typed");

    let (unknown, _) = make_gate(Value::Null, false);
    unknown.load_secret("pw", "s3cret-value", &["example.com".into()], false).unwrap();
    assert!(
        unknown
            .driver_call("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw"}}))
            .is_err(),
        "unverifiable focus refuses"
    );

    let (raw, _) = make_gate(json!("https://example.com/"), true);
    raw.load_secret("pw", "s3cret-value", &["example.com".into()], false).unwrap();
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
    let handle =
        gate.native("secretSet", json!(["api", "k-123", {"domains": ["example.com"]}])).unwrap();
    assert_eq!(handle, json!({"__secret": "api"}));
    gate.load_secret("pw", "s3cret-value", &["example.com".into()], false).unwrap();
    let list = gate.native("secretList", json!([])).unwrap();
    assert!(!list.to_string().contains("s3cret") && !list.to_string().contains("k-123"));
    assert_eq!(list[0]["agentKnown"], true);
    assert_eq!(list[1]["agentKnown"], false);
    assert_eq!(gate.native("secretDelete", json!(["api"])).unwrap(), json!(true));
    assert!(gate.native("secretSet", json!(["bad name", "v", {"domains": ["a.test"]}])).is_err());
}
