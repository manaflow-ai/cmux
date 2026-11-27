//! chief_settings: parity cases from the Swift tests the ops replace (HomeChiefSettings*, HomeChiefNames*,
//! HomeChiefPictureCrop*, HomeChiefComputer*).

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("chief_settings.{name}"), &request)
        .unwrap_or_else(|error| panic!("{name}: {error:?}"))
}

// MARK: names

#[test]
fn harness_ids_read_as_their_engine_and_route() {
    let claude = op("backendTitle", json!({ "id": "claude" }));
    let claude = claude.as_str().expect("a title");
    for (id, name) in [
        ("claude-sr2-pipe", format!("{claude} (SR2 Pipe)")),
        ("claude-cr", format!("{claude} (CodeRouter)")),
        ("claude-sr", format!("{claude} (Subrouter)")),
        ("gemini", "Antigravity".into()),
        ("pi", "Pi".into()),
        ("opencode", "OpenCode".into()),
        ("muse", "Muse Code".into()),
        ("", String::new()),
    ] {
        assert_eq!(op("harnessName", json!({ "id": id })), json!(name), "{id}");
    }
    assert_eq!(op("backendBadge", json!({ "harness": "gemini" })), json!("Antigravity"));
    assert_eq!(
        op("backendBadge", json!({ "harness": "claude-cr" })),
        Value::Null,
        "a Claude route is the default"
    );
    assert!(op("backends", json!({})).as_array().is_some_and(|list| !list.is_empty()));
}

#[test]
fn model_ids_read_as_names() {
    for (id, name) in [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-4-5-20250929", "Claude Sonnet 4.5"),
        ("gpt-5.1-codex-max", "GPT 5.1 Codex Max"),
        ("opus[1m]", "Opus (1M)"),
        ("gpt-4o-2024-08-06", "GPT 4o"),
        ("gpt-5-2025-08-07", "GPT 5"),
        ("foo-2024-13-01", "Foo 2024 13.01"),
        ("foo-20241301", "Foo 20241301"),
        ("foo-20240132", "Foo 20240132"),
        ("foo-20240131", "Foo"),
        ("opus", "Opus"),
        ("", ""),
    ] {
        assert_eq!(op("modelName", json!({ "id": id })), json!(name), "{id}");
    }
}

// MARK: model menu

fn claude_models() -> Value {
    json!([
        { "id": "default", "name": "Default (recommended)", "resolvedModel": "claude-opus-5-5" },
        { "id": "opus", "name": "Opus", "resolvedModel": "claude-opus-5-5" },
        { "id": "opus[1m]", "name": "Opus (1M context)", "resolvedModel": "claude-opus-5-5" },
        { "id": "opusplan", "name": "Opus Plan Mode" },
        { "id": "claude-opus-5-5", "name": "Claude Opus 5.5", "family": "Opus", "provider": "anthropic",
          "shortName": "Opus 5.5", "efforts": ["low", "medium", "high", "xhigh", "max"], "defaultEffort": "medium",
          "fast": true, "aliases": ["opus"], "releaseDate": "2026-09-01" },
        { "id": "claude-opus-4-5", "name": "Claude Opus 4.5", "family": "Opus", "provider": "anthropic",
          "shortName": "Opus 4.5", "efforts": ["low", "medium", "high"], "defaultEffort": "medium",
          "releaseDate": "2025-11-24" },
        { "id": "claude-sonnet-5-5", "name": "Claude Sonnet 5.5", "family": "Sonnet", "provider": "anthropic",
          "shortName": "Sonnet 5.5", "efforts": ["low", "medium", "high", "xhigh", "max"], "defaultEffort": "medium",
          "aliases": ["sonnet"], "releaseDate": "2026-09-01" },
        { "id": "sonnet", "name": "Sonnet", "resolvedModel": "claude-sonnet-5-5" },
        { "id": "claude-haiku-4-5", "name": "Claude Haiku 4.5", "family": "Haiku", "provider": "anthropic",
          "shortName": "Haiku 4.5", "fast": false, "releaseDate": "2025-10-15" }
    ])
}

fn rows(menu: &Value) -> Vec<String> {
    menu["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .map(|entry| match entry["kind"].as_str() {
            Some("header") => format!("# {}", entry["title"].as_str().unwrap_or("")),
            _ => entry["title"].as_str().unwrap_or("").to_string(),
        })
        .collect()
}

fn value_of(menu: &Value, title: &str) -> Value {
    menu["items"]
        .as_array()
        .expect("items")
        .iter()
        .find(|item| item["title"] == title)
        .map_or(Value::Null, |item| item["value"].clone())
}

