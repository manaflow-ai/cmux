//! Who may call the daemon's Auto methods (`server/auto_gate.rs`): the person switches Auto and
//! settles kept changes; a chat's own agent on the local socket does neither, for its own chat
//! or another, and never sends the wake.

use super::client::Client;
use super::leftover::{LEFTOVER, taken_with_kept_changes};
use super::*;

pub const SET: &str = "_acpmux/auto_session/set";
const WAKE: &str = "_acpmux/auto_session/wake";

/// A chat in the rig's checkout, with Auto off.
pub async fn new_chat(rig: &mut Rig) -> String {
    let created = rig.call("session/new", json!({"cwd": rig.work, "mcpServers": []})).await;
    created["sessionId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn an_agents_connection_is_refused_what_only_the_person_may_do() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let kept = taken_with_kept_changes(&mut rig).await;
    let own = new_chat(&mut rig).await;

    // The agent of one chat, on the local socket: it asks for its own chat and for another.
    let mut agent = Client::agent_of(&rig.hub, &own).await;
    let asks = [
        (SET, json!({"sessionId": own, "auto": true})),
        (SET, json!({"sessionId": kept, "auto": false})),
        (SET, json!({"sessionId": kept, "auto": true, "keepInCloud": true})),
        (LEFTOVER, json!({"sessionId": kept, "action": "discard"})),
        (LEFTOVER, json!({"sessionId": kept, "action": "apply"})),
        (WAKE, json!({})),
    ];
    for (method, params) in asks {
        let refused = agent
            .reply(method, params.clone())
            .await
            .expect_err(&format!("{method} {params} was served to an agent"));
        assert_eq!(refused["data"]["reason"], acpmux::hub::person::REASON, "{method}: {refused}");
    }
    // Nothing of it happened.
    assert_eq!(rig.row(&own)["auto"], false);
    assert!(rig.store.peek(&own).is_none(), "the agent's chat did not go to the Cloud");
    let row = rig.row(&kept);
    assert_eq!((&row["auto"], &row["keepInCloud"]), (&json!(true), &json!(false)), "{row}");
    assert_eq!(row["leftover"]["files"], 1, "{row}");

    // Reading what is kept changes nothing: that stays open to it.
    let shown = agent.reply(LEFTOVER, json!({"sessionId": kept, "action": "show"})).await;
    assert_eq!(shown.expect("show")["files"], json!(["a.txt"]));
}

#[tokio::test]
async fn the_apps_pane_is_served_and_a_remote_connection_is_not() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = new_chat(&mut rig).await;

    let mut pane = Client::connect(&rig.hub, Origin::LocalApp);
    let set = pane.reply(SET, json!({"sessionId": id, "auto": true})).await.expect("the pane");
    assert_eq!(set["autoSession"]["auto"], true, "{set}");
    assert!(rig.store.peek(&id).is_some_and(|view| view.auto), "the store has the chat");
    pane.reply(WAKE, json!({})).await.expect("the app relays the wake");
    let settled = pane.reply(LEFTOVER, json!({"sessionId": id, "action": "discard"})).await;
    settled.expect("the pane settles kept changes");

    let mut remote = Client::connect(&rig.hub, Origin::Web);
    for (method, params) in [(SET, json!({"sessionId": id, "auto": false})), (WAKE, json!({}))] {
        let refused = remote.reply(method, params).await.expect_err("served to a remote client");
        assert_eq!(refused["code"], -32601, "{method}: {refused}");
    }
    assert_eq!(rig.row(&id)["auto"], true);
}
