use super::*;
use crate::policy::DomainPattern;

struct FakeDriver {
    filter: Mutex<Option<crate::driver::RequestFilter>>,
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

    fn set_request_filter(&self, filter: Option<crate::driver::RequestFilter>) -> bool {
        *self.filter.lock().unwrap() = filter;
        true
    }
}

fn agent_secret(gate: &Gate, domain: &str) {
    gate.native("secretSet", json!(["pw", "s3cret-value", {"domains": [domain]}])).unwrap();
}

fn make_gate(focused_url: Value, raw_cdp: bool) -> (Gate, Arc<FakeDriver>) {
    let driver = Arc::new(FakeDriver {
        filter: Mutex::new(None),
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
    assert!(gate.native("secretSet", json!(["pw", "other", {"domains": ["evil.test"]}])).is_err());
    assert!(gate.native("secretDelete", json!(["pw"])).is_err());
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
    assert!(filter("https://example.com/app.js").is_none());
    assert!(filter("https://evil.test/beacon?d=1").unwrap().contains("session.allowedDomains"));
    assert!(filter("data:text/plain,x").is_none());
    // Narrowing from the VM updates the filter.
    gate.native("policyNarrow", json!([{"prohibited": ["example.com"]}])).unwrap();
    let filter = driver.filter.lock().unwrap().clone().unwrap();
    assert!(filter("https://example.com/").is_some());
}
