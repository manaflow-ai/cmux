//! Fixture crates written to a temporary folder, scanned through the library
//! API (and once through the binary): one test per kind and per exemption.

use std::collections::BTreeSet;
use std::error::Error;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use async_blocking_scan::config::Config;
use async_blocking_scan::finding::{Finding, Kind};
use async_blocking_scan::{Outcome, Request, run};

type TestResult = Result<(), Box<dyn Error>>;

/// A temporary folder removed on drop.
struct Fixture {
    dir: PathBuf,
}

impl Fixture {
    fn new() -> Result<Fixture, Box<dyn Error>> {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("async-blocking-scan-{}-{n}", std::process::id()));
        if dir.exists() {
            std::fs::remove_dir_all(&dir)?;
        }
        std::fs::create_dir_all(&dir)?;
        Ok(Fixture { dir })
    }

    fn write(&self, rel: &str, text: &str) -> Result<&Self, Box<dyn Error>> {
        let path = self.dir.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, text)?;
        Ok(self)
    }

    /// A crate `name` under `crates/name` with `src/lib.rs`.
    fn krate(&self, name: &str, lib: &str) -> Result<&Self, Box<dyn Error>> {
        let manifest = format!("[package]\nname = \"{name}\"\nversion = \"0.0.0\"\n");
        self.write(&format!("crates/{name}/Cargo.toml"), &manifest)?;
        self.write(&format!("crates/{name}/src/lib.rs"), lib)
    }

    fn root(&self) -> PathBuf {
        self.dir.join("crates")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn scan(roots: &[PathBuf], kinds: &[Kind], base: Option<&str>) -> Result<Outcome, Box<dyn Error>> {
    let cfg = Config::default_rules()?;
    let kinds: BTreeSet<Kind> = if kinds.is_empty() {
        Kind::ALL.into_iter().collect()
    } else {
        kinds.iter().copied().collect()
    };
    let request = Request { roots: roots.to_vec(), kinds, diff_base: base.map(str::to_string) };
    Ok(run(&cfg, &request)?)
}

/// `(rule, function)` of each reported finding.
fn hits(findings: &[Finding]) -> Vec<(String, String)> {
    findings.iter().map(|f| (f.rule.clone(), f.function.clone())).collect()
}

fn functions(findings: &[Finding]) -> BTreeSet<String> {
    findings.iter().map(|f| f.function.clone()).collect()
}

fn set(names: &[&str]) -> BTreeSet<String> {
    names.iter().map(|s| (*s).to_string()).collect()
}

#[test]
fn blocking_calls_in_async_code_and_their_exemptions() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "blocky",
        r#"
use std::fs;
use tokio::fs as tfs;

pub async fn std_read() { let _ = fs::read("a"); }
pub async fn full_path() { let _ = std::fs::read_to_string("a"); }
pub async fn tokio_read() { let _ = tfs::read("a").await; }
pub fn sync_read() { let _ = fs::read("a"); }
pub async fn offloaded() {
    let _ = tokio::task::spawn_blocking(move || fs::read("a")).await;
}
pub fn async_block() -> impl std::future::Future<Output = ()> {
    async { std::thread::sleep(std::time::Duration::from_millis(1)); }
}
pub async fn exists(p: &std::path::Path) -> bool { p.exists() }
pub async fn std_channel() {
    let (_tx, rx) = std::sync::mpsc::channel::<u8>(); // unbounded-allow: fixture
    let _ = rx.recv();
}
pub async fn tokio_recv(rx: &mut tokio::sync::mpsc::Receiver<u8>) { let _ = rx.recv().await; }
pub async fn allowed() {
    // blocking-allow: the fixture's reason
    let _ = fs::read("a");
}
pub async fn allowed_same_line() { let _ = fs::read("a"); } // blocking-allow: same line
pub async fn allow_without_reason() {
    // blocking-allow:
    let _ = fs::read("a");
}
pub async fn always_blocks(rt: &tokio::runtime::Runtime) { rt.block_on(async {}); }
"#,
    )?;
    let out = scan(&[fx.root()], &[Kind::Blocking], None)?;
    assert_eq!(
        functions(&out.head.findings),
        set(&[
            "std_read",
            "full_path",
            "async_block",
            "exists",
            "std_channel",
            "allow_without_reason",
            "always_blocks",
        ]),
        "{:#?}",
        out.head.findings
    );
    let exempt: Vec<_> =
        out.head.exempt.iter().map(|f| (f.function.as_str(), f.exempt.as_deref())).collect();
    assert_eq!(
        exempt,
        [("allowed", Some("the fixture's reason")), ("allowed_same_line", Some("same line"))]
    );
    assert!(out.head.findings.iter().all(|f| f.krate == "blocky" && f.kind.queue() == "Q11"));
    let typed = out.head.findings.iter().find(|f| f.function == "std_channel");
    assert_eq!(typed.map(|f| f.rule.as_str()), Some("typed-method"));
    Ok(())
}

