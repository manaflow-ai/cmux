//! Wire tests for per-terminal themes in the home session's personal state
//! (`personal-terminals-v1`, plans/cmux-next/data-model.md section 6): one
//! theme per session-qualified terminal, listed by `list-personal`.

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
    Mux::new_for_test("personal-terminals", crate::SurfaceOptions::default())
}

fn terminals(mux: &Arc<Mux>) -> Value {
    run(mux, json!({"cmd":"list-personal"})).unwrap()["terminals"].clone()
}

#[test]
fn personal_terminal_theme_capability_is_advertised() {
    let mux = personal_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "personal-terminals-v1")
    );
    assert_eq!(terminals(&mux), json!([]));
}

#[test]
fn personal_terminal_theme_sets_lists_and_clears() {
    let mux = personal_mux();
    let events = mux.subscribe();
    let set = run(
        &mux,
        json!({"cmd":"set-personal-terminal","session_id":"remote-1","terminal_key":"term_0f1e","theme":"light:Rose Pine Dawn,dark:Rose Pine"}),
    )
    .unwrap();
    assert_eq!(set["changed"], true);
    assert_eq!(set["terminal"]["theme"], "light:Rose Pine Dawn,dark:Rose Pine");
    assert_eq!(
        terminals(&mux),
        json!([{"session_id":"remote-1","terminal_key":"term_0f1e","theme":"light:Rose Pine Dawn,dark:Rose Pine"}])
    );
    assert!(events.try_iter().any(|event| matches!(event, MuxEvent::PersonalChanged { .. })));

    // The same theme again changes nothing and emits nothing.
    let again = run(
        &mux,
        json!({"cmd":"set-personal-terminal","session_id":"remote-1","terminal_key":"term_0f1e","theme":"light:Rose Pine Dawn,dark:Rose Pine"}),
    )
    .unwrap();
    assert_eq!(again["changed"], false);
    assert!(events.try_iter().next().is_none());

    // Another theme replaces it; null removes the row.
    run(&mux, json!({"cmd":"set-personal-terminal","session_id":"remote-1","terminal_key":"term_0f1e","theme":"Nord"}))
        .unwrap();
    assert_eq!(terminals(&mux)[0]["theme"], "Nord");
    let cleared = run(
        &mux,
        json!({"cmd":"set-personal-terminal","session_id":"remote-1","terminal_key":"term_0f1e","theme":null}),
    )
    .unwrap();
    assert_eq!(cleared["changed"], true);
    assert!(cleared["terminal"].is_null());
    assert_eq!(terminals(&mux), json!([]));
    let noop = run(
        &mux,
        json!({"cmd":"set-personal-terminal","session_id":"remote-1","terminal_key":"term_0f1e","theme":null}),
    )
    .unwrap();
    assert_eq!(noop["changed"], false);
}

#[test]
fn personal_terminal_theme_refuses_bad_input() {
    let mux = personal_mux();
    for request in [
        json!({"cmd":"set-personal-terminal","session_id":"","terminal_key":"t","theme":"Nord"}),
        json!({"cmd":"set-personal-terminal","session_id":"s","terminal_key":"","theme":"Nord"}),
        json!({"cmd":"set-personal-terminal","session_id":"s","terminal_key":"has space","theme":"Nord"}),
        json!({"cmd":"set-personal-terminal","session_id":"s","terminal_key":"t","theme":"Nord\ntheme = x"}),
        json!({"cmd":"set-personal-terminal","session_id":"s","terminal_key":"t","theme":" "}),
    ] {
        assert!(run(&mux, request.clone()).is_err(), "{request}");
    }
    assert_eq!(terminals(&mux), json!([]));
}

#[test]
fn personal_terminal_themes_go_with_a_forgotten_session() {
    let mux = personal_mux();
    run(&mux, json!({"cmd":"put-session","session_id":"remote-1","transport":{"kind":"ssh"}}))
        .unwrap();
    run(&mux, json!({"cmd":"set-personal-terminal","session_id":"remote-1","terminal_key":"a","theme":"Nord"}))
        .unwrap();
    run(&mux, json!({"cmd":"set-personal-terminal","session_id":"remote-2","terminal_key":"b","theme":"Vesper"}))
        .unwrap();
    assert_eq!(
        run(&mux, json!({"cmd":"forget-session","session_id":"remote-1"})).unwrap()["changed"],
        true
    );
    assert_eq!(
        terminals(&mux),
        json!([{"session_id":"remote-2","terminal_key":"b","theme":"Vesper"}])
    );
}
