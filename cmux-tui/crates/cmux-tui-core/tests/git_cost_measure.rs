#![cfg(unix)]
//! VEHICLE ONLY: this file never merges. It prints what the git children of
//! `git.status` and `git.diff` cost today, and what the candidate forms cost,
//! in one repository on one host. It asserts nothing on the clock: its rows
//! are ratios between two forms on one host, never a number for a person's Mac.
//!
//! The repository is a scratch copy of the checkout this test was built from
//! (its tracked files at HEAD; the objects are borrowed through `alternates`,
//! the source checkout is only read). It has one branch with an upstream that
//! it is 1 commit ahead of, and origin's default branch.
//!
//! Three states, each with [`RUNS`] rounds of every form (the forms take turns
//! in a round, so a slow moment of the host hits them all):
//!
//! - clean;
//! - [`CHANGED`] tracked files changed and [`UNTRACKED`] untracked files;
//! - the same, and [`TOUCHED`] more tracked files with a new mtime and the
//!   same bytes (stale stat entries: the daemon's git never writes the
//!   refreshed index back, so each run compares their content again).
//!
//! "through the daemon" is one request on the control socket of a daemon in
//! this process, from the write of the request to the read of its reply line.
//! "bare" is the same git children run by `cmux-git` with the daemon's
//! environment and no socket.

use cmux_git::diff::{Comparison, comparison, diff_args, untracked_args};
use cmux_git::run::{DEADLINE, run_git_within};
use cmux_git::{Repository, parse};
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime};

/// The recorded rounds of each state.
const RUNS: usize = 30;
const CHANGED: usize = 20;
const UNTRACKED: usize = 5;
const TOUCHED: usize = 200;

const SMALL: usize = 64 * 1024;
const LISTING: usize = 8 * 1024 * 1024;
const PATCH: usize = 16 * 1024 * 1024;

/// The work tree read of `git.status` (`git_ops.rs`, `status`).
const STATUS: [&str; 6] = [
    "status",
    "--porcelain=v2",
    "--branch",
    "-z",
    "--untracked-files=no",
    "--ignore-submodules=all",
];

/// The candidate that lists tracked and untracked changes in one run.
const STATUS_ALL: [&str; 5] =
    ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=all"];

/// The head id, the upstream and the ahead and behind counts of one branch.
const BRANCH_FORMAT: &str =
    "--format=%(objectname)%00%(upstream:short)%00%(upstream:track,nobracket)";