#[test]
fn models_group_by_family_with_one_row_per_model() {
    let menu = op("modelMenu", json!({ "models": claude_models() }));
    assert_eq!(
        rows(&menu),
        [
            "# Opus",
            "Opus 5.5",
            "Opus 5.5 · 1M context",
            "# Sonnet",
            "Sonnet 5.5",
            "# Haiku",
            "Haiku 4.5",
            "# Plan and Execute",
            "Opus Plans, Sonnet Executes",
            "# Older Models",
            "Opus 4.5",
        ]
    );
    assert_eq!(value_of(&menu, "Opus 5.5"), json!("opus"), "the alias takes its release's row");
    assert_eq!(value_of(&menu, "Opus 5.5 · 1M context"), json!("opus[1m]"));
}

#[test]
fn a_chosen_release_keeps_its_row_and_an_unoffered_one_still_shows() {
    let menu = op("modelMenu", json!({ "models": claude_models(), "chosen": "claude-opus-5-5" }));
    assert_eq!(value_of(&menu, "Opus 5.5"), json!("claude-opus-5-5"));
    assert!(!menu["items"].as_array().unwrap().iter().any(|item| item["value"] == "opus"));
    let menu = op("modelMenu", json!({ "models": claude_models(), "chosen": "claude-opus-3" }));
    assert!(menu["items"].as_array().unwrap().iter().any(|item| item["value"] == "claude-opus-3"));
}

#[test]
fn recent_picks_come_first_without_the_current_one() {
    let menu = op(
        "modelMenu",
        json!({ "models": claude_models(), "chosen": "sonnet", "recents": ["sonnet", "claude-haiku-4-5", "gone-model"] }),
    );
    assert_eq!(rows(&menu)[..3], ["# Recent", "Haiku 4.5", "# Opus"]);
    let flat = op(
        "modelMenu",
        json!({ "models": [{ "id": "a", "name": "A" }, { "id": "b", "name": "B" }] }),
    );
    assert_eq!(rows(&flat), ["A", "B"]);
}

