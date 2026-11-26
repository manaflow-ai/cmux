//! The journey's steps that more than one test takes, each asserted where it is taken.

use std::path::{Path, PathBuf};

use acpmux::hub::NewRequest;
use acpmux::store::EventRecord;
use cmux_auto_session::consts::{LEASE_MS, RENEW_MS};
use cmux_auto_session::wire::Manifest;

use super::logs::{log_of, log_when, send, until};
use super::world::{Daemon, VM, World, device, git, vm, write};

/// The prompt that waits in the queue behind the turn the laptop is cut off in.
pub const SECOND: &str = "second question";

/// How a takeover's continuation starts (`hub/restart_cut.rs`).
pub const TAKEOVER: &str = "The machine this chat ran on went away";

/// Whether a turn ended after the prompt `text` in the log: the prompt was answered.
pub fn answered(log: &[EventRecord], text: &str) -> bool {
    let sent = log
        .iter()
        .position(|event| event.kind == "user_message" && event.msg["text"].as_str() == Some(text));
    sent.is_some_and(|at| log[at..].iter().any(|event| event.kind == "turn_result"))
}

/// A chat in the laptop's checkout with Auto on, registered and copied once.
pub async fn auto_chat(world: &World, laptop: &Daemon, keep: Option<bool>) -> String {
    let request = NewRequest { cwd: Some(world.work.clone()), ..NewRequest::default() };
    let session = laptop.hub.new_session(request).await.expect("a chat");
    let id = session.id.clone();
    let set = laptop.holder.set_auto(&id, true, keep).await.expect("Auto on");
    assert_eq!(set["auto"], true, "{set}");
    world
        .until_view(&id, "the chat is registered and copied", |view| {
            view.holder == device() && view.snapshot >= 1
        })
        .await;
    id
}

/// The laptop as it was when it went away.
pub struct Cut {
    /// The file the tool's shell writes: a line at its start, another at its end.
    pub out: PathBuf,
    /// The tool's shell.
    pub pid: u32,
    /// The last snapshot the laptop stored.
    pub manifest: Manifest,
    /// The laptop's log through that snapshot.
    pub log: Vec<EventRecord>,
    /// The checkout's commit at that snapshot.
    pub head: String,
}

/// The laptop goes away mid-turn: a tool's shell runs, a second prompt waits behind the turn,
/// the folder has a local commit and uncommitted work, and all of that is in the Cloud's copy.
/// Then the laptop stops answering, changes one more line, and its lease runs out: the store
/// gives the chat to the machine at epoch 2.
pub async fn cut_mid_tool(world: &World, laptop: &Daemon, id: &str) -> Cut {
    let session = laptop.hub.resolve(id).expect("the chat");
    write(&world.work, "local.txt", "a local commit\n");
    git(&world.work, &["add", "local.txt"]);
    git(&world.work, &["commit", "--quiet", "-m", "local"]);
    write(&world.work, "a.txt", "one\nuncommitted\n");
    let head = git(&world.work, &["rev-parse", "HEAD"]);

    let out = world.dir.path().join("build.log");
    send(&laptop.hub, &session, "p-build", &format!("auto-run: {}", out.display())).await;
    let pid_file = PathBuf::from(format!("{}.pid", out.display()));
    until("the tool's shell runs", || pid_file.exists() && lines(&out) == ["start"]).await;
    let pid: u32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let tool = |log: &[EventRecord]| log.iter().any(|event| event.kind == "tool_call");
    log_when(&laptop.hub, id, "the tool call", tool).await;
    send(&laptop.hub, &session, "p-second", SECOND).await;
    // The record that put it in the queue. A snapshot names the queue as the chat has it when
    // the snapshot is made, which may be a record ahead of the log it was stored with, and the
    // machine builds its queue from the log alone.
    let waits = |event: &EventRecord| event.kind == "queued" && event.msg["promptId"] == "p-second";
    let log = log_when(&laptop.hub, id, "the second prompt waits", |log| log.iter().any(waits));
    let queued_at = log.await.iter().find(|event| waits(event)).map(|event| event.seq).unwrap();

    // The copy the machine goes on from: the open turn with its tool call, and the queue with
    // the record that made it.
    let deadline = std::time::Instant::now() + super::logs::DEADLINE;
    let manifest = loop {
        let view = world.view(id);
        let manifest = world.manifest(id).await.expect("the chat has a snapshot");
        let open = manifest.open_turn.as_ref().is_some_and(|turn| turn.tool.is_some());
        let covers = manifest.last_seq == view.last_seq && manifest.last_seq >= queued_at;
        if view.needs_run && manifest.queue.len() == 1 && open && covers {
            break manifest;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the laptop's copy mid-tool never reached the Cloud: {view:?} {manifest:?}"
        );
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    };
    let mut log = log_of(&laptop.hub, id);
    log.retain(|event| event.seq <= manifest.last_seq);

    // The laptop stops answering, and writes something the Cloud's copy does not have.
    world.laptop_net.set_offline(true);
    write(&world.work, "a.txt", "one\nchanged after the copy\n");
    world.pass_while_laptop_sleeps(LEASE_MS + 1_000);
    let taken = world.view(id);
    assert_eq!(taken.holder, vm(), "the lapsed lease gave the chat to the machine");
    assert_eq!(taken.epoch, 2);
    assert_eq!(world.phone.machine_starts(), vec![VM.to_owned()]);
    assert!(crate::daemon_env::alive(pid), "nothing told the laptop yet");
    Cut { out, pid, manifest, log, head }
}

