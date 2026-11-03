//! HOT PATH AUDIT state (hpa-state, 2026-11-03): every command that makes a
//! pane names it (`pane`) in its result. Without it the app read the whole
//! tree (`list-workspaces`, about 3.7 KB per workspace, 1.5 MB and 24 ms
//! under `Mux::state` at 400 workspaces) after each split, column and screen
//! to find the pane it had just made.

use super::*;

#[test]
fn every_pane_creation_names_the_pane_that_holds_its_surface() {
    let mux = Mux::new_for_test("pane-in-reply", crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let workspace = mux.with_state(|state| state.workspaces[0].id);

    let requests = [
        json!({"cmd": "split", "pane": pane, "dir": "right"}),
        json!({"cmd": "split", "pane": pane, "dir": "down", "kind": "browser", "url": "https://example.com/"}),
        json!({"cmd": "new-pane", "pane": pane}),
        json!({"cmd": "new-pane-right", "pane": pane}),
        json!({"cmd": "new-pane-right", "pane": pane, "kind": "browser", "url": "https://example.com/"}),
        json!({"cmd": "new-screen", "workspace": workspace}),
    ];
    for (id, mut request) in requests.into_iter().enumerate() {
        request["id"] = json!(id + 1);
        handle_message(&mux, mux.local_test_client(7), &request.to_string(), &writer);
        let response: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["ok"], true, "{request} failed: {response}");
        let reply = &response["data"];
        let surface =
            reply["surface"].as_u64().unwrap_or_else(|| panic!("{request}: no surface in {reply}"));
        let holding = mux.with_state(|state| state.pane_of(surface)).unwrap();
        assert_eq!(
            reply["pane"],
            json!(holding),
            "{request}: the reply does not name the new pane: {reply}"
        );
        assert_ne!(holding, pane, "{request}: the new surface is in the target pane");
    }
    mux.shutdown();
}
