//! `cmux link sync push` to a real Cloud-shaped daemon through a link-like
//! proxy that limits the rate and adds latency, measuring wall time and the
//! bytes on the wire. The benchmark is `#[ignore]`: run it with
//!
//! ```text
//! cargo test -p cmux-tui --test link_push_bench -- --ignored --nocapture
//! ```
//!
//! It prints one JSON line (`{"bench":"link_push",...}`). The fixture and
//! the link are tunable: `CMUX_BENCH_FILES` (source files, 3000),
//! `CMUX_BENCH_BLOB_MB` (random binary blobs committed as loose objects,
//! 160 MiB; the packed source history makes up the rest of the .git),
//! `CMUX_BENCH_RATE_MBPS` (MB/s each way, 8) and `CMUX_BENCH_LATENCY_MS`
//! (one-way delay, 30). The client is whatever this build's push does, so
//! the same file measures any change to it.
//!
//! The daemon is a headless cmux-tui with the Cloud model-plane identity
//! (`journey_support`), so it serves `fs-v1` on its own socket; the push
//! dials the proxy's socket, one link connection per local connection, as
//! the Cloud link's local socket does. Linux only, as a Cloud host is.
#![cfg(target_os = "linux")]

mod journey_support;

use std::collections::VecDeque;
use std::fs;
use std::io::{Read as _, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

fn env_number(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|value| value.parse().ok()).unwrap_or(default)
}

/// The link's shape: bytes per second each way and one-way latency.
#[derive(Clone, Copy)]
struct Link {
    rate: u64,
    latency: Duration,
}

/// Bytes the proxy moved each way.
#[derive(Default)]
struct Wire {
    up: AtomicU64,
    down: AtomicU64,
}

/// The chunks a pipe holds, each with the time it may leave, and whether
/// the source has ended (the writer then shuts its side down).
type PipeQueue = (VecDeque<(Instant, Vec<u8>)>, bool);

/// One direction of a proxied connection: chunks wait out the latency,
/// then leave no faster than the rate.
struct Pipe {
    queue: Mutex<PipeQueue>,
    ready: Condvar,
}

fn pump(mut from: UnixStream, mut to: UnixStream, link: Link, counted: Arc<Wire>, up: bool) {
    let pipe =
        Arc::new(Pipe { queue: Mutex::new((VecDeque::new(), false)), ready: Condvar::new() });
    let writer = {
        let pipe = pipe.clone();
        std::thread::spawn(move || {
            // When the link is free to send again: each chunk takes
            // `len / rate` on it, after the chunk before (an idle link
            // earns no burst).
            let mut free_at = Instant::now();
            loop {
                let (due, chunk) = {
                    let mut queue = pipe.queue.lock().unwrap();
                    loop {
                        if let Some(item) = queue.0.pop_front() {
                            break item;
                        }
                        if queue.1 {
                            let _ = to.shutdown(std::net::Shutdown::Write);
                            return;
                        }
                        queue = pipe.ready.wait(queue).unwrap();
                    }
                };
                if let Some(wait) = due.checked_duration_since(Instant::now()) {
                    std::thread::sleep(wait);
                }
                let busy = Duration::from_secs_f64(chunk.len() as f64 / link.rate as f64);
                free_at = free_at.max(Instant::now()) + busy;
                if let Some(wait) = free_at.checked_duration_since(Instant::now()) {
                    std::thread::sleep(wait);
                }
                if to.write_all(&chunk).is_err() {
                    return;
                }
                let total = if up { &counted.up } else { &counted.down };
                total.fetch_add(chunk.len() as u64, Ordering::Relaxed);
            }
        })
    };
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let read = match from.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(read) => read,
        };
        let mut queue = pipe.queue.lock().unwrap();
        queue.0.push_back((Instant::now() + link.latency, buffer[..read].to_vec()));
        pipe.ready.notify_one();
    }
    pipe.queue.lock().unwrap().1 = true;
    pipe.ready.notify_one();
    let _ = writer.join();
}

