//! Wire tests for browser profile records in the home session's personal
//! state (`browser-profiles-v1`, plans/cmux-next/data-model.md section 5).

use super::*;

const WORK: &str = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
const CLIENT: &str = "11111111-1111-4111-8111-111111111111";

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request)?;
    // The cmux app's own connection: only it may delete a browser profile.
    let client = mux.local_test_client(0);
    origin_gate::set_role_for_test(mux, client, "main");
    origin_gate::set_verified_app_for_test(mux, client, true);
    handle_command(mux, client, command, &writer)
}

fn profiles_mux() -> Arc<Mux> {
    Mux::new_for_test("browser-profiles", crate::SurfaceOptions::default())
}

fn listed(mux: &Arc<Mux>) -> Value {
    run(mux, json!({"cmd":"list-personal"})).unwrap()
}

#[test]
fn browser_profiles_start_with_the_default_profile() {
    let mux = profiles_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "browser-profiles-v1")
    );
    let personal = listed(&mux);
    assert_eq!(personal["browser_profiles"].as_array().unwrap().len(), 1);
    assert_eq!(personal["browser_profiles"][0]["id"], "default");
    assert_eq!(personal["browser_profiles"][0]["name"], "Default");
    assert_eq!(personal["browser_profiles"][0]["index"], 0);
    assert!(personal["browser_profiles"][0]["source"].is_null());
}

