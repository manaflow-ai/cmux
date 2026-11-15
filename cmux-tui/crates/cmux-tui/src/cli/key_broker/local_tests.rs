use super::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// A value no test output may hold.
const VALUE: &str = "sk_live_51Hc0ffeeD00dF00d";

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn parsed(text: &str) -> Local {
    let args = words(text);
    parse(&args[0], &args[1..]).expect("a local verb").expect("parses")
}

/// The OS store, as a map.
#[derive(Default)]
pub(in crate::cli) struct MemoryVault {
    items: RefCell<HashMap<String, String>>,
}

impl KeyVault for MemoryVault {
    fn put(&self, item: &str, value: &str) -> Result<(), String> {
        self.items.borrow_mut().insert(item.into(), value.into());
        Ok(())
    }
    fn get(&self, item: &str) -> Result<Option<Zeroizing<String>>, String> {
        Ok(self.items.borrow().get(item).map(|v| Zeroizing::new(v.clone())))
    }
    fn delete(&self, item: &str) -> Result<(), String> {
        self.items.borrow_mut().remove(item);
        Ok(())
    }
}

#[derive(Default)]
struct RecordingSinks {
    put: RefCell<Vec<(Store, String, String)>>,
}

impl Sinks for RecordingSinks {
    fn provider_token(&self, _: &str) -> Result<Zeroizing<String>, String> {
        Err("no provider in these tests".into())
    }
    fn save_provider_token(&self, _: &str, _: &str) -> Result<(), String> {
        Err("no provider in these tests".into())
    }
    fn read_bootstrap(&self) -> Result<Zeroizing<String>, String> {
        Err("no provider in these tests".into())
    }
    fn put(&self, store: &Store, name: &str, value: &str) -> Result<(), String> {
        self.put.borrow_mut().push((store.clone(), name.into(), value.into()));
        Ok(())
    }
}

type Answer = Result<Result<Value, Value>, String>;
type Answerer<'a> = Box<dyn Fn(&str, &Value) -> Answer + 'a>;

/// The cmux app: answers from `answer`, records every call.
struct FakeApp<'a> {
    calls: RefCell<Vec<(String, Value)>>,
    answer: Answerer<'a>,
}

impl<'a> FakeApp<'a> {
    fn new(answer: impl Fn(&str, &Value) -> Answer + 'a) -> Self {
        Self { calls: RefCell::new(Vec::new()), answer: Box::new(answer) }
    }
    fn methods(&self) -> Vec<String> {
        self.calls.borrow().iter().map(|(m, _)| m.clone()).collect()
    }
}

impl App for FakeApp<'_> {
    fn call(&self, method: &str, params: Value, _: Option<Instant>) -> Answer {
        let answer = (self.answer)(method, &params);
        self.calls.borrow_mut().push((method.into(), params));
        answer
    }
}

fn no_app() -> FakeApp<'static> {
    FakeApp::new(|method, _| Err(format!("no app in this test ({method})")))
}

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    paths: Paths,
    vault: MemoryVault,
    sinks: RecordingSinks,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        Self {
            paths: Paths { audit: root.join("config/keys.json") },
            root,
            _dir: dir,
            vault: MemoryVault::default(),
            sinks: RecordingSinks::default(),
        }
    }

    fn run(&self, command: &str, app: &dyn App) -> Result<Value, String> {
        run(parsed(command), &self.paths, &self.vault, &self.sinks, app, &|_| {
            Ok(Zeroizing::new(VALUE.to_owned()))
        })
    }

    fn put(&self, flags: &str) -> Value {
        self.run(&format!("put PAY_KEY {flags}"), &no_app()).unwrap()
    }

    fn audit(&self) -> String {
        std::fs::read_to_string(&self.paths.audit).unwrap()
    }

    fn record(&self) -> Value {
        let mut audit = read_audit(&self.paths.audit).unwrap();
        find_local(&mut audit, "PAY_KEY").unwrap().clone()
    }

    /// Nothing this fixture wrote outside the OS store holds the value.
    fn assert_no_value_outside_the_store(&self, replies: &[&Value]) {
        assert!(!self.audit().contains(VALUE), "the audit never holds a value");
        for reply in replies {
            assert!(!reply.to_string().contains(VALUE), "a reply never holds a value: {reply}");
        }
    }
}

