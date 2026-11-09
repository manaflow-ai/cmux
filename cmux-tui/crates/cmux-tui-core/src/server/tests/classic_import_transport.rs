//! `classic_import.plan` through the connection's own reply path: a classic
//! save whose scrollback alone passes the server's control-reply limit
//! (100 terminals of 400,000 characters, 40 MB) still answers in one reply,
//! each terminal keeping its newest scrollback, and the connection stays open.

use super::*;
use crate::server::origin_gate::{set_role_for_test, set_verified_app_for_test};
use crate::state::classic_import_router::TEST_HOME;

/// Puts the wire's classic home back, and removes it, when the test ends.
struct WireHome(std::path::PathBuf);

impl Drop for WireHome {
    fn drop(&mut self) {
        *TEST_HOME.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn a_plan_over_the_control_limit_still_answers_in_one_reply() {
    let mut nonce = [0u8; 8];
    getrandom::fill(&mut nonce).unwrap();
    let dir = std::env::temp_dir().join(format!("cmux-classic-wire-{}", u64::from_le_bytes(nonce)));
    std::fs::create_dir_all(&dir).unwrap();
    let home_path = dir.canonicalize().unwrap();
    let _restore = WireHome(home_path.clone());
    let session = home_path.join("Library/Application Support/cmux/session-com.cmuxterm.app.json");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();
    let line = "\u{1b}[32mok\u{1b}[0m compiled a crate\n";
    let scrollback = line.repeat(400_000 / line.len());
    let workspaces: Vec<Value> = (0..100)
        .map(|index| {
            json!({
                "stableId": format!("w{index}"), "currentDirectory": "/tmp",
                "panels": [{"id": format!("{index:08x}-0000-4000-8000-000000000000"),
                            "type": "terminal", "terminal": {"scrollback": scrollback}}],
            })
        })
        .collect();
    let save = json!({"version": 1, "createdAt": 5.0,
                      "windows": [{"tabManager": {"workspaces": workspaces}}]});
    let bytes = serde_json::to_vec(&save).unwrap();
    assert!(bytes.len() > crate::REMOTE_SESSION_MESSAGE_MAX_BYTES, "{}", bytes.len());
    std::fs::write(&session, bytes).unwrap();
    *TEST_HOME.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(home_path);

    let mux = test_mux();
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    set_role_for_test(&mux, client, "main");
    set_verified_app_for_test(&mux, client, true);
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let params = json!({"machine": "current", "session": "current",
                        "bundle_id": "com.cmuxterm.app", "mode": "automatic"});
    let request = resource_request("plan", "classic_import.plan", params, None);
    assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));

    let text = outbound.try_pop().expect("one reply");
    assert!(text.len() <= crate::REMOTE_SESSION_MESSAGE_MAX_BYTES, "{}", text.len());
    assert!(writer.is_open());
    let response: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(response["ok"], true, "{}", &text[..text.len().min(400)]);
    let value = &response["result"];
    let value = if value.get("plan").is_some() { value } else { &value["value"] };
    assert_eq!(value["decision"], json!({"decision": "first_run"}));
    let plan = &value["plan"];
    assert_eq!(plan["scrollback_trimmed"], 100);
    let tabs: Vec<&str> = plan["windows"][0]["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|workspace| workspace["layout"]["pane"]["tabs"][0]["scrollback"].as_str().unwrap())
        .collect();
    assert_eq!(tabs.len(), 100);
    for kept in tabs {
        assert!(scrollback.ends_with(kept) && kept.starts_with('\u{1b}'), "{}", kept.len());
        assert!(kept.len() > 100_000, "{}", kept.len());
    }
}