#[test]
fn std_lock_guards_held_across_await() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "locks",
        r#"
use std::sync::Mutex;

async fn tick() {}

pub async fn held(m: &Mutex<u8>) {
    let g = m.lock().unwrap();
    tick().await;
    let _ = *g;
}
pub async fn dropped_first(m: &Mutex<u8>) {
    let g = m.lock().unwrap();
    let _ = *g;
    drop(g);
    tick().await;
}
pub async fn temporary_in_match(m: &Mutex<Option<u8>>) {
    match *m.lock().unwrap() {
        Some(_) => tick().await,
        None => {}
    }
}
pub async fn temporary_ends(m: &Mutex<u8>) {
    let v = *m.lock().unwrap();
    tick().await;
    let _ = v;
}
pub async fn tokio_lock(m: &tokio::sync::Mutex<u8>) {
    let g = m.lock().await;
    tick().await;
    let _ = *g;
}
pub fn sync_fn(m: &Mutex<u8>) { let _g = m.lock(); }
"#,
    )?;
    let out = scan(&[fx.root()], &[Kind::Blocking], None)?;
    assert_eq!(
        hits(&out.head.findings),
        [
            ("lock-over-await".to_string(), "held".to_string()),
            ("lock-over-await".to_string(), "temporary_in_match".to_string()),
        ],
        "{:#?}",
        out.head.findings
    );
    Ok(())
}

#[test]
fn dropped_task_handles_and_unsupervised_threads() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "spawny",
        r#"
use cmux_panic_log::supervise_thread;
use std::thread;

pub fn dropped() { tokio::spawn(async {}); }
pub fn wild() { let _ = tokio::task::spawn(async {}); }
pub fn kept() -> tokio::task::JoinHandle<()> { let h = tokio::spawn(async {}); h }
pub fn via_handle() { tokio::runtime::Handle::current().spawn(async {}); }
pub fn raw_thread() { let _h = thread::spawn(|| {}); }
pub fn builder() { let _h = std::thread::Builder::new().name("x".into()).spawn(|| {}); }
pub fn supervised() {
    supervise_thread("worker", Default::default(), || { let _ = thread::spawn(|| {}); });
}
pub fn allowed() {
    // supervise-allow: joined before return in the fixture
    let _h = thread::spawn(|| {});
}
"#,
    )?;
    let out = scan(&[fx.root()], &[Kind::Spawn], None)?;
    assert_eq!(
        hits(&out.head.findings),
        [
            ("dropped-handle".to_string(), "dropped".to_string()),
            ("dropped-handle".to_string(), "wild".to_string()),
            ("dropped-handle".to_string(), "via_handle".to_string()),
            ("thread".to_string(), "raw_thread".to_string()),
            ("thread".to_string(), "builder".to_string()),
        ],
        "{:#?}",
        out.head.findings
    );
    assert_eq!(functions(&out.head.exempt), set(&["allowed"]));
    assert!(out.head.findings.iter().all(|f| f.kind.queue() == "Q12"));
    Ok(())
}

#[test]
fn pre_exec_bodies_allow_only_signal_safe_calls() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "forky",
        r#"
use std::os::unix::process::CommandExt;
use std::process::Command;

pub fn safe(cmd: &mut Command) {
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 { return Err(std::io::Error::last_os_error()); }
            Ok(())
        });
    }
}
pub fn prints(cmd: &mut Command) {
    unsafe { cmd.pre_exec(|| { println!("child"); Ok(()) }); }
}
pub fn allocates(cmd: &mut Command) {
    unsafe { cmd.pre_exec(|| { let _ = "x".to_string(); Ok(()) }); }
}
pub fn opaque(cmd: &mut Command, f: fn() -> std::io::Result<()>) {
    unsafe { cmd.pre_exec(f); }
}
pub fn allowed(cmd: &mut Command) {
    unsafe {
        // pre-exec-allow: the helper only calls dup2 and close
        cmd.pre_exec(|| helper());
    }
}
fn helper() -> std::io::Result<()> { Ok(()) }
"#,
    )?;
    let out = scan(&[fx.root()], &[Kind::PreExec], None)?;
    assert_eq!(
        hits(&out.head.findings),
        [
            ("macro".to_string(), "prints".to_string()),
            ("method".to_string(), "allocates".to_string()),
            ("opaque".to_string(), "opaque".to_string()),
        ],
        "{:#?}",
        out.head.findings
    );
    assert_eq!(functions(&out.head.exempt), set(&["allowed"]));
    Ok(())
}

