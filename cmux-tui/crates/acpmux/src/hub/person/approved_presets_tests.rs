//! `approved_presets`: a preset env the reviewed root-owned list approves needs no person; every
//! other spawn env is refused as before. The list is owned by the test's own user here (root on a
//! host), and the home is a temp folder standing in for `/home/leo`. Linux only, as the list is.
#![cfg(target_os = "linux")]

use super::approved_presets::{Source, approves};
use super::*;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

struct Fixture {
    _dir: tempfile::TempDir,
    etc: PathBuf,
    home: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let etc = dir.path().join("etc-acpmux");
        let home = dir.path().join("home-leo");
        std::fs::create_dir(&etc).unwrap();
        std::fs::create_dir(&home).unwrap();
        // Whatever the runner's umask: the folders above the list must not be group-writable.
        for d in [dir.path(), etc.as_path()] {
            std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::fs::create_dir(home.join(".codex-leo-personal")).unwrap();
        Self { _dir: dir, etc, home }
    }

    fn codex_home(&self) -> String {
        self.home.join(".codex-leo-personal").to_str().unwrap().to_owned()
    }

    fn file(&self) -> PathBuf {
        self.etc.join("approved-presets.json")
    }

    /// Write the list, 0644, owned by this user.
    fn write(&self, list: &Value) {
        std::fs::write(self.file(), serde_json::to_vec(list).unwrap()).unwrap();
        std::fs::set_permissions(self.file(), std::fs::Permissions::from_mode(0o644)).unwrap();
    }

    /// The committed entry for `leo-personal-astra`, with `env`.
    fn write_entry(&self, env: Value) {
        self.write(&json!({"schema": 1, "presets": [
            {"name": "leo-personal-astra", "harness": "codex", "env": env}
        ]}));
    }

    fn source(&self) -> Source {
        Source {
            path: self.file(),
            owner_uid: unsafe { libc::getuid() },
            home: Some(self.home.clone()),
        }
    }
}

/// What `acpmux preset leo-personal-astra harness=codex model=gpt-6.2-astra effort=high
/// env.CODEX_HOME=<home>/.codex-leo-personal` sends (`cli/orchestrate/presets.rs`).
fn the_command(codex_home: &str) -> Value {
    json!({"name": "leo-personal-astra", "set": {
        "harness": "codex", "model": "gpt-6.2-astra", "effort": "high",
        "env": {"CODEX_HOME": codex_home},
    }})
}

#[test]
fn the_refused_command_is_approved_when_the_committed_preset_matches() {
    let f = Fixture::new();
    f.write_entry(json!({"CODEX_HOME": f.codex_home()}));
    assert!(approves(&f.source(), &the_command(&f.codex_home())));
    // A folder that does not exist yet, below the home, counts too.
    let later = f.home.join(".codex-later").to_str().unwrap().to_owned();
    f.write_entry(json!({"CODEX_HOME": later}));
    assert!(approves(&f.source(), &the_command(&later)));
}

#[test]
fn no_file_approves_nothing() {
    let f = Fixture::new();
    assert!(!approves(&f.source(), &the_command(&f.codex_home())));
    assert!(!approves(&Source { home: None, ..f.source() }, &the_command(&f.codex_home())));
}

#[test]
fn a_preset_the_list_does_not_name_is_refused() {
    let f = Fixture::new();
    f.write_entry(json!({"CODEX_HOME": f.codex_home()}));
    let mut other = the_command(&f.codex_home());
    other["name"] = json!("leo-personal-other");
    assert!(!approves(&f.source(), &other));
    // Another harness for the same name.
    let mut claude = the_command(&f.codex_home());
    claude["set"]["harness"] = json!("claude");
    assert!(!approves(&f.source(), &claude));
    // No harness in the request: the stored one is not looked up.
    let mut bare = the_command(&f.codex_home());
    bare["set"].as_object_mut().unwrap().remove("harness");
    assert!(!approves(&f.source(), &bare));
    // A clear is never approved here.
    let mut clear = the_command(&f.codex_home());
    clear["clear"] = json!(true);
    assert!(!approves(&f.source(), &clear));
}

