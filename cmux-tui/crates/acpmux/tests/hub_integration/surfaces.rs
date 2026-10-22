//! One chat typed into from several places at once (`hub/composers.rs`, cmuxterm-hq#2580):
//! every client may prompt, the hub runs the prompts one turn at a time in the order they came,
//! and every client sees who sent each one and who is typing.

use super::*;

fn surface(id: &str, name: &str) -> Value {
    json!({"id": id, "name": name})
}

fn surface_prompt(id: &str, text: &str, prompt_id: &str, from: Value) -> Value {
    json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id, "surface": from}},
    })
}

fn composer_records(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    let events = hub.events(id, 0, 1000).unwrap();
    find(&events, "composer").into_iter().map(|e| e.msg.clone()).collect()
}

#[tokio::test]
async fn prompts_from_three_surfaces_queue_in_order_and_every_client_sees_who_sent_them() {
    let (hub, mut mac) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut mac, "shared").await;
    let mut phone = connect(&hub).await;
    phone.request(method::MUX_ATTACH, json!({"session": id})).await.unwrap();
    let mut cli = connect(&hub).await;

    // The Mac's turn runs until it is cancelled, so the others wait behind it.
    let running = mac
        .send(
            method::SESSION_PROMPT,
            surface_prompt(&id, "until-cancel", "p-mac", surface("mac-1", "Mac")),
        )
        .await;
    mac.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-mac").await;
    let from_phone = phone
        .send(
            method::SESSION_PROMPT,
            surface_prompt(&id, "from the phone", "p-phone", surface("iphone", "iPhone")),
        )
        .await;
    let acc = phone.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-phone").await;
    assert_eq!(acc["queued"], true);
    assert_eq!(acc["position"], 1);
    let cli_surface = json!({"id": "cli", "name": "CLI", "kind": "cli"});
    let from_cli = cli
        .send(method::SESSION_PROMPT, surface_prompt(&id, "from the cli", "p-cli", cli_surface))
        .await;
    let acc = cli.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-cli").await;
    assert_eq!(acc["position"], 2);

    // The Mac hears, live, which surface sent each queued prompt.
    let heard = mac
        .wait_for(method::MUX_EVENT, |p| {
            p["kind"] == "composer" && p["msg"]["promptId"] == "p-phone"
        })
        .await;
    assert_eq!(heard["msg"]["name"], "iPhone");
    assert_eq!(heard["msg"]["composing"], false);
    let heard = mac
        .wait_for(method::MUX_EVENT, |p| p["kind"] == "composer" && p["msg"]["promptId"] == "p-cli")
        .await;
    assert_eq!(heard["msg"]["kind"], "cli");

    // Any client reads the same queue, in run order, each prompt labelled with its surface.
    let view = phone.request(method::MUX_COMPOSERS, json!({"sessionId": id})).await.unwrap();
    assert_eq!(view["turn"]["promptId"], "p-mac");
    assert_eq!(view["turn"]["surface"]["name"], "Mac");
    let queue = view["queue"].as_array().unwrap();
    let order: Vec<&str> = queue.iter().map(|q| q["promptId"].as_str().unwrap()).collect();
    assert_eq!(order, ["p-phone", "p-cli"]);
    assert_eq!(queue[0]["surface"]["surfaceId"], "iphone");
    assert_eq!(queue[1]["surface"]["name"], "CLI");
    assert_eq!(view, cli.request(method::MUX_COMPOSERS, json!({"sessionId": id})).await.unwrap());

    // Stopping the Mac's turn runs the queue, one turn at a time, in the order it came.
    mac.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    assert!(mac.response(running).await.0.is_ok());
    assert!(phone.response(from_phone).await.0.is_ok());
    assert!(cli.response(from_cli).await.0.is_ok());
    let events = hub.events(&id, 0, 1000).unwrap();
    let ran: Vec<&str> =
        find(&events, "turn_started").iter().map(|e| e.msg["promptId"].as_str().unwrap()).collect();
    assert_eq!(ran, ["p-mac", "p-phone", "p-cli"]);
    let sent: Vec<Value> =
        composer_records(&hub, &id).iter().map(|r| r["promptId"].clone()).collect();
    assert_eq!(sent, [json!("p-mac"), json!("p-phone"), json!("p-cli")]);
    let view = mac.request(method::MUX_COMPOSERS, json!({"sessionId": id})).await.unwrap();
    assert!(view["turn"].is_null() && view["queue"].as_array().unwrap().is_empty(), "{view}");
}