#[test]
fn browser_profiles_round_trip_over_the_wire() {
    let mux = profiles_mux();
    let events = mux.subscribe();
    let created = run(
        &mux,
        json!({"cmd":"create-browser-profile","browser_profile":WORK,"name":"Work","color":"green",
               "icon":"💼","source":{"browser":"chrome","profile_dir":"Profile 1"}}),
    )
    .unwrap();
    assert_eq!(created["changed"], true);
    assert_eq!(created["browser_profile"]["id"], WORK);
    assert_eq!(created["browser_profile"]["index"], 1);
    assert_eq!(created["browser_profile"]["source"]["profile_dir"], "Profile 1");
    let revision = listed(&mux)["personal_revision"].as_u64().unwrap();
    assert!(events.try_iter().any(|event| matches!(
        event,
        MuxEvent::PersonalChanged { personal_revision } if personal_revision == revision
    )));
    // A retry with the same id returns the stored record (an interrupted
    // import finds the profile it made) and changes nothing.
    let retried =
        run(&mux, json!({"cmd":"create-browser-profile","browser_profile":WORK,"name":"Other"}))
            .unwrap();
    assert_eq!(retried["changed"], false);
    assert_eq!(retried["browser_profile"]["name"], "Work");
    assert_eq!(listed(&mux)["personal_revision"].as_u64().unwrap(), revision);
    // A new profile without an id gets a lowercase UUID.
    let generated =
        run(&mux, json!({"cmd":"create-browser-profile","name":"Client","index":1})).unwrap();
    let generated_id = generated["browser_profile"]["id"].as_str().unwrap().to_string();
    assert_eq!(generated_id.len(), 36);
    assert_eq!(generated_id, generated_id.to_lowercase());
    assert_eq!(generated["browser_profile"]["index"], 1);
    // Absent fields stay, null clears.
    let updated = run(
        &mux,
        json!({"cmd":"update-browser-profile","browser_profile":WORK,"name":"Day job","color":null}),
    )
    .unwrap();
    assert_eq!(updated["changed"], true);
    assert_eq!(updated["browser_profile"]["name"], "Day job");
    assert!(updated["browser_profile"]["color"].is_null());
    assert_eq!(updated["browser_profile"]["icon"], "💼");
    let unchanged =
        run(&mux, json!({"cmd":"update-browser-profile","browser_profile":WORK,"name":"Day job"}))
            .unwrap();
    assert_eq!(unchanged["changed"], false);
    let moved =
        run(&mux, json!({"cmd":"move-browser-profile","browser_profile":WORK,"index":0})).unwrap();
    assert_eq!(moved["browser_profile"]["index"], 0);
    let order = listed(&mux)["browser_profiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|profile| profile["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(order, vec![WORK.to_string(), "default".to_string(), generated_id]);
    for bad in [
        json!({"cmd":"create-browser-profile","browser_profile":"Work","name":"Work"}),
        json!({"cmd":"create-browser-profile","browser_profile":WORK.to_uppercase(),"name":"Work"}),
        json!({"cmd":"create-browser-profile","name":"Bad","color":"not a color"}),
        json!({"cmd":"create-browser-profile","name":"Bad","icon":"🧪🧪"}),
        json!({"cmd":"create-browser-profile","name":"Bad","source":"chrome"}),
        json!({"cmd":"create-browser-profile","name":""}),
        json!({"cmd":"update-browser-profile","browser_profile":CLIENT,"name":"Nope"}),
        json!({"cmd":"delete-browser-profile","browser_profile":"default"}),
        json!({"cmd":"delete-browser-profile","browser_profile":CLIENT}),
    ] {
        assert!(run(&mux, bad.clone()).is_err(), "{bad} must fail");
    }
}

#[test]
fn deleting_a_browser_profile_clears_the_defaults_that_name_it() {
    let mux = profiles_mux();
    run(&mux, json!({"cmd":"create-browser-profile","browser_profile":WORK,"name":"Work"}))
        .unwrap();
    run(&mux, json!({"cmd":"create-browser-profile","browser_profile":CLIENT,"name":"Client"}))
        .unwrap();
    run(
        &mux,
        json!({"cmd":"set-personal-workspace","session_id":"remote-1","workspace_key":"w1",
               "browser_profile_id":WORK}),
    )
    .unwrap();
    run(
        &mux,
        json!({"cmd":"set-personal-workspace","session_id":"remote-1","workspace_key":"w2",
               "browser_profile_id":CLIENT}),
    )
    .unwrap();
    run(&mux, json!({"cmd":"update-profile","profile":"default","browser_profile_id":WORK}))
        .unwrap();
    let deleted =
        run(&mux, json!({"cmd":"delete-browser-profile","browser_profile":WORK})).unwrap();
    assert_eq!(deleted["browser_profile"], WORK);
    assert_eq!(
        deleted["cleared_workspaces"],
        json!([{"session_id":"remote-1","workspace_key":"w1"}])
    );
    assert_eq!(deleted["cleared_rooms"], json!(["default"]));
    let personal = listed(&mux);
    let ids = personal["browser_profiles"]
        .as_array()
        .unwrap()
        .iter()
        .map(|profile| profile["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(ids, vec!["default".to_string(), CLIENT.to_string()]);
    assert_eq!(personal["browser_profiles"][1]["index"], 1);
    let workspace = |key: &str| {
        personal["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace_key"] == key)
            .cloned()
            .unwrap()
    };
    assert!(workspace("w1")["browser_profile_id"].is_null());
    assert_eq!(workspace("w2")["browser_profile_id"], CLIENT);
    assert!(personal["profiles"][0]["browser_profile_id"].is_null());
}

/// cx-d0d.89: deleting a profile (only the person can, through the app) moves
/// the browser tabs that named it to the default profile in the same commit,
/// and each says so (`tab-changed`): no tab record names a deleted profile,
/// whichever app (macOS, Linux, Windows) deleted it.
#[test]
fn deleting_a_browser_profile_moves_its_tabs_to_the_default_profile() {
    let mux = profiles_mux();
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    run(&mux, json!({"cmd":"create-browser-profile","browser_profile":WORK,"name":"Work"}))
        .unwrap();
    let opened = run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","url":"https://example.com/work",
               "engine":"webkit","pane":pane,"profile_id":WORK}),
    )
    .unwrap();
    let surface = opened["surface"].as_u64().unwrap();
    let profile_of = |mux: &Arc<Mux>| {
        let tab = mux.surface(surface).unwrap();
        mux.frontend_browser(&tab).unwrap().profile_id
    };
    assert_eq!(profile_of(&mux).as_deref(), Some(WORK));

    let events = mux.subscribe();
    let deleted =
        run(&mux, json!({"cmd":"delete-browser-profile","browser_profile":WORK})).unwrap();
    assert_eq!(profile_of(&mux), None, "the tab still names the deleted profile: {deleted}");
    let announced = std::iter::from_fn(|| events.try_recv().ok()).any(|event| {
        matches!(event, MuxEvent::TreeDelta(delta)
            if delta.kind == TreeDeltaKind::TabChanged
                && delta.surface == Some(surface)
                && delta.entity["browser_profile_id"].is_null())
    });
    assert!(announced, "no tab-changed for the tab that moved to the default profile");
}