#[test]
fn verbs_parse_and_never_take_a_value_in_argv() {
    assert_eq!(
        parsed("put DEPLOY_TOKEN --purpose deploy --hosts API.example.com,example.com --ttl 30d"),
        Local::Put(Put {
            name: "DEPLOY_TOKEN".into(),
            purpose: Some("deploy".into()),
            hosts: vec!["api.example.com".into(), "example.com".into()],
            ttl: Some(Duration::from_secs(30 * 86_400)),
            replace: false,
            asked_by: None,
            from_person: false,
        })
    );
    assert_eq!(
        parsed("use PAY_KEY=PAY_API_KEY GH --env GH_TOKEN -- deploy --prod"),
        Local::Use(Use {
            keys: vec![("PAY_KEY".into(), "PAY_API_KEY".into()), ("GH".into(), "GH_TOKEN".into())],
            mask: true,
            argv: words("deploy --prod"),
        })
    );
    assert_eq!(
        parsed("write K --to gh-secret:acme/app@prod:PAY --to json:/tmp/c.json#auth.token"),
        Local::Write {
            name: "K".into(),
            targets: vec![
                Target::Store(Store::GhSecret {
                    repo: "acme/app".into(),
                    environment: Some("prod".into()),
                    prefix: "PAY".into(),
                }),
                Target::Json("/tmp/c.json".into(), vec!["auth".into(), "token".into()]),
            ],
        }
    );
    assert!(
        matches!(parsed("request K --purpose why --timeout 2h"), Local::Request { timeout, .. } if timeout == Duration::from_secs(7_200))
    );
    assert!(matches!(
        parsed("fill K --tab tab_1 --selector #key --type"),
        Local::Fill(Fill { typing: true, .. })
    ));
    for bad in [
        "put lower",           // not an env name
        "put K sk_live_value", // a value in argv is no flag
        "put K --hosts not_a_host",
        "generate K --bytes 4",
        "generate K --from-person",
        "request K",                           // no purpose
        "request K --purpose p --from-person", // the app's own flag
        "use K",                               // no command
        "use K --",                            // no command
        "use A=X B=X -- cmd",                  // one var twice
        "use --env X -- cmd",
        "write K", // nowhere
        "write K --to s3:bucket",
        "write K --to json:/tmp/c.json", // no field
        "write K --to env-file:/tmp/.env#1BAD",
        "fill K",                           // no selector
        "fill K --app Safari --selector x", // the MCP tool's
    ] {
        let args = words(bad);
        assert!(parse(&args[0], &args[1..]).is_some_and(|r| r.is_err()), "{bad}");
    }
    assert!(parse("ls", &[]).is_none());
}

