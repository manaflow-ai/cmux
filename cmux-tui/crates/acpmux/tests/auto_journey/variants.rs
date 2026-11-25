//! Two other journeys: a chat the person keeps in the Cloud, and a chat started with no
//! laptop.

use cmux_auto_session::AutoCloud;
use cmux_auto_session::wire::{CreateRequest, FirstMessage, Repo};

use super::logs::{log_of, log_when, send, times};
use super::steps::{
    SECOND, a_period_passes, answered, auto_chat, comes_home, cut_mid_tool, laptop_returns,
};
use super::world::{World, device, read, vm};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_kept_in_the_cloud_stays_there_until_the_person_lets_it_come_home() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    let id = auto_chat(&world, &laptop, Some(true)).await;
    assert!(world.view(&id).keep_in_cloud);

    // The laptop leaves mid-tool, the machine goes on and finishes, the laptop comes back.
    let cut = cut_mid_tool(&world, &laptop, &id).await;
    log_when(&machine.hub, &id, "the machine goes on", |log| answered(log, SECOND)).await;
    world.machine_at_rest(&id).await;
    laptop_returns(&world, &laptop, &id, &cut).await;

    // The machine has nothing left to run and says so at every renewal, with the laptop
    // standing by: the chat stays in the Cloud.
    for _ in 0..3 {
        a_period_passes(&world).await;
    }
    let kept = world.view(&id);
    assert_eq!((kept.holder.clone(), kept.epoch), (vm(), 2), "{kept:?}");
    assert!(!kept.needs_run && kept.standby.contains(&device()), "{kept:?}");
    let row = laptop.row(&id);
    assert_eq!(row["here"], false, "{row}");
    assert_eq!(row["keepInCloud"], true, "{row}");
    assert_eq!(times(&log_of(&laptop.hub, &id), SECOND), 0, "nothing was brought in");

    // The person lets it come home: the machine's next renewal hands it back.
    let set = laptop.holder.set_auto(&id, true, Some(false)).await.expect("keep off");
    assert_eq!(set["keepInCloud"], false, "{set}");
    world.until_view(&id, "the store knows", |view| !view.keep_in_cloud).await;
    a_period_passes(&world).await;
    comes_home(&world, &laptop, &id, 3).await;
    assert_eq!(times(&log_of(&laptop.hub, &id), SECOND), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_started_with_no_laptop_runs_on_the_machine_and_shows_up_on_the_laptop() {
    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let machine = &world.machine;
    let start = |message: &str, text: &str| CreateRequest {
        title: Some("Started from the phone".into()),
        harness: "fake".into(),
        repo: Repo { remote: world.origin.to_string_lossy().into_owned(), branch: "main".into() },
        first_message: FirstMessage { id: message.to_owned(), text: text.to_owned() },
    };

    // The phone starts a chat. No laptop is on: the machine makes it and runs it.
    let created = world.phone.create(&start("m-1", "start here")).await.unwrap();
    let id = created.id.clone();
    assert_eq!((created.holder.clone(), created.epoch), (vm(), 1), "{created:?}");
    log_when(&machine.hub, &id, "the first message", |log| answered(log, "start here")).await;
    world.machine_at_rest(&id).await;
    assert_eq!(machine.folder(&id), machine.root.join(&id));
    assert_eq!(read(&machine.folder(&id), "a.txt"), "one\n");

    // The laptop's daemon starts. It asks for the person's chats, has no session of this one
    // and stands by for it; until the chat is its own it has no row.
    let laptop = world.start_laptop();
    world.until_view(&id, "the laptop stands by", |view| view.standby.contains(&device())).await;
    assert!(laptop.hub.resolve(&id).is_err(), "no session while it only stands by");

    // The machine's next renewal gives the chat home, and the laptop brings it in: a
    // session with the chat's history, in a folder of its own.
    a_period_passes(&world).await;
    comes_home(&world, &laptop, &id, 2).await;
    let session = laptop.hub.resolve(&id).expect("the chat is a session of the laptop");
    assert_eq!(session.meta().cwd, laptop.root.join(&id));
    assert_eq!(read(&laptop.folder(&id), "a.txt"), "one\n");
    let log = log_of(&laptop.hub, &id);
    assert!(answered(&log, "start here"), "the chat's history came along");
    assert_eq!(times(&log, "start here"), 1);
    // It runs here like any chat.
    send(&laptop.hub, &session, "p-here", "and now here").await;
    log_when(&laptop.hub, &id, "a turn on the laptop", |log| answered(log, "and now here")).await;
    assert_eq!(times(&log_of(&machine.hub, &id), "and now here"), 0);

    // A second chat, started while the laptop is on: the laptop hears of it at its next
    // wake, not before.
    let second = world.phone.create(&start("m-2", "another one")).await.unwrap().id;
    log_when(&machine.hub, &second, "its first message", |log| answered(log, "another one")).await;
    world.machine_at_rest(&second).await;
    assert!(world.view(&second).standby.is_empty(), "nobody told the laptop");
    laptop.holder.wake();
    world
        .until_view(&second, "the laptop stands by", |view| view.standby.contains(&device()))
        .await;
    a_period_passes(&world).await;
    comes_home(&world, &laptop, &second, 2).await;
    assert_eq!(times(&log_of(&laptop.hub, &second), "another one"), 1);
}

/// After the move a tool runs where the chat runs: the shell of a tool the machine's turn
/// starts is a child of the machine daemon's agent, not of the laptop's. Both daemons are
/// in this process, so the agent is told apart by the id the machine's agents carry
/// (`world::World::new`).
#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_tool_after_the_move_runs_under_the_machine_daemon() {
    use cmux_auto_session::consts::RENEW_MS;
    use cmux_auto_session::wire::InboxPost;

    let _hermetic = &crate::HERMETIC;
    let world = World::new().await;
    let laptop = world.start_laptop();
    let machine = &world.machine;
    let id = auto_chat(&world, &laptop, None).await;

    let cut = cut_mid_tool(&world, &laptop, &id).await;
    let laptop_agent = parent(cut.pid);
    assert_eq!(parent(laptop_agent), std::process::id(), "the laptop's agent is its hub's child");
    assert_ne!(agent_id(laptop_agent).as_deref(), Some(ON_THE_MACHINE), "the laptop's own agent");
    log_when(&machine.hub, &id, "the machine goes on", |log| answered(log, SECOND)).await;
    world.machine_at_rest(&id).await;

    // A tool the phone asks for now runs in the machine's turn.
    let out = world.dir.path().join("cloud-build.log");
    let run = InboxPost { id: "phone-run".into(), text: format!("auto-run: {}", out.display()) };
    world.phone.post_inbox(&id, &run).await.unwrap();
    world.pass_while_laptop_sleeps(RENEW_MS);
    let pid_file = std::path::PathBuf::from(format!("{}.pid", out.display()));
    super::logs::until("the machine's tool shell runs", || pid_file.exists()).await;
    let shell: u32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let agent = parent(shell);
    let ended = scopeguard(shell);
    assert_ne!(agent, laptop_agent);
    assert_eq!(parent(agent), std::process::id(), "the machine's agent is its hub's child");
    assert_eq!(agent_id(agent).as_deref(), Some(ON_THE_MACHINE), "spawned by the machine daemon");
    assert_eq!(world.view(&id).holder, vm());
    drop(ended);
}