/// #24432: a browser profile carries its own network identity. The proxy is
/// part of the record (scheme, host, port, optional bypass list), never a
/// secret: credentials stay out of cmux's records, so an authenticated
/// upstream goes behind a local relay the profile points at.
#[test]
fn a_browser_profile_carries_a_proxy_and_never_a_secret() {
    let mux = profiles_mux();
    run(&mux, json!({"cmd":"create-browser-profile","browser_profile":WORK,"name":"US-A"}))
        .unwrap();
    let set = run(
        &mux,
        json!({"cmd":"update-browser-profile","browser_profile":"US-A",
               "proxy":{"scheme":"socks5","host":"127.0.0.1","port":1080,"bypass":["*.corp.test"]}}),
    )
    .unwrap();
    assert_eq!(set["changed"], true);
    assert_eq!(
        set["browser_profile"]["proxy"],
        json!({"scheme":"socks5","host":"127.0.0.1","port":1080,"bypass":["*.corp.test"]})
    );
    let profiles = listed(&mux)["browser_profiles"].as_array().unwrap().clone();
    let default = profiles.iter().find(|p| p["id"] == "default").unwrap();
    // A profile without one stays direct, exactly as before.
    assert!(default.get("proxy").is_none_or(Value::is_null), "{default}");
    let work = profiles.iter().find(|p| p["id"] == WORK).unwrap();
    assert_eq!(work["proxy"]["port"], 1080);
    // The same proxy again changes nothing; null clears it.
    let again = run(
        &mux,
        json!({"cmd":"update-browser-profile","browser_profile":WORK,
               "proxy":{"scheme":"socks5","host":"127.0.0.1","port":1080,"bypass":["*.corp.test"]}}),
    )
    .unwrap();
    assert_eq!(again["changed"], false);
    let cleared =
        run(&mux, json!({"cmd":"update-browser-profile","browser_profile":WORK,"proxy":null}))
            .unwrap();
    assert!(cleared["browser_profile"]["proxy"].is_null());
    for bad in [
        json!({"scheme":"socks5","host":"127.0.0.1","port":1080,"password":"hunter2"}),
        json!({"scheme":"http","host":"gw.test","port":8080,"username":"me"}),
        json!({"scheme":"http","host":"me:pw@gw.test","port":8080}),
        json!({"scheme":"ftp","host":"gw.test","port":21}),
        json!({"scheme":"http","host":"","port":8080}),
        json!({"scheme":"http","host":"gw test","port":8080}),
        json!({"scheme":"http","host":"gw.test","port":0}),
        json!({"scheme":"http","host":"gw.test","port":70000}),
        json!({"scheme":"http","host":"gw.test"}),
        json!("socks5://127.0.0.1:1080"),
    ] {
        let error = run(
            &mux,
            json!({"cmd":"update-browser-profile","browser_profile":WORK,"proxy":bad.clone()}),
        )
        .expect_err(&format!("{bad} must be refused"));
        if bad.get("password").is_some() || bad.get("username").is_some() {
            assert!(error.to_string().contains("local relay"), "{error}");
        }
    }
    assert!(listed(&mux)["browser_profiles"][1]["proxy"].is_null());
}