#[test]
fn put_keeps_the_value_only_in_the_os_store_and_the_audit_names_it() {
    let f = Fixture::new();
    let reply = f.put("--purpose checkout --hosts pay.example");
    assert_eq!(f.vault.items.borrow().get("key.PAY_KEY").map(String::as_str), Some(VALUE));
    let record = &reply["stored"];
    assert_eq!(record["name"], "PAY_KEY");
    assert_eq!(record["provider"], "local");
    assert_eq!(record["source"], "stdin");
    assert_eq!(record["purpose"], "checkout");
    assert_eq!(record["hosts"], json!(["pay.example"]));
    assert_eq!(record["state"], "live");
    assert!(record["by"].as_str().is_some());
    // A second put under the name is refused unless it replaces.
    let refused = f.run("put PAY_KEY", &no_app()).unwrap_err();
    assert!(refused.contains("--replace"), "{refused}");
    let replaced = f.run("put PAY_KEY --replace", &no_app()).unwrap();
    assert!(replaced["stored"]["replaced_at"].is_string());
    let listed = super::super::list(&f.paths).unwrap();
    assert_eq!(listed["keys"].as_array().unwrap().len(), 1);
    assert_eq!(listed["keys"][0]["label"], "PAY_KEY");
    f.assert_no_value_outside_the_store(&[&reply, &replaced, &listed]);
    let mode = std::os::unix::fs::PermissionsExt::mode(
        &std::fs::metadata(&f.paths.audit).unwrap().permissions(),
    );
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn a_value_too_short_to_mask_is_refused() {
    let f = Fixture::new();
    let error = run(parsed("put SHORT"), &f.paths, &f.vault, &f.sinks, &no_app(), &|_| {
        Ok(Zeroizing::new("abc".into()))
    })
    .unwrap_err();
    assert!(error.contains("shorter"), "{error}");
    assert!(f.vault.items.borrow().is_empty());
}

#[test]
fn generate_makes_a_random_value_of_the_asked_shape_and_never_answers_it() {
    let f = Fixture::new();
    for (flags, check) in [
        (
            "--format hex --bytes 32",
            (|v: &str| v.len() == 64 && v.chars().all(|c| c.is_ascii_hexdigit()))
                as fn(&str) -> bool,
        ),
        ("--format alnum --bytes 40", |v: &str| {
            v.len() == 40 && v.chars().all(|c| c.is_ascii_alphanumeric())
        }),
        ("", |v: &str| {
            v.len() == 43 && v.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        }),
    ] {
        let reply =
            f.run(&format!("generate WEBHOOK_SECRET --replace {flags}"), &no_app()).unwrap();
        let value = f.vault.items.borrow().get("key.WEBHOOK_SECRET").cloned().unwrap();
        assert!(check(&value), "{flags}: {value}");
        assert_eq!(reply["stored"]["source"], "generated");
        assert!(!reply.to_string().contains(&value));
        assert!(!f.audit().contains(&value));
    }
    let a = generate(32, Format::Hex).unwrap();
    let b = generate(32, Format::Hex).unwrap();
    assert_ne!(*a, *b);
}

#[test]
fn the_masker_hides_a_value_split_across_reads() {
    let text = format!("token={VALUE}; again {VALUE}{VALUE}. end");
    for piece in [1, 2, 5, 7, 64] {
        let mut masker = Masker::new(&[VALUE, "other-secret-value"]);
        let mut out = Vec::new();
        for chunk in text.as_bytes().chunks(piece) {
            out.extend(masker.push(chunk));
        }
        out.extend(masker.finish());
        let out = String::from_utf8(out).unwrap();
        assert_eq!(out, format!("token={MASK}; again {MASK}{MASK}. end"), "pieces of {piece}");
    }
    // A prefix of the value at the very end is printed as it is: it is not the value.
    let mut masker = Masker::new(&[VALUE]);
    let mut out = masker.push(&VALUE.as_bytes()[..5]);
    out.extend(masker.finish());
    assert_eq!(out, &VALUE.as_bytes()[..5]);
}

/// A writer the test reads after the command ends.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Captured {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Captured {
    fn text(&self) -> String {
        String::from_utf8(self.0.lock().unwrap().clone()).unwrap()
    }
}

#[test]
fn use_gives_the_command_the_value_in_env_and_masks_what_it_prints() {
    let f = Fixture::new();
    f.put("");
    let Local::Use(run) = parsed("use PAY_KEY=PAY_API_KEY -- sh -c x") else { panic!() };
    let run = Use {
        argv: vec![
            "sh".into(),
            "-c".into(),
            // The value really is there: its length, then the value itself on both streams.
            "printf 'len=%s\\n' \"${#PAY_API_KEY}\"; printf 'key=%s\\n' \"$PAY_API_KEY\"; printf '%s' \"$PAY_API_KEY\" >&2; exit 7".into(),
        ],
        ..run
    };
    let (out, err) = (Captured::default(), Captured::default());
    let code = run_use(&f.paths, &f.vault, &run, out.clone(), err.clone()).unwrap();
    assert_eq!(code, 7, "the command's own exit code");
    assert_eq!(out.text(), format!("len={}\nkey={MASK}\n", VALUE.len()));
    assert_eq!(err.text(), MASK);
    let uses = &f.record()["uses"];
    assert_eq!(uses[0]["target"], "env:PAY_API_KEY for sh");
    assert_eq!(uses[0]["count"], 1);
    f.assert_no_value_outside_the_store(&[]);
}