/// The id the machine daemon's agents carry in their environment (`world::World::new`).
#[cfg(target_os = "linux")]
const ON_THE_MACHINE: &str = "on-the-cloud-machine";

/// A process's parent, from `/proc/<pid>/stat` (the field after the parenthesized name).
#[cfg(target_os = "linux")]
fn parent(pid: u32) -> u32 {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).expect("the process runs");
    let rest = &stat[stat.rfind(')').expect("a stat line") + 2..];
    rest.split(' ').nth(1).and_then(|ppid| ppid.parse().ok()).expect("a parent pid")
}

/// `ACPMUX_SESSION_ID` in a process's environment.
#[cfg(target_os = "linux")]
fn agent_id(pid: u32) -> Option<String> {
    let environ = std::fs::read(format!("/proc/{pid}/environ")).ok()?;
    environ.split(|byte| *byte == 0).find_map(|entry| {
        let entry = std::str::from_utf8(entry).ok()?;
        entry.strip_prefix("ACPMUX_SESSION_ID=").map(str::to_owned)
    })
}

/// Kills the tool's shell (ten minutes of `sleep`, started by this test) when it drops.
#[cfg(target_os = "linux")]
fn scopeguard(pid: u32) -> impl Drop {
    struct Kill(i32);
    impl Drop for Kill {
        fn drop(&mut self) {
            // SAFETY: a plain signal to the shell this test's turn started.
            unsafe { libc::kill(self.0, libc::SIGKILL) };
        }
    }
    Kill(i32::try_from(pid).expect("a pid"))
}
