//! Supervisor tests of the store's shelves (`apps.catalog.sections`) and
//! release notes (`versions` and `whats_new` on `apps.catalog.get`,
//! `store_sections.rs`) over a first-party directory.

use super::*;

/// A store app in `root`: manifest v2 with `categories`, and its What's New
/// file when `whats_new` is not null.
fn write_store_app(root: &Path, id: &str, name: &str, categories: Value, whats_new: Value) {
    let dir = root.join(id.split('/').nth(1).unwrap());
    std::fs::create_dir_all(dir.join("catalog")).unwrap();
    let manifest = json!({
        "manifestVersion": 2, "id": id, "name": name, "version": "1.0.0", "description": "d",
        "engines": { "cmux": "^2.0" }, "repository": "https://github.com/manaflow-ai/cmux",
        "categories": categories, "files": ["catalog/"],
    });
    std::fs::write(dir.join("cmux-app.v2.json"), manifest.to_string()).unwrap();
    if !whats_new.is_null() {
        std::fs::write(dir.join("catalog/whats-new.json"), whats_new.to_string()).unwrap();
    }
}

fn store_supervisor(root: &TempDir) -> Arc<Supervisor> {
    let first_party = root.0.join("first-party");
    let news = |version: &str, date_ms: i64| {
        json!({
            "version": version,
            "items": [{ "title": "Machines start faster", "pr": 44513 }],
            "versions": [
                { "version": version, "commit": "c2", "date_ms": date_ms },
                { "version": "0.9.0", "commit": "c1", "date_ms": 1000 },
            ],
        })
    };
    write_store_app(
        &first_party,
        "cmux/notes",
        "Notes",
        json!(["productivity"]),
        news("1.0.0", 3000),
    );
    write_store_app(
        &first_party,
        "cmux/dev",
        "Dev",
        json!(["developer-tools"]),
        // Written for an older version: stale, so not this version's news.
        news("0.9.0", 9000),
    );
    write_store_app(
        &first_party,
        "cmux/cloud",
        "Cloud",
        json!(["cloud", "developer-tools"]),
        news("1.0.0", 2000),
    );
    write_store_app(&first_party, "cmux/inbox", "Inbox", json!(["productivity"]), Value::Null);
    Supervisor::new(
        Config {
            state_dir: Some(root.0.join("state")),
            host_binary: None,
            host_args: Vec::new(),
            server_dir: None,
            sources: Sources {
                first_party: Some(first_party),
                // An SDK example is not on the store shelf.
                bundled: vec![root.0.join("bundled")],
                extra: vec![],
                local: None,
                customize: None,
                setups: None,
                saved_prompts: None,
                defaults: None,
            },
            idle_stop: Duration::from_secs(60),
            provider_deadline: Duration::from_secs(30),
            provider_user_deadline: Duration::from_secs(600),
            safe_mode_file: None,
            safe_mode_env: false,
        },
        Box::new(Arc::new(FakeRouter::default())),
        Box::new(Arc::new(FakeFetcher::default())),
    )
}

fn sections(supervisor: &Supervisor, args: Value) -> Value {
    supervisor.store_call(CLIENT, "cmux.apps.catalog.sections", args, Origin::Cli).unwrap()
}

fn shelf(answer: &Value) -> Vec<(String, Value, Value)> {
    answer["sections"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            (s["id"].as_str().unwrap().to_string(), s["apps"].clone(), s["next_cursor"].clone())
        })
        .collect()
}

