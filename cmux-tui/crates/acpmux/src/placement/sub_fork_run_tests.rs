use super::*;
use crate::placement::sub_fork::tests::{checkout, files, fork_of, work_on};
use crate::placement::sub_fork::{
    Cause, Machines, Outcome, Placing, WarmSlot, place_with, snapshot,
};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The sub-agent on the fork: two lines of output, then the edits of `work_on`.
struct FakeHarness {
    exit: i32,
}

impl Harness for FakeHarness {
    async fn run(&self, job: &Job, out: &mut (dyn FnMut(&str) + Send)) -> Result<i32, String> {
        out("reading the task");
        work_on(&job.checkout);
        out(&format!("done: {}", job.prompt));
        Ok(self.exit)
    }
}

/// Forks the parent by copying its disk, after `delay`; each fork's disk is kept by id.
#[derive(Default)]
struct CopyMachines {
    parent: PathBuf,
    delay: Duration,
    disks: Arc<Mutex<HashMap<String, tempfile::TempDir>>>,
    deleted: Mutex<Vec<String>>,
}

impl Machines for CopyMachines {
    async fn fork(&self, machine: &str, _client_key: &str) -> Result<String, String> {
        // The copy is taken when the fork is asked for, as a copy-on-write fork would be.
        let disk = fork_of(&self.parent);
        tokio::time::sleep(self.delay).await;
        let mut disks = self.disks.lock().unwrap();
        let id = format!("{machine}-fork-{}", disks.len());
        disks.insert(id.clone(), disk);
        Ok(id)
    }
    async fn delete(&self, machine: &str) -> Result<(), String> {
        self.deleted.lock().unwrap().push(machine.to_owned());
        Ok(())
    }
}

/// Runs the fork's job in-process on the fork's disk, over a pipe, as the ssh link would.
struct FakeLink {
    disks: Arc<Mutex<HashMap<String, tempfile::TempDir>>>,
    exit: i32,
    calls: Mutex<Vec<String>>,
    jobs: Mutex<Vec<Job>>,
}

impl FakeLink {
    fn new(disks: Arc<Mutex<HashMap<String, tempfile::TempDir>>>) -> Self {
        Self { disks, exit: 0, calls: Mutex::default(), jobs: Mutex::default() }
    }
}

impl ForkLink for FakeLink {
    async fn start(&self, fork: &str) -> Result<(), String> {
        self.calls.lock().unwrap().push(format!("start {fork}"));
        Ok(())
    }
    async fn open(&self, fork: &str, job: &Job) -> Result<Lines, String> {
        self.calls.lock().unwrap().push(format!("open {fork}"));
        self.jobs.lock().unwrap().push(job.clone());
        let disk = self.disks.lock().unwrap().get(fork).map(|d| d.path().to_owned());
        let disk = disk.ok_or("no such fork")?;
        let mut job = job.clone();
        job.checkout = disk;
        let (ours, mut theirs) = tokio::io::duplex(64);
        let harness = FakeHarness { exit: self.exit };
        tokio::spawn(async move {
            theirs.write_all(b"Welcome to the fork\n").await.unwrap();
            run_job(&job, &harness, &mut theirs).await.unwrap();
        });
        Ok(Box::pin(tokio::io::BufReader::new(ours)))
    }
}