/// The laptop comes back: its network returns, its clock jumps and the app says it woke. Its
/// process tree, the tool's shell included, is killed; the shell wrote nothing after the cut;
/// what the folder held beyond the last copy is kept as a patch; and the laptop stands by.
pub async fn laptop_returns(world: &World, laptop: &Daemon, id: &str, cut: &Cut) {
    world.laptop_net.set_offline(false);
    world.laptop_clock_catches_up();
    laptop.holder.wake();
    until("the laptop stands by with its changes kept", || {
        laptop.record(id).is_some_and(|record| !record.here && record.leftover.is_some())
    })
    .await;
    until("the tool's shell is gone", || !crate::daemon_env::alive(cut.pid)).await;
    assert_eq!(lines(&cut.out), ["start"], "the laptop's shell wrote nothing after the cut");
    let leftover = laptop.record(id).and_then(|record| record.leftover).expect("a kept patch");
    assert_eq!(leftover.files, ["a.txt"]);
    let patch = std::fs::read_to_string(&leftover.path).expect("the patch file");
    assert!(patch.contains("changed after the copy"), "{patch}");
    world
        .until_view(id, "the laptop is listed as standby", |view| view.standby.contains(&device()))
        .await;
    let row = laptop.row(id);
    assert_eq!(row["here"], false, "{row}");
    assert_eq!(world.view(id).holder, vm(), "a laptop standing by takes nothing by itself");
}

/// The lines of the file at `path`; none while it does not exist.
pub fn lines(path: &Path) -> Vec<String> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    text.lines().map(str::to_owned).collect()
}

/// How many renewals reached the store so far, from any machine.
pub fn renewals(world: &World) -> usize {
    world.phone.calls().iter().filter(|call| **call == "lease").count()
}

/// A renewal period passes everywhere, and both daemons' renewals reach the store.
pub async fn a_period_passes(world: &World) {
    let before = renewals(world);
    world.pass(RENEW_MS);
    until("both daemons renewed", || renewals(world) >= before + 2).await;
}

/// The chat as the laptop holds it after a handback at `epoch`: the store names the laptop,
/// the machine let go of what it ran, and the laptop brought the Cloud's copy in.
pub async fn comes_home(world: &World, laptop: &Daemon, id: &str, epoch: u64) {
    world
        .until_view(id, "the store gives the chat home", |view| {
            view.holder == device() && view.epoch == epoch
        })
        .await;
    let machine = &world.machine;
    until("the machine let go of the chat", || {
        machine.record(id).is_some_and(|record| !record.here)
    })
    .await;
    // The laptop hears it at its next renewal as a standby, and imports before it holds.
    world.pass(RENEW_MS);
    until("the laptop holds the chat", || {
        laptop.record(id).is_some_and(|record| record.here && record.epoch == epoch)
    })
    .await;
    let view = world.view(id);
    assert_eq!((view.holder, view.epoch), (device(), epoch));
    until("the row says the chat runs here", || {
        let row = laptop.row(id);
        row["here"] == true && row["state"] == "local"
    })
    .await;
}
