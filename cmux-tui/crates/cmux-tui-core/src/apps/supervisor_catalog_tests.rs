//! Supervisor tests of the catalog: default and first-party apps, native
//! panes and scope classes.

use super::*;

#[test]
fn the_shipped_first_party_directory_is_the_default_set() {
    let root = temp_dir();
    let first_party = root.0.join("first-party");
    write_app(&first_party, "coderouter", "cmux/coderouter", json!({ "workspace:read": "r" }));
    write_app(&first_party, "impostor", "octo/impostor", json!({}));
    let catalog = super::super::catalog::load(&Sources {
        first_party: Some(first_party),
        bundled: vec![],
        local: None,
        defaults: None,
    });
    assert_eq!(catalog.defaults, vec!["cmux/coderouter".to_string()]);
    assert_eq!(catalog.packages["cmux/coderouter"].source, super::super::mirror::Source::Default);
    assert!(
        !catalog.packages.contains_key("octo/impostor"),
        "only first-party apps load from there"
    );
    // CMUX_APPS_DEFAULT replaces the shipped set.
    let overridden = super::super::catalog::load(&Sources {
        first_party: Some(root.0.join("first-party")),
        bundled: vec![],
        local: None,
        defaults: Some(vec![]),
    });
    assert!(overridden.defaults.is_empty());
    assert_eq!(
        overridden.packages["cmux/coderouter"].source,
        super::super::mirror::Source::Bundled
    );
}

#[test]
fn a_fresh_daemon_with_the_bundle_path_lists_coderouter_installed_by_default() {
    let root = temp_dir();
    let first_party = root.0.join("first-party");
    write_app(&first_party, "coderouter", "cmux/coderouter", json!({ "workspace:read": "r" }));
    // The manifest says the app starts hidden (presentation.hiddenByDefault).
    let path = first_party.join("coderouter/cmux-app.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    manifest["presentation"] = json!({ "hiddenByDefault": true });
    std::fs::write(&path, manifest.to_string()).unwrap();
    write_app(&first_party, "notes", "cmux/notes", json!({ "workspace:read": "r" }));
    let supervisor = Supervisor::new(
        Config {
            state_dir: Some(root.0.join("state")),
            host_binary: None,
            host_args: Vec::new(),
            server_dir: None,
            sources: Sources {
                first_party: Some(first_party),
                bundled: vec![],
                local: None,
                defaults: None,
            },
            idle_stop: Duration::from_secs(60),
            provider_deadline: Duration::from_secs(30),
            provider_user_deadline: Duration::from_secs(600),
        },
        Box::new(Arc::new(FakeRouter::default())),
        Box::new(Arc::new(FakeFetcher::default())),
    );
    let coderouter = app_entry(&supervisor.list(), "cmux/coderouter");
    assert_eq!(
        (
            coderouter["installed"].clone(),
            coderouter["source"].clone(),
            coderouter["grants"].clone()
        ),
        (json!(true), json!("default"), json!(["workspace:read"]))
    );
    // A shipped default: installed and hidden, still reachable by op and
    // palette; first-party apps are hide-only.
    assert_eq!(
        (coderouter["hidden"].clone(), coderouter["hide_only"].clone()),
        (json!(true), json!(true))
    );
    // A default without the field starts visible.
    assert_eq!(app_entry(&supervisor.list(), "cmux/notes")["hidden"], json!(false));
    let mut op = SetOp {
        key: "rm".into(),
        app: "cmux/coderouter".into(),
        origin: Origin::User,
        ..SetOp::default()
    };
    op.installed = Some(false);
    assert_eq!(supervisor.set(CLIENT, op).unwrap_err().code, "apps.first_party_hide_only");
    drop(supervisor);
    // A mirror from before the rule holds a tombstone (installed false): the
    // next start restores the app, installed and hidden.
    let path = root.0.join("state/apps.json");
    let mut file: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    file["mirror"]["apps"]["cmux/coderouter"]["installed"] = json!(false);
    file["mirror"]["apps"]["cmux/coderouter"]["hidden"] = json!(false);
    file["mirror"]["apps"]["cmux/coderouter"]["grants"] = json!([]);
    std::fs::write(&path, file.to_string()).unwrap();
    let again = Supervisor::new(
        Config {
            state_dir: Some(root.0.join("state")),
            host_binary: None,
            host_args: Vec::new(),
            server_dir: None,
            sources: Sources {
                first_party: Some(root.0.join("first-party")),
                bundled: vec![],
                local: None,
                defaults: None,
            },
            idle_stop: Duration::from_secs(60),
            provider_deadline: Duration::from_secs(30),
            provider_user_deadline: Duration::from_secs(600),
        },
        Box::new(Arc::new(FakeRouter::default())),
        Box::new(Arc::new(FakeFetcher::default())),
    );
    let restored = app_entry(&again.list(), "cmux/coderouter");
    assert_eq!(
        (restored["installed"].clone(), restored["hidden"].clone(), restored["grants"].clone()),
        (json!(true), json!(true), json!(["workspace:read"]))
    );
    // The restore was written back to apps.json.
    let file: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(file["mirror"]["apps"]["cmux/coderouter"]["installed"], json!(true));
}

#[test]
fn apps_list_marks_first_party_apps_hide_only() {
    let f = fixture();
    let list = f.supervisor.list();
    assert_eq!(app_entry(&list, "cmux/demo")["hide_only"], json!(true));
    assert_eq!(app_entry(&list, "local/spy")["hide_only"], json!(false));
}

/// Gate for the switch to the daemon supervisor: every bundled first-party
/// app (`first-party-apps/<name>/BUNDLED`) loads through the supervisor's
/// loader and the manifest v2 validator, preferring `cmux-app.v2.json`, and
/// is installed by default. No first-party app may vanish at the switch.
#[test]
fn every_bundled_first_party_app_loads_and_is_installed_by_default() {
    let tree = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../first-party-apps");
    let mut bundled: Vec<(String, PathBuf)> = std::fs::read_dir(&tree)
        .expect("first-party-apps")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|dir| dir.join("BUNDLED").is_file())
        .map(|dir| {
            let file = super::super::catalog::manifest_file(&dir, true);
            let manifest: Value =
                serde_json::from_str(&std::fs::read_to_string(dir.join(file)).expect("manifest"))
                    .expect("json");
            (manifest["id"].as_str().unwrap_or_default().to_string(), dir)
        })
        .collect();
    bundled.sort();
    assert!(!bundled.is_empty(), "no bundled first-party app found in {}", tree.display());
    let root = temp_dir();
    let supervisor = Supervisor::new(
        Config {
            state_dir: Some(root.0.join("state")),
            host_binary: None,
            host_args: Vec::new(),
            server_dir: None,
            sources: Sources {
                first_party: Some(tree.clone()),
                bundled: vec![],
                local: None,
                defaults: None,
            },
            idle_stop: Duration::from_secs(60),
            provider_deadline: Duration::from_secs(30),
            provider_user_deadline: Duration::from_secs(600),
        },
        Box::new(Arc::new(FakeRouter::default())),
        Box::new(Arc::new(FakeFetcher::default())),
    );
    let catalog = super::super::catalog::load(&Sources {
        first_party: Some(tree),
        bundled: vec![],
        local: None,
        defaults: None,
    });
    let list = supervisor.list();
    for (id, dir) in bundled {
        let why = catalog.rejected.iter().find(|(d, _)| *d == dir).map(|(_, issue)| issue.clone());
        assert!(
            catalog.packages.contains_key(&id),
            "{id} ({}) does not load: {why:?}",
            dir.display()
        );
        let entry = app_entry(&list, &id);
        assert_eq!(
            (entry["installed"].clone(), entry["source"].clone()),
            (json!(true), json!("default")),
            "{id}"
        );
    }
}

