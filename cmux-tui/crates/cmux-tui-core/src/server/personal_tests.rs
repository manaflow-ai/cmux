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
