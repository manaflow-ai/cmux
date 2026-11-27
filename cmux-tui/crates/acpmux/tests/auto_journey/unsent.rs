//! A prompt the person queued on the laptop that the Cloud never had.
//!
//! A takeover goes on from the store's copy of the chat, and the laptop's own log is replaced
//! by that copy when the chat comes home. A prompt queued on the laptop after its last copy
//! reached the store is in neither. So a laptop that learns another holder has the chat sends
//! such a prompt to the chat's Cloud inbox (`runtime/tasks.rs` `unsent`), and the holder runs
//! it once.

use acpmux::store::EventRecord;

use super::logs::{log_of, log_when, send, times};
use super::steps::{
    SECOND, a_period_passes, answered, auto_chat, comes_home, cut_mid_tool, laptop_returns,
};
use super::world::World;

const LATE: &str = "one more thing";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_queued_on_a_laptop_that_dropped_off_runs_once_in_the_cloud() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    // Kept in the Cloud: the machine never gives the chat home by itself, so only the machine
    // can run what the laptop sends.
    let id = auto_chat(&world, &laptop, Some(true)).await;

    // The laptop drops off mid-tool and the machine takes the chat. Nothing told the laptop
    // yet: its turn still runs, and the person sends one more prompt there. It waits behind
    // the turn, and its record cannot reach the Cloud.
    let cut = cut_mid_tool(&world, &laptop, &id).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-late", LATE).await;
    let waits = |log: &[EventRecord]| {
        log.iter().any(|event| event.kind == "queued" && event.msg["promptId"] == "p-late")
    };
    log_when(&laptop.hub, &id, "the late prompt waits on the laptop", waits).await;

    // The machine goes on from the Cloud's copy, which has nothing of that prompt.
    log_when(&machine.hub, &id, "the machine goes on", |log| answered(log, SECOND)).await;
    world.machine_at_rest(&id).await;
    assert_eq!(times(&log_of(&machine.hub, &id), LATE), 0, "the Cloud never had the prompt");
    assert_eq!(world.view(&id).inbox, 0);

    // The laptop comes back and learns the machine has the chat. It sends the prompt to the
    // chat's Cloud inbox, and the machine runs it.
    laptop_returns(&world, &laptop, &id, &cut).await;
    world.until_view(&id, "the prompt is in the Cloud inbox", |view| view.inbox > 0).await;
    a_period_passes(&world).await;
    let ran = |log: &[EventRecord]| answered(log, LATE);
    log_when(&machine.hub, &id, "the machine runs the late prompt", ran).await;
    world.machine_at_rest(&id).await;
    let log = log_of(&machine.hub, &id);
    assert_eq!(times(&log, LATE), 1, "the late prompt ran once");
    assert_eq!(times(&log, SECOND), 1, "what the Cloud had already was not sent again");

    // The person lets the chat come home. It has the prompt once, and nothing of it is left
    // to run: the laptop's own waiting copy went with the chat it replaced.
    let set = laptop.holder.set_auto(&id, true, Some(false)).await.expect("keep off");
    assert_eq!(set["keepInCloud"], false, "{set}");
    world.until_view(&id, "the store knows", |view| !view.keep_in_cloud).await;
    a_period_passes(&world).await;
    comes_home(&world, &laptop, &id, 3).await;
    let log = log_of(&laptop.hub, &id);
    assert_eq!(times(&log, LATE), 1, "the prompt came home with the chat, once");
    assert!(answered(&log, LATE));
    let home = laptop.hub.resolve(&id).expect("the chat is home");
    assert!(home.queue().is_empty(), "nothing waits: {:?}", home.queue().len());
    let view = world.view(&id);
    assert_eq!(view.inbox_acked, view.inbox, "nothing is left in the inbox: {view:?}");
}
