//! A chat the person moves by hand: to the Cloud machine in the middle of a turn, and home
//! again in the middle of a turn.
//!
//! Nothing goes away here: the holder gives the chat. It stops the turn that runs, stores the
//! copy that covers it, and asks the store to take the chat; the new holder goes on with the
//! turn once, told that the chat moved. The agent's own session file goes with each copy.

use std::path::{Path, PathBuf};

use acpmux::store::EventRecord;
use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::RENEW_MS;
use cmux_auto_session::wire::{InboxPost, MoveRequest, MoveTo};

use super::logs::{log_of, log_when, prompts, send, times, until};
use super::native::{CLAUDE, conversation, resume_failed, session_file};
use super::steps::{TAKEOVER, answered, auto_chat, comes_home, lines};
use super::world::{World, device, vm};

/// How the continuation of a turn a move cut off starts (`hub/restart_cut.rs`).
const MOVED: &str = "This chat moved to another machine";

/// How it starts when the move did not happen.
pub const STAYED: &str = "This chat did not move";

/// How many continuations of a moved turn the log holds as prompts.
pub fn moves(log: &[EventRecord]) -> usize {
    prompts(log).iter().filter(|text| text.starts_with(MOVED)).count()
}

/// Whether the turn of the log's `nth` prompt that starts with `opening` completed: it ran to
/// its end, and was not stopped and did not fail.
pub fn completed(log: &[EventRecord], opening: &str, nth: usize) -> bool {
    let asked = |event: &&EventRecord| {
        event.kind == "user_message"
            && event.msg["text"].as_str().is_some_and(|text| text.starts_with(opening))
    };
    let Some(prompt) = log.iter().filter(asked).nth(nth - 1) else { return false };
    // Turns of one chat run one after the other: the next result is this prompt's.
    let result = log.iter().find(|event| event.kind == "turn_result" && event.seq > prompt.seq);
    result.is_some_and(|result| result.msg["status"] == "completed")
}

/// Whether the log's `nth` moved-turn continuation ran to its end.
pub fn went_on(log: &[EventRecord], nth: usize) -> bool {
    completed(log, MOVED, nth)
}

/// How many turns the log says started.
pub fn turns(log: &[EventRecord]) -> usize {
    log.iter().filter(|event| event.kind == "turn_started").count()
}

/// Asserts that a machine that gave the chat away did not go on with it. `given` is its log
/// right after the give and `later` its log some time on: no turn started there since, no
/// prompt ran there since, and the turn it stopped was never told that the chat stayed.
pub fn did_not_go_on(given: &[EventRecord], later: &[EventRecord]) {
    assert_eq!(turns(later), turns(given), "a turn started where the chat was given away");
    assert_eq!(prompts(later), prompts(given), "a prompt ran where the chat was given away");
    let stayed = prompts(later).iter().any(|text| text.starts_with(STAYED));
    assert!(!stayed, "the chat was given away: {:?}", prompts(later));
}

/// The prompt whose turn runs a tool's shell until it is stopped: the shell appends "start"
/// to `out` once, so a turn that ran twice shows there.
pub fn build(out: &Path) -> String {
    format!("auto-run: {}", out.display())
}

/// Waits until the tool's shell of a `build` turn runs; its pid.
pub async fn shell_runs(out: &Path) -> u32 {
    let pid_file = PathBuf::from(format!("{}.pid", out.display()));
    until("the tool's shell runs", || pid_file.exists() && lines(out) == ["start"]).await;
    std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_moved_by_hand_mid_turn_goes_on_once_on_the_machine_and_once_back_home() {
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
    let on_laptop = session_file(&world.work, &sid);
    let first = world.dir.path().join("first.log");
    send(&laptop.hub, &session, "p-first", &build(&first)).await;
    let laptop_shell = shell_runs(&first).await;

    // The person moves it to the Cloud. The store keeps the wish for the holder, and the chat
    // is the laptop's until the laptop gives it.
    let wished = world.phone.move_(&id, &MoveRequest::cloud()).await.expect("the move is taken");
    assert_eq!(wished.moving.as_ref().map(|wish| wish.to), Some(MoveTo::Cloud), "{wished:?}");
    assert_eq!((wished.holder.clone(), wished.epoch), (device(), 1), "{wished:?}");
    assert!(wished.keep_in_cloud, "a chat moved to the Cloud is kept there");

    // The laptop hears the wish at its next renewal: it stops the turn, copies the chat and
    // gives it. The machine takes it over at epoch 2, with nobody having gone away.
    world.pass(RENEW_MS);
    world
        .until_view(&id, "the laptop gave the chat to the machine", |view| {
            view.holder == vm() && view.epoch == 2 && view.moving.is_none()
        })
        .await;
    until("the laptop stands by", || laptop.record(&id).is_some_and(|record| !record.here)).await;
    until("the laptop's shell is gone", || !crate::daemon_env::alive(laptop_shell)).await;
    let given = log_of(&laptop.hub, &id);
    assert!(answered(&given, &build(&first)), "the laptop settled the turn it stopped");
    assert_eq!(moves(&given), 0, "the laptop gave the turn away: {:?}", prompts(&given));

    // The machine goes on with the turn once, told that the chat moved, in the laptop's own
    // agent conversation: the session file is where the machine's agent looks.
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
    assert!(world.view(&id).keep_in_cloud);

    // The laptop gave the chat: with the machine done, nothing ran on the laptop since.
    did_not_go_on(&given, &log_of(&laptop.hub, &id));

    // The phone sends a prompt, and the machine is in the middle of its tool call when the
    // person moves the chat home.
    let second = world.dir.path().join("second.log");
    let message = InboxPost { id: "phone-1".to_owned(), text: build(&second) };
    world.phone.post_inbox(&id, &message).await.unwrap();
    let machine_shell = shell_runs(&second).await;
    let wished = world.phone.move_(&id, &MoveRequest::local()).await.expect("the move is taken");
    assert_eq!(wished.moving.as_ref().map(|wish| wish.to), Some(MoveTo::Local), "{wished:?}");
    assert!(!wished.keep_in_cloud, "a chat moved home is no longer kept in the Cloud");

    // The machine gives it at its next renewal, and the laptop brings the copy in.
    world.pass(RENEW_MS);
    comes_home(&world, &laptop, &id, 3).await;
    until("the machine's shell is gone", || !crate::daemon_env::alive(machine_shell)).await;
    let at_give = std::fs::read(&on_machine).unwrap();
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
    let home = std::fs::read(&on_laptop).unwrap();
    assert!(home.starts_with(&at_give), "the machine's file came home");
    assert!(home.len() > at_give.len(), "the laptop's agent wrote on in it");
    // The machine gave the chat: with the laptop done, nothing ran on the machine since.
    let machine_log = log_of(&machine.hub, &id);
    assert_eq!(moves(&machine_log), 1, "the machine ran nothing after it gave");
    did_not_go_on(&machine_gave, &machine_log);
    let view = world.view(&id);
    assert_eq!((view.holder.clone(), view.epoch), (device(), 3), "{view:?}");
    assert!(view.moving.is_none() && !view.keep_in_cloud, "{view:?}");
}
