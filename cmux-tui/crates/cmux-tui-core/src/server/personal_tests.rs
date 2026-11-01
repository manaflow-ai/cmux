//! Wire tests for the home session's personal state (`profiles-v1`,
//! plans/cmux-next/data-model.md section 3).

use super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn personal_mux() -> Arc<Mux> {
    Mux::new_for_test("personal", crate::SurfaceOptions::default())
}

fn revision(mux: &Arc<Mux>) -> u64 {
    run(mux, json!({"cmd":"list-personal"})).unwrap()["personal_revision"].as_u64().unwrap()
}

#[test]
fn personal_state_starts_with_the_default_room_following_this_session() {
    let mux = personal_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|value| value == "profiles-v1")
    );
    let own = identity["registry_id"].as_str().unwrap().to_string();
    let personal = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert_eq!(personal["profiles"][0]["id"], "default");
    assert_eq!(personal["profiles"][0]["index"], 0);
    assert_eq!(personal["profiles"][0]["follows"], json!([own]));
    let session = &personal["sessions"][0];
    assert_eq!(session["session_id"], json!(own));
    assert_eq!(session["transport"], json!({"kind":"local"}));
    assert_eq!(session["migrated"], true);
    assert_eq!(personal["pins"], json!([]));
}

#[test]
fn rooms_round_trip_over_the_wire() {
    let mux = personal_mux();
    let events = mux.subscribe();
    let created = run(
        &mux,
        json!({"cmd":"create-profile","profile":"prof_work","name":"Work","color":"green","icon":"🧪",
               "theme":"Catppuccin Mocha","defaults":{"cwd":"/tmp","env":{"A":"1"}}}),
    )
    .unwrap();
    assert_eq!(created["changed"], true);
    assert_eq!(created["profile"]["id"], "prof_work");
    assert_eq!(created["profile"]["index"], 1);
    assert_eq!(created["profile"]["defaults"]["env"]["A"], "1");
    assert!(created["profile"]["browser_profile_id"].is_null());
    let revision_after_create = revision(&mux);
    assert!(events.try_iter().any(|event| matches!(
        event,
        MuxEvent::PersonalChanged { personal_revision } if personal_revision == revision_after_create
    )));
    // A retry with the same id and name changes nothing.
    let retried =
        run(&mux, json!({"cmd":"create-profile","profile":"prof_work","name":"Work"})).unwrap();
    assert_eq!(retried["changed"], false);
    assert_eq!(revision(&mux), revision_after_create);
    // Absent fields stay, null clears.
    let updated =
        run(&mux, json!({"cmd":"update-profile","profile":"prof_work","theme":null,"icon":"👩‍💻"}))
            .unwrap();
    assert!(updated["profile"]["theme"].is_null());
    assert_eq!(updated["profile"]["color"], "green");
    assert_eq!(updated["profile"]["icon"], "👩‍💻");
    for bad in [
        json!({"cmd":"update-profile","profile":"prof_work","icon":"🧪🧪"}),
        json!({"cmd":"update-profile","profile":"prof_work","theme":"bad\u{7}"}),
        json!({"cmd":"update-profile","profile":"prof_work","browser_profile_id":"Not-A-Uuid"}),
        json!({"cmd":"create-profile","name":"Bad","color":"not a color"}),
        json!({"cmd":"delete-profile","profile":"default"}),
    ] {
        assert!(run(&mux, bad.clone()).is_err(), "{bad} must fail");
    }
    let flag =
        run(&mux, json!({"cmd":"update-profile","profile":"prof_work","icon":"🇯🇵"})).unwrap();
    assert_eq!(flag["profile"]["icon"], "🇯🇵");
    let moved = run(&mux, json!({"cmd":"move-profile","profile":"prof_work","index":0})).unwrap();
    assert_eq!(moved["profile"]["index"], 0);
    assert_eq!(moved["changed"], true);
    let follows = run(
        &mux,
        json!({"cmd":"set-profile-follows","profile":"prof_work","session_ids":["remote-1"]}),
    )
    .unwrap();
    assert_eq!(follows["profile"]["follows"], json!(["remote-1"]));
}

