use std::cell::Cell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::daemon::{Daemon, answer, platform_for, wipe};
use super::ops::{Failure, Local, execute, github_repo};
use super::{Command, Fields, Network, parse, render};

const SECRET: &str = "sk-live-hunter2-0123456789";

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn record(id: &str, name: &str, scope: &str) -> Value {
    json!({"id": id, "name": name, "scope": scope, "is_default": name == "Default",
        "repo": "manaflow-ai/cmux", "ref": "main", "setup_script": "bun install",
        "env_vars": [{"name": "NODE_ENV", "value": "test"}],
        "secrets": [{"name": "API_KEY", "updated_at": 1, "hosts": ["api.example.com"],
            "header": {"name": "x-api-key", "format": "{value}"}}],
        "files": [{"path": ".env.example", "content": "A=1\n"}],
        "network": {"mode": "limited", "package_managers": true, "domains": ["example.com"]}})
}

/// A daemon with three environments that records every call and answers a change with the
/// environment as saved. `echo` makes its replies carry the secret's value, as a careless upstream
/// might; `refuse` makes `update` fail with a message that quotes it.
#[derive(Default)]
struct FakeDaemon {
    calls: Vec<(String, Value)>,
    echo: bool,
    refuse: bool,
    default: Option<String>,
}

fn environments() -> Vec<Value> {
    vec![
        record("env_000000000000000000000001", "Default", "personal"),
        record("env_000000000000000000000002", "web", "personal"),
        record("env_000000000000000000000003", "web", "team"),
        record("env_000000000000000000000004", "api", "team"),
    ]
}

impl Daemon for FakeDaemon {
    fn call(&mut self, action: &str, params: &Value) -> Result<Value, Failure> {
        self.calls.push((action.to_owned(), params.clone()));
        let secret_echo = |mut value: Value| {
            if self.echo {
                value["secrets"] = json!([{"name": "API_KEY", "value": SECRET, "sealed": SECRET,
                    "hosts": ["api.example.com"],
                    "header": {"name": "x-api-key", "format": "{value}"}}]);
                value["access_token"] = json!(SECRET);
            }
            value
        };
        match action {
            "list" => Ok(Value::Array(environments().into_iter().map(secret_echo).collect())),
            "update" if self.refuse => Err(Failure::new(
                "cloud_environment.invalid",
                format!("platform said: {SECRET} is not allowed"),
                1,
            )),
            "update" => {
                let mut saved = environments()
                    .into_iter()
                    .find(|env| env["id"] == params["id"])
                    .expect("an update names a listed environment");
                for (key, value) in params["patch"].as_object().unwrap() {
                    saved[key] = value.clone();
                }
                saved.as_object_mut().unwrap().remove("set_secrets");
                Ok(secret_echo(saved))
            }
            "create" => {
                let mut created = params["environment"].clone();
                created["id"] = json!("env_00000000000000000000000f");
                created["scope"] = json!("personal");
                Ok(created)
            }
            "default-get" => Ok(match &self.default {
                Some(id) => json!([
                    {"scope": "team", "repo": params["repo"], "environment": "env_000000000000000000000002"},
                    {"scope": "personal", "repo": params["repo"], "environment": id},
                ]),
                None => json!([]),
            }),
            "default-set" => {
                Ok(json!({"repo": params["repo"], "environment": params["environment"]}))
            }
            "derive" => Ok(json!({"status": "failed", "attempt": 2, "ref": params.get("ref"),
                "steps": [{"id": "install", "state": "failed", "detail": "bun install"}],
                "error": {"code": "environment.install_failed", "message": "install failed",
                    "log_tail": "error: lockfile mismatch\n"},
                "script_output": {"kind": "maintenance", "attempt": 2, "exit_code": 1,
                    "log_tail": "maintenance: lockfile mismatch\n", "finished_at": 5}})),
            other => panic!("unexpected action {other}"),
        }
    }
}

