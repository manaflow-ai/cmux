use super::*;

/// An engine that records the profile each session was opened with and
/// answers no driver call.
struct ProfileEngines(Mutex<Vec<String>>);

struct NoDriver;

impl Driver for NoDriver {
    fn call(&self, method: &str, _: &Value) -> Result<Value, DriverError> {
        match method {
            // A tab to call on (the runtime's lazy page opens one).
            "tabs.open" => Ok(json!({"targetId": "T1"})),
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        Vec::new()
    }
}

impl Engines for ProfileEngines {
    fn driver(
        &self,
        _engine: &str,
        _events: crate::driver::EventSink,
        session: &SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        self.0.lock().unwrap().push(session.profile.clone());
        Ok(Arc::new(NoDriver))
    }
}

/// An engine whose drivers the test watches through `Weak`s.
struct WatchedEngines(Mutex<Vec<std::sync::Weak<NoDriver>>>);

impl Engines for WatchedEngines {
    fn driver(
        &self,
        _engine: &str,
        _events: crate::driver::EventSink,
        _session: &SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        let driver = Arc::new(NoDriver);
        self.0.lock().unwrap().push(Arc::downgrade(&driver));
        Ok(driver)
    }
}

fn idle_host(
    tag: &str,
    idle: Duration,
) -> (Host, Arc<WatchedEngines>, std::sync::mpsc::Receiver<String>, std::path::PathBuf) {
    let engines = Arc::new(WatchedEngines(Mutex::new(Vec::new())));
    let root = std::env::temp_dir().join(format!("idle-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let host = Host::new(engines.clone(), root.display().to_string()).with_idle_timeout(idle);
    let (tx, rx) = std::sync::mpsc::channel();
    host.on_idle_end(tx);
    (host, engines, rx, root)
}

fn mcp() -> Caller {
    Caller {
        actor: "uid:501".into(),
        on_behalf_of: None,
        origin: "mcp".into(),
        locality: Default::default(),
    }
}

/// CALLER-LOCALITY: a remote caller (from the transport) is refused
/// loopback and private ranges for fetch and navigation alike; a
/// "remote" or "local" field in the request changes nothing.
#[test]
fn locality_comes_from_the_transport_not_the_request() {
    let (host, _engines, _ended, root) = idle_host("locality", DEFAULT_IDLE_TIMEOUT);
    let remote = Caller {
        locality: crate::locality::CallerLocality::Remote {
            principal: crate::locality::RemotePrincipal {
                user: "u".into(),
                install: "phone".into(),
                class: crate::locality::PrincipalClass::Agent,
                interactive: true,
            },
        },
        ..mcp()
    };
    let run = |caller: &Caller, session: &str, code: &str| {
        let params = json!({"session": session, "code": code, "engine": "headless",
                "remote": true, "locality": "remote", "origin": "remote"});
        let out = host.dispatch(caller, "browser.repl.eval", &params).unwrap();
        out["error"].as_str().unwrap_or("").to_owned()
    };
    for code in [
        "await fetch('http://127.0.0.1:9/x')",
        "await page.goto('http://192.168.1.1/')",
        "await tabs.open('http://localhost:3000/')",
    ] {
        let local = run(&mcp(), "near", code);
        assert!(!local.contains("private or loopback"), "local {code}: {local}");
        let far = run(&remote, "far", code);
        assert!(far.contains("private or loopback"), "remote {code}: {far}");
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// Classic main ends a named session after 30 minutes without a call
/// (docs/browser-repl/README.md ~:396); here the deadline is short.
#[test]
fn a_session_without_calls_ends_at_its_idle_deadline() {
    let (host, engines, ended, root) = idle_host("quiet", Duration::from_millis(200));
    host.dispatch(&mcp(), "browser.repl.open", &json!({"session": "quiet", "engine": "headless"}))
        .unwrap();
    assert_eq!(ended.recv_timeout(Duration::from_secs(10)).as_deref(), Ok("quiet"));
    assert_eq!(host.list(), json!([]), "the idle end removed the session");
    let weak = engines.0.lock().unwrap()[0].clone();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while weak.strong_count() > 0 {
        assert!(std::time::Instant::now() < deadline, "the idle end never freed the engine");
        std::thread::yield_now();
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// Every call resets the deadline, and a call in flight holds it.
#[test]
fn calls_hold_the_idle_deadline() {
    let (host, _engines, ended, root) = idle_host("busy", Duration::from_millis(400));
    let host = Arc::new(host);
    let eval = |code: &str| {
        host.dispatch(&mcp(), "browser.repl.eval", &json!({"session": "busy", "code": code}))
            .unwrap()
    };
    eval("1");
    for _ in 0..4 {
        // Paced calls (a test-only pause), each well inside the deadline.
        std::thread::sleep(Duration::from_millis(200));
        eval("1");
    }
    assert!(ended.try_recv().is_err(), "a session with calls stays");
    // One call that outlives the deadline.
    let slow = {
        let host = host.clone();
        std::thread::spawn(move || {
            host.dispatch(
                    &mcp(),
                    "browser.repl.eval",
                    &json!({"session": "busy", "code": "await new Promise((r) => setTimeout(r, 1200)); 1"}),
                )
                .unwrap()
        })
    };
    assert!(
        ended.recv_timeout(Duration::from_millis(900)).is_err(),
        "a call in flight holds the session"
    );
    slow.join().unwrap();
    assert_eq!(ended.recv_timeout(Duration::from_secs(10)).as_deref(), Ok("busy"));
    let _ = std::fs::remove_dir_all(&root);
}

/// The session's event slot holds its gate, and the gate's input
/// emitter holds the session sink, which holds the slot: only clearing
/// the slot frees a session. Every end path must clear it, the host's
/// own end too (no browser.repl.close).
#[test]
fn every_session_end_frees_the_engine() {
    let engines = Arc::new(WatchedEngines(Mutex::new(Vec::new())));
    let root = std::env::temp_dir().join(format!("host-drop-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let host = Host::new(engines.clone(), root.display().to_string());
    let caller = Caller {
        actor: "uid:501".into(),
        on_behalf_of: None,
        origin: "mcp".into(),
        locality: Default::default(),
    };
    for name in ["closed", "open"] {
        host.dispatch(
            &caller,
            "browser.repl.open",
            &json!({"session": name, "engine": "headless"}),
        )
        .unwrap();
    }
    let weak = |i: usize| engines.0.lock().unwrap()[i].clone();
    let freed = |i: usize, what: &str| {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while weak(i).strong_count() > 0 {
            assert!(std::time::Instant::now() < deadline, "{what}: the engine was never freed");
            std::thread::sleep(Duration::from_millis(10));
        }
    };
    host.dispatch(&caller, "browser.repl.close", &json!({"session": "closed"})).unwrap();
    freed(0, "browser.repl.close");
    drop(host);
    freed(1, "the host ended with the session open");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn engines_get_the_session_profile_and_only_the_person_picks_another() {
    let engines = Arc::new(ProfileEngines(Mutex::new(Vec::new())));
    let root = std::env::temp_dir().join(format!("profile-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let host = Host::new(engines.clone(), root.display().to_string());
    let caller = |origin: &str| Caller {
        actor: "uid:501".into(),
        on_behalf_of: None,
        origin: origin.into(),
        locality: Default::default(),
    };
    host.dispatch(
        &caller("mcp"),
        "browser.repl.open",
        &json!({"session": "a", "engine": "headless"}),
    )
    .unwrap();
    let refused = host
        .dispatch(
            &caller("mcp"),
            "browser.repl.open",
            &json!({"session": "b", "engine": "headless", "profile": "signed-in"}),
        )
        .unwrap_err();
    assert_eq!(refused.code, ErrorCode::Forbidden, "{refused}");
    host.dispatch(
        &caller("user"),
        "browser.repl.open",
        &json!({"session": "c", "engine": "headless", "profile": "signed-in"}),
    )
    .unwrap();
    assert_eq!(*engines.0.lock().unwrap(), vec!["agent".to_owned(), "signed-in".to_owned()]);
    for name in ["a", "c"] {
        let _ = host.dispatch(&caller("user"), "browser.repl.close", &json!({"session": name}));
    }
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn output_caps_on_char_boundaries() {
    let mut text = "héllo".repeat(10);
    assert!(cap(&mut text, 7));
    assert!(text.starts_with("héllo"));
    let mut short = "ok".to_owned();
    assert!(!cap(&mut short, 7));
}

#[test]
fn broad_caller_directories_get_a_private_root() {
    let home = std::env::var("HOME").unwrap();
    assert!(session_root(Some("/"), "/", "s").contains("cmux-browser-host"));
    assert!(session_root(Some(&home), "/", "s").contains("cmux-browser-host"));
    assert!(session_root(Some("relative/dir"), "/", "s").contains("cmux-browser-host"));
    let narrow = std::env::temp_dir().join(format!("narrow-{}", std::process::id()));
    std::fs::create_dir_all(&narrow).unwrap();
    assert_eq!(
        session_root(Some(narrow.to_str().unwrap()), "/", "s"),
        narrow.canonicalize().unwrap().display().to_string()
    );
}

#[test]
fn lease_terminal_keeps_only_a_terminal_id() {
    assert_eq!(lease_terminal(Some("term_01J9-x_y")).as_deref(), Some("term_01J9-x_y"));
    for bad in
        ["", "term_", "pane_1", "term_a b", "term_\u{202E}x", &format!("term_{}", "a".repeat(60))]
    {
        assert_eq!(lease_terminal(Some(bad)), None, "{bad:?}");
    }
    assert_eq!(lease_terminal(None), None);
}

#[test]
fn lease_labels_are_cleaned_and_capped() {
    assert_eq!(lease_label(Some("Book  a\nflight"), "s"), "Book a flight");
    assert_eq!(lease_label(Some("\u{202E}evil\u{200B}\u{0007}"), "s"), "evil");
    assert_eq!(lease_label(Some(" \u{FEFF} "), "s1"), "s1");
    assert_eq!(lease_label(None, "s1"), "s1");
    assert_eq!(lease_label(Some(&"x".repeat(200)), "s").chars().count(), 48);
}

#[test]
fn the_persons_tabs_need_a_named_session() {
    for engine in ["cef", "webkit"] {
        assert!(Host::require_named_session(engine, &json!({})).is_err(), "{engine}");
        let null = json!({"session": null});
        assert!(Host::require_named_session(engine, &null).is_err());
        let default = json!({"session": "default"});
        assert!(Host::require_named_session(engine, &default).is_err());
        assert!(Host::require_named_session(engine, &json!({"session": "a"})).is_ok());
    }
    assert!(Host::require_named_session("headless", &json!({})).is_ok());
    assert!(Host::require_named_session("auto", &json!({})).is_ok());
}

#[test]
fn session_names_are_checked() {
    assert!(Host::session_name(&json!({"session": "a.b-c_1"})).is_ok());
    assert_eq!(Host::session_name(&json!({})).unwrap(), "default");
    assert!(Host::session_name(&json!({"session": "../x"})).is_err());
}

#[test]
fn the_bundle_holds_the_manifest_scripts() {
    assert!(bundle::REPL_SCRIPTS.iter().any(|(f, _)| *f == "repl-host.js"));
    assert_eq!(bundle::AGENT_SCRIPTS.last().map(|(f, _)| *f), Some("page-agent.js"));
    assert!(agent_bundle().contains("cmux"));
}

#[test]
fn the_agent_bundle_wraps_playwright_injected_as_a_module() {
    // The #15570 install recipe (tests/browser-parity/lib/dev-driver.mjs
    // agentInstallSource): Playwright's injected script is a CommonJS
    // module, and page-agent.js reads its factory.
    let bundle = agent_bundle();
    assert!(bundle.starts_with("(() => {\nconst module = {};\n"), "{}", &bundle[..80]);
    assert!(
        bundle.contains(";const __cmuxInjectedScriptFactory = module.exports.InjectedScript;\n")
    );
    assert!(bundle.trim_end().ends_with("})()"));
    assert!(!bundle::GUIDE.is_empty());
}
