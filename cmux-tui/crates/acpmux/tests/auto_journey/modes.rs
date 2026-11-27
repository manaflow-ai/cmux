//! A chat's place mode after it started, and a move the Cloud refuses, through the daemon's own
//! requests (`_acpmux/auto_session/set {mode}`, `_acpmux/auto_session/move`).
//!
//! - Cloud: the chat is moved to the machine now and stays there with the laptop back.
//! - This machine only: the chat comes home, Auto goes off, and the Cloud never takes it.
//! - A refused move answers with one plain sentence and leaves the chat as it was. So does
//!   Cloud asked for a chat with Auto off: Auto is off for it again.
//! - This machine only, with a prompt sent while the chat comes home: the prompt runs here
//!   before Auto goes off.
//! - This machine only, then Cloud picked on another device before the chat came home: the
//!   laptop's row follows the store.

use acpmux::hub::NewRequest;
use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::{LEASE_MS, RENEW_MS};
use cmux_auto_session::wire::{InboxPost, MoveRequest};
use serde_json::{Value, json};

use super::logs::{log_of, log_when, send, times, until};
use super::steps::{a_period_passes, answered, auto_chat, comes_home, renewals};
use super::world::{Daemon, VM, World, device, vm};

const SET: &str = "_acpmux/auto_session/set";
const MOVE: &str = "_acpmux/auto_session/move";

/// What a move to the Cloud answers when the person has no Cloud machine.
const NO_MACHINE: &str = "This chat was not moved to the Cloud: there is no Cloud machine to run \
                          it on. It stays where it is.";

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
    assert_eq!(message, NO_MACHINE);
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
    // The laptop's row says where the chat stands as the store last answered it, which can be
    // from before the machine acked its assignment. One more renewal and it says what the
    // store says now: a refused move brings the store's newest view with it, and the row must
    // not differ below for that alone.
    a_period_passes(&world).await;
    until("the laptop's row says the Cloud has the chat", || laptop.row(&id)["state"] == "cloud")
        .await;

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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cloud_asked_for_a_chat_with_auto_off_that_cannot_move_leaves_auto_off() {
    let _hermetic = &crate::HERMETIC;
    let world = World::with_no_auto_machine().await;
    let laptop = world.start_laptop();

    // A chat with Auto off: it runs here and the store has nothing of it.
    let request = NewRequest { cwd: Some(world.work.clone()), ..NewRequest::default() };
    let session = laptop.hub.new_session(request).await.expect("a chat");
    let id = session.id.clone();
    let off = laptop.row(&id);
    assert_eq!(off["auto"], false, "{off}");
    assert_eq!(off["mode"], "local", "{off}");
    assert!(world.phone.peek(&id).is_none(), "the store has no such chat");

    // Cloud is asked for it. Registering needs no machine, moving does: the request is refused
    // in the move's words.
    let ask = json!({"sessionId": id, "mode": "cloud"});
    let refused = laptop.request(SET, ask).await.expect_err("there is no machine");
    assert_eq!(refused["data"]["reason"], "auto.no_machine", "{refused}");
    let message = refused["message"].as_str().unwrap_or_default();
    assert_eq!(message, NO_MACHINE);
    assert!(plain(message), "{message}");

    // The chat is as it was: Auto off on its row and in its record, closed in the store with
    // no copy kept, and it runs here.
    assert_eq!(laptop.row(&id), off);
    assert!(laptop.record(&id).is_none_or(|record| !record.auto), "{:?}", laptop.record(&id));
    let stored = world.phone.peek(&id);
    assert!(stored.as_ref().is_none_or(|view| !view.auto), "{stored:?}");
    assert!(world.manifest(&id).await.is_none(), "the Cloud kept a copy of the chat");
    send(&laptop.hub, &session, "p-here", "still here").await;
    log_when(&laptop.hub, &id, "a turn on the laptop", |log| answered(log, "still here")).await;
    assert_eq!(laptop.row(&id), off);

    // A chat that has Auto on keeps its mode when the same request is refused.
    let auto = auto_chat(&world, &laptop, None).await;
    let row = laptop.row(&auto);
    assert_eq!(row["mode"], "auto", "{row}");
    let ask = json!({"sessionId": auto, "mode": "cloud"});
    let refused = laptop.request(SET, ask).await.expect_err("there is no machine");
    assert_eq!(refused["data"]["reason"], "auto.no_machine", "{refused}");
    assert_eq!(laptop.row(&auto), row);
    let view = world.view(&auto);
    assert!(view.auto && !view.keep_in_cloud && view.moving.is_none(), "{view:?}");
    assert_eq!((view.holder.clone(), view.epoch), (device(), 1), "{view:?}");
}

/// The prompt the phone sends while the chat is on its way home.
const FROM_PHONE: &str = "from the phone";