#[tokio::test]
async fn each_surface_keeps_its_own_draft_and_others_see_it_composing() {
    let (hub, mut mac) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut mac, "drafts").await;
    let mut phone = connect(&hub).await;
    let set = |from: Value, text: &str| json!({"sessionId": id, "surface": from, "text": text});

    mac.request(method::MUX_COMPOSER_SET, set(surface("mac-1", "Mac"), "half a thought"))
        .await
        .unwrap();
    phone
        .request(method::MUX_COMPOSER_SET, set(surface("iphone", "iPhone"), "on the train"))
        .await
        .unwrap();
    // More typing on the Mac changes its draft but records nothing new: no record per key.
    let ack = mac
        .request(method::MUX_COMPOSER_SET, set(surface("mac-1", "Mac"), "half a thought, more"))
        .await
        .unwrap();
    // The answer is this surface's own state, never every surface's text.
    assert_eq!(ack, json!({"sessionId": id, "surfaceId": "mac-1", "composing": true}));
    let view = phone.request(method::MUX_COMPOSERS, json!({"sessionId": id})).await.unwrap();
    let texts: Vec<(&str, &str)> = view["composers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["surfaceId"].as_str().unwrap(), c["text"].as_str().unwrap()))
        .collect();
    assert_eq!(texts, [("mac-1", "half a thought, more"), ("iphone", "on the train")]);
    let records = composer_records(&hub, &id);
    assert_eq!(records.len(), 2, "{records:?}");
    assert!(records.iter().all(|r| r["composing"] == true));

    // The phone sends its draft: its own draft is gone, the Mac's stays, and the shared
    // single-slot draft was never touched.
    let r = phone
        .request(
            method::SESSION_PROMPT,
            surface_prompt(&id, "on the train", "p-1", surface("iphone", "iPhone")),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");
    let view = mac.request(method::MUX_COMPOSERS, json!({"sessionId": id})).await.unwrap();
    let left: Vec<&str> = view["composers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["surfaceId"].as_str().unwrap())
        .collect();
    assert_eq!(left, ["mac-1"]);
    let shared = mac.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert!(shared["draft"].is_null(), "{shared}");

    // Clearing the Mac's text says it stopped composing.
    mac.request(method::MUX_COMPOSER_SET, set(surface("mac-1", "Mac"), " \n")).await.unwrap();
    let last = composer_records(&hub, &id).pop().unwrap();
    assert_eq!(last["surfaceId"], "mac-1");
    assert_eq!(last["composing"], false);
    // Beside the name the client chose, the connection the hub saw.
    assert!(last["client"].as_str().is_some_and(|c| c.starts_with("test#")), "{last}");
    let mut last = last;
    last.as_object_mut().unwrap().remove("client");
    assert_eq!(last, json!({"surfaceId": "mac-1", "name": "Mac", "composing": false}));
    let view = mac.request(method::MUX_COMPOSERS, json!({"sessionId": id})).await.unwrap();
    assert!(view["composers"].as_array().unwrap().is_empty(), "{view}");
}

#[tokio::test]
async fn a_malformed_surface_is_refused_and_records_nothing() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "bad").await;
    for bad in [
        json!("Mac"),
        json!({"id": "x"}),
        json!({"id": "x", "name": "two\nlines"}),
        // A bidi override would let a name read as another one.
        json!({"id": "x", "name": "\u{202E}caM"}),
    ] {
        let e = c
            .request(
                method::MUX_COMPOSER_SET,
                json!({"sessionId": id, "surface": bad.clone(), "text": "t"}),
            )
            .await
            .unwrap_err();
        assert!(e.contains("surface"), "{e}");
        let e = c
            .request(method::SESSION_PROMPT, surface_prompt(&id, "hi", "p-bad", bad))
            .await
            .unwrap_err();
        assert!(e.contains("surface"), "{e}");
    }
    let long = "x".repeat(acpmux::hub::composers::MAX_SURFACE_FIELD_CHARS + 1);
    let e = c
        .request(
            method::MUX_COMPOSER_SET,
            json!({"sessionId": id, "surface": {"id": long, "name": "Mac"}, "text": "t"}),
        )
        .await
        .unwrap_err();
    assert!(e.contains("surface.id"), "{e}");
    let events = hub.events(&id, 0, 1000).unwrap();
    assert!(find(&events, "composer").is_empty());
    assert!(find(&events, "user_message").is_empty());
}