/// Serves `listen`, dialing `target` for each connection through `link`.
fn proxy(listen: &Path, target: PathBuf, link: Link) -> Arc<Wire> {
    let listener = UnixListener::bind(listen).unwrap();
    let wire = Arc::new(Wire::default());
    let counted = wire.clone();
    std::thread::spawn(move || {
        for client in listener.incoming() {
            let Ok(client) = client else { return };
            let Ok(daemon) = UnixStream::connect(&target) else { continue };
            let (up_from, up_to) = (client.try_clone().unwrap(), daemon.try_clone().unwrap());
            let counted_up = counted.clone();
            std::thread::spawn(move || pump(up_from, up_to, link, counted_up, true));
            let counted_down = counted.clone();
            std::thread::spawn(move || pump(daemon, client, link, counted_down, false));
        }
    });
    wire
}

/// A deterministic byte source (xorshift), so every run builds the same tree.
struct Noise(u64);

impl Noise {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn fill(&mut self, out: &mut [u8]) {
        for chunk in out.chunks_mut(8) {
            let bytes = self.next().to_le_bytes();
            chunk.copy_from_slice(&bytes[..chunk.len()]);
        }
    }
}

/// About 8 KiB of source-like text: varied identifiers and numbers in
/// repeated shapes, which compresses like real code (about 4x).
fn source_text(noise: &mut Noise, index: usize) -> String {
    const WORDS: [&str; 16] = [
        "value", "index", "buffer", "request", "answer", "socket", "parent", "entry", "machine",
        "folder", "revision", "listing", "budget", "progress", "manifest", "summary",
    ];
    let mut text = format!("//! Module {index}.\n\nuse std::collections::BTreeMap;\n\n");
    while text.len() < 8 * 1024 {
        let a = WORDS[(noise.next() % 16) as usize];
        let b = WORDS[(noise.next() % 16) as usize];
        let n = noise.next() % 10_000;
        text.push_str(&format!(
            "pub fn {a}_{b}_{n}(input: &[u8]) -> Option<usize> {{\n    let {a} = input.len() + {n};\n    \
             if {a} > {} {{ return None; }}\n    Some({a} * 2)\n}}\n\n",
            noise.next() % 1000
        ));
    }
    text
}

/// A working copy with `files` source files committed and packed, then
/// `blob_mb` MiB of random binary blobs over several commits left loose,
/// and a few uncommitted files (one of them random bytes).
fn fixture(at: &Path, files: usize, blob_mb: usize) -> PathBuf {
    let repo = at.join("app");
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    let mut noise = Noise(0x9e37_79b9_7f4a_7c15);
    for index in 0..files {
        let folder = repo.join(format!("src/m{:02}", index % 60));
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join(format!("f{index}.rs")), source_text(&mut noise, index)).unwrap();
    }
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "sources"]);
    git(&repo, &["repack", "-adq"]);
    let blobs = blob_mb.div_ceil(8);
    for commit in 0..blobs {
        let mut blob = vec![0u8; (blob_mb << 20) / blobs];
        noise.fill(&mut blob);
        fs::create_dir_all(repo.join("assets")).unwrap();
        fs::write(repo.join(format!("assets/blob{commit}.bin")), &blob).unwrap();
        let edited = repo.join(format!("src/m00/f{}.rs", commit * 60 % files.max(1)));
        let mut text = fs::read_to_string(&edited).unwrap_or_default();
        text.push_str(&format!("// edit {commit}\n"));
        fs::write(&edited, text).unwrap();
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-q", "-m", &format!("blob {commit}")]);
    }
    fs::write(repo.join("NOTES.md"), "uncommitted notes\n".repeat(100)).unwrap();
    let mut scratch = vec![0u8; 256 * 1024];
    noise.fill(&mut scratch);
    fs::write(repo.join("scratch.bin"), scratch).unwrap();
    repo
}

/// Bytes and files under `path`.
fn tree_size(path: &Path) -> (u64, u64) {
    let mut total = (0, 0);
    for entry in fs::read_dir(path).unwrap() {
        let entry = entry.unwrap();
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            let (bytes, files) = tree_size(&entry.path());
            total = (total.0 + bytes, total.1 + files);
        } else if kind.is_file() {
            total = (total.0 + entry.metadata().unwrap().len(), total.1 + 1);
        }
    }
    total
}

