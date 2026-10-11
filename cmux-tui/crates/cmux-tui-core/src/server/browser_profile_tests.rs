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
    handle_command(mux, mux.local_test_client(0), command, &writer)
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