#[test]
fn pins_groups_and_room_deletion() {
    let mux = personal_mux();
    run(&mux, json!({"cmd":"create-profile","profile":"prof_work","name":"Work"})).unwrap();
    // A key that exists on no session yet can be pinned.
    let pinned = run(
        &mux,
        json!({"cmd":"pin-workspace","session_id":"remote-1","workspace_key":"future-key","profile":"prof_work"}),
    )
    .unwrap();
    assert_eq!(pinned["changed"], true);
    let again = run(
        &mux,
        json!({"cmd":"pin-workspace","session_id":"remote-1","workspace_key":"future-key","profile":"prof_work"}),
    )
    .unwrap();
    assert_eq!(again["changed"], false);
    // set-personal-workspace creates the row, appended last.
    let row = run(
        &mux,
        json!({"cmd":"set-personal-workspace","session_id":"remote-1","workspace_key":"future-key","theme":"Nord"}),
    )
    .unwrap();
    let count =
        run(&mux, json!({"cmd":"list-personal"})).unwrap()["workspaces"].as_array().unwrap().len();
    assert_eq!(row["workspace"]["index"], count - 1);
    assert_eq!(row["workspace"]["theme"], "Nord");
    let group = run(
        &mux,
        json!({"cmd":"create-personal-group","group":"grp_a","name":"Agents","profile":"prof_work"}),
    )
    .unwrap();
    assert_eq!(group["group"]["profile"], "prof_work");
    run(
        &mux,
        json!({"cmd":"set-personal-workspace","session_id":"remote-1","workspace_key":"future-key","group":"grp_a","index":0}),
    )
    .unwrap();
    let listed = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert_eq!(listed["workspaces"][0]["workspace_key"], "future-key");
    assert_eq!(listed["workspaces"][0]["group"], "grp_a");
    // Pinning to another room clears a group of the old room.
    run(
        &mux,
        json!({"cmd":"pin-workspace","session_id":"remote-1","workspace_key":"future-key","profile":"default"}),
    )
    .unwrap();
    let listed = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert!(listed["workspaces"][0]["group"].is_null());
    // Moving a group to a room pins its members there.
    run(
        &mux,
        json!({"cmd":"set-personal-workspace","session_id":"remote-1","workspace_key":"future-key","group":"grp_a"}),
    )
    .unwrap();
    run(&mux, json!({"cmd":"update-personal-group","group":"grp_a","profile":"default"})).unwrap();
    run(&mux, json!({"cmd":"update-personal-group","group":"grp_a","profile":"prof_work"}))
        .unwrap();
    let listed = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert_eq!(
        listed["pins"],
        json!([{"session_id":"remote-1","workspace_key":"future-key","profile":"prof_work"}])
    );
    // Delete without a target: pins removed, groups deleted, members ungrouped.
    let deleted = run(&mux, json!({"cmd":"delete-profile","profile":"prof_work"})).unwrap();
    assert!(deleted["moved_to"].is_null());
    // Delete Space is one reopenable closed group (SPACE-DELETE-CLOSES-ITS-WORKSPACES).
    assert!(deleted["closed_id"].as_str().is_some_and(|id| id.starts_with("closed_")));
    assert_eq!(
        deleted["unpinned"],
        json!([{"session_id":"remote-1","workspace_key":"future-key"}])
    );
    let listed = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert_eq!(listed["profiles"].as_array().unwrap().len(), 1);
    assert_eq!(listed["groups"], json!([]));
    assert!(listed["workspaces"][0]["group"].is_null());
    // Delete with a target moves pins and groups.
    run(&mux, json!({"cmd":"create-profile","profile":"prof_b","name":"B"})).unwrap();
    run(&mux, json!({"cmd":"create-personal-group","group":"grp_b","name":"G","profile":"prof_b"}))
        .unwrap();
    run(
        &mux,
        json!({"cmd":"pin-workspace","session_id":"s","workspace_key":"k","profile":"prof_b"}),
    )
    .unwrap();
    let moved =
        run(&mux, json!({"cmd":"delete-profile","profile":"prof_b","move_to":"default"})).unwrap();
    assert_eq!(moved["moved_to"], "default");
    assert_eq!(moved["unpinned"], json!([]));
    let listed = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert_eq!(listed["groups"][0]["profile"], "default");
    assert!(
        listed["pins"]
            .as_array()
            .unwrap()
            .iter()
            .any(|pin| pin["profile"] == "default" && pin["workspace_key"] == "k")
    );
    let removed = run(&mux, json!({"cmd":"delete-personal-group","group":"grp_b"})).unwrap();
    assert_eq!(removed["group"], "grp_b");
    // The raw delete is the same recoverable delete as workspace_group.delete.
    let closed = mux.read_registry_state(crate::state::closed_history_store::closed_items).unwrap();
    assert_eq!(closed[0]["group"]["id"], "grp_b", "the raw delete is recorded: {closed:?}");
}

