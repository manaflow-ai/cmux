//! `_acpmux/chat_move` (`cmux chat move --on local|cloud|auto`, the agent's `move_chat`), asked
//! of the laptop by the person: the chat moves, and its setting follows.
//!
//! - Cloud: the laptop gives the chat to the machine now, and it is kept there.
//! - Cloud again: nothing to do, and the answer says so.
//! - Local, while the machine has the chat: it comes home, and Auto goes off once it is here.
//!   Asked again on its way, it is set to local already.
//! - Cloud, for a chat kept in the Cloud that still runs on the laptop: it is moved, not
//!   answered as there already.

use cmux_auto_session::consts::RENEW_MS;
use serde_json::{Value, json};

use super::logs::{log_of, log_when, send, until};
use super::steps::{answered, auto_chat};
use super::world::{Daemon, World, device, vm};

/// Asks `daemon` to move the chat; the request's whole answer.
async fn chat_move(daemon: &Daemon, id: &str, on: &str) -> Value {
    let asked = daemon.request("_acpmux/chat_move", json!({"sessionId": id, "on": on}));
    asked.await.unwrap_or_else(|error| panic!("chat move --on {on}: {error}"))
}

/// `status`, `from` and `to` of a chat move's answer.
fn outcome(answer: &Value) -> (&str, &str, &str) {
    let word = |key: &str| answer[key].as_str().unwrap_or_default();
    (word("status"), word("from"), word("to"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_move_takes_the_chat_to_the_cloud_now_and_home_when_asked() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    let id = auto_chat(&world, &laptop, None).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-hello", "hello").await;
    log_when(&laptop.hub, &id, "the laptop's turn", |log| answered(log, "hello")).await;

    // Cloud: the laptop gives the chat now, with no renewal in between, and nobody went away.
    let moved = chat_move(&laptop, &id, "cloud").await;
    assert_eq!(outcome(&moved), ("moving", "auto", "cloud"), "{moved}");
    let row = &moved["autoSession"];
    assert_eq!(row["moving"], "cloud", "answered with the chat on its way: {row}");
    assert_eq!(row["keepInCloud"], true, "{row}");
    world
        .until_view(&id, "the laptop gave the chat to the machine", |view| {
            view.holder == vm() && view.epoch == 2
        })
        .await;
    world.machine_at_rest(&id).await;
    world
        .until_view(&id, "the laptop is listed as standby", |view| view.standby.contains(&device()))
        .await;
    until("the laptop's row says where the chat is", || {
        let row = laptop.row(&id);
        row["here"] == false && row.get("moving").is_none()
    })
    .await;
    assert!(answered(&log_of(&machine.hub, &id), "hello"), "the chat's history came along");

    // Asked again, the chat is where it was asked to be.
    let again = chat_move(&laptop, &id, "cloud").await;
    assert_eq!(outcome(&again), ("already", "cloud", "cloud"), "{again}");
    assert_eq!(world.view(&id).epoch, 2, "nothing moved");

    // Local, while the machine has the chat: it is asked home, and Auto stays on until the
    // chat is here.
    let home = chat_move(&laptop, &id, "local").await;
    assert_eq!(outcome(&home), ("moving", "cloud", "local"), "{home}");
    let row = &home["autoSession"];
    assert_eq!(row["moving"], "local", "{row}");
    assert_eq!(row["here"], false, "{row}");
    let on_its_way = chat_move(&laptop, &id, "local").await;
    assert_eq!(outcome(&on_its_way), ("already", "local", "local"), "{on_its_way}");
    world.pass(RENEW_MS);
    world.until_view(&id, "the chat left the machine", |view| view.holder != vm()).await;
    world.pass(RENEW_MS);
    until("Auto is off for the chat on the laptop", || {
        let row = laptop.row(&id);
        row["auto"] == false && row["mode"] == "local" && row["here"] == true
    })
    .await;
    assert_eq!(laptop.row(&id).get("moving"), None);
    let once_home = chat_move(&laptop, &id, "local").await;
    assert_eq!(outcome(&once_home), ("already", "local", "local"), "{once_home}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_kept_in_the_cloud_that_still_runs_here_is_moved_when_asked() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    // Kept in the Cloud from its start, and on the laptop until the laptop goes away.
    let id = auto_chat(&world, &laptop, Some(true)).await;
    until("the laptop's row says the chat is here", || {
        let row = laptop.row(&id);
        row["mode"] == "cloud" && row["here"] == true && row.get("moving").is_none()
    })
    .await;

    let moved = chat_move(&laptop, &id, "cloud").await;
    assert_eq!(outcome(&moved), ("moving", "cloud", "cloud"), "{moved}");
    world
        .until_view(&id, "the laptop gave the chat to the machine", |view| {
            view.holder == vm() && view.epoch == 2
        })
        .await;
    world.machine_at_rest(&id).await;
    until("the laptop's row says where the chat is", || {
        let row = laptop.row(&id);
        row["here"] == false && row.get("moving").is_none()
    })
    .await;
    let there = chat_move(&laptop, &id, "cloud").await;
    assert_eq!(outcome(&there), ("already", "cloud", "cloud"), "{there}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn probe_machine_side_chat_move() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    let id = auto_chat(&world, &laptop, None).await;
    let moved = chat_move(&laptop, &id, "cloud").await;
    eprintln!("PROBE laptop->cloud: {moved}");
    world.until_view(&id, "on vm", |view| view.holder == vm() && view.epoch == 2).await;
    world.machine_at_rest(&id).await;
    for on in ["cloud", "auto", "local"] {
        let a = machine.request("_acpmux/chat_move", json!({"sessionId": id, "on": on})).await;
        eprintln!("PROBE machine --on {on}: {a:?}");
        eprintln!("PROBE machine row: {}  laptop row: {}", machine.row(&id), laptop.row(&id));
    }
}
