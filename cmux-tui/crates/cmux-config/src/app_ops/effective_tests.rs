use super::*;

fn op(name: &str, request: Value) -> Value {
    call(name, &request).expect("an op of this area").expect("a reply")
}

// effective.merge (the cases of Swift `EffectiveSettings`' callers' tests)

fn merged(file: Value, managed: Value, team: Value) -> Value {
    op(
        "effective.merge",
        json!({
            "file": file, "managed": managed, "team": team,
            "legacyKeys": { "agentPane.display.inspector.placement": "agentPane.display.sessionInfo.placement" },
            "chats": { "roots": "agents.chats.roots",
                       "booleans": ["agents.chats.enabled", "agents.chats.discovery", "agents.chats.sessionRecap"] },
        }),
    )
}

#[test]
fn layers_rank_forced_enforced_file_recommended_default() {
    let reply = merged(
        json!({ "a": { "file": 1, "both": "mine" } }),
        json!({ "forced": { "a.forced": "device", "a.both": "device", "EnrollmentToken": "t" },
                "recommended": { "a.rec": "rec", "a.file": 9, "a.def": "rec" } }),
        json!({ "teamName": "T", "defaults": { "a.def": "team", "a.only": "team" },
                "enforced": { "a.enf": "team", "a.both": "team" } }),
    );
    assert_eq!(
        reply["root"],
        json!({ "a": { "file": 1, "both": "device", "forced": "device", "rec": "rec",
                       "def": "rec", "only": "team", "enf": "team" } })
    );
    assert_eq!(
        reply["managedKeys"],
        json!({ "a.both": "device", "a.forced": "device", "a.enf": { "team": "T" } })
    );
    assert_eq!(reply["policy"], json!({ "EnrollmentToken": "t" }));
    assert_eq!(
        reply["diagnostics"],
        json!([
            { "kind": "managedConflict", "path": "a.both",
              "message": "the team policy value is ignored: the MDM profile manages this key" },
            { "kind": "managedOverride", "path": "a.both",
              "message": "managed by your organization; the value in cmux.json is ignored" },
        ])
    );
    assert_eq!(reply["managedChatRoots"], json!([]));
}

#[test]
fn a_non_object_file_is_empty_and_a_nested_key_wins_over_its_parent() {
    let reply =
        merged(json!([1]), json!({ "forced": { "b.c": 2, "b": { "c": 1, "d": 1 } } }), json!({}));
    assert_eq!(reply["root"], json!({ "b": { "c": 2, "d": 1 } }));
    assert_eq!(reply["diagnostics"], json!([]));
}

#[test]
fn an_older_key_fills_its_new_name_in_each_layer() {
    let reply = merged(
        json!({ "agentPane": { "display": { "inspector": { "placement": "left" } } } }),
        json!({ "forced": { "agentPane.display.inspector.placement": "push" } }),
        json!({}),
    );
    assert_eq!(
        value_at(&reply["root"], &key_path("agentPane.display.sessionInfo.placement")),
        Some(&json!("push"))
    );
    assert_eq!(reply["managedKeys"]["agentPane.display.sessionInfo.placement"], json!("device"));
    // The file's older key is aliased too: with no layer above, it fills the new one.
    let reply = merged(
        json!({ "agentPane": { "display": { "inspector": { "placement": "left" } } } }),
        json!({}),
        json!({}),
    );
    assert_eq!(
        value_at(&reply["root"], &key_path("agentPane.display.sessionInfo.placement")),
        Some(&json!("left"))
    );
}

