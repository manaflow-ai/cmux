//! The machine's assignments: `create` and `deliver` handled whole, and the reader that waits
//! at the store and handles what arrives.

use std::sync::Arc;

use acpmux::auto_session::machine::attach;
use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::wire::{
    AssignmentKind, CreateRequest, FirstMessage, InboxPost, Repo, SessionView,
};

use super::agent::FakeAgent;
use super::repos::{read, repos};
use super::{CHAT, VM, empty_store, hub, laptop_copy, laptop_goes_away, log_when, prompts, store};
use super::{turns_ended, vm};

/// How often `text` was sent to the chat as a prompt.
fn times(texts: &[String], text: &str) -> usize {
    texts.iter().filter(|sent| *sent == text).count()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn create_starts_a_chat_from_a_repository_and_deliver_queues_each_message_once() {
    let repos = repos();
    let owner = empty_store().await;
    let request = CreateRequest {
        title: Some("Start in the Cloud".into()),
        harness: "fake".into(),
        repo: Repo { remote: repos.remote_url(), branch: "main".into() },
        first_message: FirstMessage { id: "m1".into(), text: "start here".into() },
    };
    let created = owner.create(&request).await.unwrap();
    let id = created.id.clone();

    let machine_hub = hub();
    let agent = FakeAgent::start(&owner, VM);
    let cloud = Arc::new(agent.cloud());
    let root = repos.path("machine");
    let (machine, holder) =
        attach(Arc::clone(&machine_hub), Arc::clone(&cloud), vm(), root.clone());
    // The holder loop was started as this machine.
    assert_eq!(holder.holder(), &vm());

    let assigned = cloud.assignments(0).await.unwrap();
    assert_eq!(assigned.len(), 1);
    assert_eq!(assigned[0].kind, AssignmentKind::Create);
    assert_eq!(assigned[0].session.id, id);
    machine.handle(&assigned[0]).await.unwrap();

    // A chat of the repository's branch under the Cloud's id, with the first message run.
    let chat = machine_hub.resolve(&id).expect("the chat is here");
    assert_eq!(chat.meta().cwd, root.join(&id));
    assert_eq!(read(&root.join(&id), "README.md"), "base\n");
    let log = log_when(&machine_hub, &id, "the first turn", |log| turns_ended(log) >= 1).await;
    assert_eq!(prompts(&log), ["start here"]);
    // The store was told: nothing is assigned and the inbox is read.
    assert!(cloud.assignments(0).await.unwrap().is_empty());
    let after_create: SessionView = owner.get(&id).await.unwrap();
    assert!(!after_create.inbox_pending(), "{after_create:?}");

    // A message sent while the chat is here is a `deliver`: it goes into the chat's queue.
    let message = InboxPost { id: "m2".into(), text: "and then this".into() };
    owner.post_inbox(&id, &message).await.unwrap();
    let delivered = cloud.assignments(0).await.unwrap();
    assert_eq!(delivered.len(), 1);
    assert_eq!(delivered[0].kind, AssignmentKind::Deliver);
    assert!(delivered[0].session.inbox_pending());
    machine.handle(&delivered[0]).await.unwrap();
    assert!(cloud.assignments(0).await.unwrap().is_empty());
    // An ack that was lost: the same messages are read again, from the first one on, and
    // none runs a second time.
    let _ = machine.drain(&delivered[0].session).await;
    let _ = machine.drain(&assigned[0].session).await;
    let log = log_when(&machine_hub, &id, "the second turn", |log| turns_ended(log) >= 2).await;
    let texts = prompts(&log);
    assert_eq!((times(&texts, "start here"), times(&texts, "and then this")), (1, 1), "{texts:?}");
    assert!(!owner.get(&id).await.unwrap().inbox_pending());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_reader_handles_a_takeover_when_the_store_assigns_it() {
    let owner = store().await;
    let tar = {
        let mut tar = tar::Builder::new(Vec::new());
        let mut header = tar::Header::new_gnu();
        header.set_size(6);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, "notes.txt", &b"hello\n"[..]).unwrap();
        tar.into_inner().unwrap()
    };
    // The copy has a snapshot of a plain folder and no events yet.
    laptop_copy(&owner, 0, &tar).await;
    let machine_hub = hub();
    let agent = FakeAgent::start(&owner, VM);
    let root = tempfile::tempdir().unwrap();
    let (machine, _holder) =
        attach(Arc::clone(&machine_hub), Arc::new(agent.cloud()), vm(), root.path().to_owned());
    let reader = tokio::spawn(machine.run());
    // Nothing is assigned: the reader waits at the store and no chat appears.
    assert!(machine_hub.resolve(CHAT).is_err());
    laptop_goes_away(&owner);
    // The takeover arrives through the held wait; the reader imports the chat and acks.
    let acked = async {
        while !owner.as_machine(VM).assignments(0).await.unwrap().is_empty() {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(60), acked).await.expect("acked in time");
    let chat = machine_hub.resolve(CHAT).expect("the chat is here");
    assert_eq!(chat.meta().cwd, root.path().join(CHAT));
    assert_eq!(read(&root.path().join(CHAT), "notes.txt"), "hello\n");
    assert!(agent.calls().contains(&"assignment_ack"));
    reader.abort();
}
