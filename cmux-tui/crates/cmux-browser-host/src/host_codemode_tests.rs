//! Code mode parity (plans/cmux-next/computer-use-lead.md, Codemode parity):
//! `engine: "auto"` drives the app's in-app browser for a named session, and
//! the REPL answers to Aside's names over the cmux API.

use super::*;

/// Two of the person's tabs (the second one shown), and one a session opens.
struct TabsDriver;

impl Driver for TabsDriver {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        let info = |target: &str| match target {
            "T1" => json!({"url": "https://one.test/", "title": "One", "loadState": "load"}),
            "T2" => json!({"url": "https://two.test/", "title": "Two", "loadState": "load"}),
            _ => json!({"url": "https://three.test/", "title": "Three", "loadState": "load"}),
        };
        match method {
            "tabs.list" => Ok(json!([
                {"targetId": "T1", "title": "One", "url": "https://one.test/", "active": false},
                {"targetId": "T2", "title": "Two", "url": "https://two.test/", "active": true},
            ])),
            "tabs.open" => Ok(json!({"targetId": "T9"})),
            "tabs.close" => Ok(json!({})),
            "tab.info" => Ok(info(params["targetId"].as_str().unwrap_or(""))),
            // Page reads fail and say what they were asked, so a test sees
            // whether a snapshot was scoped to a ref.
            "frame.observe" | "frame.evaluate" => {
                Err(DriverError::invalid(format!("{method} {params}")))
            }
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        Vec::new()
    }
}

/// Engines whose `auto` is `auto` (what the app's provider makes it), and
/// that record the engine each session asked for.
struct ChoiceEngines {
    auto: &'static str,
    asked: Mutex<Vec<String>>,
}

impl Engines for ChoiceEngines {
    fn driver(
        &self,
        engine: &str,
        _events: crate::driver::EventSink,
        _session: &SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        self.asked.lock().unwrap().push(engine.to_owned());
        Ok(Arc::new(TabsDriver))
    }

    fn auto_engine(&self) -> &'static str {
        self.auto
    }
}

fn codemode_host(tag: &str, auto: &'static str) -> (Host, Arc<ChoiceEngines>, std::path::PathBuf) {
    let engines = Arc::new(ChoiceEngines { auto, asked: Mutex::new(Vec::new()) });
    let root = std::env::temp_dir().join(format!("codemode-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    (Host::new(engines.clone(), root.display().to_string()), engines, root)
}

fn mcp() -> Caller {
    Caller {
        actor: "uid:501".into(),
        on_behalf_of: None,
        origin: "mcp".into(),
        locality: Default::default(),
    }
}

/// The lead's measurement (2026-10-23): `browser_repl_open` answered
/// `engine: "headless"` with the app running. Decision 7: `auto` is in-app
/// Chromium where the app offers it; the implicit `default` stays headless.
#[test]
fn codemode_parity_auto_drives_the_in_app_browser_for_a_named_session() {
    let (host, engines, root) = codemode_host("auto", "cef");
    let named =
        host.dispatch(&mcp(), "browser.repl.open", &json!({"session": "agent-s1"})).unwrap();
    assert_eq!(named["engine"], "cef", "{named}");
    let implicit = host.dispatch(&mcp(), "browser.repl.open", &json!({})).unwrap();
    assert_eq!(implicit["engine"], "headless", "the shared default never gets the person's tabs");
    assert_eq!(*engines.asked.lock().unwrap(), vec!["cef".to_owned(), "auto".to_owned()]);
    let explicit = host
        .dispatch(&mcp(), "browser.repl.open", &json!({"session": "h", "engine": "headless"}))
        .unwrap();
    assert_eq!(explicit["engine"], "headless", "an explicit engine wins");
    let (host, _engines, root2) = codemode_host("noapp", "headless");
    let without_app =
        host.dispatch(&mcp(), "browser.repl.open", &json!({"session": "agent-s1"})).unwrap();
    assert_eq!(without_app["engine"], "headless", "no app (a Linux VM): headless");
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&root2);
}

/// A script written for `aside repl` runs unchanged: Aside's tab and
/// capture names are thin wrappers over `tabs.*` and `screenshot`.
#[test]
fn codemode_parity_aside_names_drive_the_cmux_tabs() {
    let (host, _engines, root) = codemode_host("aside", "headless");
    let code = r#"
        const listed = await listBrowserTabs();
        const active = await attachActiveBrowserTab();
        const activeIsPage = page.id;
        const byId = await getTabByTargetId(listed[0].targetId);
        const attached = await attachBrowserTab(listed[0]);
        const opened = await openTab("https://three.test/");
        const openedIsPage = page.id;
        await closeTab(opened);
        const refScope = await snapshot(byId, { ref: "e99" }).then(() => "no error", (e) => e.message);
        JSON.stringify({
          listed, active: active.id, activeIsPage, byId: byId.id, attached: attached.id,
          opened: opened.id, openedIsPage, closed: opened.isClosed(), refScope,
          pwd: String(pwd) === pwd() && pwd() === path.resolve("."),
          types: [typeof annotatedScreenshot, typeof closeTab],
        })
    "#;
    let out = host
        .dispatch(&mcp(), "browser.repl.eval", &json!({"session": "aside", "code": code}))
        .unwrap();
    assert_eq!(out["error"], Value::Null, "{out}");
    let line = out["output"].as_str().unwrap().trim();
    let seen: Value = serde_json::from_str(line).unwrap_or_else(|e| panic!("{e}: {line}"));
    assert_eq!(
        seen["listed"],
        json!([
            {"targetId": "T1", "title": "One", "url": "https://one.test/", "active": false, "state": "live", "workspace": null},
            {"targetId": "T2", "title": "Two", "url": "https://two.test/", "active": true, "state": "live", "workspace": null},
        ])
    );
    assert_eq!(seen["active"], "T2");
    assert_eq!(seen["activeIsPage"], "T2", "attaching makes the tab `page`");
    assert_eq!(seen["byId"], "T1");
    assert_eq!(seen["attached"], "T1");
    assert_eq!(seen["opened"], "T9");
    assert_eq!(seen["openedIsPage"], "T9");
    assert_eq!(seen["closed"], true);
    assert!(
        seen["refScope"].as_str().unwrap().contains("e99"),
        "snapshot(page, {{ ref }}) scopes to the ref: {seen}"
    );
    assert_eq!(seen["pwd"], true);
    assert_eq!(seen["types"], json!(["function", "function"]));
    let _ = std::fs::remove_dir_all(&root);
}