#[test]
fn sessions_register_import_once_and_forget() {
    let mux = personal_mux();
    run(&mux, json!({"cmd":"create-profile","profile":"prof_work","name":"Work"})).unwrap();
    let put = run(
        &mux,
        json!({"cmd":"put-session","session_id":"remote-1","machine_name":"build-box","session_name":"main",
               "transport":{"kind":"ssh","host":"build-box"},"capabilities":["profiles-v1"],"follow_with":"prof_work"}),
    )
    .unwrap();
    assert_eq!(put["created"], true);
    assert_eq!(put["session"]["migrated"], false);
    let listed = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    let follows_of = |id: &str| {
        listed["profiles"].as_array().unwrap().iter().find(|profile| profile["id"] == id).unwrap()["follows"].clone()
    };
    assert!(follows_of("default").as_array().unwrap().contains(&json!("remote-1")));
    assert_eq!(follows_of("prof_work"), json!(["remote-1"]));
    let refreshed = run(
        &mux,
        json!({"cmd":"put-session","session_id":"remote-1","transport":{"kind":"ssh","host":"build-box"}}),
    )
    .unwrap();
    assert_eq!(refreshed["created"], false);
    assert_eq!(refreshed["session"]["machine_name"], "build-box");
    let import = json!({"cmd":"import-session-organization","session_id":"remote-1",
        "groups":[{"id":"grp_shared","name":"Shared","color":"red","collapsed":true}],
        "workspaces":[{"workspace_key":"w1","group":"grp_shared"},{"workspace_key":"w2"}]});
    assert_eq!(run(&mux, import.clone()).unwrap()["imported"], true);
    let before = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert_eq!(run(&mux, import).unwrap()["imported"], false);
    let after = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert_eq!(before, after);
    let w1 = after["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["workspace_key"] == "w1")
        .unwrap()
        .clone();
    assert_eq!(w1["group"], "grp_shared");
    run(&mux, json!({"cmd":"pin-workspace","session_id":"remote-1","workspace_key":"w1","profile":"prof_work"})).unwrap();
    assert!(run(&mux, json!({"cmd":"forget-session","session_id":"remote-1"})).is_err());
    let forgotten =
        run(&mux, json!({"cmd":"forget-session","session_id":"remote-1","force":true})).unwrap();
    assert_eq!(forgotten["changed"], true);
    let listed = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert!(
        listed["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|session| session["session_id"] != "remote-1")
    );
    assert!(
        listed["workspaces"].as_array().unwrap().iter().all(|row| row["session_id"] != "remote-1")
    );
    assert_eq!(listed["pins"], json!([]));
}

#[test]
fn repeated_session_puts_emit_no_personal_changed() {
    let mux = personal_mux();
    let request = json!({"cmd":"put-session","session_id":"remote-1","machine_name":"build-box",
        "session_name":"main","transport":{"kind":"ssh","host":"build-box"},
        "capabilities":["profiles-v1"]});
    let first = run(&mux, request.clone()).unwrap();
    assert_eq!(first["created"], true);
    let before = revision(&mux);
    let events = mux.subscribe();
    for _ in 0..16 {
        let repeated = run(&mux, request.clone()).unwrap();
        assert_eq!(repeated["created"], false);
        assert_eq!(repeated["session"], first["session"]);
    }
    assert_eq!(revision(&mux), before);
    assert!(!events.try_iter().any(|event| matches!(event, MuxEvent::PersonalChanged { .. })));
    let mut changed = request;
    changed["machine_name"] = json!("renamed-box");
    let updated = run(&mux, changed).unwrap();
    assert_eq!(updated["session"]["machine_name"], "renamed-box");
    assert_eq!(updated["created"], false);
    assert_eq!(revision(&mux), before + 1);
    assert!(events.try_iter().any(|event| matches!(event, MuxEvent::PersonalChanged { .. })));
}

/// The app records each connected session with the capabilities its
/// `identify` returned (SessionRegistrar). This daemon's own list must be
/// accepted as it is: a refused `put-session` leaves the machine out of the
/// registry, and the next launch does not restore it (P-AUSTIN B7a).
#[test]
fn put_session_records_this_daemons_whole_capability_list() {
    let mux = personal_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].clone();
    let put = run(
        &mux,
        json!({"cmd":"put-session","session_id":"remote-1","transport":{"kind":"ssh","host":"build-box"},
               "capabilities":capabilities}),
    )
    .expect("put-session accepts the capability list identify returned");
    assert_eq!(put["session"]["capabilities"], capabilities);
    let listed = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    let recorded = listed["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["session_id"] == "remote-1")
        .expect("the session is in the registry");
    assert_eq!(recorded["capabilities"], capabilities);
}

/// `personal-mixed-order-v1`: groups and loose workspaces share one
/// personal order (`workspace_group.update {top_index}`).
#[test]
fn identify_advertises_the_mixed_personal_order() {
    let mux = personal_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "personal-mixed-order-v1")
    );
}