/// The VM: a daemon that serves `fs-v1` on its socket.
fn cloud_vm(root: &Path) -> Machine {
    Machine::start(
        root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-link-push-bench".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    )
}

fn scratch(label: &str) -> (PathBuf, Cleanup) {
    // A socket path must stay under SUN_LEN: a short folder under /tmp.
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("{label}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    (root.clone(), Cleanup(root))
}

/// Pushes `repo` to the VM's `~/work/app` through `link`; the summary, the
/// wall time and the wire counts.
fn push_through(
    root: &Path,
    vm: &Machine,
    repo: &Path,
    link: Link,
) -> (Value, Duration, Arc<Wire>) {
    let proxied = root.join("link.sock");
    let wire = proxy(&proxied, vm.socket.clone(), link);
    let started = Instant::now();
    let (ok, summary) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", root.join("mac-state"))
            .args(["link", "sync", "push", "--socket"])
            .arg(&proxied)
            .arg(repo)
            .arg(vm.home().join("work/app")),
    );
    let wall = started.elapsed();
    assert!(ok && summary["ok"] == json!(true), "sync push: {summary}");
    (summary, wall, wire)
}

fn advertises_deflate(vm: &Machine) -> bool {
    let identity = vm.rpc(json!({"id": 1, "cmd": "identify"}));
    identity["data"]["capabilities"]
        .as_array()
        .is_some_and(|served| served.iter().any(|name| name == "fs-write-deflate-v1"))
}

/// A real daemon takes the push compressed: the source files cross in far
/// fewer bytes than they hold, and land byte for byte with their bits.
#[test]
fn a_push_to_a_cloud_daemon_crosses_compressed_and_lands_exact() {
    use std::os::unix::fs::PermissionsExt as _;
    let (root, _cleanup) = scratch("lpb");
    let vm = cloud_vm(&root);
    assert!(advertises_deflate(&vm), "the Cloud daemon does not take deflate writes");
    let repo = fixture(&root.join("mac"), 200, 0);
    let script = repo.join("run.sh");
    fs::write(&script, "#!/bin/sh\necho hi\n".repeat(200)).unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    let link = Link { rate: 64 << 20, latency: Duration::ZERO };
    let (_, _, wire) = push_through(&root, &vm, &repo, link);
    let synced = vm.home().join("work/app");
    for relative in ["src/m03/f3.rs", "src/m00/f0.rs", "NOTES.md", "run.sh", "scratch.bin"] {
        assert!(
            fs::read(repo.join(relative)).unwrap() == fs::read(synced.join(relative)).unwrap(),
            "{relative} differs"
        );
    }
    let mode = fs::metadata(synced.join("run.sh")).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o755);
    let (text_bytes, _) = tree_size(&repo.join("src"));
    let (all_bytes, _) = tree_size(&repo);
    let up = wire.up.load(Ordering::Relaxed);
    // Base64 of everything would be 4/3 of it; the sources compress well
    // below their size, so the whole push crosses in less than it holds.
    assert!(up < all_bytes, "{up} wire bytes for {all_bytes} ({text_bytes} of sources)");
}

#[test]
#[ignore = "benchmark: run with --ignored --nocapture"]
fn link_push_bench() {
    let files = usize::try_from(env_number("CMUX_BENCH_FILES", 3000)).unwrap();
    let blob_mb = usize::try_from(env_number("CMUX_BENCH_BLOB_MB", 160)).unwrap();
    let link = Link {
        rate: env_number("CMUX_BENCH_RATE_MBPS", 8) * 1_000_000,
        latency: Duration::from_millis(env_number("CMUX_BENCH_LATENCY_MS", 30)),
    };
    let (root, _cleanup) = scratch("lpbb");
    let vm = cloud_vm(&root);
    let repo = fixture(&root.join("mac"), files, blob_mb);
    let (local_bytes, local_files) = tree_size(&repo);
    let (git_bytes, git_files) = tree_size(&repo.join(".git"));
    let (summary, wall, wire) = push_through(&root, &vm, &repo, link);
    let line = json!({
        "bench": "link_push",
        "rate_bytes_per_s": link.rate,
        "latency_ms": link.latency.as_millis() as u64,
        "local_files": local_files,
        "local_bytes": local_bytes,
        "git_files": git_files,
        "git_bytes": git_bytes,
        "written": summary["written"],
        "deflate_advertised": advertises_deflate(&vm),
        "wall_ms": wall.as_millis() as u64,
        "wire_up_bytes": wire.up.load(Ordering::Relaxed),
        "wire_down_bytes": wire.down.load(Ordering::Relaxed),
    });
    println!("{line}");
}

