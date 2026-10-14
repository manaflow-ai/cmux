//! Wire tests for a machine's icon on the home session registry
//! (`session-icon-v1`): `set-session-icon` sets or (null) clears the `icon`
//! of one `list-personal` session record, the record the sidebar shows as a
//! machine, and `put-session`, which the app sends on every sync, keeps it.

use super::super::*;

const REMOTE: &str = "remote-1";

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn session_icon_mux() -> Arc<Mux> {
    Mux::new_for_test("session-icon", crate::SurfaceOptions::default())
}

/// The machine-readable `error_code` the response envelope carries.
fn error_code(result: anyhow::Result<Value>) -> String {
    let error = result.expect_err("the command must fail");
    response_error_code(&error).unwrap_or_else(|| format!("no code: {error}"))
}

fn put_remote(mux: &Arc<Mux>, machine_name: &str) -> Value {
    run(
        mux,
        json!({"cmd":"put-session","session_id":REMOTE,"machine_name":machine_name,
               "session_name":"main","transport":{"kind":"ssh","host":machine_name}}),
    )
    .unwrap()
}

fn set_icon(mux: &Arc<Mux>, session: &str, icon: Value) -> anyhow::Result<Value> {
    run(mux, json!({"cmd":"set-session-icon","session_id":session,"icon":icon}))
}

fn personal(mux: &Arc<Mux>) -> Value {
    run(mux, json!({"cmd":"list-personal"})).unwrap()
}

/// The listed record of `session`, which carries `icon` (null when none).
fn listed_session(mux: &Arc<Mux>, session: &str) -> Value {
    personal(mux)["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|record| record["session_id"] == session)
        .unwrap_or_else(|| panic!("no session {session}"))
        .clone()
}

fn personal_changes(events: &crate::event_bus::MuxEventReceiver) -> usize {
    events.try_iter().filter(|event| matches!(event, MuxEvent::PersonalChanged { .. })).count()
}

/// Store an SVG through the wire (`put-blob`) and return its icon value.
fn put_svg(mux: &Arc<Mux>) -> String {
    use base64::Engine as _;
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z"/></svg>"#;
    let stored = run(
        mux,
        json!({"cmd":"put-blob","media_type":"image/svg+xml",
               "data":base64::engine::general_purpose::STANDARD.encode(svg)}),
    )
    .unwrap();
    stored["icon"].as_str().unwrap().to_string()
}

#[test]
fn session_icon_capability_is_advertised_and_records_start_without_one() {
    let mux = session_icon_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|value| value == "session-icon-v1"),
        "{identity}"
    );
    let own = identity["registry_id"].as_str().unwrap().to_string();
    let record = listed_session(&mux, &own);
    assert!(record.get("icon").is_some_and(Value::is_null), "{record}");
    let put = put_remote(&mux, "build-box");
    assert!(put["session"].get("icon").is_some_and(Value::is_null), "{put}");
}

#[test]
fn a_session_takes_an_icon_and_clears_it() {
    let mux = session_icon_mux();
    put_remote(&mux, "build-box");
    let events = mux.subscribe();
    let revision = personal(&mux)["personal_revision"].clone();

    let set = set_icon(&mux, REMOTE, json!("🚀")).unwrap();
    assert_eq!(set["changed"], true, "{set}");
    assert_eq!(set["session"]["session_id"], REMOTE);
    assert_eq!(set["session"]["icon"], "🚀");
    assert_eq!(set["session"]["machine_name"], "build-box");
    assert_eq!(listed_session(&mux, REMOTE)["icon"], "🚀");
    assert_ne!(personal(&mux)["personal_revision"], revision);
    assert_eq!(personal_changes(&events), 1);

    let symbol = set_icon(&mux, REMOTE, json!("server.rack")).unwrap();
    assert_eq!(symbol["changed"], true);
    assert_eq!(listed_session(&mux, REMOTE)["icon"], "server.rack");
    assert_eq!(personal_changes(&events), 1);

    // The same icon again changes nothing and emits nothing.
    let revision = personal(&mux)["personal_revision"].clone();
    let same = set_icon(&mux, REMOTE, json!("server.rack")).unwrap();
    assert_eq!(same["changed"], false);
    assert_eq!(same["session"]["icon"], "server.rack");
    assert_eq!(personal(&mux)["personal_revision"], revision);
    assert_eq!(personal_changes(&events), 0);

    // JSON null clears it.
    let cleared = set_icon(&mux, REMOTE, Value::Null).unwrap();
    assert_eq!(cleared["changed"], true);
    assert!(cleared["session"]["icon"].is_null(), "{cleared}");
    assert!(listed_session(&mux, REMOTE)["icon"].is_null());
    assert_eq!(personal_changes(&events), 1);
    let again = set_icon(&mux, REMOTE, Value::Null).unwrap();
    assert_eq!(again["changed"], false);
    assert_eq!(personal_changes(&events), 0);

    // This daemon's own record (the local machine) takes one too.
    let own =
        run(&mux, json!({"cmd":"identify"})).unwrap()["registry_id"].as_str().unwrap().to_string();
    set_icon(&mux, &own, json!("laptopcomputer")).unwrap();
    assert_eq!(listed_session(&mux, &own)["icon"], "laptopcomputer");
    assert!(listed_session(&mux, REMOTE)["icon"].is_null());
}