#[test]
fn use_refuses_an_expired_removed_or_missing_key_and_runs_nothing() {
    let f = Fixture::new();
    f.put("--ttl 1d");
    let marker = f.root.join("ran");
    let run = |name: &str| Use {
        keys: vec![(name.to_owned(), "K".into())],
        mask: true,
        argv: vec!["touch".into(), marker.display().to_string()],
    };
    // Expire it.
    {
        let _lock = AuditLock::take(&f.paths.audit).unwrap();
        let mut audit = read_audit(&f.paths.audit).unwrap();
        find_local(&mut audit, "PAY_KEY").unwrap()["expires_at_s"] = json!(1);
        write_audit(&f.paths.audit, &audit).unwrap();
    }
    let expired =
        run_use(&f.paths, &f.vault, &run("PAY_KEY"), Captured::default(), Captured::default())
            .unwrap_err();
    assert!(expired.contains("expired"), "{expired}");
    let missing =
        run_use(&f.paths, &f.vault, &run("NOPE"), Captured::default(), Captured::default())
            .unwrap_err();
    assert!(missing.contains("cmux keys put NOPE"), "{missing}");
    f.run("put PAY_KEY --replace", &no_app()).unwrap();
    super::super::run(
        super::super::Command::Revoke { id: "PAY_KEY".into() },
        &f.paths,
        &FailingHttp,
        &f.sinks,
        &f.vault,
    )
    .unwrap();
    assert!(f.vault.items.borrow().is_empty(), "removing deletes the value");
    let removed =
        run_use(&f.paths, &f.vault, &run("PAY_KEY"), Captured::default(), Captured::default())
            .unwrap_err();
    assert!(removed.contains("removed"), "{removed}");
    assert!(!marker.exists(), "no refused use ran its command");
    assert_eq!(super::super::list(&f.paths).unwrap()["keys"][0]["state"], "revoked");
}

/// A provider that must not be called: removing a stored key is local.
struct FailingHttp;

impl super::super::Http for FailingHttp {
    fn call(
        &self,
        method: &str,
        url: &str,
        _: &str,
        _: Option<&Value>,
    ) -> Result<(u16, Value), String> {
        panic!("no provider call for a stored key: {method} {url}")
    }
}