/// An origin shaped like GitHub for `repo`: every commit is on it, and a machine
/// clones from it (`CMUX_TEST_GIT_SEED_GITHUB`) as a Cloud VM clones from GitHub,
/// off this Mac's link.
fn publish(repo: &Path, github: &Path) {
    let bare = github.join("acme/app.git");
    fs::create_dir_all(&bare).unwrap();
    git(&bare, &["init", "-q", "--bare"]);
    git(&bare, &["config", "uploadpack.allowFilter", "true"]);
    git(repo, &["remote", "add", "origin", "https://github.com/acme/app.git"]);
    let local = format!("url.file://{}/.insteadOf", github.display());
    git(repo, &["config", &local, "https://github.com/"]);
    git(repo, &["-c", "protocol.file.allow=always", "push", "-q", "-u", "origin", "main"]);
}

/// A VM that serves `fs-v1` and seeds from the `github` origin.
fn seeding_vm(root: &Path, name: &str, github: &Path) -> Machine {
    Machine::start(
        root,
        name,
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(root).to_string_lossy().into_owned()),
            ("CMUX_TEST_GIT_SEED_GITHUB", github.to_string_lossy().into_owned()),
            ("CMUX_VM_ID", format!("vm-relay-bench-{name}")),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    )
}

/// Runs one `cmux link ...` as this Mac; its summary and wall time.
fn timed(root: &Path, args: &[&std::ffi::OsStr]) -> (Value, Duration) {
    let started = Instant::now();
    let (ok, summary) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", root.join("mac-state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .arg("link")
            .args(args),
    );
    let wall = started.elapsed();
    assert!(ok && summary["ok"] == json!(true), "{args:?}: {summary}");
    (summary, wall)
}

fn wire_total(wires: &[&Arc<Wire>]) -> u64 {
    wires.iter().map(|w| w.up.load(Ordering::Relaxed) + w.down.load(Ordering::Relaxed)).sum()
}

/// Every name, mode, link and byte under `folder`, `.git` included, as one number.
fn digest(folder: &Path) -> u64 {
    use std::hash::{Hash as _, Hasher as _};
    use std::os::unix::fs::PermissionsExt as _;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let mut stack = vec![folder.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let mut entries: Vec<_> = fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).collect();
        entries.sort();
        for path in entries {
            let meta = fs::symlink_metadata(&path).unwrap();
            path.strip_prefix(folder).unwrap().hash(&mut hasher);
            meta.permissions().mode().hash(&mut hasher);
            if meta.file_type().is_symlink() {
                fs::read_link(&path).unwrap().hash(&mut hasher);
            } else if meta.is_dir() {
                stack.push(path);
            } else {
                fs::read(&path).unwrap().hash(&mut hasher);
            }
        }
    }
    hasher.finish()
}

