//! The machine's assignments: the reader waits at the store and tells the holder loop of what
//! arrives, and the loop does the work: `create`, `takeover` and `deliver`, each acked once.

use std::sync::Arc;
use std::time::Duration;

use acpmux::auto_session::machine::{Machine, attach};
use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{
    Assignment, AssignmentKind, CreateRequest, FirstMessage, InboxPost, Repo, SessionView,
};

use super::agent::FakeAgent;
use super::repos::{read, repos};
use super::{CHAT, VM, empty_store, hub, laptop_copy, laptop_goes_away, log_when, prompts, store};
use super::{turns_ended, vm};

/// How often `text` was sent to the chat as a prompt.
fn times(texts: &[String], text: &str) -> usize {
    texts.iter().filter(|sent| *sent == text).count()
}

/// Waits until `ready` holds, for at most a minute.
async fn until(what: &str, mut ready: impl FnMut() -> bool) {
    let waited = async {
        while !ready() {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    };
    let in_time = tokio::time::timeout(Duration::from_secs(60), waited).await;
    assert!(in_time.is_ok(), "timed out waiting for: {what}");
}

/// Waits until the store has nothing assigned to the machine: the loop acked what it was told.
async fn acked(owner: &FakeAutoCloud) {
    let machine = owner.as_machine(VM);
    let none_left = async {
        while !machine.assignments(0).await.unwrap().is_empty() {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(60), none_left).await.expect("acked in time");
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
    // The reader tells the loop, which makes the chat, takes its inbox and acks.
    let reader = tokio::spawn(machine.run());
    acked(&owner).await;

    // A chat of the repository's branch under the Cloud's id, with the first message run.
    let chat = machine_hub.resolve(&id).expect("the chat is here");
    assert_eq!(chat.meta().cwd, root.join(&id));
    assert_eq!(read(&root.join(&id), "README.md"), "base\n");
    let log = log_when(&machine_hub, &id, "the first turn", |log| turns_ended(log) >= 1).await;
    assert_eq!(prompts(&log), ["start here"]);
    let after_create: SessionView = owner.get(&id).await.unwrap();
    assert!(!after_create.inbox_pending(), "{after_create:?}");

    // A message sent while the chat is here goes into the chat's queue and is acked.
    let message = InboxPost { id: "m2".into(), text: "and then this".into() };
    owner.post_inbox(&id, &message).await.unwrap();
    log_when(&machine_hub, &id, "the second turn", |log| turns_ended(log) >= 2).await;
    acked(&owner).await;
    assert!(!owner.get(&id).await.unwrap().inbox_pending());

    // An ack that was lost: the store assigns the same again, and nothing runs a second time.
    let acks =
        |agent: &FakeAgent| agent.calls().iter().filter(|call| **call == "assignment_ack").count();
    let before = acks(&agent);
    let now = owner.get(&id).await.unwrap();
    holder.assigned(&Assignment { kind: AssignmentKind::Create, session: now.clone() });
    holder.assigned(&Assignment { kind: AssignmentKind::Deliver, session: now });
    // The repeated deliver's ack follows its look at the inbox.
    until("both repeats are acked", || acks(&agent) >= before + 2).await;
    let log = machine_hub.events(&id, 0, 100_000).unwrap();
    let texts = prompts(&log);
    assert_eq!((times(&texts, "start here"), times(&texts, "and then this")), (1, 1), "{texts:?}");
    reader.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_loop_takes_a_chat_over_when_the_reader_tells_it() {
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
    // The takeover arrives through the held wait; the loop imports the chat and acks.
    acked(&owner).await;
    let chat = machine_hub.resolve(CHAT).expect("the chat is here");
    assert_eq!(chat.meta().cwd, root.path().join(CHAT));
    assert_eq!(read(&root.path().join(CHAT), "notes.txt"), "hello\n");
    assert!(agent.calls().contains(&"assignment_ack"));
    reader.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_reader_does_none_of_the_work_itself() {
    let owner = store().await;
    laptop_copy(&owner, 0, b"never read").await;
    let machine_hub = hub();
    let agent = FakeAgent::start(&owner, VM);
    let root = tempfile::tempdir().unwrap();
    let (tell, mut told) = tokio::sync::mpsc::unbounded_channel();
    let machine = Machine::telling(Arc::new(agent.cloud()), move |assignment| {
        let _ = tell.send((assignment.kind, assignment.session.id.clone()));
    });
    let reader = tokio::spawn(machine.run());
    laptop_goes_away(&owner);
    // The takeover arrives through the held wait and is told, as the holder loop would be.
    let first = tokio::time::timeout(Duration::from_secs(60), told.recv()).await;
    assert_eq!(first.expect("told in time"), Some((AssignmentKind::Takeover, CHAT.to_owned())));
    // The reader did none of its work: no chat is here and the assignment waits for its ack.
    assert!(machine_hub.resolve(CHAT).is_err());
    assert!(!root.path().join(CHAT).exists());
    assert_eq!(owner.as_machine(VM).assignments(0).await.unwrap().len(), 1);
    assert!(!agent.calls().contains(&"assignment_ack"));
    reader.abort();
}