#[test]
fn an_env_that_is_not_exactly_the_committed_map_is_refused() {
    let f = Fixture::new();
    f.write_entry(json!({"CODEX_HOME": f.codex_home()}));
    // Another value.
    let other = f.home.join(".codex").to_str().unwrap().to_owned();
    assert!(!approves(&f.source(), &the_command(&other)));
    // One key more.
    let mut more = the_command(&f.codex_home());
    more["set"]["env"]["NODE_OPTIONS"] = json!("--require /tmp/x.js");
    assert!(!approves(&f.source(), &more));
    // A null (a removal) or a non-string.
    let mut null = the_command(&f.codex_home());
    null["set"]["env"]["CODEX_HOME"] = Value::Null;
    assert!(!approves(&f.source(), &null));
    let mut empty = the_command(&f.codex_home());
    empty["set"]["env"] = json!({});
    assert!(!approves(&f.source(), &empty));
}

#[test]
fn an_unlisted_env_key_is_refused_even_when_the_file_lists_it() {
    let f = Fixture::new();
    for key in ["PATH", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "OPENAI_API_KEY"] {
        let value = f.home.join("bin").to_str().unwrap().to_owned();
        f.write_entry(json!({key: value}));
        let mut req = the_command(&f.codex_home());
        req["set"]["env"] = json!({key: value});
        assert!(!approves(&f.source(), &req), "{key}");
    }
}

#[test]
fn a_path_outside_the_home_is_refused_even_when_the_file_lists_it() {
    let f = Fixture::new();
    let home = f.home.to_str().unwrap().to_owned();
    let outside = f.etc.to_str().unwrap().to_owned();
    for value in [
        outside.clone(),
        "/tmp/codex".to_owned(),
        format!("{home}/../etc-acpmux"),
        format!("{home}/./.codex-leo-personal"),
        home.clone(),
        format!("{home}-other/.codex"),
        ".codex-leo-personal".to_owned(),
        String::new(),
        // The spawn expands these (`config.rs`): `${model}` comes from the same request.
        format!("{home}/x${{model}}"),
        format!("{home}/${{home}}"),
        "~/.codex-leo-personal".to_owned(),
        format!("{home}/~x"),
    ] {
        f.write_entry(json!({"CODEX_HOME": value}));
        assert!(!approves(&f.source(), &the_command(&value)), "{value:?}");
    }
    // A symlink below the home that resolves outside it.
    std::os::unix::fs::symlink(&f.etc, f.home.join(".codex-escape")).unwrap();
    let escape = f.home.join(".codex-escape").to_str().unwrap().to_owned();
    f.write_entry(json!({"CODEX_HOME": escape}));
    assert!(!approves(&f.source(), &the_command(&escape)));
    let below = f.home.join(".codex-escape/deeper").to_str().unwrap().to_owned();
    f.write_entry(json!({"CODEX_HOME": below}));
    assert!(!approves(&f.source(), &the_command(&below)));
}

#[test]
fn a_list_anyone_but_its_owner_could_write_approves_nothing() {
    // Not a regular file: a FIFO at the path (opened non-blocking, then refused).
    {
        let f = Fixture::new();
        let c = std::ffi::CString::new(f.file().to_str().unwrap()).unwrap();
        // SAFETY: a NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o644) }, 0);
        assert!(!approves(&f.source(), &the_command(&f.codex_home())));
    }
    let f = Fixture::new();
    f.write_entry(json!({"CODEX_HOME": f.codex_home()}));
    let req = the_command(&f.codex_home());
    // The daemon's own user wrote it, and root is required: an agent's file.
    if unsafe { libc::getuid() } != 0 {
        assert!(!approves(&Source { owner_uid: 0, ..f.source() }, &req));
    }
    // Group or world writable.
    for mode in [0o664, 0o646] {
        std::fs::set_permissions(f.file(), std::fs::Permissions::from_mode(mode)).unwrap();
        assert!(!approves(&f.source(), &req), "{mode:o}");
    }
    std::fs::set_permissions(f.file(), std::fs::Permissions::from_mode(0o644)).unwrap();
    // A writable folder above it.
    std::fs::set_permissions(&f.etc, std::fs::Permissions::from_mode(0o777)).unwrap();
    assert!(!approves(&f.source(), &req));
    std::fs::set_permissions(&f.etc, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(approves(&f.source(), &req));
    // A folder above it that is a symlink to a folder another user could own: resolved, then checked.
    let linked = f.home.join("etc-link");
    std::os::unix::fs::symlink(&f.etc, &linked).unwrap();
    assert!(approves(&Source { path: linked.join("approved-presets.json"), ..f.source() }, &req));
    std::fs::set_permissions(&f.etc, std::fs::Permissions::from_mode(0o775)).unwrap();
    assert!(!approves(&Source { path: linked.join("approved-presets.json"), ..f.source() }, &req));
    std::fs::set_permissions(&f.etc, std::fs::Permissions::from_mode(0o755)).unwrap();
    // The path itself a symlink to a good file.
    let link = f.etc.join("link.json");
    std::os::unix::fs::symlink(f.file(), &link).unwrap();
    assert!(!approves(&Source { path: link, ..f.source() }, &req));
}

#[test]
fn a_malformed_list_approves_nothing() {
    let f = Fixture::new();
    let req = the_command(&f.codex_home());
    let entry = json!({"name": "leo-personal-astra", "harness": "codex", "env": {"CODEX_HOME": f.codex_home()}});
    for list in [
        json!({"schema": 2, "presets": [entry.clone()]}),
        json!({"presets": [entry.clone()]}),
        json!({"schema": 1, "presets": [entry.clone()], "extra": true}),
        json!({"schema": 1, "presets": [{"name": "leo-personal-astra", "harness": "codex",
               "env": {"CODEX_HOME": f.codex_home()}, "policy": "approve-all"}]}),
        json!([entry.clone()]),
    ] {
        f.write(&list);
        assert!(!approves(&f.source(), &req), "{list}");
    }
    std::fs::write(f.file(), b"{not json").unwrap();
    assert!(!approves(&f.source(), &req));
    // Over the size limit.
    let big = json!({"schema": 1, "about": "x".repeat(70 * 1024), "presets": [entry]});
    f.write(&big);
    assert!(!approves(&f.source(), &req));
}

fn test_hub(f: Option<&Fixture>) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]},
                      "claude": {"argv": ["claude"], "family": "claude"}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    if let Some(f) = f {
        *hub.approved_presets.lock().unwrap() = f.source();
    }
    hub
}