/// Move a chat's folder from one Cloud VM to another through the same two links (one per
/// machine, each `CMUX_BENCH_RATE_MBPS` each way with `CMUX_BENCH_LATENCY_MS`): before, Bring
/// Back Local (`seed pull --or-copy` into this Mac's folder) then Move to Cloud (`seed push`,
/// the machine cloning from the origin); after, `seed move`, git VM to VM with this Mac's
/// folder untouched (`seed_cli::hop`); and the file-by-file relay (`sync relay`) beside them.
/// Then a folder that started on VM one (its own clone, no folder of this Mac's): before, the
/// file-by-file relay it took; after, `seed move` with no Mac folder, git from its upstream.
/// Run with `cargo test -p cmux-tui --test link_push_bench link_relay_bench -- --ignored
/// --nocapture`; it prints one JSON line (`{"bench":"link_relay",...}`).
#[test]
#[ignore = "benchmark: run with --ignored --nocapture"]
fn link_relay_bench() {
    let files = usize::try_from(env_number("CMUX_BENCH_FILES", 3000)).unwrap();
    let blob_mb = usize::try_from(env_number("CMUX_BENCH_BLOB_MB", 160)).unwrap();
    let link = Link {
        rate: env_number("CMUX_BENCH_RATE_MBPS", 8) * 1_000_000,
        latency: Duration::from_millis(env_number("CMUX_BENCH_LATENCY_MS", 30)),
    };
    let (root, _cleanup) = scratch("lrb");
    let github = root.join("github");
    let one = seeding_vm(&root, "one", &github);
    let two = seeding_vm(&root, "two", &github);
    let three = seeding_vm(&root, "three", &github);
    let four = seeding_vm(&root, "four", &github);
    let five = seeding_vm(&root, "five", &github);
    let six = seeding_vm(&root, "six", &github);
    let repo = fixture(&root.join("mac"), files, blob_mb);
    publish(&repo, &github);
    let (local_bytes, local_files) = tree_size(&repo);
    let (git_bytes, _) = tree_size(&repo.join(".git"));
    let os = |text: &str| std::ffi::OsString::from(text);

    // Move to Cloud put the folder on VM one (set up, not measured), and the chat worked there.
    let first = one.home().join("work/app");
    timed(
        &root,
        &[
            &os("seed"),
            &os("push"),
            &os("--socket"),
            one.socket.as_os_str(),
            repo.as_os_str(),
            first.as_os_str(),
        ],
    );
    let mut noise = Noise(7);
    let mut written = vec![0u8; 2 << 20];
    noise.fill(&mut written);
    fs::write(first.join("assets/vm-output.bin"), &written).unwrap();
    let edited = first.join("src/m01/f1.rs");
    let text = fs::read_to_string(&edited).unwrap() + "// edited on vm one\n";
    fs::write(&edited, text).unwrap();

    // After: VM one to VM four as git (`cmux link seed move`, the hop), measured first while
    // this Mac's record is still the seed VM one started from. This Mac's folder stays as it was.
    let mac_before = digest(&repo);
    let (one_hop, four_link) = (root.join("one-hop.sock"), root.join("four.sock"));
    let wire_one_hop = proxy(&one_hop, one.socket.clone(), link);
    let wire_four = proxy(&four_link, four.socket.clone(), link);
    let fourth = four.home().join("work/app");
    let (hopped, hop_wall) = timed(
        &root,
        &[
            &os("seed"),
            &os("move"),
            &os("--from-socket"),
            one_hop.as_os_str(),
            &os("--socket"),
            four_link.as_os_str(),
            repo.as_os_str(),
            first.as_os_str(),
            fourth.as_os_str(),
        ],
    );
    let hop_wire = wire_total(&[&wire_one_hop, &wire_four]);
    assert_eq!(hopped["ok"], json!(true), "{hopped}");
    let mac_untouched = digest(&repo) == mac_before;
    assert!(mac_untouched, "the move wrote into this Mac's folder");

    // Before: Bring Back Local, then Move to Cloud on VM two.
    let (one_before, two_link) = (root.join("one-before.sock"), root.join("two.sock"));
    let wire_one_before = proxy(&one_before, one.socket.clone(), link);
    let wire_two = proxy(&two_link, two.socket.clone(), link);
    let second = two.home().join("work/app");
    let (pulled, pull_wall) = timed(
        &root,
        &[
            &os("seed"),
            &os("pull"),
            &os("--socket"),
            one_before.as_os_str(),
            repo.as_os_str(),
            first.as_os_str(),
            &os("--or-copy"),
        ],
    );
    let (pushed, push_wall) = timed(
        &root,
        &[
            &os("seed"),
            &os("push"),
            &os("--socket"),
            two_link.as_os_str(),
            repo.as_os_str(),
            second.as_os_str(),
        ],
    );
    let before_wire = wire_total(&[&wire_one_before, &wire_two]);

    // Machine to machine, file by file: one relay, VM one to VM three.
    let (one_after, three_link) = (root.join("one-after.sock"), root.join("three.sock"));
    let wire_one_after = proxy(&one_after, one.socket.clone(), link);
    let wire_three = proxy(&three_link, three.socket.clone(), link);
    let third = three.home().join("work/app");
    let (relayed, relay_wall) = timed(
        &root,
        &[
            &os("sync"),
            &os("relay"),
            &os("--from-socket"),
            one_after.as_os_str(),
            &os("--socket"),
            three_link.as_os_str(),
            first.as_os_str(),
            third.as_os_str(),
        ],
    );
    let after_wire = wire_total(&[&wire_one_after, &wire_three]);

    // Both land the same folder.
    let status = ["status", "--porcelain=v2", "--branch"];
    assert_eq!(git(&second, &status), git(&first, &status), "VM two differs");
    assert_eq!(git(&third, &status), git(&first, &status), "VM three differs");
    assert_eq!(git(&fourth, &status), git(&first, &status), "VM four differs");
    assert_eq!(fs::read(fourth.join("assets/vm-output.bin")).unwrap(), written);
    assert_eq!(fs::read(third.join("assets/vm-output.bin")).unwrap(), written);

    // A folder that started on VM one: its own clone of the origin, with the same work.
    let cloned = one.home().join("work/cloned");
    let bare = github.join("acme/app.git");
    git(
        &one.home(),
        &[
            "clone",
            "-q",
            "--no-local",
            "-b",
            "main",
            bare.to_str().unwrap(),
            cloned.to_str().unwrap(),
        ],
    );
    git(&cloned, &["remote", "set-url", "origin", "https://github.com/acme/app.git"]);
    fs::write(cloned.join("assets/vm-output.bin"), &written).unwrap();
    let edited = cloned.join("src/m01/f1.rs");
    let text = fs::read_to_string(&edited).unwrap() + "// edited on vm one\n";
    fs::write(&edited, text).unwrap();
    let (one_vm_relay, five_link) = (root.join("one-vm-relay.sock"), root.join("five.sock"));
    let wire_one_vm_relay = proxy(&one_vm_relay, one.socket.clone(), link);
    let wire_five = proxy(&five_link, five.socket.clone(), link);
    let fifth = five.home().join("work/app");
    let (_, vm_relay_wall) = timed(
        &root,
        &[
            &os("sync"),
            &os("relay"),
            &os("--from-socket"),
            one_vm_relay.as_os_str(),
            &os("--socket"),
            five_link.as_os_str(),
            cloned.as_os_str(),
            fifth.as_os_str(),
        ],
    );
    let vm_relay_wire = wire_total(&[&wire_one_vm_relay, &wire_five]);
    let (one_vm_hop, six_link) = (root.join("one-vm-hop.sock"), root.join("six.sock"));
    let wire_one_vm_hop = proxy(&one_vm_hop, one.socket.clone(), link);
    let wire_six = proxy(&six_link, six.socket.clone(), link);
    let sixth = six.home().join("work/app");
    let (_, vm_hop_wall) = timed(
        &root,
        &[
            &os("seed"),
            &os("move"),
            &os("--from-socket"),
            one_vm_hop.as_os_str(),
            &os("--socket"),
            six_link.as_os_str(),
            cloned.as_os_str(),
            sixth.as_os_str(),
        ],
    );
    let vm_hop_wire = wire_total(&[&wire_one_vm_hop, &wire_six]);
    assert_eq!(git(&fifth, &status), git(&cloned, &status), "VM five differs");
    assert_eq!(git(&sixth, &status), git(&cloned, &status), "VM six differs");
    assert_eq!(fs::read(sixth.join("assets/vm-output.bin")).unwrap(), written);

    let line = json!({
        "bench": "link_relay",
        "rate_bytes_per_s": link.rate,
        "latency_ms": link.latency.as_millis() as u64,
        "local_files": local_files,
        "local_bytes": local_bytes,
        "git_bytes": git_bytes,
        "before_ms": (pull_wall + push_wall).as_millis() as u64,
        "before_pull_ms": pull_wall.as_millis() as u64,
        "before_push_ms": push_wall.as_millis() as u64,
        "before_wire_bytes": before_wire,
        "before_pull_mode": pulled["mode"],
        "before_push_mode": pushed["mode"],
        "relay_ms": relay_wall.as_millis() as u64,
        "relay_wire_bytes": after_wire,
        "relay_written": relayed["written"],
        "after_ms": hop_wall.as_millis() as u64,
        "after_wire_bytes": hop_wire,
        "mac_folder_untouched": mac_untouched,
        "started_on_vm_relay_ms": vm_relay_wall.as_millis() as u64,
        "started_on_vm_relay_wire_bytes": vm_relay_wire,
        "started_on_vm_git_ms": vm_hop_wall.as_millis() as u64,
        "started_on_vm_git_wire_bytes": vm_hop_wire,
    });
    println!("{line}");
}
