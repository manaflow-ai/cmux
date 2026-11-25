//! The importer: a chat's Cloud copy becomes a chat of this daemon, with its folder.

use std::path::Path;
use std::sync::Arc;

use acpmux::auto_session::import::Importer;
use acpmux::auto_session::{ImportError, ImportReason, SessionImporter};
use acpmux::hub::Hub;
use cmux_auto_session::cloud::AutoCloud;
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{Holder, Manifest, OpenTool, OpenTurn, SessionView};
use cmux_host::cloud::auto_session::Kind;

use super::agent::FakeAgent;
use super::repos::{Repos, carry, git, git_cwd, read, repos, write};
use super::{
    VM, append, as_events, chunk, empty_store, hub, laptop_goes_away, laptop_holds, log_when, mac,
    manifest_of, new_chat, prompts, send, snapshot, turns_ended, vm,
};

/// Posts the folder `dir` as the chat's snapshot by `holder`, taken after event `last_seq`;
/// `edit` finishes the manifest.
async fn post_folder(
    cloud: &impl AutoCloud,
    (id, holder, epoch): (&str, &Holder, u64),
    (repos, dir): (&Repos, &Path),
    last_seq: u64,
    edit: impl FnOnce(&mut Manifest),
) -> u64 {
    let (bundle, patch) = carry(dir, &repos.base, repos.dir.path());
    let mut names = [Vec::new(), Vec::new()];
    for (bytes, file) in [&bundle, &patch].into_iter().zip(&mut names) {
        if !bytes.is_empty() {
            file.push(chunk(cloud, id, holder, epoch, bytes).await);
        }
    }
    let [bundle, patch] = names;
    let mut manifest = manifest_of(git_cwd(repos, bundle, patch), last_seq);
    edit(&mut manifest);
    snapshot(cloud, id, holder, epoch, manifest).await
}

/// A laptop whose chat is mid-turn in a tool call, with a second prompt queued behind it, a
/// local commit and uncommitted work in its folder; and the store holding its copy.
struct Laptop {
    repos: Repos,
    owner: FakeAutoCloud,
    id: String,
    /// The laptop's hub: it keeps the chat's agent alive for the test.
    _hub: Arc<Hub>,
}

/// `whole`: the copy has the laptop's whole log. Otherwise it ends at the turn's start, before
/// the tool call shows in it, and only the manifest names the call.
async fn laptop_mid_turn(whole: bool) -> Laptop {
    let repos = repos();
    write(&repos.laptop, "local.txt", "a local commit\n");
    git(&repos.laptop, &["add", "local.txt"]);
    git(&repos.laptop, &["commit", "-q", "-m", "local"]);
    write(&repos.laptop, "README.md", "base\nuncommitted\n");
    let laptop_hub = hub();
    let chat = new_chat(&laptop_hub, &repos.laptop).await;
    let id = chat.id.clone();
    send(&laptop_hub, &chat, "p1", "tool-hang").await;
    let tool = |log: &[_]| log.iter().any(|e: &acpmux::store::EventRecord| e.kind == "tool_call");
    log_when(&laptop_hub, &id, "the tool call", tool).await;
    send(&laptop_hub, &chat, "p2", "second question").await;
    let log = laptop_hub.events(&id, 0, 100_000).unwrap();
    let started = log.iter().find(|event| event.kind == "turn_started").expect("a turn");
    let turn_id = started.msg["turnId"].as_str().unwrap().to_owned();
    let last = if whole { log.last().unwrap().seq } else { started.seq };
    let events: Vec<_> = as_events(&log).into_iter().filter(|event| event.seq <= last).collect();

    let owner = empty_store().await;
    laptop_holds(&owner, &id).await;
    append(&owner, &id, &mac(), 1, &events).await;
    let agent_session = chat.meta().agent_session_id.unwrap_or_default();
    post_folder(&owner, (&id, &mac(), 1), (&repos, &repos.laptop), last, |manifest| {
        manifest.harness_session_id = agent_session;
        manifest.draft = "half a thought".into();
        let tool = OpenTool { name: "Bash".into(), args: "cargo build --release".into() };
        manifest.open_turn = Some(OpenTurn { turn_id, prompt_id: "p1".into(), tool: Some(tool) });
    })
    .await;
    laptop_goes_away(&owner);
    Laptop { repos, owner, id, _hub: laptop_hub }
}

/// The machine's daemon: its hub, the agent it reaches the store through, and its importer,
/// whose new chats get folders under `root`.
struct MachineSide {
    hub: Arc<Hub>,
    agent: FakeAgent,
    importer: Arc<dyn SessionImporter>,
}

