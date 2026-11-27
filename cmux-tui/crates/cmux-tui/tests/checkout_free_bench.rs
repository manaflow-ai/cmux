//! One small-PR task in each tier a chat can get (crate `cmux-no-checkout`, `tier::choose`): edit
//! one file of a GitHub repository, run one targeted test, then make the commit and the pull
//! request. Leo, 2026-11-17: "what other assistants do ... they don't fetch the entire
//! repository. They just do it all through the GitHub MCP connection".
//!
//! Same host, same repository, same edit, same test, same write for all three:
//!
//! - **no-checkout**: `Remote` reads the branch, the tree and the files it needs from GitHub's
//!   API; the test's paths alone are projected into a temporary folder, deleted after.
//! - **projection**: the repository is a folder on "the Mac" (cloned before the clock starts: it
//!   is the person's own folder); the real `cmux-tui link project serve` sends its manifest to a
//!   machine running the real `projection-v1` server over a link that delays every byte by
//!   [`RTT`]/2 each way, the machine mounts it (FUSE), and the edit and the test run in the mount.
//! - **checkout**: `git clone` from GitHub, then the edit and the test in the clone.
//!
//! The write is the same in all three: the edited file as a commit through the git data API on a
//! new branch, and a pull request. With `GH_TOKEN` and `CMUX_TIER_BENCH_WRITE_REPO` (a throwaway
//! repository holding the same file) it goes to GitHub and the bench closes the pull request and
//! deletes the branch after; without them it goes to the `mock` stand-in, which counts the same
//! request and answer bytes.
//!
//! Measured per tier: time to first edit (from the chat's start to the edited file written), bytes
//! moved over the network (every byte to and from GitHub, counted at a CONNECT proxy the API
//! client and git both go through, plus every byte over the Mac's link, plus the write), and the
//! disk the chat leaves behind on the machine when it ends.
//!
//!     CMUX_TUI_STATE_DIR=$(mktemp -d) CMUX_TIER_BENCH_PYTHON=/path/to/python-with-pytest \
//!       cargo test -p cmux-tui --test checkout_free_bench -- --ignored --nocapture
#![cfg(target_os = "linux")]

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_no_checkout::mock::Mock;
use cmux_no_checkout::{GitHub, Remote};
use cmux_tui_core::fs_ops::{self, FsService, Roots, stream};
use serde_json::{Value, json};
use zeroize::Zeroizing;

/// The Mac's link: about Leo's round trip to a Cloud machine (RFD 0007's bench).
const RTT: Duration = Duration::from_millis(50);

fn env(key: &str, default: &str) -> String {
    std::env::var(key).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| default.to_owned())
}

/// The task, from the env (defaults: a mid-size Python repository and one of its test files).
struct Job {
    repo: String,
    branch: String,
    edit: String,
    paths: Vec<String>,
    test: Vec<String>,
    python: String,
}

fn job() -> Job {
    Job {
        repo: env("CMUX_TIER_BENCH_REPO", "pallets/click"),
        branch: env("CMUX_TIER_BENCH_REF", "main"),
        edit: env("CMUX_TIER_BENCH_EDIT", "src/click/utils.py"),
        paths: env(
            "CMUX_TIER_BENCH_PATHS",
            "src/click,tests/conftest.py,tests/test_utils,pyproject.toml",
        )
        .split(',')
        .map(str::to_owned)
        .collect(),
        test: env("CMUX_TIER_BENCH_TEST", "-m pytest -q -p no:cacheprovider tests/test_utils")
            .split_whitespace()
            .map(str::to_owned)
            .collect(),
        python: env("CMUX_TIER_BENCH_PYTHON", "python3"),
    }
}

/// The edit: one line added at the end of the file.
fn edited(bytes: &[u8]) -> Vec<u8> {
    let mut out = bytes.to_vec();
    out.extend_from_slice(b"\n# Edited by the checkout-free chats bench.\n");
    out
}