#[test]
fn spawned_children_must_be_reaped() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "kids",
        r#"
use std::process::Command;

pub struct Owner { child: Option<std::process::Child> }

pub fn dropped() -> std::io::Result<()> { Command::new("x").spawn()?; Ok(()) }
pub fn unreaped() -> std::io::Result<()> { let _c = Command::new("x").spawn()?; Ok(()) }
pub fn waited() -> std::io::Result<()> { let mut c = Command::new("x").spawn()?; c.wait()?; Ok(()) }
pub fn stored(o: &mut Owner) -> std::io::Result<()> {
    let c = Command::new("x").spawn()?;
    o.child = Some(c);
    Ok(())
}
pub async fn killed_on_drop() -> std::io::Result<()> {
    let _c = tokio::process::Command::new("x").kill_on_drop(true).spawn()?;
    Ok(())
}
pub async fn awaited() -> std::io::Result<()> {
    let mut c = tokio::process::Command::new("x").spawn()?;
    c.wait().await?;
    Ok(())
}
pub fn allowed() -> std::io::Result<()> {
    // child-allow: the daemon double-forks and its parent exits at once
    Command::new("x").spawn()?;
    Ok(())
}
"#,
    )?;
    let out = scan(&[fx.root()], &[Kind::Child], None)?;
    assert_eq!(
        hits(&out.head.findings),
        [
            ("dropped".to_string(), "dropped".to_string()),
            ("unreaped".to_string(), "unreaped".to_string()),
        ],
        "{:#?}",
        out.head.findings
    );
    assert_eq!(functions(&out.head.exempt), set(&["allowed"]));
    Ok(())
}

#[test]
fn unbounded_channels_need_a_reason() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "queues",
        r#"
use tokio::sync::mpsc;

pub fn tokio_unbounded() { let _ = mpsc::unbounded_channel::<u8>(); }
pub fn tokio_bounded() { let _ = mpsc::channel::<u8>(8); }
pub fn std_unbounded() { let _ = std::sync::mpsc::channel::<u8>(); }
pub fn std_bounded() { let _ = std::sync::mpsc::sync_channel::<u8>(1); }
pub fn crossbeam() { let _ = crossbeam_channel::unbounded::<u8>(); }
pub fn allowed() {
    // unbounded-allow: one message per user action, drained each frame
    let _ = mpsc::unbounded_channel::<u8>();
}
"#,
    )?;
    let out = scan(&[fx.root()], &[Kind::Unbounded], None)?;
    assert_eq!(
        functions(&out.head.findings),
        set(&["tokio_unbounded", "std_unbounded", "crossbeam"]),
        "{:#?}",
        out.head.findings
    );
    assert_eq!(functions(&out.head.exempt), set(&["allowed"]));
    Ok(())
}

#[test]
fn test_code_is_skipped() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "tested",
        r#"
#[cfg(test)]
mod helpers;
#[cfg(all(test, unix))]
mod unix_tests { pub async fn t() { let _ = std::fs::read("a"); } }
#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn t() { tokio::spawn(async {}); }
}
#[test]
fn bare() { std::thread::spawn(|| {}); }
pub async fn shipped() { let _ = std::fs::read("a"); }
"#,
    )?
    .write("crates/tested/src/helpers.rs", "pub async fn h() { let _ = std::fs::read(\"a\"); }\n")?
    .write("crates/tested/src/more_tests.rs", "pub async fn h() { std::fs::read(\"a\"); }\n")?
    .write("crates/tested/tests/it.rs", "async fn h() { std::fs::read(\"a\"); }\n")?
    .write("crates/tested/benches/b.rs", "async fn h() { std::fs::read(\"a\"); }\n")?;
    let out = scan(&[fx.root()], &[], None)?;
    assert_eq!(hits(&out.head.findings), [("call".to_string(), "shipped".to_string())]);
    assert_eq!(out.head.files, 1);
    Ok(())
}