#[test]
fn chat_roots_add_up_and_switches_are_only_forced_off() {
    let reply = merged(
        json!({ "agents": { "chats": { "roots": ["/u", "/m"], "discovery": true } } }),
        json!({ "forced": { "agents.chats.roots": ["/m", "/f"], "agents.chats.enabled": false,
                            "agents.chats.discovery": true } }),
        json!({ "teamName": "T", "defaults": { "agents.chats.roots": ["/d"] },
                "enforced": { "agents.chats.sessionRecap": false, "agents.chats.roots": "no" } }),
    );
    assert_eq!(reply["managedChatRoots"], json!(["/d", "/m", "/f"]));
    assert_eq!(
        reply["root"],
        json!({ "agents": { "chats": { "roots": ["/u", "/m", "/d", "/f"], "enabled": false,
                                       "discovery": true, "sessionRecap": false } } })
    );
    assert_eq!(
        reply["managedKeys"],
        json!({ "agents.chats.enabled": "device", "agents.chats.sessionRecap": { "team": "T" } })
    );
    // Chat keys are never generic managed keys, so they draw no override diagnostic.
    assert_eq!(reply["diagnostics"], json!([]));
}

#[test]
fn unset_chats_stay_unset() {
    let reply = merged(json!({}), json!({}), json!({}));
    assert_eq!(reply["root"], json!({}));
    let reply =
        merged(json!({}), json!({ "recommended": { "agents.chats.enabled": false } }), json!({}));
    assert_eq!(reply["root"], json!({ "agents": { "chats": { "enabled": false } } }));
    assert_eq!(reply["managedKeys"], json!({}));
}

// font_faces.load (Swift `ChatFontFacesTests`; font_faces/tests.rs has the reader's cases)

const WOFF2: &[u8] = b"wOF2\0\x01\0\0rest of the font";

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-app-faces-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn loaded(faces: Value) -> Value {
    op("font_faces.load", json!({ "faces": faces }))["faces"].clone()
}

#[test]
fn faces_load_as_data_urls_and_a_changed_file_is_read_again() {
    let dir = scratch("changed");
    let path = dir.join("x.woff2");
    std::fs::write(&path, WOFF2).unwrap();
    let value = format!("file:{}", path.display());
    let first = loaded(json!({ " Lora :italic": value }));
    assert_eq!(first, json!({ "Lora:italic": font_faces::data_url("woff2", WOFF2) }));
    assert_eq!(loaded(json!({ "Lora:italic": value })), first);
    let changed = [WOFF2, b"more".as_slice()].concat();
    std::fs::write(&path, &changed).unwrap();
    assert_eq!(loaded(json!({ "A": value }))["A"], json!(font_faces::data_url("woff2", &changed)));
    std::fs::remove_file(&path).unwrap();
    assert_eq!(loaded(json!({ "A": value })), json!({}));
}

#[test]
fn bad_faces_are_skipped_and_at_most_eight_keys_are_read() {
    let dir = scratch("eight");
    let mut faces = Map::new();
    for index in 0..10 {
        let path = dir.join(format!("f{index}.woff2"));
        std::fs::write(&path, WOFF2).unwrap();
        faces.insert(format!("Face {index}"), json!(format!("file:{}", path.display())));
    }
    faces.insert("Face 0:bold".into(), json!("file:/nope.woff2"));
    let real = dir.join("f0.woff2");
    let link = dir.join("link.woff2");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let out = loaded(Value::Object(faces));
    let mut keys: Vec<String> = out.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(keys, (0..=6).map(|i| format!("Face {i}")).collect::<Vec<_>>());
    assert_eq!(loaded(json!({ "A": format!("file:{}", link.display()) })), json!({}));
    for bad in [json!(3), json!("x.woff2"), json!("file:fonts/x.woff2")] {
        assert_eq!(loaded(json!({ "A": bad })), json!({}));
    }
}

// chat_roots.* (Swift `ChatRootValidator`)