#[derive(Default)]
struct FakeLocal {
    files: HashMap<PathBuf, String>,
    repo: Option<String>,
    asked: Cell<usize>,
}

impl Local for FakeLocal {
    fn read_file(&self, path: &Path) -> Result<String, Failure> {
        self.files
            .get(path)
            .cloned()
            .ok_or_else(|| Failure::new("env.file_unreadable", "missing", 1))
    }
    fn current_repo(&self) -> Option<String> {
        self.repo.clone()
    }
    fn secret_value(&self, _key: &str) -> Result<Zeroizing<String>, Failure> {
        self.asked.set(self.asked.get() + 1);
        Ok(Zeroizing::new(SECRET.to_owned()))
    }
}

fn run(line: &str, daemon: &mut FakeDaemon, local: &FakeLocal) -> Result<Value, Failure> {
    execute(&parse(&words(line)).unwrap(), daemon, local)
}

/// Every printed form of `answer`: `--json` (as `print_local_success` writes it) and the text form.
fn printed(line: &str, answer: &Value) -> String {
    let command = parse(&words(line)).unwrap();
    format!("{answer}\n{}", render::human(&command, answer))
}

#[test]
fn every_verb_parses_and_help_is_help() {
    for help in ["", "help", "--help", "list --help", "set-secret web K -h"] {
        assert_eq!(parse(&words(help)), Ok(Command::Help), "{help:?}");
    }
    assert_eq!(parse(&words("ls")), Ok(Command::List));
    assert_eq!(parse(&words("show web")), Ok(Command::Show { env: "web".into() }));
    assert_eq!(
        parse(&words("create api --repo a/b --ref dev --setup-file s.sh --maintenance-file m.sh")),
        Ok(Command::Create {
            name: "api".into(),
            fields: Fields {
                repo: Some("a/b".into()),
                git_ref: Some("dev".into()),
                setup_file: Some("s.sh".into()),
                maintenance_file: Some("m.sh".into()),
                ..Fields::default()
            }
        })
    );
    assert_eq!(
        parse(&words("edit web --image ubuntu-24.04 --network=off")),
        Ok(Command::Edit {
            env: "web".into(),
            fields: Fields {
                image: Some("ubuntu-24.04".into()),
                network: Some(Network::Off),
                ..Fields::default()
            }
        })
    );
    assert_eq!(
        parse(&words("set-secret web API_KEY --host api.example.com --host b.example.com")),
        Ok(Command::SetSecret {
            env: "web".into(),
            key: "API_KEY".into(),
            hosts: vec!["api.example.com".into(), "b.example.com".into()]
        })
    );
    assert_eq!(parse(&words("default")), Ok(Command::Default { repo: None, env: None }));
    assert_eq!(
        parse(&words("default --repo a/b web")),
        Ok(Command::Default { repo: Some("a/b".into()), env: Some("web".into()) })
    );
    for bad in [
        "list extra",
        "create",
        "create api --image x",
        "create api --network off",
        "edit web",
        "edit web --network none",
        "edit web --repo nope",
        "edit web --repo a/b --repo c/d",
        "set-var web 1BAD v",
        "set-var web K",
        "add-file web .env",
        "add-file web ../x --from f",
        "rm-file web",
        "logs",
        "default a b",
        "show web --repo a/b",
        "unknown web",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

#[test]
fn a_secret_value_is_never_an_argument_and_a_secret_needs_a_host() {
    for line in [
        format!("set-secret web API_KEY {SECRET} --host api.example.com"),
        format!("set-secret web API_KEY --host api.example.com {SECRET}"),
        format!("set-secret web API_KEY --value {SECRET} --host api.example.com"),
        format!("set-secret web API_KEY --value={SECRET} --host api.example.com"),
    ] {
        let error = parse(&words(&line)).expect_err(&line);
        assert!(!error.0.contains(SECRET), "a refusal never quotes the value: {}", error.0);
    }
    let refused = parse(&words("set-secret web API_KEY")).unwrap_err();
    assert!(refused.0.contains("--host"), "{}", refused.0);
    for host in [
        "https://api.example.com",
        "API.example.com",
        "*.example.com",
        "api.example.com:443",
        "localhost",
    ] {
        assert!(parse(&words(&format!("set-secret web K --host {host}"))).is_err(), "{host}");
    }
    let nine = (0..9).map(|i| format!("--host h{i}.example.com")).collect::<Vec<_>>().join(" ");
    assert!(parse(&words(&format!("set-secret web K {nine}"))).is_err(), "at most 8 hosts");
}

#[test]
fn set_secret_sends_the_value_once_and_never_prints_it() {
    let line = "set-secret env_000000000000000000000004 API_KEY --host api.example.com";
    let mut daemon = FakeDaemon { echo: true, ..FakeDaemon::default() };
    let local = FakeLocal::default();
    let saved = run(line, &mut daemon, &local).unwrap();
    assert_eq!(local.asked.get(), 1, "the value is read once, from the prompt or stdin");
    // The one update carries it, with the secret's header kept and its hosts.
    let updates: Vec<&Value> =
        daemon.calls.iter().filter(|(a, _)| a == "update").map(|(_, p)| p).collect();
    assert_eq!(updates.len(), 1);
    assert_eq!(
        updates[0]["patch"],
        json!({"set_secrets": [{"name": "API_KEY", "value": SECRET, "hosts": ["api.example.com"],
            "header": {"name": "x-api-key", "format": "{value}"}}]})
    );
    let other_calls = daemon.calls.iter().filter(|(a, _)| a != "update");
    assert!(other_calls.into_iter().all(|(_, params)| !params.to_string().contains(SECRET)));
    // The daemon's reply carried the value (echo); neither --json nor text prints it.
    let out = printed(line, &saved);
    assert!(!out.contains(SECRET), "{out}");
    assert_eq!(saved["secrets"], json!([{"name": "API_KEY", "hosts": ["api.example.com"]}]));
}

#[test]
fn a_refused_secret_never_carries_the_value_in_its_error() {
    let mut daemon = FakeDaemon { refuse: true, ..FakeDaemon::default() };
    let failure =
        run("set-secret api API_KEY --host api.example.com", &mut daemon, &FakeLocal::default())
            .unwrap_err();
    assert_eq!(failure.code, "cloud_environment.invalid");
    assert!(!format!("{failure:?}").contains(SECRET), "{failure:?}");
    assert!(failure.message.contains("[redacted]"), "{}", failure.message);
}

#[test]
fn a_daemon_refusal_is_its_code_and_its_own_message() {
    let failure = answer(
        json!({"id": "cmux-env", "ok": false, "error_code": "cloud_environment.secret_needs_host",
        "error": "Could not save or load the cloud environment. Try again."}),
    )
    .unwrap_err();
    assert_eq!(failure.code, "cloud_environment.secret_needs_host");
    assert_eq!(answer(json!({"ok": true, "data": [1]})), Ok(json!([1])));
}

#[test]
fn a_request_is_wiped_after_it_is_sent() {
    let mut request =
        json!({"access_token": SECRET, "params": {"patch": {"set_secrets": [{"value": SECRET}]}}});
    wipe(&mut request);
    assert!(!request.to_string().contains(SECRET), "{request}");
}

#[test]
fn show_and_list_print_secret_names_and_hosts_only() {
    let mut daemon = FakeDaemon { echo: true, ..FakeDaemon::default() };
    let local = FakeLocal::default();
    let shown = run("show api", &mut daemon, &local).unwrap();
    assert_eq!(shown["id"], "env_000000000000000000000004");
    assert_eq!(shown["files"], json!([{"path": ".env.example", "bytes": 4}]));
    assert_eq!(shown["env_vars"], json!([{"name": "NODE_ENV", "value": "test"}]));
    let out = printed("show api", &shown);
    assert!(!out.contains(SECRET) && out.contains("API_KEY -> api.example.com"), "{out}");
    let listed = run("list", &mut daemon, &local).unwrap();
    assert_eq!(listed["environments"].as_array().unwrap().len(), 4);
    assert!(!printed("list", &listed).contains(SECRET));
}

#[test]
fn a_name_shared_by_two_scopes_needs_the_id_and_an_unknown_name_fails() {
    let mut daemon = FakeDaemon::default();
    let local = FakeLocal::default();
    let ambiguous = run("show web", &mut daemon, &local).unwrap_err();
    assert_eq!(ambiguous.code, "env.ambiguous");
    assert!(ambiguous.message.contains("env_000000000000000000000002"), "{}", ambiguous.message);
    assert_eq!(run("show WEB2", &mut daemon, &local).unwrap_err().code, "env.not_found");
    assert_eq!(run("show API", &mut daemon, &local).unwrap()["name"], "api", "any case");
}

#[test]
fn edits_send_one_update_with_only_the_changed_fields() {
    let local = FakeLocal {
        files: HashMap::from([
            (PathBuf::from("s.sh"), "make".to_owned()),
            (PathBuf::from("m.sh"), "make update".to_owned()),
            (PathBuf::from("local.env"), "B=2\n".to_owned()),
        ]),
        ..FakeLocal::default()
    };
    let patch_of = |line: &str| {
        let mut daemon = FakeDaemon::default();
        run(line, &mut daemon, &local).unwrap();
        let (action, params) = daemon.calls.last().unwrap().clone();
        assert_eq!(action, "update", "{line}");
        assert_eq!(params["id"], "env_000000000000000000000004", "{line}");
        params["patch"].clone()
    };
    assert_eq!(
        patch_of(
            "edit api --setup-file s.sh --maintenance-file m.sh --repo a/b --ref dev --image img"
        ),
        json!({"setup_script": "make", "maintenance_script": "make update", "repo": "a/b", "ref": "dev", "image": "img"})
    );
    assert_eq!(
        patch_of("edit api --network off"),
        json!({"network": {"mode": "off", "package_managers": true, "domains": ["example.com"]}})
    );
    assert_eq!(
        patch_of("set-var api NODE_ENV production"),
        json!({"env_vars": [{"name": "NODE_ENV", "value": "production"}]})
    );
    assert_eq!(patch_of("unset-var api NODE_ENV"), json!({"env_vars": []}));
    assert_eq!(patch_of("unset-secret api API_KEY"), json!({"remove_secrets": ["API_KEY"]}));
    assert_eq!(
        patch_of("add-file api config/local.env --from local.env"),
        json!({"files": [{"path": ".env.example", "content": "A=1\n"}, {"path": "config/local.env", "content": "B=2\n"}]})
    );
    assert_eq!(patch_of("rm-file api .env.example"), json!({"files": []}));
    let mut daemon = FakeDaemon::default();
    for missing in ["unset-var api NOPE", "unset-secret api NOPE", "rm-file api nope.txt"] {
        assert_eq!(
            run(missing, &mut daemon, &local).unwrap_err().code,
            "env.not_found",
            "{missing}"
        );
    }
    assert!(daemon.calls.iter().all(|(action, _)| action == "list"), "nothing missing is saved");
}

#[test]
fn create_posts_the_name_and_the_given_fields() {
    let local = FakeLocal {
        files: HashMap::from([(PathBuf::from("s.sh"), "make".to_owned())]),
        ..FakeLocal::default()
    };
    let mut daemon = FakeDaemon::default();
    let created = run("create tools --repo a/b --setup-file s.sh", &mut daemon, &local).unwrap();
    assert_eq!(
        daemon.calls[0].1,
        json!({"environment": {"name": "tools", "repo": "a/b", "setup_script": "make"}})
    );
    assert_eq!(created["name"], "tools");
}

#[test]
fn default_reads_this_folders_repo_and_sets_an_environment_by_name() {
    let local = FakeLocal { repo: Some("manaflow-ai/cmux".into()), ..FakeLocal::default() };
    let mut daemon = FakeDaemon {
        default: Some("env_000000000000000000000004".into()),
        ..FakeDaemon::default()
    };
    let shown = run("default", &mut daemon, &local).unwrap();
    assert_eq!(shown["repo"], "manaflow-ai/cmux");
    assert_eq!(shown["environment"]["name"], "api");
    let set = run("default --repo a/b api", &mut daemon, &local).unwrap();
    assert_eq!(set["environment"]["id"], "env_000000000000000000000004");
    let (action, params) = daemon.calls.last().unwrap();
    assert_eq!(action, "default-set");
    assert_eq!(params, &json!({"repo": "a/b", "environment": "env_000000000000000000000004"}));
    let none = run("default", &mut FakeDaemon::default(), &local).unwrap();
    assert_eq!(none["environment"], Value::Null);
    let nowhere = run("default", &mut FakeDaemon::default(), &FakeLocal::default()).unwrap_err();
    assert_eq!(nowhere.exit, 2);
}

#[test]
fn logs_derive_the_environments_repository_and_print_the_output() {
    let mut daemon = FakeDaemon::default();
    let logs = run("logs api", &mut daemon, &FakeLocal::default()).unwrap();
    let (action, params) = daemon.calls.last().unwrap();
    assert_eq!(action, "derive");
    assert_eq!(
        params,
        &json!({"repo": "manaflow-ai/cmux", "ref": "main", "environment": "env_000000000000000000000004"})
    );
    assert_eq!(logs["log_tail"], "maintenance: lockfile mismatch\n", "script_output first");
    assert_eq!(logs["script"]["kind"], "maintenance");
    assert_eq!(logs["script"]["exit_code"], 1);
    let out = printed("logs api", &logs);
    assert!(out.contains("lockfile mismatch") && out.contains("failed"), "{out}");
}

#[test]
fn the_token_goes_only_to_the_platform_of_the_api_that_issued_it() {
    use cmux_cloud_environment as env;
    assert_eq!(platform_for(env::PRODUCTION_API).as_deref(), Some(env::PRODUCTION_PLATFORM));
    assert_eq!(
        platform_for(&format!("{}/", env::STAGING_API)).as_deref(),
        Some(env::STAGING_PLATFORM)
    );
    assert_eq!(platform_for("http://localhost:8787").as_deref(), Some("http://localhost:8788"));
    assert_eq!(platform_for("https://attacker.example"), None);
    assert_eq!(platform_for("https://cmux-api-preview-12.debussy.workers.dev"), None);
}

#[test]
fn a_github_origin_names_the_project() {
    for url in [
        "https://github.com/manaflow-ai/cmux.git",
        "https://github.com/manaflow-ai/cmux",
        "git@github.com:manaflow-ai/cmux.git",
        "ssh://git@github.com/manaflow-ai/cmux",
    ] {
        assert_eq!(github_repo(url).as_deref(), Some("manaflow-ai/cmux"), "{url}");
    }
    for url in ["https://gitlab.com/a/b", "git@github.com:a", "https://github.com/a/b/c"] {
        assert_eq!(github_repo(url), None, "{url}");
    }
}

#[test]
fn the_help_names_every_verb_and_says_a_secret_value_is_never_an_argument() {
    for verb in [
        "list",
        "show",
        "create",
        "edit",
        "set-var",
        "unset-var",
        "set-secret",
        "unset-secret",
        "add-file",
        "rm-file",
        "default",
        "logs",
    ] {
        assert!(super::USAGE.contains(&format!("cmux env {verb}")), "{verb}");
    }
    assert!(super::USAGE.contains("never from the command line"));
    assert!(super::USAGE.contains("--network off|limited|full"));
}
