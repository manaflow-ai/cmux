//! A chat's place mode after it started, and a move the Cloud refuses, through the daemon's own
//! requests (`_acpmux/auto_session/set {mode}`, `_acpmux/auto_session/move`).
//!
//! - Cloud: the chat is moved to the machine now and stays there with the laptop back.
//! - This machine only: the chat comes home, Auto goes off, and the Cloud never takes it.
//! - A refused move answers with one plain sentence and leaves the chat as it was.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::{LEASE_MS, RENEW_MS};
use serde_json::{Value, json};

use super::logs::{log_of, log_when, send, times, until};
use super::steps::{a_period_passes, answered, auto_chat, comes_home};
use super::world::{Daemon, VM, World, device, vm};

const SET: &str = "_acpmux/auto_session/set";
const MOVE: &str = "_acpmux/auto_session/move";

/// Sets the chat's mode on `daemon`; the row's `autoSession` the request answers.
async fn set_mode(daemon: &Daemon, id: &str, mode: &str) -> Value {
    let set = daemon.request(SET, json!({"sessionId": id, "mode": mode})).await;
    set.unwrap_or_else(|error| panic!("mode {mode}: {error}"))["autoSession"].clone()
}

/// The chat is set to Cloud on the laptop and the machine has it, at rest, with the laptop
/// standing by.
async fn in_the_cloud(world: &World, laptop: &Daemon, id: &str) {
    let row = set_mode(laptop, id, "cloud").await;
    assert_eq!(row["mode"], "cloud", "{row}");
    assert_eq!(row["moving"], "cloud", "answered with the chat on its way: {row}");
    assert_eq!(row["keepInCloud"], true, "{row}");
    world
        .until_view(id, "the laptop gave the chat to the machine", |view| {
            view.holder == vm() && view.epoch == 2
        })
        .await;
    world.machine_at_rest(id).await;
    world
        .until_view(id, "the laptop is listed as standby", |view| view.standby.contains(&device()))
        .await;
    until("the laptop's row says where the chat is", || {
        let row = laptop.row(id);
        row["here"] == false && row.get("moving").is_none()
    })
    .await;
}