/// The scratch directory, removed when the test ends or fails.
struct Scratch {
    dir: PathBuf,
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// The real git, as an absolute path.
fn real_git() -> PathBuf {
    let path = std::env::var_os("PATH").expect("PATH is set");
    std::env::split_paths(&path)
        .map(|dir| dir.join("git"))
        .find(|candidate| candidate.is_file())
        .expect("git is on PATH")
}

/// A setup run of the real git, with no user or system config. Its output.
fn setup_git(real: &Path, directory: &Path, arguments: &[&str]) -> String {
    let output = Command::new(real)
        .arg("-C")
        .arg(directory)
        .args(["-c", "safe.directory=*", "-c", "maintenance.auto=false", "-c", "gc.auto=0"])
        .args(["-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {arguments:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim_end_matches('\n').to_string()
}

/// One connection to the daemon; one request at a time.
struct Connection {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Connection {
    fn open(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
        let mut writer = stream.try_clone().unwrap();
        writeln!(writer, "{}", json!({"id": 0, "cmd": "ping"})).unwrap();
        let mut connection = Self { writer, reader: BufReader::new(stream), next: 0 };
        connection.line_of(&json!(0));
        connection
    }

    /// The reply line with `id`, its value, and the time from `started` to
    /// the read of that line (the parse is not in it).
    fn line_of(&mut self, id: &Value) -> (Duration, Value, usize) {
        let started = Instant::now();
        loop {
            let mut line = String::new();
            let read = self.reader.read_line(&mut line).unwrap();
            let at = started.elapsed();
            assert!(read > 0, "the daemon closed the connection before the reply {id}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if &reply["id"] == id {
                return (at, reply, line.len());
            }
        }
    }

    /// One `cmux.protocol/2` request: the time to its reply line, the reply
    /// and the bytes of the line.
    fn ask(&mut self, operation: &str, mut params: Value) -> (Duration, Value, usize) {
        self.next += 1;
        let id = json!(format!("m{}", self.next));
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        let started = Instant::now();
        writeln!(self.writer, "{request}").unwrap();
        let wrote = started.elapsed();
        let (waited, reply, bytes) = self.line_of(&id);
        assert_eq!(reply["ok"], true, "{operation} failed: {reply:.600}");
        (wrote + waited, reply, bytes)
    }
}

/// What every form reads.
struct Ctx {
    repo: PathBuf,
    /// Opened one time, with today's config overrides.
    repository: Repository,
    comparison: Comparison,
    connection: Connection,
    /// The changed and the untracked files of the state.
    changed: Vec<PathBuf>,
    /// The bytes of the last reply line of a daemon form.
    reply_bytes: usize,
    /// The bytes the last content hash read.
    hashed_bytes: usize,
}

fn timed<T>(work: impl FnOnce() -> T) -> Duration {
    let started = Instant::now();
    let _ = work();
    started.elapsed()
}

/// One git child with the daemon's environment and no config override.
fn bare(repo: &Path, arguments: &[&str]) -> Option<String> {
    let output = run_git_within(repo, &[], arguments, SMALL, DEADLINE).ok()?;
    Some(String::from_utf8_lossy(&output.stdout).trim_end_matches('\n').to_string())
}

/// The candidate: the branch headers of `git.status` from refs only.
fn refs_only_headers(repo: &Path) -> parse::BranchHeaders {
    let mut headers = parse::BranchHeaders::default();
    let Some(reference) = bare(repo, &["symbolic-ref", "--quiet", "HEAD"]) else {
        headers.head = bare(repo, &["rev-parse", "--verify", "--quiet", "HEAD"]);
        return headers;
    };
    let listed = bare(repo, &["for-each-ref", BRANCH_FORMAT, reference.as_str()]);
    let listed = listed.unwrap_or_default();
    let mut fields = listed.split('\0');
    headers.head = fields.next().filter(|id| !id.is_empty()).map(str::to_string);
    headers.upstream = fields.next().filter(|name| !name.is_empty()).map(str::to_string);
    for part in fields.next().unwrap_or_default().split(", ") {
        if let Some(count) = part.strip_prefix("ahead ") {
            headers.ahead = count.parse().unwrap_or(0);
        } else if let Some(count) = part.strip_prefix("behind ") {
            headers.behind = count.parse().unwrap_or(0);
        }
    }
    let branch = reference.strip_prefix("refs/heads/").unwrap_or(&reference);
    headers.branch = Some(branch.to_string());
    headers
}

fn status_daemon(ctx: &mut Ctx) -> Duration {
    let (elapsed, _, bytes) = ctx.connection.ask("git.status", json!({"path": ctx.repo}));
    ctx.reply_bytes = bytes;
    elapsed
}

fn status_today(ctx: &mut Ctx) -> Duration {
    timed(|| {
        let repository = Repository::open(&ctx.repo).unwrap();
        repository.run(&STATUS, 256 * 1024).unwrap();
        let _ = repository.base_branch();
        let _ = repository.main_checkout();
    })
}

fn status_refs_only(ctx: &mut Ctx) -> Duration {
    timed(|| {
        let _ = bare(&ctx.repo, &["rev-parse", "--show-toplevel"]);
        let _ = refs_only_headers(&ctx.repo);
        let _ = ctx.repository.base_branch();
        let _ = ctx.repository.main_checkout();
    })
}

fn child_toplevel(ctx: &mut Ctx) -> Duration {
    timed(|| bare(&ctx.repo, &["rev-parse", "--show-toplevel"]))
}

fn child_filters(ctx: &mut Ctx) -> Duration {
    timed(|| cmux_git::filter_overrides(&ctx.repo))
}

fn child_status(ctx: &mut Ctx) -> Duration {
    timed(|| ctx.repository.run(&STATUS, 256 * 1024))
}

fn child_base(ctx: &mut Ctx) -> Duration {
    timed(|| ctx.repository.base_branch())
}

fn child_main_checkout(ctx: &mut Ctx) -> Duration {
    timed(|| ctx.repository.main_checkout())
}

fn child_symbolic_ref(ctx: &mut Ctx) -> Duration {
    timed(|| bare(&ctx.repo, &["symbolic-ref", "--quiet", "HEAD"]))
}

fn child_for_each_ref(ctx: &mut Ctx) -> Duration {
    timed(|| bare(&ctx.repo, &["for-each-ref", BRANCH_FORMAT, "refs/heads/main"]))
}

fn diff_daemon(ctx: &mut Ctx) -> Duration {
    let params = json!({"path": ctx.repo, "scope": "uncommitted", "include_patch": false});
    let (elapsed, _, bytes) = ctx.connection.ask("git.diff", params);
    ctx.reply_bytes = bytes;
    elapsed
}

fn patch_daemon(ctx: &mut Ctx) -> Duration {
    let params = json!({"path": ctx.repo, "scope": "uncommitted", "include_patch": true});
    let (elapsed, _, bytes) = ctx.connection.ask("git.diff", params);
    ctx.reply_bytes = bytes;
    elapsed
}

fn diff_child(ctx: &Ctx, mode: &[&str], limit: usize) -> Duration {
    let arguments = diff_args(&ctx.comparison, mode, &[]);
    timed(|| ctx.repository.run(&arguments, limit))
}

fn child_name_status(ctx: &mut Ctx) -> Duration {
    diff_child(ctx, &["--name-status", "-z"], LISTING)
}

fn child_numstat(ctx: &mut Ctx) -> Duration {
    diff_child(ctx, &["--numstat", "-z"], LISTING)
}

fn child_raw_numstat(ctx: &mut Ctx) -> Duration {
    diff_child(ctx, &["--raw", "--numstat", "-z"], LISTING)
}

fn child_patch(ctx: &mut Ctx) -> Duration {
    diff_child(ctx, &["--patch", "--full-index", "--unified=3"], PATCH)
}

fn child_untracked(ctx: &mut Ctx) -> Duration {
    let arguments = untracked_args(&[]);
    timed(|| ctx.repository.run(&arguments, LISTING))
}

fn child_status_all(ctx: &mut Ctx) -> Duration {
    timed(|| ctx.repository.run(&STATUS_ALL, LISTING))
}

fn stat_changed(ctx: &mut Ctx) -> Duration {
    timed(|| {
        for path in &ctx.changed {
            std::hint::black_box(std::fs::symlink_metadata(path).unwrap().len());
        }
    })
}

fn hash_changed(ctx: &mut Ctx) -> Duration {
    let mut bytes = 0;
    let elapsed = timed(|| {
        for path in &ctx.changed {
            let data = std::fs::read(path).unwrap();
            bytes += data.len();
            std::hint::black_box(Sha256::digest(&data));
        }
    });
    ctx.hashed_bytes = bytes;
    elapsed
}

type Form = (&'static str, fn(&mut Ctx) -> Duration);

/// Every form, in the order of a round. The first word says what it is:
/// `daemon` (a whole request), `today` or `candidate` (bare children of a
/// whole read), `child` (one git child), `process` (no child).
const FORMS: &[Form] = &[
    ("daemon    git.status, the whole request", status_daemon),
    ("today     git.status children: open + status + base + main checkout", status_today),
    (
        "candidate git.status from refs: toplevel + symbolic-ref + for-each-ref + base + main checkout",
        status_refs_only,
    ),
    ("child     rev-parse --show-toplevel", child_toplevel),
    ("child     config --get-regexp of the filters", child_filters),
    (
        "child     status --porcelain=v2 --branch --untracked-files=no (the work tree read)",
        child_status,
    ),
    (
        "child     base branch (symbolic-ref, config, symbolic-ref origin/HEAD, rev-parse)",
        child_base,
    ),
    ("child     rev-parse --git-common-dir --git-dir", child_main_checkout),
    ("child     symbolic-ref --quiet HEAD", child_symbolic_ref),
    (
        "child     for-each-ref of the branch: head id, upstream, ahead and behind",
        child_for_each_ref,
    ),
    ("daemon    git.diff uncommitted, no patch, the whole request", diff_daemon),
    (
        "daemon    git.diff uncommitted, include_patch, the whole request (today's fingerprint read)",
        patch_daemon,
    ),
    ("child     diff --name-status", child_name_status),
    ("child     diff --numstat", child_numstat),
    ("child     diff --raw --numstat, one run", child_raw_numstat),
    ("child     ls-files --others --exclude-standard", child_untracked),
    ("child     diff --patch --full-index --unified=3", child_patch),
    (
        "child     status --porcelain=v2 --untracked-files=all, tracked and untracked in one run",
        child_status_all,
    ),
    ("process   lstat of the changed and untracked files", stat_changed),
    ("process   read + SHA-256 of the changed and untracked files", hash_changed),
];

fn milliseconds(duration: Duration) -> String {
    format!("{:.2}", duration.as_secs_f64() * 1000.0)
}

/// The sample at the quantile `part` (nearest rank) of sorted `samples`.
fn quantile(samples: &[Duration], part: f64) -> Duration {
    let rank = (samples.len() as f64 * part).ceil() as usize;
    samples[rank.clamp(1, samples.len()) - 1]
}

/// [`RUNS`] rounds of every form after one round that is not recorded, and
/// one line for each form.
fn measure(state: &str, ctx: &mut Ctx) {
    for &(_, form) in FORMS {
        form(ctx);
    }
    let mut samples = vec![Vec::with_capacity(RUNS); FORMS.len()];
    let mut reply_bytes = vec![0; FORMS.len()];
    for _ in 0..RUNS {
        for (index, &(_, form)) in FORMS.iter().enumerate() {
            ctx.reply_bytes = 0;
            samples[index].push(form(ctx));
            reply_bytes[index] = ctx.reply_bytes;
        }
    }
    eprintln!("git-cost: === state: {state} (ms; n = {RUNS} for each row)");
    for (index, &(name, _)) in FORMS.iter().enumerate() {
        let row = &mut samples[index];
        row.sort();
        let reply = match reply_bytes[index] {
            0 => String::new(),
            bytes => format!(" | reply line {bytes} bytes"),
        };
        eprintln!(
            "git-cost: p50 {:>8} | p95 {:>8} | max {:>8} | min {:>8} | {name}{reply}",
            milliseconds(quantile(row, 0.5)),
            milliseconds(quantile(row, 0.95)),
            milliseconds(row[row.len() - 1]),
            milliseconds(row[0]),
        );
    }
    eprintln!(
        "git-cost: the content hash read {} bytes of {} files",
        ctx.hashed_bytes,
        ctx.changed.len()
    );
    let today = ctx.repository.run(&STATUS, 256 * 1024).unwrap();
    let today = parse::branch_headers(&today.stdout);
    let candidate = refs_only_headers(&ctx.repo);
    eprintln!("git-cost: branch headers of today's status child: {today:?}");
    assert_eq!(candidate, today, "the refs-only form gives other branch headers ({state})");
}

/// A git child's arguments without the leading `-c key=value` pairs.
fn without_config(line: &str) -> String {
    let mut words = line.split(' ').peekable();
    while words.peek() == Some(&"-c") {
        words.next();
        words.next();
    }
    words.collect::<Vec<_>>().join(" ")
}

/// The regular files among `names`, as (path, bytes).
fn regular_files(repo: &Path, names: &[String]) -> Vec<(PathBuf, u64)> {
    names
        .iter()
        .filter_map(|name| {
            let path = repo.join(name);
            let metadata = std::fs::symlink_metadata(&path).ok()?;
            metadata.is_file().then(|| (path, metadata.len()))
        })
        .collect()
}

/// `count` of `items`, at equal steps.
fn spread<T: Clone>(items: &[T], count: usize) -> Vec<T> {
    assert!(items.len() >= count, "{} items, {count} wanted", items.len());
    (0..count).map(|index| items[index * items.len() / count].clone()).collect()
}

#[test]
fn git_cost_measure_prints_the_cost_of_the_status_and_diff_forms() {
    let real = real_git();
    let scratch =
        Scratch { dir: std::env::temp_dir().join(format!("gcost-{}", std::process::id())) };
    let bin = scratch.dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    // The daemon's git is `git` on PATH. It is a link to the real git while the
    // clock runs; the count pass at the end puts a script that logs its
    // arguments in its place. PATH changes here, before any other thread.
    std::os::unix::fs::symlink(&real, bin.join("git")).unwrap();
    let mut path = bin.as_os_str().to_owned();
    path.push(":");
    path.push(std::env::var_os("PATH").unwrap());
    unsafe { std::env::set_var("PATH", path) };

    // The source: the checkout this test was built from. It is only read.
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let source = PathBuf::from(setup_git(&real, manifest, &["rev-parse", "--show-toplevel"]));
    let common = PathBuf::from(setup_git(
        &real,
        &source,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    ));
    let head = setup_git(&real, &source, &["rev-parse", "HEAD"]);
    let packs = std::fs::read_dir(common.join("objects/pack")).map_or(0, |entries| {
        entries
            .filter_map(Result::ok)
            .filter(|entry| entry.path().extension().is_some_and(|extension| extension == "pack"))
            .count()
    });
    let shallow = common.join("shallow").is_file();

    // The scratch repository: the source's objects, its own index and files.
    let repo = scratch.dir.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let setup_started = Instant::now();
    setup_git(&real, &repo, &["init", "--quiet"]);
    setup_git(&real, &repo, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    let alternates = format!("{}\n", common.join("objects").display());
    std::fs::write(repo.join(".git/objects/info/alternates"), alternates).unwrap();
    if shallow {
        std::fs::copy(common.join("shallow"), repo.join(".git/shallow")).unwrap();
    }
    setup_git(&real, &repo, &["update-ref", "refs/heads/main", &head]);
    setup_git(&real, &repo, &["reset", "--hard", "--quiet"]);
    setup_git(&real, &repo, &["update-ref", "refs/remotes/origin/main", &head]);
    let origin_head = ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"];
    setup_git(&real, &repo, &origin_head);
    setup_git(&real, &repo, &["config", "remote.origin.url", "/nonexistent/origin"]);
    let fetch = ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"];
    setup_git(&real, &repo, &fetch);
    setup_git(&real, &repo, &["config", "branch.main.remote", "origin"]);
    setup_git(&real, &repo, &["config", "branch.main.merge", "refs/heads/main"]);
    setup_git(&real, &repo, &["commit", "--quiet", "--allow-empty", "-m", "ahead"]);
    // An index entry as new as the index file is compared by content at each
    // read. One refresh after the clock's second has passed makes the tree clean.
    std::thread::sleep(Duration::from_secs(2));
    setup_git(&real, &repo, &["update-index", "-q", "--refresh"]);
    let dirty = setup_git(&real, &repo, &["status", "--porcelain"]);
    assert!(dirty.is_empty(), "the scratch repository is not clean: {dirty:.300}");
    let setup_seconds = setup_started.elapsed().as_secs_f64();

    let listed = setup_git(&real, &repo, &["ls-files", "-z"]);
    let names: Vec<String> =
        listed.split('\0').filter(|name| !name.is_empty()).map(str::to_string).collect();
    let files = regular_files(&repo, &names);
    let file_bytes: u64 = files.iter().map(|(_, bytes)| bytes).sum();
    let space = Command::new("df").arg("-P").arg(&repo).output().ok();
    let space = space.map(|output| String::from_utf8_lossy(&output.stdout).into_owned());
    let space = space.unwrap_or_default();
    eprintln!(
        "git-cost: host {} {}, {} cpus; {}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        std::thread::available_parallelism().map_or(0, usize::from),
        setup_git(&real, &repo, &["--version"]),
    );
    eprintln!(
        "git-cost: source {} at {head}: {packs} pack files, shallow {shallow}",
        source.display()
    );
    eprintln!(
        "git-cost: scratch repository {}: {} tracked entries, {} regular files, {file_bytes} \
         bytes; made in {setup_seconds:.1} s; file system: {}",
        repo.display(),
        names.len(),
        files.len(),
        space.lines().last().unwrap_or_default(),
    );

    // The daemon, and the reads that do not change between the states.
    let socket = scratch.dir.join("d.sock");
    let mux = Mux::new(format!("git-cost-{}", std::process::id()), SurfaceOptions::default());
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    // The daemon lives as long as the test process.
    std::mem::forget(mux);
    let repository = Repository::open(&repo).unwrap();
    let comparison = comparison(&repository, "uncommitted").unwrap();
    eprintln!("git-cost: today's config overrides of the repository: {:?}", repository.overrides);
    let mut ctx = Ctx {
        repo: repo.clone(),
        repository,
        comparison,
        connection: Connection::open(&socket),
        changed: Vec::new(),
        reply_bytes: 0,
        hashed_bytes: 0,
    };

    measure("clean", &mut ctx);
    let (_, clean, _) =
        ctx.connection.ask("git.diff", json!({"path": repo, "scope": "uncommitted"}));
    assert_eq!(clean["result"]["files"].as_array().map(Vec::len), Some(0), "a clean tree");

    // State 2: source files of 2 kB to 200 kB get one more line; 5 new files.
    let sources: Vec<PathBuf> = files
        .iter()
        .filter(|(path, bytes)| {
            let extension = path.extension().and_then(|extension| extension.to_str());
            matches!(extension, Some("rs" | "swift" | "ts" | "tsx"))
                && (2_000..200_000).contains(bytes)
        })
        .map(|(path, _)| path.clone())
        .collect();
    let changed = spread(&sources, CHANGED);
    for path in &changed {
        let mut file = std::fs::File::options().append(true).open(path).unwrap();
        file.write_all(b"\n// one more line of the cost measure\n").unwrap();
    }
    ctx.changed = changed;
    for number in 0..UNTRACKED {
        let path = repo.join(format!("cost-measure-untracked-{number}.txt"));
        std::fs::write(&path, "a line of an untracked file\n".repeat(80)).unwrap();
        ctx.changed.push(path);
    }
    let state = format!("{CHANGED} tracked files changed + {UNTRACKED} untracked files");
    measure(&state, &mut ctx);
    let (_, dirty, _) =
        ctx.connection.ask("git.diff", json!({"path": repo, "scope": "uncommitted"}));
    let seen = dirty["result"]["files"].as_array().map(Vec::len);
    assert_eq!(seen, Some(CHANGED + UNTRACKED), "the changed and the untracked files");

    // State 3: 200 more tracked files get a new mtime and keep their bytes.
    let all: Vec<PathBuf> = files.iter().map(|(path, _)| path.clone()).collect();
    let touched = spread(&all, TOUCHED);
    let mut touched_bytes = 0;
    for path in &touched {
        touched_bytes += std::fs::symlink_metadata(path).unwrap().len();
        let file = std::fs::File::options().append(true).open(path).unwrap();
        file.set_modified(SystemTime::now()).unwrap();
    }
    eprintln!(
        "git-cost: {TOUCHED} tracked files touched (new mtime, same bytes): {touched_bytes} bytes"
    );
    measure(&format!("{state} + {TOUCHED} tracked files touched"), &mut ctx);

    // The count pass: `git` on PATH becomes a script that logs its arguments.
    let log = scratch.dir.join("children.log");
    let script = format!(
        "#!/bin/sh\necho \"$*\" >> \"{}\"\nexec \"{}\" \"$@\"\n",
        log.display(),
        real.display()
    );
    let counting = bin.join("git.count");
    std::fs::write(&counting, script).unwrap();
    std::fs::set_permissions(&counting, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::rename(&counting, bin.join("git")).unwrap();
    eprintln!("git-cost: === the git children of one run of each form (the last state)");
    for &(name, form) in FORMS {
        let _ = std::fs::remove_file(&log);
        form(&mut ctx);
        let children = std::fs::read_to_string(&log).unwrap_or_default();
        eprintln!("git-cost: {} children | {name}", children.lines().count());
        if name.starts_with("daemon") || name.starts_with("candidate") {
            for line in children.lines() {
                eprintln!("git-cost:     git {:.150}", without_config(line));
            }
        }
    }
    drop(ctx);
    drop(scratch);
}