/// `workspace-group-icon-v1`: a personal workspace group has an icon
/// (`workspace_group.update {icon}`, `list-personal` groups).
#[test]
fn identify_advertises_workspace_group_icons() {
    let mux = personal_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "workspace-group-icon-v1")
    );
}

/// `workspace-group-pin-v1`: a personal workspace group can be pinned
/// (saved) (`workspace_group.update {pinned}`, `list-personal` groups).
#[test]
fn identify_advertises_workspace_group_pins() {
    let mux = personal_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "workspace-group-pin-v1")
    );
}

/// cx-d0d.41 (`personal-remote-localhost-v1`): a workspace's own
/// remote-localhost choice is personal state. `set-personal-workspace`
/// takes `remote_localhost` (true or false; null clears back to the
/// `browser.remoteLocalhost` setting), the row and `list-personal` carry it,
/// and it leaves the row's other fields alone.
#[test]
fn a_personal_workspace_keeps_its_own_remote_localhost_choice() {
    let mux = personal_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "personal-remote-localhost-v1"),
        "identify does not advertise personal-remote-localhost-v1"
    );
    let key = json!({"session_id":"remote-1","workspace_key":"build-box-ws"});
    let set = |fields: Value| {
        let mut request = json!({"cmd":"set-personal-workspace"});
        for source in [&key, &fields] {
            for (name, value) in source.as_object().unwrap() {
                request[name] = value.clone();
            }
        }
        run(&mux, request).unwrap()
    };
    let listed = |mux: &Arc<Mux>| {
        run(mux, json!({"cmd":"list-personal"})).unwrap()["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace_key"] == "build-box-ws")
            .cloned()
            .unwrap()
    };

    let row = set(json!({"theme":"Nord"}));
    assert!(row["workspace"]["remote_localhost"].is_null(), "a new row follows the setting");
    let row = set(json!({"remote_localhost": false}));
    assert_eq!(row["changed"], true);
    assert_eq!(row["workspace"]["remote_localhost"], false);
    assert_eq!(listed(&mux)["remote_localhost"], false);
    assert_eq!(listed(&mux)["theme"], "Nord", "the choice changed another field");
    let before = revision(&mux);
    assert_eq!(set(json!({"remote_localhost": false}))["changed"], false);
    assert_eq!(revision(&mux), before, "an unchanged choice committed a revision");
    assert_eq!(set(json!({"remote_localhost": true}))["workspace"]["remote_localhost"], true);
    let cleared = set(json!({"remote_localhost": null}));
    assert!(cleared["workspace"]["remote_localhost"].is_null(), "null does not clear the choice");
    assert_eq!(listed(&mux)["theme"], "Nord");
}