/// An HTTP CONNECT proxy on loopback that counts every byte each way.
fn counting_proxy(counted: Arc<AtomicU64>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for client in listener.incoming().flatten() {
            let counted = Arc::clone(&counted);
            std::thread::spawn(move || tunnel(client, &counted));
        }
    });
    url
}

fn tunnel(client: TcpStream, counted: &Arc<AtomicU64>) {
    let mut reader = BufReader::new(client.try_clone().unwrap());
    let mut first = String::new();
    if reader.read_line(&mut first).is_err() {
        return;
    }
    let mut header = String::new();
    while reader.read_line(&mut header).is_ok_and(|n| n > 2) {
        header.clear();
    }
    let Some(target) = first.split_whitespace().nth(1).map(str::to_owned) else { return };
    let Ok(upstream) = TcpStream::connect(&target) else { return };
    let mut client_w = client.try_clone().unwrap();
    let _ = client_w.write_all(b"HTTP/1.1 200 Connection established\r\n\r\n");
    let pump =
        |mut from: Box<dyn std::io::Read + Send>, mut to: TcpStream, counted: Arc<AtomicU64>| {
            std::thread::spawn(move || {
                let mut buffer = vec![0u8; 64 * 1024];
                while let Ok(n) = from.read(&mut buffer) {
                    if n == 0 || to.write_all(&buffer[..n]).is_err() {
                        break;
                    }
                    counted.fetch_add(n as u64, Ordering::Relaxed);
                }
                let _ = to.shutdown(std::net::Shutdown::Write);
            })
        };
    // What the client sent after the CONNECT head (TLS), then the rest of its stream.
    let leftover = reader.buffer().to_vec();
    let mut up = upstream.try_clone().unwrap();
    counted.fetch_add(leftover.len() as u64, Ordering::Relaxed);
    let _ = up.write_all(&leftover);
    let a = pump(Box::new(client), upstream.try_clone().unwrap(), Arc::clone(counted));
    let b = pump(Box::new(upstream), client_w, Arc::clone(counted));
    let _ = (a.join(), b.join());
}

/// Copies `from` to `to`, each read arriving `RTT`/2 after it left, counting every byte.
fn delayed(mut from: UnixStream, mut to: UnixStream, counted: Arc<AtomicU64>) {
    let (due, arrivals) = std::sync::mpsc::channel::<(Instant, Vec<u8>)>();
    std::thread::spawn(move || {
        for (at, bytes) in arrivals {
            std::thread::sleep(at.saturating_duration_since(Instant::now()));
            if to.write_all(&bytes).is_err() {
                break;
            }
        }
        let _ = to.shutdown(std::net::Shutdown::Write);
    });
    std::thread::spawn(move || {
        let mut buffer = vec![0u8; 256 * 1024];
        loop {
            match from.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(read) => {
                    counted.fetch_add(read as u64, Ordering::Relaxed);
                    if due.send((Instant::now() + RTT / 2, buffer[..read].to_vec())).is_err() {
                        return;
                    }
                }
            }
        }
    });
}

/// A Cloud machine on `socket` serving `home` (as `tests/link_project.rs`'s): every connection
/// crosses the delayed, counted link; a dial whose first line is `projection.serve` is served by
/// the daemon's projection, any other by its `fs-v1` lines.
fn machine(socket: &Path, home: &Path, counted: &Arc<AtomicU64>) {
    let listener = UnixListener::bind(socket).unwrap();
    let home = home.to_path_buf();
    let counted = Arc::clone(counted);
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.clone()]))));
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            let (near, far) = UnixStream::pair().unwrap();
            delayed(
                connection.try_clone().unwrap(),
                near.try_clone().unwrap(),
                Arc::clone(&counted),
            );
            delayed(near, connection, Arc::clone(&counted));
            let home = home.clone();
            std::thread::spawn(move || serve(far, service, &home));
        }
    });
}

