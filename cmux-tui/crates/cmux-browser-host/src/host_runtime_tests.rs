//! The real REPL runtime (the bundled JS) on a scripted driver: what agent
//! code gets back from snapshots and pointer input, end to end through
//! `browser.repl.eval`, with no browser.

use super::*;

/// One tab whose page is a heading named after the document's URL and one
/// link, read through `frame.observe snapshot`. `tab.navigate` commits a new
/// document and reports it as Chromium's driver does (`tab.navigated`,
/// `sameDocument: false`). Records every call.
struct PageDriver {
    capabilities: Vec<&'static str>,
    events: crate::driver::EventSink,
    url: Mutex<String>,
    calls: Arc<Mutex<Vec<(String, Value)>>>,
}

impl Driver for PageDriver {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        self.calls.lock().unwrap().push((method.to_owned(), params.clone()));
        let url = self.url.lock().unwrap().clone();
        match method {
            "tabs.open" => Ok(json!({"targetId": "T1"})),
            "tab.info" => Ok(json!({"url": url, "title": "Page",
                "viewport": {"width": 1280, "height": 800}, "loadState": "load"})),
            "frames.list" => Ok(json!([{"frameId": "MAIN", "url": url}])),
            "tab.navigate" => {
                let next = params["url"].as_str().unwrap_or("about:blank").to_owned();
                *self.url.lock().unwrap() = next.clone();
                (self.events)(DriverEvent {
                    name: "tab.navigated".into(),
                    payload: json!({"targetId": "T1", "frameId": "MAIN", "url": next,
                        "sameDocument": false}),
                });
                Ok(json!({"url": next}))
            }
            "frame.observe" if params["method"] == "snapshot" => Ok(json!({
                "flat": [
                    [0, {"role": "heading", "name": format!("Page at {url}"), "level": 1}],
                    [0, {"role": "link", "name": "More", "ref": "e1", "act": 1}],
                ],
                "max": 1, "visited": 2, "size": 40,
            })),
            "input.mouse" => Ok(Value::Null),
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        self.capabilities.clone()
    }
}

struct PageEngines {
    capabilities: Vec<&'static str>,
    calls: Arc<Mutex<Vec<(String, Value)>>>,
}

impl Engines for PageEngines {
    fn driver(
        &self,
        _engine: &str,
        events: crate::driver::EventSink,
        _session: &SessionContext,
    ) -> Result<Arc<dyn Driver>, DriverError> {
        Ok(Arc::new(PageDriver {
            capabilities: self.capabilities.clone(),
            events,
            url: Mutex::new("about:blank".into()),
            calls: self.calls.clone(),
        }))
    }
}

struct Repl {
    host: Host,
    calls: Arc<Mutex<Vec<(String, Value)>>>,
    root: std::path::PathBuf,
}

impl Repl {
    fn new(tag: &str, capabilities: Vec<&'static str>) -> Repl {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let engines = Arc::new(PageEngines { capabilities, calls: calls.clone() });
        let root = std::env::temp_dir().join(format!("host-runtime-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let host = Host::new(engines, root.display().to_string());
        host.dispatch(&mcp(), "browser.repl.open", &json!({"session": "s", "engine": "headless"}))
            .unwrap();
        Repl { host, calls, root }
    }

    /// The printed output of one call; a thrown error fails the test.
    fn eval(&self, code: &str) -> String {
        let out = self
            .host
            .dispatch(&mcp(), "browser.repl.eval", &json!({"session": "s", "code": code}))
            .unwrap();
        assert!(out["error"].is_null(), "{code}: {}", out["error"]);
        out["output"].as_str().unwrap_or("").trim_end().to_owned()
    }

    fn mouse_moves(&self) -> usize {
        self.calls
            .lock()
            .unwrap()
            .iter()
            .filter(|(method, params)| method == "input.mouse" && params["type"] == "move")
            .count()
    }
}

impl Drop for Repl {
    fn drop(&mut self) {
        let _ = self.host.dispatch(&mcp(), "browser.repl.close", &json!({"session": "s"}));
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn mcp() -> Caller {
    Caller {
        actor: "uid:501".into(),
        on_behalf_of: None,
        origin: "mcp".into(),
        locality: Default::default(),
    }
}

/// The first snapshot of a new document is not a diff against the page
/// before it: that diff compared two unrelated trees (0.5-3 s of diff work
/// on a big page before the first read of a small one, browser-use-perf.md)
/// and its lines meant nothing. A second snapshot of the same document
/// still prints only the changes.
#[test]
fn a_new_document_starts_its_snapshots_without_a_previous_one() {
    let repl = Repl::new("docs", Vec::new());
    let first = "# no previous snapshot of this tab; every line is new:";
    let a = repl.eval(
        "await page.goto('https://a.test/'); const s1 = await snapshot(); s1.diff.split('\\n').find((l) => l.startsWith('#'))",
    );
    assert_eq!(a, first);
    let b = repl.eval(
        "const nav = page.waitForEvent('framenavigated'); await page.goto('https://b.test/'); \
         await nav; const s2 = await snapshot(); s2.diff.split('\\n').find((l) => l.startsWith('#'))",
    );
    assert_eq!(b, first, "the first snapshot of b.test diffed against a.test");
    let again = repl
        .eval("const s3 = await snapshot(); s3.diff.split('\\n').find((l) => l.startsWith('#'))");
    assert_eq!(again, "# no changes since the previous snapshot");
}

/// A headless tab nobody sees gets the agent pointer without the human
/// path: one move to the point, no dwell or hold (each click cost about
/// 0.4-0.5 s more, browser-use-perf.md). A tab a person can see (an
/// engine without the `headless` capability) keeps the human glide.
#[test]
fn headless_tabs_click_without_the_human_path_and_visible_tabs_keep_it() {
    let code = "await page.mouse.click(600, 400); null";
    let headless = Repl::new("instant", vec!["headless"]);
    headless.eval(code);
    assert_eq!(headless.mouse_moves(), 1, "a headless click moves once");
    let shown = Repl::new("human", Vec::new());
    shown.eval(code);
    assert!(shown.mouse_moves() > 3, "a visible tab's click glides: {} moves", shown.mouse_moves());
    assert_eq!(
        headless.eval("page.mouse.configure({ motion: 'human' }).motion"),
        "human",
        "a script can still ask for the human path"
    );
}
