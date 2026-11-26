//! A chat the person moves while its holder is in the middle of taking the Cloud's inbox.
//!
//! The holder reads the inbox, writes each message into the chat's log, and only then tells the
//! store it has them (`runtime/inbox.rs`). A give whose copy was read between the two would hand
//! the chat over with the message in neither the copy nor the inbox. So the give's copy waits
//! for the message: the chat stays the laptop's until it is the chat's own.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::RENEW_MS;
use cmux_auto_session::wire::{InboxPost, MoveRequest};

use super::logs::{log_of, log_when, send, times, until};
use super::steps::{answered, auto_chat, renewals};
use super::world::{World, device, vm};

const FROM_PHONE: &str = "a question from the phone";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_the_laptop_is_taking_when_the_chat_is_moved_runs_once_on_the_machine() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;

    let id = auto_chat(&world, &laptop, None).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-hello", "hello").await;
    log_when(&laptop.hub, &id, "the laptop's turn", |log| answered(log, "hello")).await;

    // The phone sends a prompt. The laptop hears of it at its next renewal and reads the
    // inbox, and that read is slow to answer.
    world.laptop_net.hold_inbox_reads(true);
    let message = InboxPost { id: "phone-1".to_owned(), text: FROM_PHONE.to_owned() };
    world.phone.post_inbox(&id, &message).await.expect("the Cloud takes the prompt");
    world.pass(RENEW_MS);
    until("the laptop reads the inbox", || world.laptop_net.inbox_read_waits()).await;

    // The person moves the chat to the Cloud meanwhile, and the laptop starts to give it.
    world.phone.move_(&id, &MoveRequest::cloud()).await.expect("the move is taken");
    world.pass(RENEW_MS);
    until("the laptop is giving the chat", || laptop.row(&id)["moving"] == "cloud").await;

    // The give waits for the message the laptop is taking. Two more renewals later the chat is
    // still the laptop's, with the message still the Cloud's to hand out.
    for _ in 0..2 {
        let before = renewals(&world);
        world.pass(RENEW_MS);
        until("the laptop renewed", || renewals(&world) > before).await;
    }
    let view = world.view(&id);
    assert_eq!((view.holder.clone(), view.epoch), (device(), 1), "{view:?}");
    assert!(view.inbox_pending(), "the message was not taken yet: {view:?}");
    assert_eq!(laptop.row(&id)["moving"], "cloud", "the chat is still on its way");

    // The read answers. The laptop makes the message the chat's own, and then gives the chat.
    world.laptop_net.hold_inbox_reads(false);
    world
        .until_view(&id, "the laptop gave the chat to the machine", |view| {
            view.holder == vm() && view.epoch == 2 && view.moving.is_none()
        })
        .await;
    until("the laptop stands by", || laptop.record(&id).is_some_and(|record| !record.here)).await;

    // The machine runs the phone's prompt, once, and nothing of it ran on the laptop.
    log_when(&machine.hub, &id, "the machine runs the phone's prompt", |log| {
        answered(log, FROM_PHONE)
    })
    .await;
    world.machine_at_rest(&id).await;
    let log = log_of(&machine.hub, &id);
    assert_eq!(times(&log, FROM_PHONE), 1, "the prompt ran exactly once, on the machine");
    assert_eq!(times(&log, "hello"), 1, "the laptop's own turn came with the copy, once");
    let on_laptop = log_of(&laptop.hub, &id);
    assert!(!answered(&on_laptop, FROM_PHONE), "the laptop gave the chat away before it ran");
    let view = world.view(&id);
    assert_eq!(view.inbox_acked, view.inbox, "nothing is left in the inbox: {view:?}");
}