#[test]
fn several_roots_and_crate_names() -> TestResult {
    let one = Fixture::new()?;
    one.krate("first", "pub fn f() { tokio::spawn(async {}); }\n")?;
    let two = Fixture::new()?;
    two.krate("second", "pub fn f() { tokio::spawn(async {}); }\n")?;
    let out = scan(&[one.root(), two.root()], &[Kind::Spawn], None)?;
    let crates: Vec<&str> = out.head.findings.iter().map(|f| f.krate.as_str()).collect();
    assert_eq!(crates, ["first", "second"]);
    assert_eq!(out.head.files, 2);
    Ok(())
}

#[test]
fn a_file_that_does_not_parse_is_reported() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate("broken", "pub fn f( {\n")?;
    let out = scan(&[fx.root()], &[], None)?;
    assert_eq!(out.head.parse_errors.len(), 1);
    assert!(out.head.parse_errors[0].file.ends_with("broken/src/lib.rs"));
    Ok(())
}

fn git(dir: &Path, args: &[&str]) -> TestResult {
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .status()?;
    if status.success() { Ok(()) } else { Err(format!("git {args:?}: {status}").into()) }
}

#[test]
fn diff_reports_only_findings_new_since_the_base() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate("moving", "pub fn old() { tokio::spawn(async {}); }\n")?;
    git(&fx.dir, &["init", "-q"])?;
    git(&fx.dir, &["add", "-A"])?;
    git(&fx.dir, &["commit", "-q", "-m", "base"])?;
    // The old finding moves down two lines; a new one appears.
    fx.krate(
        "moving",
        "\n\npub fn old() { tokio::spawn(async {}); }\npub fn new() { let _ = mpsc_unbounded(); tokio::spawn(async {}); }\nfn mpsc_unbounded() {}\n",
    )?;
    let out = scan(&[fx.root()], &[], Some("HEAD"))?;
    assert_eq!(out.base_findings, Some(1));
    assert_eq!(out.head.findings.len(), 2);
    assert_eq!(hits(out.reported()), [("dropped-handle".to_string(), "new".to_string())]);
    Ok(())
}

#[test]
fn diff_works_when_the_root_is_the_git_top_level() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate("top", "pub fn old() { tokio::spawn(async {}); }\n")?;
    let root = fx.root();
    git(&root, &["init", "-q"])?;
    git(&root, &["add", "-A"])?;
    git(&root, &["commit", "-q", "-m", "base"])?;
    fx.krate(
        "top",
        "pub fn old() { tokio::spawn(async {}); }\npub fn new() { tokio::spawn(async {}); }\n",
    )?;
    let out = scan(&[root], &[], Some("HEAD"))?;
    assert_eq!(out.base_findings, Some(1));
    assert_eq!(hits(out.reported()), [("dropped-handle".to_string(), "new".to_string())]);
    Ok(())
}

#[test]
fn cmux_blocking_wrappers_offload_and_count_as_spawns() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "wrapped",
        r#"
use std::path::PathBuf;
use cmux_threads::blocking;

pub async fn spawn_blocking(p: PathBuf) -> Vec<u8> {
    cmux_blocking::spawn_blocking(move || std::fs::read(&p).unwrap()).await.unwrap()
}
pub async fn scoped(p: PathBuf) -> Vec<u8> {
    cmux_blocking::scoped_blocking_call("read", kind(), || std::fs::read(&p).unwrap())
}
pub async fn threads_scoped(p: PathBuf) -> Vec<u8> {
    cmux_threads::scoped_blocking_call(kind(), || std::fs::read(&p).unwrap())
}
pub async fn threads_blocking_module(p: PathBuf) -> Vec<u8> {
    blocking::scoped_blocking_call(kind(), || std::fs::read(&p).unwrap())
}
pub async fn with_stack() {
    let _h = cmux_threads::spawn_with_stack("n", q(), 1, || {
        std::thread::sleep(std::time::Duration::from_millis(1));
    });
}
pub async fn dropped_wrapper() { cmux_blocking::spawn_blocking(|| {}); }
fn kind() {}
fn q() {}
"#,
    )?;
    let blocking = scan(&[fx.root()], &[Kind::Blocking], None)?;
    assert!(blocking.head.findings.is_empty(), "{:#?}", blocking.head.findings);
    let spawn = scan(&[fx.root()], &[Kind::Spawn], None)?;
    assert_eq!(
        hits(&spawn.head.findings),
        [
            ("thread".to_string(), "with_stack".to_string()),
            ("dropped-handle".to_string(), "dropped_wrapper".to_string()),
        ],
        "{:#?}",
        spawn.head.findings
    );
    Ok(())
}