#[test]
fn write_copies_into_files_and_fields_as_0600_and_records_each_copy() {
    let f = Fixture::new();
    f.put("--hosts api.pay.example");
    let json_path = f.root.join("app/config.json");
    std::fs::create_dir_all(json_path.parent().unwrap()).unwrap();
    std::fs::write(&json_path, r#"{"name": "app", "auth": {"user": "leo"}}"#).unwrap();
    let toml_path = f.root.join("app/config.toml");
    std::fs::write(&toml_path, "# keep this comment\n[server]\nport = 8080\n").unwrap();
    let env_path = f.root.join("app/.env");
    std::fs::write(&env_path, "A=1\nexport PAY_API_KEY=old\nB=2\n").unwrap();
    let file_path = f.root.join("app/secrets/pay");
    let reply = f
        .run(
            &format!(
                "write PAY_KEY --to file:{} --to json:{}#auth.token --to toml:{}#pay.key --to env-file:{}#PAY_API_KEY --to gh-secret:acme/app:PAY_SECRET --to vault:PAY_API_KEY",
                file_path.display(),
                json_path.display(),
                toml_path.display(),
                env_path.display()
            ),
            &no_app(),
        )
        .unwrap();
    assert_eq!(std::fs::read_to_string(&file_path).unwrap(), VALUE);
    let config: Value =
        serde_json::from_str(&std::fs::read_to_string(&json_path).unwrap()).unwrap();
    assert_eq!(config, json!({"name": "app", "auth": {"user": "leo", "token": VALUE}}));
    let toml = std::fs::read_to_string(&toml_path).unwrap();
    assert!(toml.starts_with("# keep this comment\n[server]\nport = 8080\n"), "{toml}");
    assert!(toml.contains(&format!("[pay]\nkey = \"{VALUE}\"")), "{toml}");
    assert_eq!(
        std::fs::read_to_string(&env_path).unwrap(),
        format!("A=1\nPAY_API_KEY={VALUE}\nB=2\n")
    );
    for path in [&file_path, &json_path, &toml_path, &env_path] {
        let mode = std::os::unix::fs::PermissionsExt::mode(
            &std::fs::metadata(path).unwrap().permissions(),
        );
        assert_eq!(mode & 0o777, 0o600, "{}", path.display());
    }
    let put = f.sinks.put.borrow();
    assert_eq!(put[0].1, "PAY_SECRET", "the spec's last part is the whole secret name");
    assert_eq!(put[0].2, VALUE);
    assert_eq!(
        put[1].0,
        Store::Vault { prefix: "PAY_API_KEY".into(), hosts: vec!["api.pay.example".into()] },
        "a kept key with hosts is filled only toward them"
    );
    let stores = f.record()["stores"].clone();
    assert_eq!(stores.as_array().unwrap().len(), 6);
    assert!(stores.as_array().unwrap().contains(&json!("gh-secret:acme/app:PAY_SECRET")));
    assert!(
        stores
            .as_array()
            .unwrap()
            .contains(&json!(format!("json:{}#auth.token", json_path.display())))
    );
    f.assert_no_value_outside_the_store(&[&reply]);
}

#[test]
fn write_refuses_a_link_and_a_file_that_is_not_json() {
    let f = Fixture::new();
    f.put("");
    let real = f.root.join("real");
    std::fs::write(&real, "x").unwrap();
    let link = f.root.join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let error =
        f.run(&format!("write PAY_KEY --to file:{}", link.display()), &no_app()).unwrap_err();
    assert!(error.contains("not a plain file"), "{error}");
    assert_eq!(std::fs::read_to_string(&real).unwrap(), "x");
    let broken = f.root.join("broken.json");
    std::fs::write(&broken, "{ not json").unwrap();
    let error =
        f.run(&format!("write PAY_KEY --to json:{}#a", broken.display()), &no_app()).unwrap_err();
    assert!(error.contains("not JSON"), "{error}");
    assert_eq!(std::fs::read_to_string(&broken).unwrap(), "{ not json");
}

#[test]
fn env_lines_quote_what_a_shell_would_read_otherwise() {
    assert_eq!(*set_env_line(None, "K", "a b\"$c"), "K=\"a b\\\"\\$c\"\n");
    assert_eq!(*set_env_line(Some("K=1\nK=2\n"), "K", "plain-value"), "K=plain-value\n");
}

fn browser(url: &'static str, echo: bool) -> impl Fn(&str, &Value) -> Answer {
    move |method, params| match method {
        "browser.page.state" => Ok(Ok(json!({"tab": "tab_1", "url": url}))),
        "browser.page.fill" | "browser.page.type" => {
            // An app that echoes the field's new value back: it must never reach the reply.
            let value = if echo { params["text"].clone() } else { Value::Null };
            Ok(Ok(json!({"tab": "tab_1", "value": value})))
        }
        other => Err(format!("unexpected {other}")),
    }
}

#[test]
fn fill_types_the_key_by_reference_into_a_page_on_its_hosts_only() {
    let f = Fixture::new();
    f.put("--hosts pay.example");
    let app = FakeApp::new(browser("https://dashboard.pay.example/apikeys", true));
    let reply = f.run("fill PAY_KEY --selector #api-key", &app).unwrap();
    assert_eq!(app.methods(), vec!["browser.page.state", "browser.page.fill"]);
    let sent = app.calls.borrow()[1].1.clone();
    assert_eq!(sent["text"], VALUE, "the app gets the value, from this process");
    assert_eq!(sent["secret"], true);
    assert_eq!(sent["secret_hosts"], json!(["pay.example"]));
    assert_eq!(reply["filled"], "PAY_KEY");
    assert_eq!(reply["host"], "dashboard.pay.example");
    assert_eq!(f.record()["uses"][0]["target"], "browser:dashboard.pay.example #api-key");
    f.assert_no_value_outside_the_store(&[&reply]);

    // Another site gets nothing.
    let phishing = FakeApp::new(browser("https://pay.example.evil.test/login", true));
    let error = f.run("fill PAY_KEY --selector #api-key", &phishing).unwrap_err();
    assert!(error.contains("not filled"), "{error}");
    assert_eq!(phishing.methods(), vec!["browser.page.state"], "nothing typed");
    assert!(!error.contains(VALUE));
}

#[test]
fn request_asks_the_app_and_answers_the_record_the_person_stored() {
    let f = Fixture::new();
    // The app: shows the ask, and stores what the person pastes as `cmux keys put --from-person` does.
    let app = FakeApp::new(|method, params| {
        assert_eq!(method, "keys.request");
        assert_eq!(params["name"], "EVAL_API_KEY");
        assert_eq!(params["purpose"], "evals");
        assert!(params.get("value").is_none());
        let put = Put {
            name: "EVAL_API_KEY".into(),
            purpose: Some("evals".into()),
            hosts: vec![],
            ttl: None,
            replace: false,
            asked_by: params["requester"].as_str().map(str::to_owned),
            from_person: true,
        };
        store(&f.paths, &f.vault, &put, VALUE, "person")?;
        Ok(Ok(json!({"stored": true, "name": "EVAL_API_KEY"})))
    });
    let reply = f.run("request EVAL_API_KEY --purpose evals", &app).unwrap();
    assert_eq!(reply["stored"]["source"], "person");
    assert!(reply["stored"]["asked_by"].is_string());
    assert_eq!(f.vault.items.borrow().get("key.EVAL_API_KEY").map(String::as_str), Some(VALUE));
    f.assert_no_value_outside_the_store(&[&reply]);

    let declined = FakeApp::new(|_, _| Ok(Err(json!({"code": "declined", "message": "no"}))));
    let error = f.run("request OTHER_KEY --purpose evals", &declined).unwrap_err();
    assert!(error.contains("declined"), "{error}");
    let old_app = FakeApp::new(|_, _| Ok(Err(json!({"code": "method_not_found"}))));
    let error = f.run("request OTHER_KEY --purpose evals", &old_app).unwrap_err();
    assert!(error.contains("cmux keys put OTHER_KEY"), "{error}");
}

#[test]
fn hosts_match_the_host_or_a_subdomain_only() {
    let hosts = vec!["pay.example".to_owned()];
    assert!(host_allowed("pay.example", &hosts));
    assert!(host_allowed("dashboard.pay.example", &hosts));
    assert!(!host_allowed("evilpay.example", &hosts));
    assert!(!host_allowed("pay.example.evil.test", &hosts));
    assert_eq!(
        url_host("https://user@Dashboard.Pay.Example:443/x?y").as_deref(),
        Some("dashboard.pay.example")
    );
    assert_eq!(url_host("file:///etc/passwd"), None);
}

#[test]
fn json_answers_mask_the_value_anywhere_in_them() {
    let masked = mask_json(&json!({"a": [format!("x{VALUE}y")], VALUE: 1}), &[VALUE]);
    assert!(!masked.to_string().contains(VALUE));
}