#[test]
fn native_pane_apps_install_and_list_but_never_spawn_a_host() {
    // A v2-only package (no cmux-app.json) whose only implementation is a
    // native pane and that has no runtime.main, like first-party Home.
    let root = temp_dir();
    let app = root.0.join("bundled/native");
    std::fs::create_dir_all(&app).unwrap();
    let manifest = json!({
        "manifestVersion": 2, "id": "cmux/native", "name": "Native", "version": "1.0.0",
        "description": "d", "engines": { "cmux": "^2.0" },
        "repository": "https://github.com/manaflow-ai/cmux",
        "implements": { "cmux.pane/1": { "native": "home", "title": "Native" } }
    });
    std::fs::write(app.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
    let f = fixture_with(&["cmux/native"], Duration::from_secs(60), root);
    let entry = app_entry(&f.supervisor.list(), "cmux/native");
    assert_eq!(
        (entry["installed"].clone(), entry["source"].clone()),
        (json!(true), json!("default"))
    );
    let refused =
        f.supervisor.mount(CLIENT, "n1", "cmux/native", "cmux.pane/1", json!({})).unwrap_err();
    assert_eq!(refused.code, "apps.interface");
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request("cmux/native", "native.open", None, Origin::User, None),
        Box::new(move |r| tx.send(r).unwrap()),
    );
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err().code,
        "apps.op.unknown"
    );
    assert!(
        f.events.try_iter().all(|e| e["event"] != "apps-host"),
        "a native-pane app never starts a host"
    );
}

#[test]
fn apps_list_shows_scope_classes_and_elevated_grants_need_the_user() {
    let root = temp_dir();
    let bundled = root.0.join("bundled");
    write_app(&bundled, "term", "cmux/term", json!({ "workspace:read": "r" }));
    let path = bundled.join("term/cmux-app.json");
    let mut manifest: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    manifest["optionalScopes"] = json!({ "terminal:backend": "Run terminals for you." });
    std::fs::write(&path, manifest.to_string()).unwrap();
    let f = fixture_with(&[], Duration::from_secs(60), root);
    let entry = app_entry(&f.supervisor.list(), "cmux/term");
    assert_eq!(
        entry["scope_classes"],
        json!({ "workspace:read": "standard", "terminal:backend": "elevated" })
    );
    f.install("cmux/term");
    let installed = app_entry(&f.supervisor.list(), "cmux/term");
    assert_eq!(installed["grants"], json!(["workspace:read"]), "never granted at install");
    let refused = f
        .set("cli", "cmux/term", Origin::Cli, |o| o.grant = Some(("terminal:backend".into(), true)))
        .unwrap_err();
    assert_eq!(refused.code, "apps.scope_elevated");
    f.set("user", "cmux/term", Origin::User, |o| o.grant = Some(("terminal:backend".into(), true)))
        .unwrap();
    let granted = app_entry(&f.supervisor.list(), "cmux/term");
    assert_eq!(granted["grants"], json!(["terminal:backend", "workspace:read"]));
}