/// `put-session` refreshes a record on every app sync; it never touches the
/// icon.
#[test]
fn put_session_keeps_a_session_icon() {
    let mux = session_icon_mux();
    put_remote(&mux, "build-box");
    set_icon(&mux, REMOTE, json!("💻")).unwrap();

    let refreshed = put_remote(&mux, "build-box-renamed");
    assert_eq!(refreshed["created"], false);
    assert_eq!(refreshed["session"]["machine_name"], "build-box-renamed");
    assert_eq!(refreshed["session"]["icon"], "💻", "{refreshed}");
    let bare = run(
        &mux,
        json!({"cmd":"put-session","session_id":REMOTE,"transport":{"kind":"ssh","host":"other"}}),
    )
    .unwrap();
    assert_eq!(bare["session"]["icon"], "💻", "{bare}");
    assert_eq!(listed_session(&mux, REMOTE)["icon"], "💻");

    // A forgotten session takes its icon with it.
    run(&mux, json!({"cmd":"forget-session","session_id":REMOTE})).unwrap();
    let again = put_remote(&mux, "build-box");
    assert_eq!(again["created"], true);
    assert!(again["session"]["icon"].is_null(), "{again}");
}

#[test]
fn a_session_icon_is_refused_when_it_is_not_an_icon_or_the_session_is_unknown() {
    let mux = session_icon_mux();
    put_remote(&mux, "build-box");
    let revision = personal(&mux)["personal_revision"].clone();
    for bad in ["Not An Icon", "", "🚀🚀", "svg:sha256-nothex", "image:"] {
        assert!(set_icon(&mux, REMOTE, json!(bad)).is_err(), "{bad:?}");
    }
    assert!(set_icon(&mux, REMOTE, json!(7)).is_err());
    // `icon` is required: null clears, absent is refused.
    assert!(run(&mux, json!({"cmd":"set-session-icon","session_id":REMOTE})).is_err());
    // An unknown or malformed session.
    let unknown = set_icon(&mux, "remote-404", json!("🚀")).expect_err("unknown session");
    assert!(unknown.to_string().contains("unknown session remote-404"), "{unknown}");
    assert!(set_icon(&mux, "remote-404", Value::Null).is_err());
    assert!(set_icon(&mux, "has space", json!("🚀")).is_err());
    assert_eq!(personal(&mux)["personal_revision"], revision);
    assert!(listed_session(&mux, REMOTE)["icon"].is_null());
    assert!(
        personal(&mux)["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|record| record["session_id"] != "remote-404")
    );
}

/// A stored SVG is a session icon too: a missing one is refused, a stored
/// one sets, and the blob outlives the sweep while the record names it.
#[test]
fn a_session_icon_takes_a_stored_asset_and_keeps_it_from_the_sweep() {
    use crate::workspace_registry::personal_store::blobs::sweep_blobs;
    let mux = session_icon_mux();
    put_remote(&mux, "build-box");
    let missing = format!("svg:sha256-{}", "0".repeat(64));
    assert_eq!(error_code(set_icon(&mux, REMOTE, json!(missing))), "unknown_icon_asset");
    let icon = put_svg(&mux);
    // The digest of an SVG does not name a raster.
    let swapped = icon.replace("svg:", "image:");
    assert_eq!(error_code(set_icon(&mux, REMOTE, json!(swapped))), "unknown_icon_asset");
    assert!(listed_session(&mux, REMOTE)["icon"].is_null());

    let set = set_icon(&mux, REMOTE, json!(icon)).unwrap();
    assert_eq!(set["changed"], true);
    assert_eq!(set["session"]["icon"], json!(icon));
    assert_eq!(listed_session(&mux, REMOTE)["icon"], json!(icon));

    // Long after the put, only the session's reference keeps the blob.
    let later = u64::MAX / 2;
    mux.with_icon_registry(|registry| sweep_blobs(&registry.connection.get(), later)).unwrap();
    run(&mux, json!({"cmd":"get-blob","blob":icon})).unwrap();

    // Once cleared, nothing names it and the sweep takes it.
    set_icon(&mux, REMOTE, Value::Null).unwrap();
    mux.with_icon_registry(|registry| sweep_blobs(&registry.connection.get(), later)).unwrap();
    assert_eq!(error_code(run(&mux, json!({"cmd":"get-blob","blob":icon}))), "not_found");
}
