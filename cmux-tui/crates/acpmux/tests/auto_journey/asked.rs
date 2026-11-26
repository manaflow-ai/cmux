//! A chat the person moves from the laptop's own request (`_acpmux/auto_session/move`), in the
//! middle of a turn each time: to the Cloud machine, and home again.
//!
//! [`super::moved`] moves the chat as the phone does, through the store, and the holder hears
//! of it at its next renewal. Here the laptop is asked: it gives the chat it holds at once,
//! and asks the store to bring home a chat the machine holds.

use acpmux::store::EventRecord;
use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::RENEW_MS;
use cmux_auto_session::wire::InboxPost;
use serde_json::{Value, json};

use super::logs::{log_of, log_when, prompts, send, times, until};
use super::moved::{STAYED, build, completed, did_not_go_on, moves, shell_runs, went_on};
use super::native::{CLAUDE, conversation, resume_failed, session_file};
use super::steps::{TAKEOVER, answered, auto_chat, comes_home, lines};
use super::world::{Daemon, World, device, vm};

/// Asks `daemon` to move the chat `to`; the row's `autoSession` the request answers.
async fn ask_move(daemon: &Daemon, id: &str, to: &str) -> Value {
    let asked = daemon.request("_acpmux/auto_session/move", json!({"sessionId": id, "to": to}));
    asked.await.unwrap_or_else(|error| panic!("move to {to}: {error}"))["autoSession"].clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_the_laptop_is_asked_to_move_mid_turn_goes_on_once_there_and_once_back_home() {
    let _hermetic = &crate::HERMETIC;
    let world = World::with_agent(CLAUDE).await;
    let laptop = world.start_laptop();
    let machine = &world.machine;

    // A chat on the laptop, one turn done, and a second one in the middle of a tool call.
    let id = auto_chat(&world, &laptop, None).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-hello", "hello").await;
    log_when(&laptop.hub, &id, "the laptop's turn", |log| answered(log, "hello")).await;
    let sid = conversation(&laptop, &id);
    let first = world.dir.path().join("first.log");
    send(&laptop.hub, &session, "p-first", &build(&first)).await;
    let laptop_shell = shell_runs(&first).await;

    // The laptop is asked to move it to the Cloud. The answer is the row with the chat on its
    // way, and the laptop gives the chat with no renewal in between: no time passes here.
    let row = ask_move(&laptop, &id, "cloud").await;
    assert_eq!(row["moving"], "cloud", "{row}");
    assert_eq!(row["mode"], "cloud", "a chat moved to the Cloud is kept there: {row}");
    world
        .until_view(&id, "the laptop gave the chat to the machine", |view| {
            view.holder == vm() && view.epoch == 2 && view.moving.is_none()
        })
        .await;
    until("the laptop's shell is gone", || !crate::daemon_env::alive(laptop_shell)).await;
    until("the laptop stands by", || laptop.record(&id).is_some_and(|record| !record.here)).await;
    let given = log_of(&laptop.hub, &id);
    assert!(answered(&given, &build(&first)), "the laptop settled the turn it stopped");
    assert_eq!(moves(&given), 0, "the laptop gave the turn away: {:?}", prompts(&given));

    // The machine goes on with the turn once, told that the chat moved, in the laptop's own
    // agent conversation.
    let log = log_when(&machine.hub, &id, "the machine goes on", |log| went_on(log, 1)).await;
    assert_eq!(moves(&log), 1, "{:?}", prompts(&log));
    assert_eq!(times(&log, &build(&first)), 1, "the prompt itself ran once, on the laptop");
    assert!(!prompts(&log).iter().any(|text| text.starts_with(TAKEOVER)), "nobody went away");
    let on_machine = session_file(&machine.folder(&id), &sid);
    assert!(on_machine.is_file(), "the agent's file: {}", on_machine.display());
    assert_eq!(conversation(machine, &id), sid, "the machine resumed the laptop's conversation");
    assert!(!resume_failed(machine, &id), "no fresh conversation was started");
    assert_eq!(lines(&first), ["start"], "the tool ran once");
    world.machine_at_rest(&id).await;
    world
        .until_view(&id, "the laptop is listed as standby", |view| view.standby.contains(&device()))
        .await;
    until("the laptop's row says the chat is in the Cloud", || {
        let row = laptop.row(&id);
        row["here"] == false && row["mode"] == "cloud" && row.get("moving").is_none()
    })
    .await;

    // The laptop gave the chat: with the machine done, nothing ran on the laptop since.
    did_not_go_on(&given, &log_of(&laptop.hub, &id));

    // The phone sends a prompt, and the machine is in the middle of its tool call when the
    // laptop is asked to bring the chat home. The answer says where it is going.
    let second = world.dir.path().join("second.log");
    let message = InboxPost { id: "phone-1".to_owned(), text: build(&second) };
    world.phone.post_inbox(&id, &message).await.unwrap();
    let machine_shell = shell_runs(&second).await;
    let row = ask_move(&laptop, &id, "local").await;
    assert_eq!(row["moving"], "local", "{row}");
    assert_eq!(row["mode"], "auto", "a chat moved home is no longer kept in the Cloud: {row}");
    assert_eq!(row["here"], false, "{row}");

    // The machine gives it at its next renewal, and the laptop brings the copy in.
    world.pass(RENEW_MS);
    comes_home(&world, &laptop, &id, 3).await;
    until("the machine's shell is gone", || !crate::daemon_env::alive(machine_shell)).await;
    let machine_gave = log_of(&machine.hub, &id);
    assert!(answered(&machine_gave, &build(&second)), "the machine settled the turn it stopped");

    // Home: the turn goes on once more, on the laptop, in the same conversation, and every
    // prompt of the chat ran exactly once.
    let log = log_when(&laptop.hub, &id, "the laptop goes on", |log| went_on(log, 2)).await;
    assert_eq!(moves(&log), 2, "{:?}", prompts(&log));
    for prompt in ["hello".to_owned(), build(&first), build(&second)] {
        assert_eq!(times(&log, &prompt), 1, "{prompt}: {:?}", prompts(&log));
    }
    let odd = |text: &String| text.starts_with(TAKEOVER) || text.starts_with(STAYED);
    assert!(!prompts(&log).iter().any(odd), "{:?}", prompts(&log));
    assert_eq!(lines(&first), ["start"], "the first tool ran once");
    assert_eq!(lines(&second), ["start"], "the second tool ran once");
    assert_eq!(conversation(&laptop, &id), sid, "the laptop resumed the same conversation");
    assert!(!resume_failed(&laptop, &id), "no fresh conversation was started");
    // The machine gave the chat: with the laptop done, nothing ran on the machine since.
    let machine_log = log_of(&machine.hub, &id);
    assert_eq!(moves(&machine_log), 1, "the machine ran nothing after it gave");
    did_not_go_on(&machine_gave, &machine_log);
    let view = world.view(&id);
    assert_eq!((view.holder.clone(), view.epoch), (device(), 3), "{view:?}");
    assert!(view.moving.is_none() && !view.keep_in_cloud, "{view:?}");
    until("the row says the chat is home", || {
        let row = laptop.row(&id);
        row["here"] == true && row["mode"] == "auto" && row.get("moving").is_none()
    })
    .await;
}

/// The Cloud cannot take the chat the laptop is asked to move, and says so only once the turn
/// was stopped for the move: the store's size limit is under the chat's last copy, the one a
/// give sends after it stopped the turn. (The store this test runs on has no way to lose its
/// Cloud machine or to refuse the hand-over itself at a set moment; its limit is one.) The chat
/// stays, and the turn goes on exactly once on the laptop, told that the chat did not move.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_move_the_cloud_refuses_after_the_turn_stopped_goes_on_once_on_the_laptop() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    let id = auto_chat(&world, &laptop, None).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    let first = world.dir.path().join("first.log");
    send(&laptop.hub, &session, "p-first", &build(&first)).await;
    shell_runs(&first).await;

    // The store takes the move, and the laptop stops the turn for it at once. From here on the
    // store takes no copy of the chat: the one the give waits for is refused as too large.
    let row = ask_move(&laptop, &id, "cloud").await;
    assert_eq!(row["moving"], "cloud", "{row}");
    world.phone.set_snapshot_max(1);

    // The turn goes on here, told that the chat stayed, and runs to its end.
    let stays = |log: &[EventRecord]| completed(log, STAYED, 1);
    let log = log_when(&laptop.hub, &id, "the turn goes on here", stays).await;
    let stayed =
        |log: &[EventRecord]| prompts(log).iter().filter(|text| text.starts_with(STAYED)).count();
    assert_eq!(stayed(&log), 1, "{:?}", prompts(&log));
    assert_eq!(moves(&log), 0, "the chat did not move: {:?}", prompts(&log));
    assert_eq!(times(&log, &build(&first)), 1, "the prompt itself ran once");
    assert!(answered(&log, &build(&first)), "the laptop settled the turn it stopped");
    assert_eq!(lines(&first), ["start"], "the tool ran once");

    // The person is told once, in plain words, why the chat was not moved.
    let told: Vec<&EventRecord> =
        log.iter().filter(|event| event.kind == "auto_not_moved").collect();
    assert_eq!(told.len(), 1, "told once: {:?}", prompts(&log));
    assert_eq!(told[0].msg["to"], "cloud", "{:?}", told[0].msg);
    assert_eq!(
        told[0].msg["text"],
        "This chat was not moved to the Cloud: it is too large to copy. It goes on where it is."
    );

    // The chat is the laptop's as before, and the machine never had it.
    let view = world.view(&id);
    assert_eq!((view.holder.clone(), view.epoch), (device(), 1), "{view:?}");
    assert!(log_of(&machine.hub, &id).is_empty(), "the machine has nothing of the chat");
    let row = laptop.row(&id);
    assert_eq!(row["here"], true, "{row}");
    assert_eq!(row["state"], "local", "{row}");

    // The chat runs on, and the stopped turn is not continued a second time.
    send(&laptop.hub, &session, "p-after", "after").await;
    let log = log_when(&laptop.hub, &id, "the next turn", |log| answered(log, "after")).await;
    assert_eq!(stayed(&log), 1, "{:?}", prompts(&log));
    assert_eq!(moves(&log), 0, "{:?}", prompts(&log));
    assert_eq!(lines(&first), ["start"], "the tool ran once");
}
