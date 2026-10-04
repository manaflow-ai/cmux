//! Supervisor tests of the host-side ABI enforcement (raw calls; the runtime
//! is not involved) and palette runs.

use super::*;

#[test]
fn view_state_ops_need_a_live_token_for_this_app_spent_once() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    for op in ["tab.focus", "terminal.viewport.scroll", "workspace.focus", "pane.zoom"] {
        let refused = f.call("m1", op, json!({}), false);
        assert_eq!(refused["body"]["code"], "gesture.required", "{op}: {refused}");
    }
    // One user event: the first view-state call spends its token, the second is refused.
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "tab.focus", "params": { "tab": "tab_1" }, "twice": true }),
            true,
        )
        .unwrap();
    let mut results = Vec::new();
    while results.len() < 2 {
        let update =
            f.wait("call result", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
        results.push(update["ops"][0]["props"]["result"].clone());
    }
    // Answers arrive in any order: a refusal is immediate, an accepted call
    // answers from its worker thread.
    let accepted = results.iter().filter(|r| r["ok"] == true).count();
    let refused = results.iter().filter(|r| r["body"]["code"] == "gesture.required").count();
    assert_eq!((accepted, refused), (1, 1), "a token is spent once: {results:?}");
}

#[test]
fn a_client_cannot_mint_a_token_and_another_apps_token_does_not_count() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    // A token the client wrote into the payload is stripped (automation event).
    f.supervisor
        .dispatch(
            CLIENT,
            "m1",
            "n1",
            "tap",
            json!({ "op": "tab.focus", "params": {}, "gesture": "g_forged" }),
            false,
        )
        .unwrap();
    let update =
        f.wait("call result", |e| e["event"] == "apps-scene" && e["ops"][0]["op"] == "update");
    assert_eq!(update["ops"][0]["props"]["result"]["body"]["code"], "gesture.required");
}

#[test]
fn action_run_honors_the_action_catalog_and_needs_a_gesture() {
    let f = fixture();
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    for (id, reason) in [
        ("palette.auth.signIn", "credentials"),
        ("quit", "endsApp"),
        ("keepMacAwake", "systemChange"),
        ("taskManager.killProcess", "liveInput"),
    ] {
        let refused = f.call("m1", "action.run", json!({ "id": id }), true);
        assert_eq!(
            (refused["body"]["code"].clone(), refused["body"]["details"]["reason"].clone()),
            (json!("scope.missing"), json!(reason)),
            "{id}"
        );
    }
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "made.up" }), true)["body"]["code"],
        "operation.unsupported"
    );
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "newWindow" }), false)["body"]["code"],
        "gesture.required"
    );
    // Allowed with a gesture; with no Mac app connected it fails at once (APP-R1).
    let unavailable = f.call("m1", "action.run", json!({ "id": "newWindow" }), true);
    assert_eq!(
        (unavailable["body"]["code"].clone(), unavailable["body"]["retryable"].clone()),
        (json!("provider.unavailable"), json!(true))
    );
    assert_eq!(unavailable["body"]["details"]["family"], "action");
}

#[test]
fn action_run_needs_the_actions_scope() {
    let f = fixture();
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    assert_eq!(
        f.call("m1", "action.run", json!({ "id": "newWindow" }), true)["body"]["code"],
        "scope.missing"
    );
}

#[test]
fn a_palette_command_runs_its_user_only_op_with_the_palette_gesture() {
    let f = fixture();
    f.install("cmux/demo");
    let (tx, rx) = channel();
    let tx2 = tx.clone();
    f.supervisor.run(
        run_request("cmux/demo", "demo.focus", None, Origin::User, Some("palette-run-1")),
        Box::new(move |r| tx.send(r).unwrap()),
    );
    assert!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().is_ok(),
        "focus from the palette is accepted"
    );
    let calls = f.router.calls.lock().unwrap().clone();
    assert_eq!((calls[0].1.as_str(), calls[0].4), ("tab.focus", Origin::User));
    // The same command from the CLI carries no gesture and is refused.
    f.supervisor.run(
        run_request("cmux/demo", "demo.focus", None, Origin::Cli, Some("palette-run-2")),
        Box::new(move |r| tx2.send(r).unwrap()),
    );
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err().code,
        "gesture.required"
    );
}

#[test]
fn apps_list_lists_palette_commands_and_apps_run_runs_them() {
    let f = fixture();
    f.install("cmux/demo");
    let demo = app_entry(&f.supervisor.list(), "cmux/demo");
    assert_eq!(
        demo["commands"],
        json!([{ "op": "demo.go", "title": "Go", "when": "paneFocused:editor" }])
    );
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::User, None),
        Box::new(move |r| tx.send(r).unwrap()),
    );
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(),
        json!({ "value": "go" })
    );
}
