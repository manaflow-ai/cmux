use super::*;
use crate::placement::sub_fork::tests::{checkout, fork_of};
use crate::placement::sub_fork_run::{Lines, run_job};
use std::collections::HashMap;
use std::sync::Mutex;

#[test]
fn builds_and_test_runs_are_heavy_and_the_rest_stays_here() {
    assert_eq!(heavy_class("cargo test -p acpmux"), Some("a Rust test run"));
    assert_eq!(heavy_class("cd crates && cargo build --release"), Some("a Rust build"));
    assert_eq!(heavy_class("/usr/bin/swift test"), Some("a Swift test run"));
    assert_eq!(heavy_class("pnpm test"), Some("a test run"));
    assert_eq!(heavy_class("go test ./..."), Some("a Go test run"));
    assert_eq!(heavy_class("ls -la"), None);
    assert_eq!(heavy_class("cargo --version"), None);
    assert_eq!(heavy_class("cargo test --help"), None);
    assert_eq!(heavy_class("pnpm dev"), None, "a dev server is a serve VM, not a run VM");
    assert_eq!(heavy_class("cargo test &"), None, "backgrounded by itself");
    assert_eq!(heavy_class("acpmux run-vm -- cargo test"), None, "already a run-VM call");
}

#[test]
fn on_by_default_until_the_kill_switch() {
    use serde_json::json;
    assert!(on_in(None, None));
    assert!(on_in(Some(&json!({})), None));
    assert!(on_in(Some(&json!({"cloud": {"runVms": true}})), Some("1")));
    assert!(!on_in(Some(&json!({"cloud": {"runVms": false}})), None));
    assert!(!on_in(None, Some("0")));
    assert!(!on_in(None, Some(" OFF ")));
}

#[test]
fn only_when_on_and_on_a_cloud_machine() {
    assert!(goes(true, Some("vm_a"), "cargo test").is_some());
    assert!(goes(false, Some("vm_a"), "cargo test").is_none());
    assert!(goes(true, None, "cargo test").is_none());
    assert!(goes(true, Some("  "), "cargo test").is_none());
    assert!(goes(true, Some("vm_a"), "git status").is_none());
}

#[test]
fn the_wrapped_call_runs_this_binary_with_the_command_after_the_separator() {
    let words = vec!["/opt/acpmux".to_owned()];
    let text = wrap(&words, "cargo test -p 'a b'");
    let argv = shell_words(&text);
    assert_eq!(argv, ["/opt/acpmux", "run-vm", "--", "cargo test -p 'a b'"]);
}

fn shell_words(text: &str) -> Vec<String> {
    // `set --` keeps the quoting: print each word NUL-separated.
    let out = std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("set -- {text}; for w in \"$@\"; do printf '%s\\0' \"$w\"; done"))
        .output()
        .unwrap();
    String::from_utf8(out.stdout)
        .unwrap()
        .split('\0')
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Forks by copying the parent's disk; each fork's disk kept by id.
struct CopyMachines {
    parent: PathBuf,
    disks: Arc<Mutex<HashMap<String, tempfile::TempDir>>>,
    deleted: Mutex<Vec<String>>,
    refuse: bool,
}

impl CopyMachines {
    fn new(parent: &Path) -> Self {
        Self {
            parent: parent.to_owned(),
            disks: Default::default(),
            deleted: Default::default(),
            refuse: false,
        }
    }
}