#[test]
fn the_store_shelves_come_in_order_and_page() {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "demo", "cmux/demo", json!({}));
    let supervisor = store_supervisor(&root);

    let answer = sections(&supervisor, json!({}));
    assert!(answer["revision"].is_u64(), "{answer}");
    let featured = &answer["sections"][0];
    assert_eq!(
        (&featured["kind"], &featured["title_key"]),
        (&json!("featured"), &json!("apps.store.section.featured"))
    );
    let category = &answer["sections"][2];
    assert_eq!(
        (&category["kind"], &category["category"], &category["title_key"]),
        (&json!("category"), &json!("cloud"), &json!("apps.store.category.cloud"))
    );
    // Cloud first, then by name; recent by the current
    // version's date (a stale or missing file has none); one section per
    // category. The SDK example is on no shelf.
    let row = |id: &str, apps: Value| (id.to_string(), apps, Value::Null);
    assert_eq!(
        shelf(&answer),
        [
            row("featured", json!(["cmux/cloud", "cmux/dev", "cmux/inbox", "cmux/notes"])),
            row("recent", json!(["cmux/notes", "cmux/cloud"])),
            row("category:cloud", json!(["cmux/cloud"])),
            row("category:developer-tools", json!(["cmux/cloud", "cmux/dev"])),
            row("category:productivity", json!(["cmux/inbox", "cmux/notes"])),
        ]
    );

    // Paging: each section's first page names its next cursor; a section
    // and its cursor answer only that section's next page.
    let first = sections(&supervisor, json!({ "limit": 3 }));
    assert_eq!(first["sections"][0]["apps"], json!(["cmux/cloud", "cmux/dev", "cmux/inbox"]));
    assert_eq!(first["sections"][0]["next_cursor"], json!("3"));
    assert_eq!(first["sections"][1]["next_cursor"], Value::Null);
    let next = sections(&supervisor, json!({ "section": "featured", "cursor": "3", "limit": 3 }));
    assert_eq!(shelf(&next), [row("featured", json!(["cmux/notes"]))]);

    for (args, code) in [
        (json!({ "cursor": "3" }), "bad-request"),
        (json!({ "section": "featured", "cursor": "x" }), "bad-request"),
        (json!({ "section": "charts" }), "apps.section.unknown"),
        (json!({ "shelf": "store" }), "bad-request"),
    ] {
        let refused = supervisor
            .store_call(CLIENT, "apps.catalog.sections", args.clone(), Origin::Cli)
            .unwrap_err();
        assert_eq!(refused.code, code, "{args}");
    }
}

#[test]
fn a_listing_answers_its_versions_and_whats_new() {
    let root = temp_dir();
    let supervisor = store_supervisor(&root);
    let get = |app: &str| {
        supervisor
            .store_call(CLIENT, "apps.catalog.get", json!({ "app": app }), Origin::Cli)
            .unwrap()
    };

    let cloud = get("cmux/cloud");
    assert_eq!(
        cloud["whats_new"],
        json!({ "version": "1.0.0", "items": [{ "title": "Machines start faster", "pr": 44513 }] })
    );
    assert_eq!(
        cloud["versions"],
        json!([
            { "version": "1.0.0", "commit": "c2", "date_ms": 2000 },
            { "version": "0.9.0", "commit": "c1", "date_ms": 1000 },
        ])
    );

    // No file, or one written for another version: the one current version
    // and no What's New.
    for app in ["cmux/inbox", "cmux/dev"] {
        let detail = get(app);
        assert_eq!(detail["versions"], json!([{ "version": "1.0.0" }]), "{app}: {detail}");
        assert!(detail.get("whats_new").is_none(), "{app}: {detail}");
    }
}

/// The shipped first-party tree: Cloud leads the store, and
/// each listing's versions start at its manifest's version.
#[test]
fn the_shipped_store_features_cloud_first() {
    let tree = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../first-party-apps");
    let root = temp_dir();
    let supervisor = Supervisor::new(
        Config {
            state_dir: Some(root.0.join("state")),
            host_binary: None,
            host_args: Vec::new(),
            server_dir: None,
            sources: Sources { first_party: Some(tree), ..Sources::default() },
            idle_stop: Duration::from_secs(60),
            provider_deadline: Duration::from_secs(30),
            provider_user_deadline: Duration::from_secs(600),
            safe_mode_file: None,
            safe_mode_env: false,
        },
        Box::new(Arc::new(FakeRouter::default())),
        Box::new(Arc::new(FakeFetcher::default())),
    );
    let answer = sections(&supervisor, json!({}));
    let featured = answer["sections"][0]["apps"].as_array().unwrap();
    assert_eq!(featured[..1], [json!("cmux/cloud")], "{answer}");
    for app in ["cmux/cloud"] {
        let detail = supervisor
            .store_call(CLIENT, "apps.catalog.get", json!({ "app": app }), Origin::Cli)
            .unwrap();
        assert_eq!(detail["versions"][0]["version"], detail["version"], "{app}: {detail}");
    }
}
