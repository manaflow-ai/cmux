use super::*;

fn test_mux() -> Arc<Mux> {
    Mux::new_for_test("frontend-browser-history", crate::SurfaceOptions::default())
}

fn run_json_command(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

#[test]
fn cmux_next_frontend_browser_history_commands_round_trip() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&FRONTEND_BROWSER_HISTORY_CAPABILITY));
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let created = run_json_command(
        &mux,
        json!({
            "cmd":"new-frontend-browser-tab",
            "pane": pane,
            "url":"https://cmux.com",
            "engine":"webkit",
        }),
    )
    .unwrap();
    let surface = created["surface"].as_u64().unwrap();
    let get = json!({"cmd":"get-frontend-browser-history","surface":surface});
    assert!(run_json_command(&mux, get.clone()).unwrap()["history"].is_null());

    let history = json!({
        "entries": [{"url":"https://cmux.com"}, {"url":"https://cmux.com/docs"}],
        "index": 1,
        "scroll": {"x": 0, "y": 480.5},
    });
    let stored = run_json_command(
        &mux,
        json!({"cmd":"set-frontend-browser-history","surface":surface,"history":history}),
    )
    .unwrap();
    assert_eq!(stored["surface"], surface);
    let read = run_json_command(&mux, get.clone()).unwrap();
    assert_eq!(read["surface"], surface);
    assert_eq!(read["history"], history);
    // The history stays out of the tree.
    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    assert!(!tree.to_string().contains("cmux.com/docs"));

    // Non-object and oversized values are bad requests that keep the
    // stored history; `history` is required, and `null` clears it.
    for rejected in [json!([]), json!("text"), json!(1), json!(true)] {
        let error = run_json_command(
            &mux,
            json!({"cmd":"set-frontend-browser-history","surface":surface,"history":rejected}),
        )
        .unwrap_err();
        assert!(error.to_string().contains("bad request"), "{error}");
    }
    let oversized = json!({
        "pad": "x".repeat(64 * 1024),
    });
    let error = run_json_command(
        &mux,
        json!({"cmd":"set-frontend-browser-history","surface":surface,"history":oversized}),
    )
    .unwrap_err();
    assert!(error.to_string().contains("exceeds"), "{error}");
    assert!(
        run_json_command(&mux, json!({"cmd":"set-frontend-browser-history","surface":surface}))
            .is_err()
    );
    assert_eq!(run_json_command(&mux, get.clone()).unwrap()["history"], history);
    run_json_command(
        &mux,
        json!({"cmd":"set-frontend-browser-history","surface":surface,"history":null}),
    )
    .unwrap();
    assert!(run_json_command(&mux, get).unwrap()["history"].is_null());

    // A PTY tab is not a frontend browser.
    let error = run_json_command(
        &mux,
        json!({"cmd":"set-frontend-browser-history","surface":terminal,"history":{}}),
    )
    .unwrap_err();
    assert!(error.to_string().contains("frontend-rendered"), "{error}");
    assert!(
        run_json_command(&mux, json!({"cmd":"get-frontend-browser-history","surface":terminal}),)
            .is_err()
    );
}