impl Machines for CopyMachines {
    async fn fork(&self, machine: &str, _key: &str) -> Result<String, String> {
        if self.refuse {
            return Err("the pool has no room".into());
        }
        let disk = fork_of(&self.parent);
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

/// Runs the command job in-process on the fork's disk with the real [`ShellHarness`], over a
/// pipe, as the ssh link would; the parent's paths are mapped onto the fork's disk.
struct ShellLink {
    disks: Arc<Mutex<HashMap<String, tempfile::TempDir>>>,
    parent: PathBuf,
    jobs: Mutex<Vec<Job>>,
}

impl ForkLink for ShellLink {
    async fn start(&self, _fork: &str) -> Result<(), String> {
        Ok(())
    }
    async fn open(&self, fork: &str, job: &Job) -> Result<Lines, String> {
        self.jobs.lock().unwrap().push(job.clone());
        let disk = self.disks.lock().unwrap().get(fork).map(|d| d.path().to_owned());
        let disk = disk.ok_or("no such fork")?;
        let mut job = job.clone();
        let rel = job.cwd.as_deref().and_then(|c| c.strip_prefix(&self.parent).ok());
        job.cwd = Some(disk.join(rel.unwrap_or(Path::new(""))));
        job.checkout = disk;
        let (ours, mut theirs) = tokio::io::duplex(64);
        tokio::spawn(async move {
            run_job(&job, &ShellHarness, &mut theirs).await.unwrap();
        });
        Ok(Box::pin(tokio::io::BufReader::new(ours)))
    }
}

/// A link that cannot reach the fork.
struct Unreachable;

impl ForkLink for Unreachable {
    async fn start(&self, _fork: &str) -> Result<(), String> {
        Ok(())
    }
    async fn open(&self, _fork: &str, _job: &Job) -> Result<Lines, String> {
        Err("ssh: connection refused".into())
    }
}

async fn run_it<L: ForkLink>(
    machines: Arc<CopyMachines>,
    link: &L,
    command: &str,
    cwd: &Path,
) -> (Ran, Vec<String>) {
    let mut lines = Vec::new();
    let mut out = |l: &str| lines.push(l.to_owned());
    let ran = on_fork(machines, link, "vm_a", "a test run", command, cwd, None, &mut out).await;
    (ran, lines)
}

#[tokio::test]
async fn a_heavy_command_runs_on_the_fork_streams_its_output_and_its_files_come_back() {
    let parent = checkout();
    let p = parent.path();
    std::fs::create_dir(p.join("sub")).unwrap();
    std::fs::write(p.join("sub/in.txt"), "input\n").unwrap();
    let machines = Arc::new(CopyMachines::new(p));
    let link =
        ShellLink { disks: machines.disks.clone(), parent: p.to_owned(), jobs: Default::default() };
    // In the parent's `sub/`: reads a file, writes one tracked and one ignored output, says
    // something on stderr, and fails with 3.
    let command = "cat in.txt; echo built > out.txt; mkdir -p ../target && echo obj > ../target/o; \
echo warn >&2; exit 3";
    let (ran, lines) = run_it(machines.clone(), &link, command, &p.join("sub")).await;
    let Ran::Done { exit, row } = ran else { panic!("ran here: {ran:?}") };
    assert_eq!(exit, 3, "the command's own exit");
    assert_eq!(lines, ["input", "warn"]);
    assert_eq!(std::fs::read_to_string(p.join("sub/out.txt")).unwrap(), "built\n");
    assert!(!p.join("target/o").exists(), "ignored build outputs stay on the run VM");
    assert_eq!(row.files, Some(1));
    assert_eq!(row.ran, "fork");
    assert_eq!(row.fork_deleted, Some(true));
    assert_eq!(*machines.deleted.lock().unwrap(), vec!["vm_a-fork-0".to_owned()]);
    let job = link.jobs.lock().unwrap()[0].clone();
    assert_eq!(job.cwd.as_deref(), Some(p.join("sub").as_path()));
    assert_eq!(job.command.as_deref(), Some(command));
}

#[tokio::test]
async fn a_refused_fork_runs_the_command_here_with_the_cause() {
    let parent = checkout();
    let mut machines = CopyMachines::new(parent.path());
    machines.refuse = true;
    let link = Unreachable;
    let (ran, lines) = run_it(Arc::new(machines), &link, "cargo test", parent.path()).await;
    let Ran::Here { row } = ran else { panic!("ran on a fork: {ran:?}") };
    assert!(row.cause.unwrap().contains("no room"));
    assert!(lines.is_empty());
}

#[tokio::test]
async fn an_unreachable_fork_is_deleted_and_the_command_runs_here() {
    let parent = checkout();
    let machines = Arc::new(CopyMachines::new(parent.path()));
    let (ran, _) = run_it(machines.clone(), &Unreachable, "cargo test", parent.path()).await;
    let Ran::Here { row } = ran else { panic!("ran on a fork: {ran:?}") };
    assert!(row.cause.unwrap().contains("connection refused"));
    assert_eq!(row.fork_deleted, Some(true));
    assert_eq!(machines.deleted.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn outside_a_git_checkout_it_runs_here() {
    let dir = tempfile::tempdir().unwrap();
    let machines = Arc::new(CopyMachines::new(dir.path()));
    let (ran, _) = run_it(machines.clone(), &Unreachable, "cargo test", dir.path()).await;
    assert!(matches!(ran, Ran::Here { .. }));
    assert!(machines.disks.lock().unwrap().is_empty(), "no fork taken");
}