#[test]
fn handles_bound_through_ok_and_some_patterns_are_followed() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "handles",
        r#"
use tokio::runtime::Handle;

pub fn let_else() {
    let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
    rt.spawn(async {});
}
pub fn if_let() {
    if let Ok(rt) = Handle::try_current() {
        rt.spawn(async {});
    }
}
pub fn while_let() {
    while let Ok(rt) = Handle::try_current() {
        rt.spawn(async {});
    }
}
pub fn kept() -> Option<tokio::task::JoinHandle<()>> {
    let Ok(rt) = Handle::try_current() else { return None };
    Some(rt.spawn(async {}))
}
"#,
    )?;
    let out = scan(&[fx.root()], &[Kind::Spawn], None)?;
    assert_eq!(
        functions(&out.head.findings),
        set(&["let_else", "if_let", "while_let"]),
        "{:#?}",
        out.head.findings
    );
    Ok(())
}

#[test]
fn lock_futures_and_multi_line_guard_allow_comments() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "guards",
        r#"
use std::sync::Mutex;

async fn tick() {}

pub struct S { state: Mutex<u8> }

pub async fn timeout_lock(m: &tokio::sync::Mutex<u8>, d: std::time::Duration) {
    let Ok(g) = tokio::time::timeout(d, m.lock()).await else { return };
    tick().await;
    let _ = *g;
}
pub async fn joined(a: &tokio::sync::Mutex<u8>, b: &tokio::sync::Mutex<u8>) {
    let (_x, _y) = tokio::join!(a.lock(), b.lock());
    tick().await;
}
impl S {
    pub async fn multi_line(&self) {
        // blocking-allow: the fixture's multi-line guard
        let g = self
            .state
            .lock()
            .unwrap();
        tick().await;
        let _ = *g;
    }
    pub async fn nested_under_outer_allow(&self, on: bool) {
        // blocking-allow: covers only the if statement's own line
        if on {
            let g = self.state.lock().unwrap();
            tick().await;
            let _ = *g;
        }
    }
}
"#,
    )?;
    let out = scan(&[fx.root()], &[Kind::Blocking], None)?;
    assert_eq!(
        hits(&out.head.findings),
        [("lock-over-await".to_string(), "S::nested_under_outer_allow".to_string())],
        "{:#?}",
        out.head.findings
    );
    let exempt: Vec<_> =
        out.head.exempt.iter().map(|f| (f.function.as_str(), f.exempt.as_deref())).collect();
    assert_eq!(exempt, [("S::multi_line", Some("the fixture's multi-line guard"))]);
    Ok(())
}

#[test]
fn the_binary_prints_json_with_queue_counts() -> TestResult {
    let fx = Fixture::new()?;
    fx.krate(
        "cli",
        "pub async fn f() { let _ = std::fs::read(\"a\"); tokio::spawn(async {}); }\n",
    )?;
    let output = Command::new(env!("CARGO_BIN_EXE_async-blocking-scan"))
        .arg("--root")
        .arg(fx.root())
        .args(["--json", "--check"])
        .output()?;
    assert_eq!(output.status.code(), Some(1), "{}", String::from_utf8_lossy(&output.stderr));
    let report: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(report["queues"]["Q11"], 1);
    assert_eq!(report["queues"]["Q12"], 1);
    assert_eq!(report["queues"]["Q20"], 0);
    assert_eq!(report["counts"]["blocking"], 1);
    assert_eq!(report["by_crate"]["cli"]["spawn"], 1);
    assert_eq!(report["findings"].as_array().map(Vec::len), Some(2));
    let text = Command::new(env!("CARGO_BIN_EXE_async-blocking-scan"))
        .arg("--root")
        .arg(fx.root())
        .args(["--kind", "pre_exec,child,unbounded"])
        .output()?;
    assert_eq!(text.status.code(), Some(0));
    let stdout = String::from_utf8(text.stdout)?;
    assert!(stdout.contains("Q20: 0 (pre_exec 0, child 0, unbounded 0)"), "{stdout}");
    Ok(())
}
