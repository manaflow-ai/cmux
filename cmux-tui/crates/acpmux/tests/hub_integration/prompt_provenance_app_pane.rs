//! The app's own pane before it proved the person (`server/requests/prompt_sender.rs`
//! `app_pane_unproven`): its prompts are the person's, never an unverified sender.

use super::prompt_provenance::{Client, hub, prompt};
use acpmux::server::Origin;
use serde_json::json;

/// Leo's composer prompts sent while acpmux restarted (2026-11-12): the app's pane reconnected
/// to a daemon that did not hold its person key yet, so the pane had not proved the person, and
/// each prompt, a screenshot then "STOP CALLING ME ... UNVERIFIED ... SENDER", was recorded as
/// `unverified` and drawn as "Unverified sender · No message text" in the inbox group. A prompt
/// from the app's own pane is the person's, run or queued behind a busy turn, with its text and
/// its image; one that names another sender through the pane stays that sender's, and none
/// lifts a protected hold (`PromptOptions::unproven_owner`).
#[tokio::test]
async fn the_app_panes_prompt_before_it_proved_the_person_is_theirs_with_text_and_image() {
    let hub = hub();
    let mut owner = Client::open(&hub);
    let session = owner.new_session(json!({"harness": "fake"})).await;
    // A fresh pane connection after the restart: LocalApp, no `person_prove` yet.
    let mut pane = Client::open_as(&hub, Origin::LocalApp);
    let image = json!({"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo=", "name": "image.png"});
    let with_image = |id: &str, text: &str| {
        let mut p = prompt(&session, id, text, None);
        p["prompt"].as_array_mut().unwrap().push(image.clone());
        p
    };
    pane.call("session/prompt", with_image("p-shot", "these are so ugly")).await;
    // Queued behind a running turn, as a send during a slow restart is.
    owner.busy(&session).await;
    let queued = pane.queue(with_image("p-queued", "STOP CALLING ME UNVERIFIED SENDER")).await;
    let waiting = owner.records(&session, "queued").await;
    let waiting = waiting.iter().find(|m| m["promptId"] == "p-queued").expect("its queued record");
    assert_eq!(waiting.pointer("/_meta/provenance"), None, "{waiting}");
    owner.cancel(&session).await;
    let done = pane.reply_to(queued).await;
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("end_turn")), "{done}");
    // An agent's message the pane passes on keeps its sender.
    let mut named = prompt(&session, "p-named", "ship it", None);
    named["_meta"]["acpmux"]["fromAgent"] = json!("builder");
    pane.call("session/prompt", named).await;

    for (id, text) in
        [("p-shot", "these are so ugly"), ("p-queued", "STOP CALLING ME UNVERIFIED SENDER")]
    {
        let message = owner.user_message(&session, id).await;
        assert_eq!(message.pointer("/_meta/provenance"), None, "{id}: {message}");
        assert_eq!(message["text"], text, "{id}: {message}");
        let images = message["images"].as_array().map_or(0, Vec::len);
        assert_eq!(images, 1, "{id}: its image survives: {message}");
    }
    let named = owner.user_message(&session, "p-named").await;
    assert_eq!(named.pointer("/_meta/provenance/kind"), Some(&json!("agent_message")), "{named}");
}
