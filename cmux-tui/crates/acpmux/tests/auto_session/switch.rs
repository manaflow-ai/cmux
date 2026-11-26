//! `_acpmux/auto_session/set` is answered from the store's answer: Auto on from the
//! registration's (`runtime/register.rs`), Keep in Cloud from its own call
//! (`runtime/switch.rs`). What the store refused or never heard is not shown as done.

use super::access::{SET, new_chat};
use super::*;

fn puts(rig: &Rig) -> usize {
    rig.cloud.calls().iter().filter(|call| **call == "put").count()
}

#[tokio::test]
async fn keep_in_cloud_is_answered_once_the_store_has_it_and_fails_when_it_does_not() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = new_chat(&mut rig).await;

    // Auto on and kept in the Cloud, in one request: the registration says both.
    let on = json!({"sessionId": id, "auto": true, "keepInCloud": true});
    let set = rig.call(SET, on).await;
    assert_eq!(set["autoSession"]["keepInCloud"], true, "{set}");
    assert!(rig.view(&id).keep_in_cloud, "the store has it when the request is answered");

    // The store cannot be reached: the request fails, and the row keeps what the store has.
    let off = json!({"sessionId": id, "auto": true, "keepInCloud": false});
    rig.cloud.set_offline(true);
    let failed = rig.reply(SET, off.clone()).await.unwrap_err();
    assert_eq!(failed["data"]["reason"], "auto.unreachable", "{failed}");
    assert_eq!(rig.row(&id)["keepInCloud"], true, "nothing was shown as done");
    assert!(rig.record(&id).unwrap().keep_in_cloud);
    assert!(rig.view(&id).keep_in_cloud);

    // Reachable again: the same request is answered with what the store took.
    rig.cloud.set_offline(false);
    let set = rig.call(SET, off).await;
    assert_eq!(set["autoSession"]["keepInCloud"], false, "{set}");
    assert!(!rig.view(&id).keep_in_cloud, "the store has it when the request is answered");
    assert_eq!(rig.row(&id)["keepInCloud"], false);

    // Asking for what the store already has asks nobody.
    let keeps = |rig: &Rig| rig.cloud.calls().iter().filter(|call| **call == "keep").count();
    let before = keeps(&rig);
    rig.call(SET, json!({"sessionId": id, "auto": true, "keepInCloud": false})).await;
    assert_eq!(keeps(&rig), before);
}

#[tokio::test]
async fn auto_on_that_the_store_refuses_is_answered_the_refusal_and_stays_off() {
    let _hermetic = &HERMETIC;
    // The store takes no device of this name: it refuses every registration from it.
    let mut rig = Rig::as_device("not a device").await;
    let id = new_chat(&mut rig).await;

    let refused = rig.reply(SET, json!({"sessionId": id, "auto": true})).await.unwrap_err();
    let said = refused["message"].as_str().unwrap_or_default();
    assert!(said.contains("400") && said.contains("device"), "the store's own words: {refused}");
    assert_eq!(refused["data"]["retryable"], false, "{refused}");

    // Auto is off for the chat again, and the daemon does not go on asking.
    assert_eq!(rig.row(&id)["auto"], false);
    assert_eq!(rig.record(&id), None);
    assert!(rig.store.peek(&id).is_none());
    // One registration, and the close that follows a registration that may have got there.
    until("the store was told Auto is off", || puts(&rig) == 2).await;
    rig.pass(RENEW_MS);
    rig.pass(RENEW_MS);
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(puts(&rig), 2, "no registration is sent again");
}

#[tokio::test]
async fn auto_on_with_no_answer_from_the_store_answers_the_row_as_it_is() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = new_chat(&mut rig).await;

    // No network: the request is not held past the registration it waits for.
    rig.cloud.set_offline(true);
    let set = rig.call(SET, json!({"sessionId": id, "auto": true})).await;
    let row = &set["autoSession"];
    assert_eq!(
        (&row["auto"], &row["here"], &row["state"]),
        (&json!(true), &json!(true), &json!("local"))
    );
    assert!(rig.store.peek(&id).is_none(), "the store has not heard of the chat");
    assert_eq!(rig.row(&id)["auto"], true);

    // The daemon goes on asking: with the network back, the next period registers the chat.
    rig.cloud.set_offline(false);
    rig.pass(RENEW_MS);
    let (store, me) = (rig.store.clone(), rig.me.clone());
    until("the chat is registered and copied", || {
        store.peek(&id).is_some_and(|view| view.holder == me && view.snapshot >= 1)
    })
    .await;
}