/// A link whose stream is fixed text.
struct CannedLink(&'static str);

impl ForkLink for CannedLink {
    async fn start(&self, _fork: &str) -> Result<(), String> {
        Ok(())
    }
    async fn open(&self, _fork: &str, _job: &Job) -> Result<Lines, String> {
        Ok(Box::pin(std::io::Cursor::new(self.0.as_bytes())))
    }
}

fn task(dir: &Path) -> Task {
    Task {
        prompt: "edit".into(),
        checkout: dir.to_owned(),
        base_tree: snapshot(dir).unwrap(),
        model: Some("opus".into()),
        sync_patch: Vec::new(),
    }
}

fn opts(budget: Duration, warm: Arc<WarmSlot<CopyMachines>>) -> Placing<CopyMachines> {
    Placing { budget, warm, model: Some("opus".into()) }
}

#[tokio::test]
async fn a_fork_in_the_budget_runs_the_sub_agent_there_and_its_files_come_back_byte_exact() {
    let parent = checkout();
    let machines =
        Arc::new(CopyMachines { parent: parent.path().to_owned(), ..Default::default() });
    let runner = ForkRunner::new(FakeLink::new(machines.disks.clone()));
    let warm = Arc::new(WarmSlot::default());
    let out = place_with(
        true,
        Some("m"),
        machines.clone(),
        &runner,
        &opts(Duration::from_secs(30), warm),
        "edit",
        parent.path(),
    )
    .await;
    let Outcome::Applied { fork, report, files: n, first_output_ms, warm, .. } = &out else {
        panic!("{out:?}");
    };
    assert_eq!(fork, "m-fork-0");
    assert!(!warm);
    assert_eq!(*n, 7);
    assert_eq!(report, "reading the task\ndone: edit");
    assert!(first_output_ms.is_some());
    let disk = machines.disks.lock().unwrap().get("m-fork-0").unwrap().path().to_owned();
    assert_eq!(files(parent.path()), files(&disk));
    // Woken before it was reached, reached once, deleted after.
    assert_eq!(*runner.link.calls.lock().unwrap(), ["start m-fork-0", "open m-fork-0"]);
    assert_eq!(*machines.deleted.lock().unwrap(), ["m-fork-0"]);
    let jobs = runner.link.jobs.lock().unwrap();
    assert_eq!(jobs[0].model.as_deref(), Some("opus"));
    assert!(jobs[0].sync_patch.is_empty(), "a fork taken for this task needs no sync");
}

#[tokio::test]
async fn a_fork_past_the_budget_never_blocks_the_start_and_waits_warm_for_the_next_sub_agent() {
    let parent = checkout();
    let machines = Arc::new(CopyMachines {
        parent: parent.path().to_owned(),
        delay: Duration::from_millis(300),
        ..Default::default()
    });
    let runner = ForkRunner::new(FakeLink::new(machines.disks.clone()));
    let warm = Arc::new(WarmSlot::default());
    let began = std::time::Instant::now();
    let first = place_with(
        true,
        Some("m"),
        machines.clone(),
        &runner,
        &opts(Duration::from_millis(20), warm.clone()),
        "edit",
        parent.path(),
    )
    .await;
    assert!(began.elapsed() < Duration::from_millis(250), "the start waited on the fork");
    let Outcome::Fallback { cause: Cause::Fork, detail, fork_deleted: None } = &first else {
        panic!("{first:?}");
    };
    assert!(detail.contains("warm"), "{detail}");
    assert!(first.runs_here());
    // The fork lands in the background and is kept warm.
    for _ in 0..100 {
        if warm.peek().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let parked = warm.peek().expect("a warm fork");
    assert_eq!(parked.id, "m-fork-0");
    assert!(parked.fork_ms >= 300, "{}", parked.fork_ms);

    // The parent moves on before the next sub-agent: the warm fork is synced to now.
    std::fs::write(parent.path().join("keep.txt"), "keep, edited after the warm fork\n").unwrap();
    std::fs::write(parent.path().join("later.txt"), "made after the fork\n").unwrap();
    let second = place_with(
        true,
        Some("m"),
        machines.clone(),
        &runner,
        &opts(Duration::from_millis(20), warm.clone()),
        "edit",
        parent.path(),
    )
    .await;
    let Outcome::Applied { fork, warm: was_warm, fork_ms, .. } = &second else {
        panic!("{second:?}");
    };
    assert_eq!(fork, "m-fork-0");
    assert!(was_warm);
    assert_eq!(*fork_ms, parked.fork_ms);
    assert!(warm.peek().is_none(), "a warm fork serves one sub-agent");
    let disk = machines.disks.lock().unwrap().get("m-fork-0").unwrap().path().to_owned();
    assert_eq!(files(parent.path()), files(&disk));
    assert_eq!(
        std::fs::read_to_string(parent.path().join("keep.txt")).unwrap(),
        "keep, edited after the warm fork\n"
    );
    assert!(parent.path().join("later.txt").exists());
    assert!(!runner.link.jobs.lock().unwrap()[0].sync_patch.is_empty());
    assert_eq!(*machines.deleted.lock().unwrap(), ["m-fork-0"]);
}

#[tokio::test]
async fn an_unused_warm_fork_is_deleted_after_its_ttl_and_a_newer_one_replaces_it() {
    let machines = Arc::new(CopyMachines::default());
    let slot = Arc::new(WarmSlot::<CopyMachines>::with_ttl(Duration::from_millis(80)));
    let warm = |id: &str| crate::placement::sub_fork::WarmFork {
        id: id.into(),
        source: "m".into(),
        base_tree: "t".into(),
        fork_ms: 1,
        at: std::time::Instant::now(),
    };
    slot.park(machines.clone(), warm("a"));
    slot.park(machines.clone(), warm("b"));
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert_eq!(*machines.deleted.lock().unwrap(), ["a"], "the older warm fork is deleted");
    assert!(slot.take("other").is_none(), "a warm fork is only for its own machine");
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(*machines.deleted.lock().unwrap(), ["a", "b"]);
    assert!(slot.peek().is_none());
}

#[tokio::test]
async fn an_error_frame_a_failed_exit_and_a_cut_stream_are_each_a_run_failure() {
    let parent = checkout();
    let t = task(parent.path());
    let err = ForkRunner::new(CannedLink("{\"error\":\"sync: no git\"}\n")).run("f", &t).await;
    assert_eq!(err.unwrap_err(), "on the fork: sync: no git");
    let cut = ForkRunner::new(CannedLink("{\"out\":\"half\"}\n")).run("f", &t).await;
    assert!(cut.unwrap_err().contains("ended before"));

    let machines =
        Arc::new(CopyMachines { parent: parent.path().to_owned(), ..Default::default() });
    let id = machines.fork("m", "sub-fork-x").await.unwrap();
    let mut link = FakeLink::new(machines.disks.clone());
    link.exit = 3;
    let failed = ForkRunner::new(link).run(&id, &t).await;
    assert_eq!(failed.unwrap_err(), "the sub-agent on the fork exited 3");
}

#[tokio::test]
async fn lines_that_are_not_frames_are_skipped_and_the_times_are_kept() {
    let parent = checkout();
    let t = task(parent.path());
    let runner = ForkRunner::new(CannedLink(
        "Last login: today\n{\"base\":\"x\"}\nnot json\n{\"out\":\"hi\"}\n{\"done\":{\"exit\":0,\"patch\":\"\"}}\n",
    ));
    let ran = runner.run("f", &t).await.unwrap();
    assert_eq!(ran.report, "hi");
    assert!(ran.patch.is_empty());
    assert!(ran.first_output_ms.is_some() && ran.files_back_ms.is_some());
    assert_eq!(runner.times().first_output_ms, ran.first_output_ms);
}

#[tokio::test]
async fn a_job_that_is_not_json_answers_an_error_frame() {
    let parent = checkout();
    let job = Job {
        checkout: parent.path().to_owned(),
        sync_patch: "not base64!".into(),
        prompt: "p".into(),
        name: "n".into(),
        model: None,
    };
    let mut out = Vec::new();
    run_job(&job, &FakeHarness { exit: 0 }, &mut out).await.unwrap();
    let frame: Frame = serde_json::from_slice(out.trim_ascii_end()).unwrap();
    assert!(matches!(frame, Frame::Error(e) if e.starts_with("sync patch")));
}

#[test]
fn the_ssh_route_takes_only_a_plain_host_user_port_and_an_ed25519_key() {
    let ok = json!({"host": "10.0.0.7", "port": 22, "username": "cmux",
        "hostPublicKey": "ssh-ed25519 AAAAC3Nza host", "expiresAtUnix": 1});
    assert_eq!(
        ssh_route(&ok).unwrap(),
        ("10.0.0.7".into(), 22, "cmux".into(), "ssh-ed25519 AAAAC3Nza host".into())
    );
    let with = |k: &str, v: Value| {
        let mut e = ok.clone();
        e[k] = v;
        ssh_route(&e)
    };
    assert!(with("host", json!("-oProxyCommand")).is_err(), "an ssh option is not a host");
    assert!(with("username", json!("-l")).is_err());
    assert!(with("host", json!("a b")).is_err());
    assert!(with("username", json!("root;rm")).is_err());
    assert!(with("port", json!(70000)).is_err());
    assert!(with("hostPublicKey", json!("ssh-rsa AAAA")).is_err());
    assert!(with("hostPublicKey", json!("ssh-ed25519 A\nevil")).is_err());
}