/// Runs the op as the app does: answers each `need` from `fs` (path -> link target).
fn refused(path: &str, home: &str, fs: &[(&str, &str)]) -> Option<String> {
    let mut links = Map::new();
    let resolve = |links: &mut Map<String, Value>, need: &str| {
        let target = fs.iter().find(|(at, _)| *at == need).map(|(_, to)| json!(to));
        links.insert(need.to_owned(), target.unwrap_or(Value::Null));
    };
    let resolved = loop {
        let reply = op("chat_roots.resolve_home", json!({ "home": home, "links": links.clone() }));
        match reply["need"].as_str() {
            Some(need) => resolve(&mut links, need),
            None => break reply["home"].as_str().unwrap().to_owned(),
        }
    };
    let mut links = Map::new();
    for _ in 0..200 {
        let reply = op(
            "chat_roots.refusal",
            json!({ "path": path, "homes": [home, resolved], "links": links.clone() }),
        );
        match reply["need"].as_str() {
            Some(need) => {
                assert!(!links.contains_key(need), "asked twice for {need}");
                resolve(&mut links, need);
            }
            None => return reply["refusal"].as_str().map(str::to_owned),
        }
    }
    panic!("the walk never ended");
}

#[test]
fn chat_roots_are_refused_by_spelling() {
    let home = "/Users/someone";
    let reason = |path: &str| refused(path, home, &[]);
    assert_eq!(reason("relative").as_deref(), Some("relative"));
    assert_eq!(reason("/a\0b").as_deref(), Some("relative"));
    assert_eq!(reason("/").as_deref(), Some("system"));
    assert_eq!(reason("/Users/Someone/").as_deref(), Some("home"));
    assert_eq!(reason("/Volumes/Disk/x").as_deref(), Some("volume"));
    assert_eq!(reason("/net/host").as_deref(), Some("volume"));
    assert_eq!(reason("/Users/someone/documents/x").as_deref(), Some("protected"));
    assert_eq!(reason("/Users/someone/Library/Mobile Documents").as_deref(), Some("protected"));
    assert_eq!(reason("/Users/someone/code/../Desktop").as_deref(), Some("protected"));
    assert_eq!(reason("/Users/someone/.claude/projects"), None);
    assert_eq!(reason("/Users/someone/./code/../.codex"), None);
    assert_eq!(reason("/Users/someone/Library"), None);
}

#[test]
fn chat_roots_follow_links_and_the_home_through_its_own() {
    let fs = [
        ("/Users/someone/code/docs", "/Users/someone/Documents/site"),
        ("/Users/someone/rel", "../someone/Desktop"),
        ("/tmp", "private/tmp"),
        ("/home", "/Users/someone"),
        ("/loop", "/loop"),
    ];
    let reason = |path: &str, home: &str| refused(path, home, &fs);
    assert_eq!(reason("/Users/someone/code/docs", "/Users/someone").as_deref(), Some("protected"));
    assert_eq!(
        reason("/Users/someone/code/docs/x", "/Users/someone").as_deref(),
        Some("protected")
    );
    assert_eq!(reason("/Users/someone/rel", "/Users/someone").as_deref(), Some("protected"));
    assert_eq!(reason("/tmp/x", "/Users/someone"), None);
    assert_eq!(reason("/loop", "/Users/someone").as_deref(), Some("symlink"));
    // A home reached by a link is the home by either name.
    assert_eq!(reason("/Users/someone", "/home").as_deref(), Some("home"));
    assert_eq!(reason("/Users/someone/Music", "/home").as_deref(), Some("protected"));
    assert_eq!(reason("/home/Music", "/home").as_deref(), Some("protected"));
}

#[test]
fn a_protected_spelling_is_refused_before_any_link_is_asked() {
    let reply = op(
        "chat_roots.refusal",
        json!({ "path": "/Users/someone/Documents/x", "homes": ["/Users/someone"], "links": {} }),
    );
    assert_eq!(reply, json!({ "refusal": "protected" }));
    let reply = op(
        "chat_roots.refusal",
        json!({ "path": "/Users/someone/code", "homes": ["/Users/someone"], "links": {} }),
    );
    assert_eq!(reply, json!({ "need": "/Users" }));
}