/// Whether Auto is off for the chat on the laptop. Closing a chat in the store drops what its
/// inbox still holds, so by then the laptop must have made the phone's message `message` the
/// chat's own (the `auto_inbox` record of its log): this panics when it has not.
fn off_with_the_inbox_taken(laptop: &Daemon, id: &str, message: &str) -> bool {
    if laptop.row(id)["auto"] != false {
        return false;
    }
    let log = log_of(&laptop.hub, id);
    let taken =
        log.iter().any(|event| event.kind == "auto_inbox" && event.msg["promptId"] == message);
    assert!(taken, "Auto went off for the chat before the laptop took the Cloud's prompt");
    true
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_sent_while_a_chat_set_to_local_comes_home_runs_before_auto_goes_off() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    let id = auto_chat(&world, &laptop, None).await;
    in_the_cloud(&world, &laptop, &id).await;
    let row = set_mode(&laptop, &id, "local").await;
    assert_eq!(row["mode"], "local", "{row}");
    assert_eq!(row["moving"], "local", "{row}");

    // The machine hands the chat over at its next renewal. The laptop's clock stands still, so
    // it does not renew and has not heard: the chat is on its way home.
    world.pass_while_laptop_sleeps(RENEW_MS);
    world
        .until_view(&id, "the machine gave the chat to the laptop", |view| {
            view.holder == device() && view.epoch == 3
        })
        .await;
    assert_eq!(laptop.row(&id)["here"], false, "the laptop has not heard yet");

    // The phone sends a prompt now. It waits in the Cloud's inbox for the laptop.
    let message = InboxPost { id: "phone-1".to_owned(), text: FROM_PHONE.to_owned() };
    world.phone.post_inbox(&id, &message).await.expect("the Cloud takes the prompt");
    assert!(world.view(&id).inbox_pending(), "the prompt waits for the laptop");
    assert_eq!(times(&log_of(&machine.hub, &id), FROM_PHONE), 0);

    // The laptop renews, brings the chat in and takes the prompt, which runs here. Auto is
    // not off before the prompt is the laptop's.
    world.laptop_clock_catches_up();
    until("the phone's prompt ran on the laptop", || {
        off_with_the_inbox_taken(&laptop, &id, "phone-1");
        answered(&log_of(&laptop.hub, &id), FROM_PHONE)
    })
    .await;

    // With the inbox taken and a copy of its own stored, Auto goes off: at the latest when the
    // laptop's next renewal says so.
    world.pass(RENEW_MS);
    until("Auto is off for the chat on the laptop", || {
        off_with_the_inbox_taken(&laptop, &id, "phone-1")
    })
    .await;
    let row = laptop.row(&id);
    assert_eq!(row["mode"], "local", "{row}");
    assert_eq!(row["here"], true, "{row}");
    until("the store closed the chat", || world.phone.peek(&id).is_none_or(|view| !view.auto))
        .await;
    let log = log_of(&laptop.hub, &id);
    assert_eq!(times(&log, FROM_PHONE), 1, "the prompt ran exactly once, on the laptop");
    assert!(answered(&log, FROM_PHONE), "its turn ended");
    assert_eq!(times(&log_of(&machine.hub, &id), FROM_PHONE), 0, "the machine never ran it");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_set_to_local_then_to_cloud_on_the_phone_reads_cloud_and_keeps_auto() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let id = auto_chat(&world, &laptop, None).await;
    in_the_cloud(&world, &laptop, &id).await;

    // This machine only, while the machine has the chat: it reads local, on its way home.
    let row = set_mode(&laptop, &id, "local").await;
    assert_eq!(row["mode"], "local", "{row}");
    assert_eq!(row["moving"], "local", "{row}");

    // Before the machine gives it, the person picks Cloud for the chat on the phone: the move
    // home is off and the chat is kept in the Cloud.
    let kept = world.phone.move_(&id, &MoveRequest::cloud()).await.expect("the chat stays");
    assert_eq!((kept.holder.clone(), kept.epoch), (vm(), 2), "{kept:?}");
    assert!(kept.keep_in_cloud && kept.moving.is_none(), "{kept:?}");

    // The laptop hears it at its next renewal: the row follows the store, not what this
    // laptop was asked last.
    a_period_passes(&world).await;
    until("the laptop's row reads Cloud", || {
        let row = laptop.row(&id);
        row["mode"] == "cloud" && row.get("moving").is_none()
    })
    .await;
    for _ in 0..2 {
        a_period_passes(&world).await;
    }
    let row = laptop.row(&id);
    assert_eq!(row["auto"], true, "{row}");
    assert_eq!(row["mode"], "cloud", "{row}");
    assert_eq!(row["here"], false, "{row}");
    assert_eq!(row["keepInCloud"], true, "{row}");
    let view = world.view(&id);
    assert_eq!((view.holder.clone(), view.epoch), (vm(), 2), "{view:?}");
    assert!(view.auto && view.keep_in_cloud, "{view:?}");

    // Auto again from the laptop: the chat comes home by the handback and runs a turn here.
    let row = set_mode(&laptop, &id, "auto").await;
    assert_eq!(row["mode"], "auto", "{row}");
    world.until_view(&id, "the store knows", |view| !view.keep_in_cloud).await;
    a_period_passes(&world).await;
    comes_home(&world, &laptop, &id, 3).await;
    let stored = world.view(&id).snapshot;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-home", "home again").await;
    log_when(&laptop.hub, &id, "a turn on the laptop", |log| answered(log, "home again")).await;

    // The laptop stores a copy of its own, which is when a chat still set to this machine
    // only has Auto switched off. This one is an Auto chat: it stays one.
    world
        .until_view(&id, "the laptop stored a copy of its own", |view| view.snapshot > stored)
        .await;
    let renewed = renewals(&world);
    world.pass(RENEW_MS);
    until("the laptop renewed", || renewals(&world) > renewed).await;
    let row = laptop.row(&id);
    assert_eq!(row["auto"], true, "{row}");
    assert_eq!(row["mode"], "auto", "{row}");
    let view = world.view(&id);
    assert!(view.auto, "the chat is still an Auto chat in the store: {view:?}");
    assert_eq!((view.holder.clone(), view.epoch), (device(), 3), "{view:?}");
}
