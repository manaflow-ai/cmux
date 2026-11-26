//! The whole journey of one chat: it runs on the laptop, the laptop goes away mid-tool, the
//! Cloud machine goes on with it, the phone sends to it, the laptop comes back and stands by,
//! and at the machine's turn end the chat comes home.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::{LEASE_MS, RENEW_MS};
use cmux_auto_session::wire::{Cwd, Delivery, ErrorCode, EventsAppend, InboxPost, SeqRecord};
use serde_json::json;

use super::logs::{log_of, log_when, prompts, send, through, times};
use super::steps::{
    SECOND, TAKEOVER, answered, auto_chat, comes_home, cut_mid_tool, laptop_returns, lines,
};
use super::world::{VM, World, device, git, read, vm, write};

const PHONE: &str = "from the phone";
const LAST: &str = "one more from the phone";

fn post(id: &str, text: &str) -> InboxPost {
    InboxPost { id: id.to_owned(), text: text.to_owned() }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_goes_on_in_the_cloud_when_the_laptop_leaves_mid_tool_and_comes_home() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;

    // A chat with Auto on runs a turn on the laptop: its events and a whole snapshot are in
    // the store, and the laptop holds it at epoch 1.
    let id = auto_chat(&world, &laptop, None).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-hello", "hello").await;
    log_when(&laptop.hub, &id, "the laptop's turn", |log| answered(log, "hello")).await;
    let deadline = std::time::Instant::now() + super::logs::DEADLINE;
    let (page, first) = loop {
        let page = world.phone.events(&id, 0, None).await.unwrap();
        let ended = page.events.iter().find(|event| event.record["kind"] == "turn_result");
        let manifest = world.manifest(&id).await.expect("a snapshot");
        if ended.is_some_and(|ended| manifest.last_seq >= ended.seq) {
            break (page, manifest);
        }
        assert!(std::time::Instant::now() < deadline, "the turn never reached the Cloud");
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    };
    let seqs: Vec<u64> = page.events.iter().map(|event| event.seq).collect();
    assert_eq!(seqs, (1..=page.last_seq).collect::<Vec<_>>(), "every record, in order");
    let Cwd::Git { bundle, patch, .. } = &first.cwd else {
        panic!("a checkout goes in the git form: {:?}", first.cwd);
    };
    for chunk in bundle.iter().chain(patch) {
        world.phone.chunk(&id, chunk).await.expect("every chunk the snapshot names");
    }
    let held = world.view(&id);
    assert_eq!((held.holder.clone(), held.epoch), (device(), 1), "{held:?}");

    // Mid-turn, with a tool's shell running, the laptop stops answering. At the lease's end
    // the store gives the chat to the machine: a takeover at epoch 2.
    let cut = cut_mid_tool(&world, &laptop, &id).await;

    // The machine imports it and goes on: the cut turn once, as a continuation that names
    // the tool call, then the prompt that waited behind it.
    log_when(&machine.hub, &id, "the machine goes on", |log| answered(log, SECOND)).await;
    world.machine_at_rest(&id).await;
    let log = log_of(&machine.hub, &id);
    let last = cut.manifest.last_seq;
    assert_eq!(through(&log, last), through(&cut.log, last), "the laptop's history");
    assert_eq!(cut.manifest.queue.len(), 1);
    assert_eq!(cut.manifest.queue[0].text, SECOND, "the laptop's queue");
    let texts = prompts(&log);
    let at = |wanted: &dyn Fn(&str) -> bool| -> Vec<usize> {
        (0..texts.len()).filter(|i| wanted(&texts[*i])).collect()
    };
    let continued = at(&|text| text.starts_with(TAKEOVER));
    let waited = at(&|text| text == SECOND);
    assert_eq!((continued.len(), waited.len()), (1, 1), "{texts:#?}");
    assert!(continued[0] < waited[0], "the continuation runs first: {texts:#?}");
    let told = &texts[continued[0]];
    assert!(told.contains("auto-run:") && told.contains("Run the build"), "{told}");
    let unknown = log.iter().filter(|event| event.msg["detail"] == "outcome_unknown").count();
    assert_eq!(unknown, 1, "the cut turn is settled once");
    assert_eq!(times(&log, "hello"), 1);
    // Its folder is the laptop's at the last snapshot, not what the laptop wrote after it.
    let folder = machine.folder(&id);
    assert_eq!(folder, machine.root.join(&id));
    assert_eq!(git(&folder, &["rev-parse", "--abbrev-ref", "HEAD"]), "main");
    assert_eq!(git(&folder, &["rev-parse", "HEAD"]), cut.head);
    assert_eq!(read(&folder, "local.txt"), "a local commit\n");
    assert_eq!(read(&folder, "a.txt"), "one\nuncommitted\n");
    assert_eq!(git(&folder, &["status", "--porcelain"]), "M a.txt");

    // The phone sends to the chat: the machine takes the message once and answers it.
    let posted = world.phone.post_inbox(&id, &post("phone-1", PHONE)).await.unwrap();
    assert_eq!(posted.state, Delivery::Delivered);
    world.pass_while_laptop_sleeps(RENEW_MS);
    log_when(&machine.hub, &id, "the phone's message is answered", |log| answered(log, PHONE))
        .await;
    world.machine_at_rest(&id).await;
    // The same message again, and more renewals, give the chat nothing twice.
    world.phone.post_inbox(&id, &post("phone-1", PHONE)).await.unwrap();
    for _ in 0..2 {
        world.pass_while_laptop_sleeps(RENEW_MS);
        let now = world.phone.now();
        world
            .until_view(&id, "the machine renewed", |view| view.lease_expires_at == now + LEASE_MS)
            .await;
        world.machine_at_rest(&id).await;
    }
    assert_eq!(times(&log_of(&machine.hub, &id), PHONE), 1);
    assert_eq!(times(&log_of(&laptop.hub, &id), PHONE), 0, "the laptop is away");

    // The machine's agent leaves work in its folder: a commit and an uncommitted line.
    write(&folder, "machine.txt", "the machine's commit\n");
    git(&folder, &["add", "machine.txt"]);
    git(&folder, &["commit", "--quiet", "-m", "machine"]);
    write(&folder, "a.txt", "one\nuncommitted\nthe machine's line\n");
    let machine_head = git(&folder, &["rev-parse", "HEAD"]);

    // The laptop comes back: its tree is killed, a patch is kept, and it stands by.
    laptop_returns(&world, &laptop, &id, &cut).await;

    // At the machine's next turn end with nothing queued, the chat is handed back.
    world.phone.post_inbox(&id, &post("phone-2", LAST)).await.unwrap();
    log_when(&machine.hub, &id, "the machine's last turn", |log| answered(log, LAST)).await;
    world
        .until_view(&id, "the chat is handed back", |view| {
            view.holder == device() && view.epoch == 3
        })
        .await;
    let home = world.manifest(&id).await.expect("the machine's last snapshot");
    assert!(matches!(home.cwd, Cwd::Git { .. }), "the machine's commits go as commits");
    assert_eq!(home.last_seq, world.view(&id).last_seq, "the snapshot covers the last event");
    comes_home(&world, &laptop, &id, 3).await;

    // The laptop has the whole chat once, in its own folder, with the machine's changes.
    let machine_log = log_of(&machine.hub, &id);
    let laptop_log = log_of(&laptop.hub, &id);
    assert_eq!(through(&laptop_log, home.last_seq), through(&machine_log, home.last_seq));
    for text in ["hello", SECOND, PHONE, LAST] {
        assert_eq!(times(&laptop_log, text), 1, "{text:?} in {:#?}", prompts(&laptop_log));
    }
    let continuations =
        prompts(&laptop_log).iter().filter(|text| text.starts_with(TAKEOVER)).count();
    assert_eq!(continuations, 1);
    assert_eq!(laptop.folder(&id), world.work);
    assert_eq!(git(&world.work, &["rev-parse", "HEAD"]), machine_head);
    assert_eq!(read(&world.work, "machine.txt"), "the machine's commit\n");
    assert_eq!(read(&world.work, "local.txt"), "a local commit\n");
    assert_eq!(read(&world.work, "a.txt"), "one\nuncommitted\nthe machine's line\n");
    // What the laptop wrote after the cut is still kept aside, and its shell never went on.
    assert!(laptop.record(&id).is_some_and(|record| record.leftover.is_some()));
    assert_eq!(lines(&cut.out), ["start"]);

    // The next prompt runs on the laptop, and its copy goes under epoch 3.
    let before = world.view(&id).snapshot;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-home", "back home").await;
    log_when(&laptop.hub, &id, "a turn on the laptop", |log| answered(log, "back home")).await;
    assert_eq!(times(&log_of(&machine.hub, &id), "back home"), 0);
    world.until_view(&id, "a copy under the new epoch", |view| view.snapshot > before).await;
    assert_eq!(world.view(&id).holder, device());

    // A write from the machine at the epoch it held is refused.
    let stored = world.view(&id).last_seq;
    let late = SeqRecord { seq: stored + 1, record: json!({"late": true}) };
    let stale = EventsAppend { holder: vm(), epoch: 2, events: vec![late] };
    let refused = world.phone.as_machine(VM).append_events(&id, &stale).await.unwrap_err();
    assert_eq!(refused.code(), Some(ErrorCode::StaleEpoch), "{refused}");
    assert_eq!(world.view(&id).last_seq, stored);
}