#[test]
fn a_home_past_forty_links_is_the_home_as_given() {
    let reply =
        op("chat_roots.resolve_home", json!({ "home": "/loop/x", "links": { "/loop": "/loop" } }));
    assert_eq!(reply, json!({ "home": "/loop/x" }));
}

// sidebar_look.* (Swift `AASidebarLookPresetGalleryTests`' data cases)

#[test]
fn a_look_fills_only_what_the_root_leaves_unset() {
    let text = r#"{ "name": "x", "sidebar": { "groupBy": "folder", "showColors": false } }"#;
    let entries = op("sidebar_look.entries", json!({ "name": "x", "text": text }));
    assert_eq!(
        entries,
        json!({ "entries": [
            { "path": ["sidebar", "groupBy"], "value": "folder" },
            { "path": ["sidebar", "showColors"], "value": false },
        ] })
    );
    let root = json!({ "sidebar": { "look": "x", "showColors": true } });
    let filled = op("sidebar_look.fill", json!({ "root": root, "name": "x", "text": text }));
    assert_eq!(
        filled,
        json!({ "root": { "sidebar": { "look": "x", "showColors": true, "groupBy": "folder" } } })
    );
    let broken = op("sidebar_look.fill", json!({ "root": root, "name": "x", "text": "{" }));
    assert_eq!(broken, json!({ "root": root }));
}

#[test]
fn other_ops_are_not_this_areas() {
    assert!(call("jsonc.parse", &json!({})).is_none());
    assert!(call("theme.overlay", &json!({})).is_none());
}

#[test]
fn personal_github_login_requires_user_consent_in_both_mergers() {
    use crate::managed::{ManagedPreferences, PERSONAL_GITHUB_LOGIN as KEY, TeamPolicyLayer};

    // Exercise the app operation and the native settings owner with the same policy input.
    let check = |file: Value, managed: Value, team: Value, expected: Option<bool>, lock: Value| {
        let app = merged(file.clone(), managed.clone(), team.clone());
        let native = crate::EffectiveSettings::merge(
            &file,
            &ManagedPreferences {
                forced: members(&managed, "forced").unwrap(),
                recommended: members(&managed, "recommended").unwrap(),
            },
            &TeamPolicyLayer {
                team_name: "T".into(),
                defaults: members(&team, "defaults").unwrap(),
                enforced: members(&team, "enforced").unwrap(),
                ..Default::default()
            },
            Schema::embedded(),
        );
        for root in [&app["root"], &native.root] {
            assert_eq!(root.pointer("/cloud/useMyGitHubLogin").and_then(Value::as_bool), expected);
        }
        assert_eq!(app["managedKeys"][KEY], lock);
        assert_eq!(
            native.managed_keys.get(KEY).map(|source| source.wire_name()),
            if lock == "device" {
                Some("mdm")
            } else if lock.is_object() {
                Some("team")
            } else {
                None
            }
        );
    };
    let file = json!({"cloud": {"useMyGitHubLogin": true}});
    for grant in [json!(true), json!("true"), Value::Null] {
        let on = json!({(KEY): grant});
        let device = json!({"forced": on, "recommended": on});
        let team = json!({"teamName": "T", "defaults": on, "enforced": on});
        check(json!({}), device.clone(), team.clone(), None, Value::Null);
        check(file.clone(), device, team, Some(true), Value::Null);
    }
    check(
        file.clone(),
        json!({"forced": {(KEY): true}}),
        json!({"teamName": "T", "enforced": {(KEY): false}}),
        Some(false),
        json!({"team": "T"}),
    );
    check(
        file,
        json!({"forced": {(KEY): false}}),
        json!({"enforced": {(KEY): true}}),
        Some(false),
        json!("device"),
    );
    check(
        json!({}),
        json!({"forced": {"cloud": {"useMyGitHubLogin": true}}}),
        json!({}),
        None,
        Value::Null,
    );
}