fn serve(connection: UnixStream, service: &FsService, home: &Path) {
    let mut writer = connection.try_clone().unwrap();
    let mut reader = BufReader::new(connection.try_clone().unwrap());
    let mut first = true;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        if first && cmux_tui_core::projection::frame_command(&line).is_some() {
            let leftover = reader.buffer().to_vec();
            cmux_tui_core::projection::serve(
                &connection,
                line.trim_end(),
                leftover,
                &[home.to_path_buf()],
            );
            return;
        }
        first = false;
        let request: Value = serde_json::from_str(&line).unwrap();
        let id = request["id"].clone();
        let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
        let reply = if cmd == "identify" {
            json!({"id": id, "ok": true, "data": {"capabilities": [
                fs_ops::FS_CAPABILITY, cmux_tui_core::projection::PROJECTION_CAPABILITY,
            ]}})
        } else {
            stream::answer(&id, service.call("local", &cmd, request))
        };
        let mut text = reply.to_string();
        text.push('\n');
        if writer.write_all(text.as_bytes()).is_err() {
            return;
        }
    }
}

/// Disk used under `path` (allocated blocks, as `du`), 0 when it is gone.
fn disk(path: &Path) -> u64 {
    use std::os::unix::fs::MetadataExt as _;
    let Ok(meta) = std::fs::symlink_metadata(path) else { return 0 };
    let mut total = meta.blocks() * 512;
    if meta.is_dir() {
        for entry in std::fs::read_dir(path).into_iter().flatten().flatten() {
            total += disk(&entry.path());
        }
    }
    total
}

/// The targeted test in `dir`; panics when it fails (a row is only a row if the test passed).
fn test(job: &Job, dir: &Path) -> Duration {
    let started = Instant::now();
    let out = Command::new(&job.python)
        .args(&job.test)
        .current_dir(dir)
        .env("PYTHONPATH", dir.join("src"))
        .env("PYTHONDONTWRITEBYTECODE", "1")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "the test failed in {}:\n{}{}",
        dir.display(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    started.elapsed()
}

/// Where the write goes: GitHub (a throwaway repository) or the stand-in.
enum Sink {
    GitHub { repo: String, token: String },
    Mock,
}

fn sink() -> Sink {
    match (std::env::var("GH_TOKEN"), std::env::var("CMUX_TIER_BENCH_WRITE_REPO")) {
        (Ok(token), Ok(repo)) if !token.is_empty() && !repo.is_empty() => {
            Sink::GitHub { repo, token }
        }
        _ => Sink::Mock,
    }
}

/// The commit and the pull request for `bytes` at `job.edit`; answers the bytes it moved.
async fn write(
    job: &Job,
    base: &[u8],
    bytes: Vec<u8>,
    tier: &str,
    proxy: (&str, &AtomicU64),
) -> (u64, String) {
    let (proxy, counted) = proxy;
    let branch = format!("lane/tier-bench-{tier}-{}", std::process::id());
    match sink() {
        Sink::Mock => {
            let mock =
                Mock::start(&job.repo, &[(job.edit.as_str(), base, "100644")]).await.unwrap();
            let gh = GitHub::new(&mock.url, &mock.repo, None, None).unwrap();
            let mut remote = Remote::open(gh, None).await.unwrap();
            remote.write(&job.edit, bytes).await.unwrap();
            remote.commit(&branch, "Edit one file (tier bench)").await.unwrap();
            let pull =
                remote.github().open_pull("Tier bench", "", &branch, "main", true).await.unwrap();
            assert_eq!(mock.branch(&branch).unwrap()[&job.edit].0, edited(base));
            let moved = mock.bytes_up() + mock.bytes_down();
            mock.close().await;
            (moved, pull.url)
        }
        Sink::GitHub { repo, token } => {
            let before = counted.load(Ordering::Relaxed);
            let gh =
                GitHub::new(github_api(), &repo, Some(Zeroizing::new(token)), Some(proxy)).unwrap();
            let mut remote = Remote::open(gh, None).await.unwrap();
            let base_branch = remote.branch().to_owned();
            remote.write(&job.edit, bytes).await.unwrap();
            remote.commit(&branch, "Edit one file (tier bench)").await.unwrap();
            let gh = remote.github().clone();
            let pull = gh
                .open_pull("Tier bench (throwaway)", "", &branch, &base_branch, true)
                .await
                .unwrap();
            let moved = counted.load(Ordering::Relaxed) - before;
            // Throwaway: closed and deleted at once.
            gh.close_pull(pull.number).await.unwrap();
            gh.delete_branch(&branch).await.unwrap();
            (moved, pull.url)
        }
    }
}

fn github_api() -> &'static str {
    cmux_no_checkout::github::GITHUB_API
}