fn machine_side(owner: &FakeAutoCloud, root: &Path) -> MachineSide {
    let hub = hub();
    let agent = FakeAgent::start(owner, VM);
    let importer = Importer::new(Arc::clone(&hub), Arc::new(agent.cloud()), root);
    MachineSide { hub, agent, importer }
}

/// The chat as the machine is assigned it.
async fn assigned(side: &MachineSide) -> SessionView {
    let assignments = side.agent.cloud().assignments(0).await.unwrap();
    assignments.into_iter().next().expect("an assignment").session
}

const TAKEOVER: &str = "The machine this chat ran on went away";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_takeover_brings_the_log_and_the_folder_and_goes_on_with_the_cut_turn_first() {
    let laptop = laptop_mid_turn(true).await;
    let root = laptop.repos.path("machine");
    let side = machine_side(&laptop.owner, &root);
    let view = assigned(&side).await;
    assert_eq!((view.id.as_str(), view.epoch, &view.holder), (laptop.id.as_str(), 2, &vm()));

    let imported = side.importer.import(&view, ImportReason::Takeover).await.unwrap();
    side.hub.auto_accept_import(&view.id);
    assert_eq!((imported.session_id.as_str(), imported.epoch), (laptop.id.as_str(), 2));
    assert_eq!((imported.last_seq, imported.snapshot), (view.last_seq, view.snapshot));

    // The folder: the remote's commit, the laptop's commit on top, its uncommitted work.
    let folder = root.join(&laptop.id);
    assert_eq!(git(&folder, &["rev-parse", "--abbrev-ref", "HEAD"]), "main");
    let laptops_head = git(&laptop.repos.laptop, &["rev-parse", "HEAD"]);
    assert_eq!(git(&folder, &["rev-parse", "HEAD"]), laptops_head);
    assert_eq!(read(&folder, "local.txt"), "a local commit\n");
    assert_eq!(read(&folder, "README.md"), "base\nuncommitted\n");
    assert_eq!(git(&folder, &["status", "--porcelain"]), "M README.md");

    // The chat: the laptop's history, the cut turn ended as unknown, then one continuation
    // that names the tool call, then the prompt that waited behind the turn.
    let chat = side.hub.resolve(&laptop.id).expect("the chat is here");
    assert_eq!(chat.meta().cwd, folder);
    let log = log_when(&side.hub, &laptop.id, "both turns", |log| turns_ended(log) >= 3).await;
    let unknown: Vec<_> = log.iter().filter(|e| e.msg["detail"] == "outcome_unknown").collect();
    assert_eq!(unknown.len(), 1, "{unknown:?}");
    let texts = prompts(&log);
    let at = |wanted: &dyn Fn(&str) -> bool| -> Vec<usize> {
        (0..texts.len()).filter(|i| wanted(&texts[*i])).collect()
    };
    let continued = at(&|text| text.starts_with(TAKEOVER));
    let waited = at(&|text| text == "second question");
    assert_eq!((continued.len(), waited.len()), (1, 1), "{texts:#?}");
    assert!(continued[0] < waited[0], "{texts:#?}");
    let told = &texts[continued[0]];
    assert!(told.contains("tool-hang") && told.contains("Run a long build"), "{told}");

    // The same import again answers the same and runs nothing more.
    let again = side.importer.import(&view, ImportReason::Takeover).await.unwrap();
    side.hub.auto_accept_import(&view.id);
    assert_eq!(again, imported);
    assert_eq!(prompts(&side.hub.events(&laptop.id, 0, 100_000).unwrap()), texts);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_tool_call_only_the_snapshot_knows_of_is_named_in_the_continuation() {
    let laptop = laptop_mid_turn(false).await;
    let root = laptop.repos.path("machine");
    let side = machine_side(&laptop.owner, &root);
    let view = assigned(&side).await;
    side.importer.import(&view, ImportReason::Takeover).await.unwrap();
    side.hub.auto_accept_import(&view.id);
    let log =
        log_when(&side.hub, &laptop.id, "the continuation", |log| turns_ended(log) >= 2).await;
    let texts = prompts(&log);
    let told = texts.iter().find(|text| text.starts_with(TAKEOVER)).expect("a continuation");
    assert!(told.contains("was Bash with input: cargo build --release"), "{told}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_copy_with_a_chunk_missing_leaves_no_chat_and_no_folder() {
    let laptop = laptop_mid_turn(true).await;
    let root = laptop.repos.path("machine");
    let side = machine_side(&laptop.owner, &root);
    let view = assigned(&side).await;
    side.agent.lose(Kind::Chunk);
    let failed = side.importer.import(&view, ImportReason::Takeover).await.unwrap_err();
    let ImportError::Cloud(error) = &failed else { panic!("{failed}") };
    assert_eq!(error.status(), Some(404), "{error}");
    assert!(side.hub.resolve(&laptop.id).is_err());
    assert!(!root.join(&laptop.id).exists());
    // The store has the chunk again: the same import now goes through.
    side.agent.find(Kind::Chunk);
    side.importer.import(&view, ImportReason::Takeover).await.unwrap();
    side.hub.auto_accept_import(&view.id);
    assert!(side.hub.resolve(&laptop.id).is_ok());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_handback_puts_the_machines_work_into_the_laptops_own_chat_and_folder() {
    // The laptop's chat, idle, with its copy in the store.
    let repos = repos();
    let laptop_hub = hub();
    let chat = new_chat(&laptop_hub, &repos.laptop).await;
    let id = chat.id.clone();
    send(&laptop_hub, &chat, "p1", "hello").await;
    let log = log_when(&laptop_hub, &id, "the laptop's turn", |log| turns_ended(log) >= 1).await;
    let owner = empty_store().await;
    laptop_holds(&owner, &id).await;
    append(&owner, &id, &mac(), 1, &as_events(&log)).await;
    let agent_session = chat.meta().agent_session_id.unwrap_or_default();
    let last = log.last().unwrap().seq;
    post_folder(&owner, (&id, &mac(), 1), (&repos, &repos.laptop), last, |manifest| {
        manifest.harness_session_id = agent_session.clone();
    })
    .await;

    // The machine takes it over, runs a turn, commits and leaves uncommitted work.
    laptop_goes_away(&owner);
    let root = repos.path("machine");
    let side = machine_side(&owner, &root);
    let view = assigned(&side).await;
    side.importer.import(&view, ImportReason::Takeover).await.unwrap();
    side.hub.auto_accept_import(&view.id);
    let on_machine = side.hub.resolve(&id).unwrap();
    send(&side.hub, &on_machine, "m1", "from the machine").await;
    let done = |log: &[_]| {
        prompts(log).iter().any(|text| text == "from the machine") && turns_ended(log) >= 2
    };
    let machine_log = log_when(&side.hub, &id, "the machine's turn", done).await;
    let folder = root.join(&id);
    write(&folder, "machine.txt", "the machine's commit\n");
    git(&folder, &["add", "machine.txt"]);
    git(&folder, &["commit", "-q", "-m", "machine"]);
    write(&folder, "README.md", "base\nthe machine's uncommitted line\n");
    let cloud = side.agent.cloud();
    let new_events: Vec<_> = as_events(&machine_log).into_iter().filter(|e| e.seq > last).collect();
    append(&cloud, &id, &vm(), 2, &new_events).await;
    let machine_last = machine_log.last().unwrap().seq;
    post_folder(&cloud, (&id, &vm(), 2), (&repos, &folder), machine_last, |manifest| {
        manifest.harness_session_id = agent_session;
    })
    .await;

    // Meanwhile the laptop's folder got a file git does not track and an edit of its own.
    write(&repos.laptop, "notes.local", "mine\n");
    write(&repos.laptop, "README.md", "base\nthe laptop's stale edit\n");
    let importer =
        Importer::new(Arc::clone(&laptop_hub), Arc::new(owner.clone()), repos.path("unused"));
    let view = owner.get(&id).await.unwrap();
    let imported = importer.import(&view, ImportReason::Handback).await.unwrap();
    laptop_hub.auto_accept_import(&id);
    assert_eq!((imported.session_id.as_str(), imported.last_seq), (id.as_str(), machine_last));

    // The same chat, in the same folder, now with the machine's turn in its log.
    let back = laptop_hub.resolve(&id).expect("the chat is still the laptop's");
    assert_eq!(back.meta().cwd, repos.laptop);
    let texts = prompts(&laptop_hub.events(&id, 0, 100_000).unwrap());
    assert_eq!(texts, ["hello", "from the machine"]);
    // The folder is the machine's: its commit, its uncommitted line. The laptop's own file
    // stays, and what the folder held before is kept under a ref.
    assert_eq!(read(&repos.laptop, "machine.txt"), "the machine's commit\n");
    assert_eq!(read(&repos.laptop, "README.md"), "base\nthe machine's uncommitted line\n");
    assert_eq!(read(&repos.laptop, "notes.local"), "mine\n");
    assert_eq!(git(&repos.laptop, &["rev-parse", "HEAD"]), git(&folder, &["rev-parse", "HEAD"]));
    let kept = format!("refs/cmux/auto/before/{}-{}:README.md", id.replace('_', "-"), view.epoch);
    assert_eq!(git(&repos.laptop, &["show", &kept]), "base\nthe laptop's stale edit");
    assert!(!repos.path("unused").exists());
}
