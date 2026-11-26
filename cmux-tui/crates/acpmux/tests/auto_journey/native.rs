//! The agent's own session file goes with the chat's copy, both ways.
//!
//! The stand-in agent keeps a file per conversation where Claude Code keeps its own
//! (`FAKE_CLAUDE_STORE`), under a folder named for the chat's folder, and refuses to resume a
//! conversation whose file is not there. The laptop's chat folder and the machine's differ,
//! so the machine's agent resumes only when the import put the file where it looks.

use std::path::{Path, PathBuf};

use acpmux::hub::NewRequest;
use cmux_auto_session::AutoCloud;
use cmux_auto_session::chunks::name_of;
use cmux_auto_session::consts::RENEW_MS;
use cmux_auto_session::wire::{Fence, InboxPost, NativeFile, SnapshotPost};

use super::logs::{log_of, log_when, send, times};
use super::steps::{SECOND, answered, auto_chat, comes_home, cut_mid_tool, laptop_returns};
use super::world::{Agent, Daemon, VM, World, device, vm};

/// An agent that keeps its sessions as Claude Code does, on a profile of the `claude` family.
pub const CLAUDE: Agent = Agent { env: &[("FAKE_CLAUDE_STORE", "1")], family: Some("claude") };

const LAST: &str = "one more from the phone";

/// Where the agent of a chat in `folder` keeps the conversation `sid`.
pub fn session_file(folder: &Path, sid: &str) -> PathBuf {
    let home = PathBuf::from(std::env::var_os("HOME").expect("the test has a HOME"));
    let plain = |c: char| if c.is_ascii_alphanumeric() { c } else { '-' };
    let project: String = folder.to_string_lossy().chars().map(plain).collect();
    home.join(".claude").join("projects").join(project).join(format!("{sid}.jsonl"))
}

/// The agent conversation the chat runs on `daemon`.
pub fn conversation(daemon: &Daemon, id: &str) -> String {
    let meta = daemon.hub.resolve(id).expect("the chat is here").meta();
    meta.agent_session_id.expect("the chat has an agent conversation")
}