#[test]
fn default_names_the_model_and_effort_it_runs() {
    let snapshot = json!({
        "models": claude_models(),
        "efforts": ["minimal", "low", "medium", "high", "xhigh", "max"],
        "speeds": ["default"],
        "effective": { "harness": "claude" }
    });
    let titles = op("engineTitles", json!({ "snapshot": snapshot }));
    assert_eq!(titles["defaultModel"], json!("Default (Opus 5.5)"));
    assert_eq!(titles["defaultEffort"], json!("Default (Medium)"));
    let efforts = |model: &str| {
        let mut snapshot = snapshot.clone();
        snapshot["model"] = json!(model);
        op("engineTitles", json!({ "snapshot": snapshot }))["efforts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pick| pick["value"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(efforts("claude-opus-4-5"), ["low", "medium", "high"]);
    assert_eq!(efforts("opus"), ["low", "medium", "high", "xhigh", "max"]);
    assert_eq!(efforts("opusplan"), ["minimal", "low", "medium", "high", "xhigh", "max"]);
}

// MARK: engine

#[test]
fn default_titles_name_what_default_means() {
    assert_eq!(op("defaultTitled", json!({ "value": "Claude" })), json!("Default (Claude)"));
    assert_eq!(op("defaultTitled", json!({})), json!("Default"));
    assert_eq!(op("defaultTitled", json!({ "value": "default" })), json!("Default"));
}

#[test]
fn recents_keep_five_newest_first() {
    let list = json!(["a", "b", "c", "d", "e"]);
    assert_eq!(
        op("recentsRemember", json!({ "model": "c", "list": list })),
        json!(["c", "a", "b", "d", "e"])
    );
    assert_eq!(
        op("recentsRemember", json!({ "model": "f", "list": list })),
        json!(["f", "a", "b", "c", "d"])
    );
}

#[test]
fn hosted_config_reads_ok_and_reports_failures() {
    let ok = op(
        "hostedConfig",
        json!({ "status": 200, "bodyText": "{\"value\":{\"config\":{\"model\":\"m\"}}}" }),
    );
    assert_eq!(ok, json!({ "config": { "model": "m" } }));
    let put = op("hostedConfig", json!({ "status": 200, "body": { "value": { "model": "m" } } }));
    assert_eq!(put, json!({ "config": { "model": "m" } }));
    let refused = op(
        "hostedConfig",
        json!({ "status": 403, "body": { "error": { "code": "agent_launch_disabled" } } }),
    );
    assert_eq!(refused["error"]["kind"], json!("agentsDisabled"), "{refused}");
    for status in [401, 404, 500] {
        let failed = op("hostedConfig", json!({ "status": status, "body": {} }));
        assert!(failed.get("error").is_some(), "{status}: {failed}");
    }
}

// MARK: names state

#[test]
fn next_name_takes_the_first_free_number() {
    assert_eq!(op("nextName", json!({ "taken": [] })), json!("Chief"));
    assert_eq!(op("nextName", json!({ "taken": ["Chief"] })), json!("Chief 2"));
    assert_eq!(op("nextName", json!({ "taken": ["Chief", "Chief 2"] })), json!("Chief 3"));
    assert_eq!(op("nextName", json!({ "taken": ["Chief", "Chief 3"] })), json!("Chief 2"));
}

#[test]
fn a_rename_shows_until_the_record_catches_up() {
    let renamed = op(
        "namesStep",
        json!({ "state": {}, "event": { "kind": "rename", "conversation": "c1", "name": "Ada", "record": "Chief" } }),
    );
    assert_eq!(
        op("namesOf", json!({ "state": renamed, "conversation": "c1", "record": "Chief" })),
        json!("Ada")
    );
    let settled = op(
        "namesStep",
        json!({ "state": renamed, "event": { "kind": "settle", "conversation": "c1", "record": "Ada" } }),
    );
    assert_eq!(
        op("namesOf", json!({ "state": settled, "conversation": "c1", "record": "Ada" })),
        json!("Ada")
    );
    assert_eq!(settled["pending"], json!({}));
    let rolled = op(
        "namesStep",
        json!({ "state": renamed, "event": { "kind": "rollBack", "conversation": "c1", "name": "Ada" } }),
    );
    assert_eq!(
        op("namesOf", json!({ "state": rolled, "conversation": "c1", "record": "Chief" })),
        json!("Chief")
    );
}

#[test]
fn the_oldest_chief_is_the_one() {
    let chosen = op(
        "selectChief",
        json!({ "conversations": [
            { "id": "b", "title": "Chief", "participants": ["agent_mux"], "createdAt": "2026-11-02T00:00:00.000Z" },
            { "id": "a", "title": "Chief", "participants": [{ "id": "agent_mux" }], "createdAt": "2026-11-01T00:00:00.000Z" },
            { "id": "0", "title": "Chief", "participants": ["agent_mux"], "createdAt": "not a date" },
            { "id": "1", "title": "Chief", "participants": [], "createdAt": "2020-01-01T00:00:00.000Z" }
        ] }),
    );
    assert_eq!(chosen, json!("a"));
}

// MARK: picture

#[test]
fn a_crop_stays_on_the_picture() {
    let start = op(
        "cropStep",
        json!({ "state": { "imageSize": { "width": 200, "height": 100 }, "zoom": 1, "center": { "x": 100, "y": 50 } }, "event": { "kind": "zoom", "zoom": 9 } }),
    );
    assert_eq!(start["zoom"], json!(5.0));
    assert_eq!(start["side"], json!(20.0));
    let panned = op(
        "cropStep",
        json!({ "state": start, "event": { "kind": "pan", "delta": { "width": 1000, "height": 0 }, "diameter": 100 } }),
    );
    assert_eq!(panned["center"]["x"], json!(10.0), "dragging right shows the picture's left edge");
    let still = op(
        "cropStep",
        json!({ "state": start, "event": { "kind": "pan", "delta": { "width": 10, "height": 10 }, "diameter": 0 } }),
    );
    assert_eq!(still["center"], start["center"]);
}

#[test]
fn a_render_is_at_most_512_pixels() {
    let crop = json!({ "imageSize": { "width": 2000, "height": 1000 }, "zoom": 1, "center": { "x": 1000, "y": 500 } });
    let render = op("cropRender", json!({ "crop": crop, "width": 2000, "height": 1000 }));
    assert_eq!(render["pixels"], json!(512));
    assert_eq!(
        render["source"],
        json!({ "x": 500.0, "y": 0.0, "width": 1000.0, "height": 1000.0 })
    );
    let small = op("cropRender", json!({ "crop": crop, "width": 200, "height": 100 }));
    assert_eq!(small["pixels"], json!(100));
}

#[test]
fn the_registry_keeps_four_picture_types_up_to_a_mebibyte() {
    let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A];
    assert_eq!(op("registryMediaType", json!({ "head": png })), json!("image/png"));
    assert_eq!(op("registryMediaType", json!({ "head": png, "length": 1_048_577 })), Value::Null);
    assert_eq!(
        op("registryMediaType", json!({ "head": [0xFF, 0xD8, 0xFF, 0xE0] })),
        json!("image/jpeg")
    );
    assert_eq!(op("registryMediaType", json!({ "head": b"GIF89a".to_vec() })), json!("image/gif"));
    assert_eq!(
        op("registryMediaType", json!({ "head": b"RIFF\0\0\0\0WEBPVP8 ".to_vec() })),
        json!("image/webp")
    );
    assert_eq!(
        op("registryMediaType", json!({ "head": b"RIFF\0\0\0\0WAVE".to_vec() })),
        Value::Null
    );
    assert_eq!(op("pictureExtension", json!({ "mediaType": "image/jpeg" })), json!("jpg"));
    assert_eq!(op("pictureFileName", json!({ "mediaType": "image/gif" })), json!("avatar.gif"));
    assert_eq!(op("pictureFileName", json!({ "mediaType": "image/webp" })), json!("avatar.png"));
}

#[test]
fn an_avatar_names_a_picture_only_as_a_bare_image_file() {
    for (avatar, picture) in [
        ("avatar.png", true),
        ("Me.JPEG", true),
        ("a/b.png", false),
        ("🦊", false),
        (".png", false),
        ("x.txt", false),
    ] {
        assert_eq!(op("namesPicture", json!({ "avatar": avatar })), json!(picture), "{avatar}");
    }
}

#[test]
fn path_keys_and_square_copies() {
    assert_eq!(op("pathKey", json!({ "path": "" })), json!("811c9dc5"));
    assert_eq!(op("pathKey", json!({ "path": "a" })), json!("e40c292c"));
    assert_eq!(op("squareCrop", json!({ "width": 10, "height": 10 })), Value::Null);
    assert_eq!(
        op("squareCrop", json!({ "width": 30, "height": 10 })),
        json!({ "x": 10.0, "y": 0.0, "width": 10.0, "height": 10.0 })
    );
    let key = op("pathKey", json!({ "path": "/p/me.jpg" }));
    assert_eq!(
        op("squaredCacheName", json!({ "path": "/p/me.jpg", "stamp": 7 })),
        json!(format!("{}-me-7.png", key.as_str().unwrap()))
    );
}

// MARK: computer

#[test]
fn the_control_bar_says_who_drives() {
    assert_eq!(op("controlLine", json!({ "chief": "Ada" })), Value::Null);
    assert_eq!(
        op("controlLine", json!({ "chief": "Ada", "control": { "holder": "chief" } })),
        json!({ "status": "Ada is using the computer", "action": "takeOver" })
    );
    assert_eq!(
        op(
            "controlLine",
            json!({ "chief": "Ada", "control": { "holder": "human", "reason": "  " } })
        ),
        json!({ "status": "You\u{2019}re in control", "action": "giveBack" })
    );
    assert_eq!(
        op(
            "controlLine",
            json!({ "chief": "Ada", "control": { "holder": "human", "reason": " Sign in please\n" } })
        )["status"],
        json!("Sign in please")
    );
}

#[test]
fn the_section_shows_only_when_paid_or_entitled() {
    let hidden =
        op("computerSection", json!({ "status": { "provisioning": false }, "paid": false }));
    assert_eq!(hidden["shows"], json!("hidden"));
    let entitled =
        op("computerSection", json!({ "status": { "entitled": true, "provisionError": "x" } }));
    assert_eq!(entitled["shows"], json!("fromStatus"));
    assert_eq!(entitled["section"]["provisionFailed"], json!(true));
    let failed = op("computerSection", json!({ "section": entitled["section"], "shown": true }));
    assert_eq!(failed["shows"], json!("keepUnavailable"));
    assert_eq!(failed["section"]["entitled"], json!(true), "a failed read keeps what it knew");
    assert_eq!(
        op("computerSection", json!({ "section": entitled["section"] }))["shows"],
        json!("hidden")
    );
}

#[test]
fn the_screen_note_follows_the_state() {
    assert_eq!(op("computerNote", json!({ "state": "live" }))["note"], json!("Connecting\u{2026}"));
    assert_eq!(
        op("computerNote", json!({ "state": "live", "hasImage": true }))["note"],
        Value::Null
    );
    assert_eq!(
        op("computerNote", json!({ "state": "live", "feedLive": true }))["note"],
        Value::Null
    );
    assert_eq!(
        op("computerNote", json!({ "state": "waking" })),
        json!({ "note": "Waking up\u{2026}", "sleepFace": true, "awake": true })
    );
    assert_eq!(op("computerNote", json!({ "state": "asleep" }))["awake"], json!(false));
    assert_eq!(op("computerNote", json!({ "state": "unavailable" }))["sleepFace"], json!(false));
}

#[test]
fn the_card_reads_the_screen_each_second_and_the_status_every_eight() {
    assert_eq!(
        op("computerPoll", json!({ "live": true })),
        json!({ "readsStatus": true, "waitMs": 900, "nextSinceMs": 900 })
    );
    assert_eq!(
        op("computerPoll", json!({ "sinceMs": 7200, "live": true })),
        json!({ "readsStatus": false, "waitMs": 900, "nextSinceMs": 8100 })
    );
    assert_eq!(
        op("computerPoll", json!({ "sinceMs": 8100, "live": true }))["readsStatus"],
        json!(true)
    );
    assert_eq!(
        op("computerPoll", json!({ "live": true, "watchesScreen": false }))["waitMs"],
        json!(8000)
    );
    assert_eq!(op("computerPoll", json!({}))["nextSinceMs"], json!(8000));
}