fn token() -> cmux_no_checkout::Token {
    std::env::var("CMUX_TIER_BENCH_READ_TOKEN").ok().filter(|t| !t.is_empty()).map(Zeroizing::new)
}

struct Row {
    tier: &'static str,
    first_edit: Duration,
    test: Duration,
    total: Duration,
    network: u64,
    write: u64,
    left: u64,
    pull: String,
}

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && Command::new("fusermount3").arg("-V").output().is_ok_and(|out| out.status.success())
}

fn git(dir: &Path, args: &[&str], proxy: Option<&str>) {
    let mut command = Command::new("git");
    command.arg("-C").arg(dir).args(args).stdout(Stdio::null());
    command.env_remove("HTTPS_PROXY").env_remove("https_proxy");
    if let Some(proxy) = proxy {
        command.env("https_proxy", proxy).env("HTTPS_PROXY", proxy);
    }
    let out = command.output().unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

async fn no_checkout(job: &Job, proxy: &str, counted: &AtomicU64) -> Row {
    let before = counted.load(Ordering::Relaxed);
    let started = Instant::now();
    let gh = GitHub::new(github_api(), &job.repo, token(), Some(proxy)).unwrap();
    let mut remote = Remote::open(gh, Some(&job.branch)).await.unwrap();
    let base = remote.read(&job.edit).await.unwrap();
    remote.write(&job.edit, edited(&base)).await.unwrap();
    let first_edit = started.elapsed();
    let projected = remote.project(&job.paths).await.unwrap();
    let root = projected.path().to_owned();
    let test = test(job, &root);
    projected.close().unwrap();
    let network = counted.load(Ordering::Relaxed) - before;
    let (write, pull) = write(job, &base, edited(&base), "no-checkout", (proxy, counted)).await;
    Row {
        tier: "no-checkout",
        first_edit,
        test,
        total: started.elapsed(),
        network,
        write,
        left: disk(&root),
        pull,
    }
}

async fn projection(job: &Job, proxy: &str, counted: &AtomicU64, scratch: &Path) -> Row {
    // The person's folder, on "the Mac" before the chat starts: not counted.
    let mac = scratch.join("mac");
    std::fs::create_dir_all(&mac).unwrap();
    let url = format!("https://github.com/{}", job.repo);
    git(&mac, &["clone", "-q", "--branch", &job.branch, &url, "repo"], None);
    let folder = mac.join("repo");
    let home = scratch.join("machine-home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("tb").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("m.sock");
    let link = Arc::new(AtomicU64::new(0));
    machine(&socket, &home, &link);
    let at = home.join("work/repo");

    let started = Instant::now();
    let mut server = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", scratch.join("mac-state"))
        .args(["link", "project", "serve", "--any-size", "--socket"])
        .arg(&socket)
        .arg("--at")
        .arg(&at)
        .arg(&folder)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(server.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let answer: Value = serde_json::from_str(line.trim()).unwrap();
    assert_eq!(answer["ok"], true, "{answer}");
    let base = std::fs::read(at.join(&job.edit)).unwrap();
    std::fs::write(at.join(&job.edit), edited(&base)).unwrap();
    let first_edit = started.elapsed();
    let test = test(job, &at);
    let bytes = std::fs::read(at.join(&job.edit)).unwrap();
    let network = link.load(Ordering::Relaxed);
    let (write, pull) = write(job, &base, bytes, "projection", (proxy, counted)).await;
    let total = started.elapsed();
    // The chat ends: the folder's server (ours) stops and the mount goes.
    let _ = server.kill();
    let _ = server.wait();
    let _ = Command::new("fusermount3").args(["-u", "-z"]).arg(&at).status();
    let state = PathBuf::from(std::env::var("CMUX_TUI_STATE_DIR").unwrap()).join("projections");
    Row {
        tier: "projection",
        first_edit,
        test,
        total,
        network,
        write,
        left: disk(&state) + disk(&at),
        pull,
    }
}

async fn checkout(job: &Job, proxy: &str, counted: &AtomicU64, scratch: &Path) -> Row {
    let work = scratch.join("checkout");
    std::fs::create_dir_all(&work).unwrap();
    let before = counted.load(Ordering::Relaxed);
    let started = Instant::now();
    let url = format!("https://github.com/{}", job.repo);
    git(&work, &["clone", "-q", "--branch", &job.branch, &url, "repo"], Some(proxy));
    let repo = work.join("repo");
    let base = std::fs::read(repo.join(&job.edit)).unwrap();
    std::fs::write(repo.join(&job.edit), edited(&base)).unwrap();
    let first_edit = started.elapsed();
    let test = test(job, &repo);
    let network = counted.load(Ordering::Relaxed) - before;
    let (write, pull) = write(job, &base, edited(&base), "checkout", (proxy, counted)).await;
    Row {
        tier: "checkout",
        first_edit,
        test,
        total: started.elapsed(),
        network,
        write,
        left: disk(&work),
        pull,
    }
}

fn mb(bytes: u64) -> String {
    if bytes < 1_000_000 {
        format!("{:.1} kB", bytes as f64 / 1e3)
    } else {
        format!("{:.1} MB", bytes as f64 / 1e6)
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "a bench over the network: CMUX_TUI_STATE_DIR=$(mktemp -d) cargo test -p cmux-tui --test checkout_free_bench -- --ignored --nocapture"]
async fn one_small_pr_in_each_tier() {
    assert!(fuse_here(), "the projection row needs FUSE (/dev/fuse and fusermount3)");
    assert!(
        std::env::var("CMUX_TUI_STATE_DIR").is_ok_and(|v| !v.is_empty()),
        "set CMUX_TUI_STATE_DIR to an empty folder: the machine's projection state goes there"
    );
    let job = job();
    let counted = Arc::new(AtomicU64::new(0));
    let proxy = counting_proxy(Arc::clone(&counted));
    let scratch = tempfile::tempdir().unwrap();
    let rows = vec![
        no_checkout(&job, &proxy, &counted).await,
        projection(&job, &proxy, &counted, scratch.path()).await,
        checkout(&job, &proxy, &counted, scratch.path()).await,
    ];
    println!(
        "repo {} @ {}, edit {}, test `{}`",
        job.repo,
        job.branch,
        job.edit,
        job.test.join(" ")
    );
    println!("| tier | time to first edit | bytes moved | disk left behind | test | total |");
    println!("|---|---|---|---|---|---|");
    for r in &rows {
        println!(
            "| {} | {} ms | {} ({} read + {} write) | {} | {} ms | {} ms |",
            r.tier,
            r.first_edit.as_millis(),
            mb(r.network + r.write),
            mb(r.network),
            mb(r.write),
            mb(r.left),
            r.test.as_millis(),
            r.total.as_millis()
        );
    }
    for r in &rows {
        println!(
            "{}",
            json!({"tier": r.tier, "first_edit_ms": r.first_edit.as_millis(), "test_ms": r.test.as_millis(),
                   "total_ms": r.total.as_millis(), "network_bytes": r.network, "write_bytes": r.write,
                   "left_bytes": r.left, "pull": r.pull,
                   "write_to": match sink() { Sink::Mock => "mock", Sink::GitHub { .. } => "github" }})
        );
    }
    assert_eq!(rows[0].left, 0, "no-checkout leaves nothing behind");
}