/// What a refusal must not say to a person.
fn plain(message: &str) -> bool {
    !["lease", "epoch", "give", "wish", "auto."].iter().any(|word| message.contains(word))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_set_to_cloud_moves_there_and_stays_when_the_laptop_is_back() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    let id = auto_chat(&world, &laptop, None).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-hello", "hello").await;
    log_when(&laptop.hub, &id, "the laptop's turn", |log| answered(log, "hello")).await;
    assert_eq!(laptop.row(&id)["mode"], "auto");

    // Cloud: the laptop gives the chat now, with no renewal in between, and nobody went away.
    in_the_cloud(&world, &laptop, &id).await;
    assert!(answered(&log_of(&machine.hub, &id), "hello"), "the chat's history came along");

    // The laptop is there the whole time, and the machine says at every renewal that it has
    // nothing left to run: the chat stays in the Cloud.
    for _ in 0..3 {
        a_period_passes(&world).await;
    }
    let kept = world.view(&id);
    assert_eq!((kept.holder.clone(), kept.epoch), (vm(), 2), "{kept:?}");
    assert!(kept.keep_in_cloud && kept.moving.is_none(), "{kept:?}");
    assert!(kept.standby.contains(&device()), "{kept:?}");
    let row = laptop.row(&id);
    assert_eq!(row["mode"], "cloud", "{row}");
    assert_eq!(row["here"], false, "{row}");
    assert_eq!(row.get("moving"), None, "{row}");

    // Auto again: the chat comes home at the machine's next renewal.
    let row = set_mode(&laptop, &id, "auto").await;
    assert_eq!(row["mode"], "auto", "{row}");
    world.until_view(&id, "the store knows", |view| !view.keep_in_cloud).await;
    a_period_passes(&world).await;
    comes_home(&world, &laptop, &id, 3).await;
    assert_eq!(laptop.row(&id)["mode"], "auto");
    assert_eq!(times(&log_of(&laptop.hub, &id), "hello"), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_set_to_local_comes_home_and_is_never_taken_by_the_cloud() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    let id = auto_chat(&world, &laptop, None).await;
    in_the_cloud(&world, &laptop, &id).await;

    // This machine only, while the machine has the chat: it is asked home, and reads local
    // from now on. Auto stays on until the chat is here.
    let row = set_mode(&laptop, &id, "local").await;
    assert_eq!(row["mode"], "local", "{row}");
    assert_eq!(row["moving"], "local", "{row}");
    assert_eq!(row["auto"], true, "{row}");
    assert_eq!(row["here"], false, "{row}");

    // The machine hands it over at its next renewal; the laptop brings it in, stores a copy
    // of its own, and then Auto goes off for it.
    world.pass(RENEW_MS);
    world.until_view(&id, "the chat left the machine", |view| view.holder != vm()).await;
    world.pass(RENEW_MS);
    until("Auto is off for the chat on the laptop", || {
        let row = laptop.row(&id);
        row["auto"] == false && row["mode"] == "local" && row["here"] == true
    })
    .await;
    assert_eq!(laptop.row(&id).get("moving"), None);
    until("the store closed the chat", || world.phone.peek(&id).is_none_or(|view| !view.auto))
        .await;

    // The laptop goes away for longer than two leases. The store gives the chat to nobody,
    // starts no machine for it, and the chat runs on the laptop as any chat does.
    let starts = world.phone.machine_starts().len();
    world.laptop_net.set_offline(true);
    world.pass_while_laptop_sleeps(LEASE_MS + 1_000);
    world.pass_while_laptop_sleeps(LEASE_MS + 1_000);
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-here", "still here").await;
    log_when(&laptop.hub, &id, "a turn on the laptop", |log| answered(log, "still here")).await;
    assert_eq!(world.phone.machine_starts().len(), starts, "no machine was started for it");
    let assigned = world.phone.as_machine(VM).assignments(0).await.unwrap_or_default();
    assert!(!assigned.iter().any(|assignment| assignment.session.id == id), "{assigned:?}");
    let closed = world.phone.peek(&id);
    assert!(closed.is_none_or(|view| view.holder != vm() && !view.auto), "the Cloud took it");
    assert_eq!(times(&log_of(&machine.hub, &id), "still here"), 0);
    world.laptop_net.set_offline(false);
    world.laptop_clock_catches_up();
    assert_eq!(laptop.row(&id)["mode"], "local");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_move_with_no_cloud_machine_says_so_and_changes_nothing() {
    let _hermetic = &crate::HERMETIC;
    let world = World::with_no_auto_machine().await;
    let laptop = world.start_laptop();
    let id = auto_chat(&world, &laptop, None).await;
    let row = laptop.row(&id);

    let ask = json!({"sessionId": id, "to": "cloud"});
    let refused = laptop.request(MOVE, ask).await.expect_err("there is no machine");
    assert_eq!(refused["data"]["reason"], "auto.no_machine", "{refused}");
    let message = refused["message"].as_str().unwrap_or_default();
    assert_eq!(
        message,
        "This chat was not moved to the Cloud: there is no Cloud machine to run it on. It \
         stays where it is."
    );
    assert!(plain(message), "{message}");

    // Nothing changed: in the store, on the row, and the chat runs here as before.
    let view = world.view(&id);
    assert_eq!((view.holder.clone(), view.epoch), (device(), 1), "{view:?}");
    assert!(!view.keep_in_cloud && view.moving.is_none(), "{view:?}");
    assert_eq!(laptop.row(&id), row);
    assert_eq!(row["mode"], "auto", "{row}");
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-here", "still here").await;
    log_when(&laptop.hub, &id, "a turn on the laptop", |log| answered(log, "still here")).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_move_home_to_a_laptop_that_does_not_stand_by_says_so_and_changes_nothing() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let id = auto_chat(&world, &laptop, None).await;
    in_the_cloud(&world, &laptop, &id).await;

    // The store has not heard from the laptop for longer than a lease: it no longer counts
    // as standing by, so there is no laptop to move the chat to.
    world.pass_while_laptop_sleeps(LEASE_MS + 1_000);
    let row = laptop.row(&id);
    let ask = json!({"sessionId": id, "to": "local"});
    let refused = laptop.request(MOVE, ask).await.expect_err("no laptop stands by");
    assert_eq!(refused["data"]["reason"], "auto.no_laptop", "{refused}");
    let message = refused["message"].as_str().unwrap_or_default();
    assert_eq!(
        message,
        "This chat was not moved to this computer: this computer is not ready to take it back \
         yet; try again in a moment. It stays where it is."
    );
    assert!(plain(message), "{message}");

    let view = world.view(&id);
    assert_eq!((view.holder.clone(), view.epoch), (vm(), 2), "{view:?}");
    assert!(view.keep_in_cloud && view.moving.is_none(), "{view:?}");
    assert_eq!(laptop.row(&id), row);
    assert_eq!(row["mode"], "cloud", "{row}");
    assert_eq!(row.get("moving"), None, "{row}");
}