async fn check(hub: &Hub, m: &str, params: &Value) -> Result<(), RpcError> {
    hub.person_check(false, false, None, true, m, params).await.map(|_| ())
}

fn refused(r: Result<(), RpcError>) -> bool {
    r.is_err_and(|e| e.data.as_ref().is_some_and(|d| d["reason"] == REASON))
}

#[tokio::test]
async fn the_person_check_lets_the_approved_preset_through_and_nothing_wider() {
    let f = Fixture::new();
    f.write_entry(json!({"CODEX_HOME": f.codex_home()}));
    let req = the_command(&f.codex_home());
    // The daemon's own list (none on a test host): refused as today.
    assert!(refused(check(&test_hub(None), method::MUX_PRESETS, &req).await));
    let hub = test_hub(Some(&f));
    check(&hub, method::MUX_PRESETS, &req).await.expect("an approved preset env");
    // The same env as a daemon default: still the person's.
    let defaults = json!({"family": "codex", "set": {"env": {"CODEX_HOME": f.codex_home()}}});
    assert!(refused(check(&hub, method::MUX_DEFAULTS, &defaults).await));
    // The approved env with a policy that does not ask, a mode, or an approval: still the person's.
    let mut wide = req.clone();
    wide["set"]["policy"] = json!("approve-all");
    assert!(refused(check(&hub, method::MUX_PRESETS, &wide).await));
    let mut approve = req.clone();
    approve["approveMode"] = json!(true);
    assert!(refused(check(&hub, method::MUX_PRESETS, &approve).await));
    // A mode: the preset mode check still runs. A Claude preset with its approved config folder
    // may start in an asking mode, never in one that skips the asks.
    let dir = f.home.join(".claude-other").to_str().unwrap().to_owned();
    f.write(&json!({"schema": 1, "presets": [
        {"name": "claude-other", "harness": "claude", "env": {"CLAUDE_CONFIG_DIR": dir}}
    ]}));
    let claude = |mode: &str| {
        json!({"name": "claude-other", "set": {
            "harness": "claude", "mode": mode, "env": {"CLAUDE_CONFIG_DIR": dir},
        }})
    };
    check(&hub, method::MUX_PRESETS, &claude("plan")).await.expect("an asking mode");
    assert!(refused(check(&hub, method::MUX_PRESETS, &claude("bypassPermissions")).await));
    f.write_entry(json!({"CODEX_HOME": f.codex_home()}));
    // Another value, key or name.
    let other = f.home.join(".codex").to_str().unwrap().to_owned();
    assert!(refused(check(&hub, method::MUX_PRESETS, &the_command(&other)).await));
    let mut renamed = req.clone();
    renamed["name"] = json!("someone-else");
    assert!(refused(check(&hub, method::MUX_PRESETS, &renamed).await));
}