/// Whether the chat's agent on `daemon` ever failed to resume its conversation.
pub fn resume_failed(daemon: &Daemon, id: &str) -> bool {
    log_of(&daemon.hub, id).iter().any(|event| event.kind == "resume_failed")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_agents_own_session_file_goes_to_the_machine_and_comes_home() {
    let _hermetic = &crate::HERMETIC;
    let world = World::with_agent(CLAUDE).await;
    let laptop = world.start_laptop();
    let machine = &world.machine;

    // A chat on the laptop: its agent keeps the conversation in a file of its own.
    let id = auto_chat(&world, &laptop, None).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-hello", "hello").await;
    log_when(&laptop.hub, &id, "the laptop's turn", |log| answered(log, "hello")).await;
    let sid = conversation(&laptop, &id);
    let on_laptop = session_file(&world.work, &sid);
    assert!(on_laptop.is_file(), "the agent's file: {}", on_laptop.display());

    // The laptop goes away mid-tool. Its last snapshot names the file, as the chunks its
    // bytes cut into: nothing wrote to it between that snapshot and the cut.
    let cut = cut_mid_tool(&world, &laptop, &id).await;
    let at_cut = std::fs::read(&on_laptop).unwrap();
    let native = &cut.manifest.native;
    assert_eq!(native.len(), 1, "{native:?}");
    assert_eq!(native[0].label, "claude-project");
    assert!(native[0].path.ends_with(&format!("{sid}.jsonl")), "{native:?}");
    assert_eq!(native[0].chunks, [name_of(&at_cut)], "the file's bytes, as one chunk");

    // The machine imports the copy into a folder of its own. The file is where its agent
    // looks, with the laptop's bytes, and the agent resumed that conversation and wrote on.
    log_when(&machine.hub, &id, "the machine goes on", |log| answered(log, SECOND)).await;
    world.machine_at_rest(&id).await;
    let on_machine = session_file(&machine.folder(&id), &sid);
    assert_ne!(on_machine, on_laptop, "each machine's agent looks under its own folder's name");
    let there = std::fs::read(&on_machine).expect("the file where the machine's agent looks");
    assert!(there.starts_with(&at_cut), "the laptop's bytes come first");
    assert!(there.len() > at_cut.len(), "the machine's agent wrote on in the same file");
    assert_eq!(conversation(machine, &id), sid, "the machine resumed the laptop's conversation");
    assert!(!resume_failed(machine, &id), "no fresh conversation was started");

    // The laptop's agent wrote one more line after its last copy, which the chat never had.
    let mut late = at_cut.clone();
    late.extend_from_slice(b"{\"type\":\"written after the cut\"}\n");
    std::fs::write(&on_laptop, &late).unwrap();
    laptop_returns(&world, &laptop, &id, &cut).await;

    // The machine's last turn ends and the chat is handed back: its last snapshot names the
    // machine's file as it is then.
    let message = InboxPost { id: "phone-1".to_owned(), text: LAST.to_owned() };
    world.phone.post_inbox(&id, &message).await.unwrap();
    log_when(&machine.hub, &id, "the machine's last turn", |log| answered(log, LAST)).await;
    world
        .until_view(&id, "the chat is handed back", |view| {
            view.holder == device() && view.epoch == 3
        })
        .await;
    let at_handback = std::fs::read(&on_machine).unwrap();
    let home = world.manifest(&id).await.expect("the machine's last snapshot");
    assert_eq!(home.native.len(), 1, "{:?}", home.native);
    assert_eq!(home.native[0].chunks, [name_of(&at_handback)]);
    assert!(at_handback.starts_with(&there));

    // Home again: the laptop's file is the chat's, the line the chat never had is kept
    // beside it, and the laptop's agent resumes the same conversation.
    comes_home(&world, &laptop, &id, 3).await;
    assert_eq!(std::fs::read(&on_laptop).unwrap(), at_handback, "the Cloud copy's file");
    let kept = PathBuf::from(format!("{}.before-cloud-copy", on_laptop.display()));
    assert_eq!(std::fs::read(&kept).unwrap(), late, "what the laptop's agent had written");
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-home", "back home").await;
    log_when(&laptop.hub, &id, "a turn on the laptop", |log| answered(log, "back home")).await;
    assert_eq!(conversation(&laptop, &id), sid, "the laptop resumed the same conversation");
    assert!(!resume_failed(&laptop, &id), "no fresh conversation was started");
    let after = std::fs::read(&on_laptop).unwrap();
    assert!(after.starts_with(&at_handback) && after.len() > at_handback.len());
    assert_eq!(times(&log_of(&laptop.hub, &id), "hello"), 1);
}

/// What a copy that names a conversation not its own brings as that conversation's file.
const FORGED: &[u8] = b"{\"type\":\"a line this conversation never had\"}\n";

/// Where a file the Cloud copy replaced is kept (`native.rs` `REPLACED_SUFFIX`).
fn kept_beside(file: &Path) -> PathBuf {
    PathBuf::from(format!("{}.before-cloud-copy", file.display()))
}

/// A chat of the laptop goes to the machine as the laptop goes away, and comes home with a
/// copy written with the machine's credential: the machine's last copy, but naming the agent
/// conversation `named` and bringing [`FORGED`] as its file. Whoever holds a chat writes its
/// copy, so this is the most one chat's copy can say. Answers the chat's id and the
/// conversation it ran on the laptop.
async fn comes_home_with_a_copy_naming(
    world: &World,
    laptop: &Daemon,
    named: &str,
) -> (String, String) {
    let machine = &world.machine;
    let id = auto_chat(world, laptop, None).await;
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-hello", "hello").await;
    log_when(&laptop.hub, &id, "the laptop's turn", |log| answered(log, "hello")).await;
    let sid = conversation(laptop, &id);
    let cut = cut_mid_tool(world, laptop, &id).await;
    log_when(&machine.hub, &id, "the machine goes on", |log| answered(log, SECOND)).await;
    world.machine_at_rest(&id).await;

    let cloud = world.phone.as_machine(VM);
    let mut manifest = world.manifest(&id).await.expect("the machine's snapshot");
    let chunk = name_of(FORGED);
    cloud.put_chunk(&id, &chunk, FORGED, &Fence::new(vm(), 2)).await.expect("the file's chunk");
    manifest.harness_session_id = named.to_owned();
    let path = format!(".claude/projects/-any-folder/{named}.jsonl");
    let file = NativeFile { label: "claude-project".to_owned(), path, chunks: vec![chunk] };
    manifest.native = vec![file];
    let post = SnapshotPost { holder: vm(), epoch: 2, manifest };
    cloud.post_snapshot(&id, &post).await.expect("the copy that names another conversation");

    // The laptop comes back and stands by. The machine has nothing left to run, so its next
    // renewal hands the chat back, and that copy is the one the laptop imports.
    laptop_returns(world, laptop, &id, &cut).await;
    world.pass_while_laptop_sleeps(RENEW_MS);
    world
        .until_view(&id, "the chat is handed back", |view| {
            view.holder == device() && view.epoch == 3
        })
        .await;
    let newest = world.manifest(&id).await.expect("the copy the laptop imports");
    assert_eq!(newest.harness_session_id, named, "the copy the laptop imports names it");
    world.laptop_clock_catches_up();
    comes_home(world, laptop, &id, 3).await;
    (id, sid)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_copy_that_names_another_chats_conversation_does_not_change_that_chats_file() {
    let _hermetic = &crate::HERMETIC;
    let world = World::with_agent(CLAUDE).await;
    let laptop = world.start_laptop();

    // Another chat in the same folder, which never leaves the laptop: its agent keeps its
    // conversation in the same project folder as the Auto chat's.
    let request = NewRequest { cwd: Some(world.work.clone()), ..NewRequest::default() };
    let other = laptop.hub.new_session(request).await.expect("another chat");
    send(&laptop.hub, &other, "p-other", "the other chat's own").await;
    let own = |log: &[_]| answered(log, "the other chat's own");
    log_when(&laptop.hub, &other.id, "the other chat's turn", own).await;
    let others_sid = conversation(&laptop, &other.id);
    let others_file = session_file(&world.work, &others_sid);
    let before = std::fs::read(&others_file).expect("the other chat's agent file");

    let (id, sid) = comes_home_with_a_copy_naming(&world, &laptop, &others_sid).await;
    assert_ne!(sid, others_sid);

    // The chat is home with the copy's log, and the other chat's file is as it was: nothing
    // replaced it and nothing was set aside.
    assert_eq!(times(&log_of(&laptop.hub, &id), SECOND), 1, "the machine's turn came home");
    assert_eq!(std::fs::read(&others_file).unwrap(), before, "the other chat's file");
    assert!(!kept_beside(&others_file).exists(), "nothing of the other chat was replaced");

    // The chat goes on with the conversation it ran here, not the other chat's: its next turn
    // writes nothing into the other chat's file.
    assert_eq!(conversation(&laptop, &id), sid, "the chat keeps its own conversation");
    let session = laptop.hub.resolve(&id).expect("the chat");
    send(&laptop.hub, &session, "p-home", "back home").await;
    log_when(&laptop.hub, &id, "a turn on the laptop", |log| answered(log, "back home")).await;
    assert_eq!(conversation(&laptop, &id), sid);
    assert!(!resume_failed(&laptop, &id), "the chat resumed the conversation it has here");
    assert_eq!(std::fs::read(&others_file).unwrap(), before, "the other chat's file");

    // The other chat goes on in its own conversation, with its own memory.
    send(&laptop.hub, &other, "p-other-2", "still mine").await;
    let mine = |log: &[_]| answered(log, "still mine");
    log_when(&laptop.hub, &other.id, "the other chat's next turn", mine).await;
    assert_eq!(conversation(&laptop, &other.id), others_sid);
    let after = std::fs::read(&others_file).unwrap();
    assert!(after.starts_with(&before) && after.len() > before.len());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_copy_does_not_replace_the_file_of_a_conversation_the_chat_never_ran_here() {
    let _hermetic = &crate::HERMETIC;
    let world = World::with_agent(CLAUDE).await;
    let laptop = world.start_laptop();

    // A conversation in the chat's project folder that no chat of this daemon keeps, as one
    // the person ran with the agent by hand.
    let stray = "0e0e0e0e-1111-4222-8333-444444444444";
    let strays_file = session_file(&world.work, stray);
    let before = b"{\"type\":\"a conversation the person ran by hand\"}\n";
    std::fs::create_dir_all(strays_file.parent().unwrap()).unwrap();
    std::fs::write(&strays_file, before).unwrap();

    let (id, sid) = comes_home_with_a_copy_naming(&world, &laptop, stray).await;
    assert_ne!(sid, stray);

    // The import went through, and the file that was here is left as it is, as after a move
    // by hand: only a chat's own file is replaced by its copy.
    assert_eq!(times(&log_of(&laptop.hub, &id), SECOND), 1, "the machine's turn came home");
    assert_eq!(std::fs::read(&strays_file).unwrap(), before);
    assert!(!kept_beside(&strays_file).exists(), "nothing was replaced");
}
