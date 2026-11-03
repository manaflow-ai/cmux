//! The hermetic test environment of the acpmux tests (cx-s8wux, cx-s8wux.1).
//!
//! A test process has the host's whole environment. On a fleet host its PATH
//! holds real agent CLIs (codex, claude, gemini, opencode) with real
//! accounts: a daemon started with that environment, or a hub run in the
//! test process, discovers them and runs live model probes, prewarms,
//! sign-in checks and CLI auto-updates (cx-w014j: a host codex ran a test's
//! fake login shell; cx-fylng). So:
//!
//! 1. Every test process runs hermetic. A test file includes this module and
//!    names its process in the crate root:
//!    `const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();`
//!    (or `Process::deny()`); without that constant the file does not build.
//!    Before `main`, the process starts itself again with the environment
//!    below and its own arguments ([`enter`]), so a hub, a store or an agent
//!    it starts in process never sees the host's PATH or HOME.
//! 2. Every `acpmux` process a test starts gets the same environment from
//!    [`acpmux`], [`command`] or [`apply`], on its own scratch directory.
//!
//! The environment:
//!
//! - nothing from the host (`env_clear`), except the test-runner variables
//!   in [`PASS`] and what a process lists with [`Process::keep`];
//! - `PATH`: a private directory with links to the named host tools
//!   (`python3` always, for the stand-in agents and fake shells), then the
//!   system directories. No real agent CLI can be found on it;
//! - `HOME`: `<scratch>/home`, under the scratch directory of the process
//!   (in Cargo's target tmp, never under the temp directory, which tests use
//!   as a Web root) or the test. Never the scratch directory itself: tests use that as the
//!   daemon's home or a chat's folder, and the daemon refuses to start an
//!   agent in the user's home folder unless a person picks it;
//! - `TMPDIR`: the test process's temp directory (macOS: the per-user one);
//! - `ACPMUX_SESSION_CPU_CLASS=normal`: a stand-in harness keeps its normal CPU class (see
//!   [`vars`]);
//! - `ACPMUX_AGENT_LAUNCH=deny`: no agent starts at all (cx-9ettq). A test
//!   that drives a stand-in agent (fake_agent.py, fake_claude.py) opts out
//!   with [`Agents::StandIn`]; it keeps the bare PATH, so only its stand-in
//!   can start.
//!
//! A test sets anything else it needs with `.env(...)` after this.
//! `tests/hermetic_daemon_guard.rs` refuses a test file that does not
//! include this module, or that names the binary (`CARGO_BIN_EXE_acpmux`)
//! anywhere but here.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::Command;

/// How a test process runs: see the module text. The crate root of every
/// test file defines `const HERMETIC: daemon_env::Process`.
#[derive(Clone, Copy, Debug)]
pub struct Process {
    agents: Agents,
    keep: &'static [&'static str],
    inject: &'static [(&'static str, &'static str)],
    tools: &'static [&'static str],
}

impl Process {
    /// No agent starts in this process or in a daemon it starts without a
    /// choice of its own.
    pub const fn deny() -> Self {
        Self { agents: Agents::Deny, keep: &[], inject: &[], tools: &[] }
    }

    /// The process starts its own stand-in agents (a hub run in process).
    pub const fn stand_in() -> Self {
        Self { agents: Agents::StandIn, keep: &[], inject: &[], tools: &[] }
    }

    /// Host variables this process truly needs, kept as they are (each one
    /// named with its reason where the constant is defined).
    pub const fn keep(self, keep: &'static [&'static str]) -> Self {
        Self { keep, ..self }
    }

    /// Synthetic, non-secret variables the hermetic process starts with.
    /// Tests use these instead of copying credential-bearing host values.
    pub const fn with_env(self, inject: &'static [(&'static str, &'static str)]) -> Self {
        Self { inject, ..self }
    }

    /// Host tools (by name) this process runs itself, found on the host's
    /// PATH before the process goes hermetic, so [`tool_dir`] and
    /// [`bare_path`] can link them later (the hermetic PATH no longer
    /// holds them). The host's PATH itself is never kept.
    pub const fn tools(self, tools: &'static [&'static str]) -> Self {
        Self { tools, ..self }
    }
}

/// The variable that carries a [`Process::tools`] tool's host path into the
/// hermetic process.
#[cfg(unix)]
fn tool_var(name: &str) -> String {
    format!("ACPMUX_TEST_TOOL_{name}")
}

/// Test-runner variables every hermetic process keeps: they hold no
/// credential and no PATH, and the harness or a test reads them.
pub const PASS: &[&str] = &[
    "RUST_BACKTRACE",
    "RUST_LIB_BACKTRACE",
    "RUST_LOG",
    "RUST_MIN_STACK",
    "RUST_TEST_THREADS",
    "RUST_TEST_NOCAPTURE",
    "RUST_TEST_TIME_UNIT",
    "RUST_TEST_TIME_INTEGRATION",
    "RUST_TEST_SHUFFLE",
    "RUST_TEST_SHUFFLE_SEED",
    "TERM",
    "NO_COLOR",
    "ASAN_OPTIONS",
    "LSAN_OPTIONS",
    "TSAN_OPTIONS",
    "MSAN_OPTIONS",
    "LD_LIBRARY_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH",
    "LLVM_PROFILE_FILE",
    "CARGO_MANIFEST_DIR",
    "CARGO_TARGET_TMPDIR",
    // `peer_transport` asks for a non-loopback address only on CI.
    "CI",
];

/// Set in the hermetic process, so it does not start itself again.
const ENTERED: &str = "ACPMUX_TEST_HERMETIC";
/// The python3 interpreter the process found before it went hermetic.
const PYTHON: &str = "ACPMUX_TEST_PYTHON";

/// Runs before `main` in every test binary that includes this module, with
/// the crate root's `HERMETIC`. `argv` comes from the loader (glibc and
/// macOS pass it to initializers), because std may not have read it yet.
/// Other unix targets (musl passes no arguments) get no initializer and run
/// with the host environment; no CI job runs these tests there.
#[cfg(unix)]
#[used]
#[cfg_attr(all(target_os = "linux", target_env = "gnu"), unsafe(link_section = ".init_array"))]
#[cfg_attr(target_vendor = "apple", unsafe(link_section = "__DATA,__mod_init_func"))]
static ENTER_HERMETIC: extern "C" fn(i32, *const *const std::ffi::c_char) = {
    extern "C" fn init(argc: i32, argv: *const *const std::ffi::c_char) {
        let args = if argv.is_null() {
            std::env::args_os().collect()
        } else {
            (0..argc.max(0) as usize)
                .map(|i| {
                    // SAFETY: the loader's argv holds argc valid C strings.
                    let arg = unsafe { std::ffi::CStr::from_ptr(*argv.add(i)) };
                    arg.to_bytes().to_vec()
                })
                .map(std::os::unix::ffi::OsStringExt::from_vec)
                .collect()
        };
        enter(super::HERMETIC, args);
    }
    init
};

/// Windows runs no re-start before `main`: Windows CI runs only
/// `windows_daemon`, which starts every daemon through [`apply`]. Other test
/// files that run a hub in process compile there but run with the host
/// environment. The constant is still required.
#[cfg(windows)]
const _: Process = super::HERMETIC;

/// Starts this process again (same pid, same arguments) with the hermetic
/// environment, unless it already runs with it.
#[cfg(unix)]
pub fn enter(process: Process, args: Vec<std::ffi::OsString>) {
    use std::os::unix::process::CommandExt;
    if std::env::var_os(ENTERED).is_some() {
        remove_moved_scratch_at_exit();
        return;
    }
    // A folder an earlier process with this pid left is not this one's.
    let scratch = scratch_base().join(format!("amx-proc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(home(&scratch)).unwrap();
    let mut env = vars(&scratch, process.agents, &[]);
    for key in PASS.iter().chain(process.keep) {
        if let Ok(value) = std::env::var(key) {
            env.retain(|(k, _)| k != key);
            env.push(((*key).to_owned(), value));
        }
    }
    // Threads at the daemon's worker stack (`cli/entry.rs`), not std's 2 MiB: a hub this process
    // runs polls the same request futures the daemon polls on its workers, and they need more than
    // 2 MiB in places (a `/btw` side session's start, 2.0-2.3 MiB on Linux CI, 2026-10-31). A test
    // on a smaller thread than the daemon's would fail on a stack the daemon never has, and one on
    // a larger thread would pass where the daemon aborts. A host's own RUST_MIN_STACK, kept above,
    // wins.
    if !env.iter().any(|(key, _)| key == "RUST_MIN_STACK") {
        env.push(("RUST_MIN_STACK".into(), acpmux::cli::entry::WORKER_STACK_BYTES.to_string()));
    }
    for (key, value) in process.inject {
        env.retain(|(k, _)| k != key);
        env.push(((*key).to_owned(), (*value).to_owned()));
    }
    env.push((ENTERED.into(), "1".into()));
    // The interpreter found now, so the hermetic process does not look again.
    env.push((PYTHON.into(), host_tool("python3").display().to_string()));
    for tool in process.tools {
        env.push((tool_var(tool), host_tool(tool).display().to_string()));
    }
    let exe = std::env::current_exe().expect("the test binary's path");
    let mut args = args.into_iter();
    let mut cmd = Command::new(&exe);
    if let Some(arg0) = args.next() {
        cmd.arg0(arg0);
    }
    let err = cmd.args(args).env_clear().envs(env).exec();
    panic!("start {} again with the hermetic environment: {err}", exe.display());
}

/// Where a test process keeps its scratch folder (and so its HOME): Cargo's target tmp, not the
/// temp directory, because tests use the temp directory as a Web root and a root that holds HOME
/// is dropped. But in a folder the daemon guards (`protected_folders.rs`: another volume, as a
/// fleet Mac's `/Volumes/ephemeral0` build disk, or a checkout in ~/Documents), every test chat
/// under HOME would be one whose restored queue waits for a person. There the scratch goes to
/// [`moved_scratch_base`] on the boot volume and is removed when the process exits.
#[cfg(unix)]
fn scratch_base() -> PathBuf {
    let target = PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
    // With the host's HOME still: a checkout in ~/Documents is guarded too.
    if acpmux::protected_folders::unasked_refusal(&target).is_none() {
        return target;
    }
    let base = moved_scratch_base();
    own_private_dir(&base);
    base
}

/// `amx-<uid>` in a boot-volume folder outside the temp directory, the tests' Web root:
/// `/private/tmp` on macOS (the temp directory there is the per-user folder or a fleet step's
/// own; `/tmp` links to `/private/tmp`, so the path is the same spelled and resolved), and
/// `/var/tmp` elsewhere (where the temp directory is often `/tmp`).
#[cfg(unix)]
fn moved_scratch_base() -> PathBuf {
    let tmp = if cfg!(target_vendor = "apple") { "/private/tmp" } else { "/var/tmp" };
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("{tmp}/amx-{uid}"))
}

/// Makes `dir` owner-only (0700) if missing and refuses one another user owns, so no other
/// account can read or replace a test's HOME in a shared folder.
#[cfg(unix)]
fn own_private_dir(dir: &Path) {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    let _ = std::fs::DirBuilder::new().mode(0o700).create(dir);
    let meta = std::fs::symlink_metadata(dir).expect("the moved scratch folder");
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    assert!(meta.is_dir() && meta.uid() == uid, "{} is not a folder of this user", dir.display());
    let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
}

/// In the hermetic process: when its scratch folder was moved out of Cargo's target tmp
/// ([`scratch_base`]), removes it at exit, so a fleet host's disk does not fill with one folder
/// per test process. Only this process's own folder, `amx-proc-<its pid>` (the start again keeps
/// the pid): a process the test starts from this binary has the same HOME and another pid, and
/// its exit must not remove its parent's HOME. A process that aborts leaves its folder; the next
/// process with its pid removes it.
#[cfg(unix)]
fn remove_moved_scratch_at_exit() {
    fn own_moved_scratch() -> Option<PathBuf> {
        let home = PathBuf::from(std::env::var_os("HOME")?);
        let own = moved_scratch_base().join(format!("amx-proc-{}", std::process::id()));
        (home.parent()? == own).then_some(own)
    }
    extern "C" fn remove() {
        if let Some(scratch) = own_moved_scratch() {
            let _ = std::fs::remove_dir_all(scratch);
        }
    }
    if own_moved_scratch().is_some() {
        // SAFETY: `remove` takes no arguments and only reads the environment and removes files.
        unsafe { libc::atexit(remove) };
    }
}

/// The readiness line a `daemon run --ready-fd 1` writes on `stdout`. The daemon's log shares
/// stdout, so a line it logs first (a startup warning) comes before it; each such line goes on
/// to this test's stderr.
pub fn ready_line(stdout: impl std::io::Read) -> String {
    use std::io::BufRead;
    let mut stdout = std::io::BufReader::new(stdout);
    loop {
        let mut line = String::new();
        let read = stdout.read_line(&mut line).expect("read the daemon's stdout");
        assert!(read > 0, "the daemon exited before it was ready");
        if line.contains("\"ready\":true") {
            return line;
        }
        eprint!("daemon before ready: {line}");
    }
}

/// The binary under test. Only for values (a path a daemon passes on, an
/// agent host launcher); start a process with [`acpmux`] or [`command`].
pub fn bin() -> &'static Path {
    // Other workspace test targets reuse the process environment without
    // owning an acpmux executable. They must use their own native runner.
    match option_env!("CARGO_BIN_EXE_acpmux") {
        Some(binary) => Path::new(binary),
        None => panic!("this test target has no acpmux binary"),
    }
}

/// Whether the daemon may start agent processes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Agents {
    /// `ACPMUX_AGENT_LAUNCH=deny`: no agent, probe, prewarm or sign-in check.
    Deny,
    /// Launches allowed, for a test's own stand-in agent. PATH stays bare.
    StandIn,
}

/// `acpmux` with the hermetic environment, agent launches denied.
pub fn acpmux(scratch: &Path) -> Command {
    command(scratch, Agents::Deny, &[])
}

/// `acpmux` with the hermetic environment; `tools` are host tools (by name,
/// found on the test's PATH) to put on the daemon's PATH besides `python3`.
pub fn command(scratch: &Path, agents: Agents, tools: &[&str]) -> Command {
    let mut cmd = Command::new(bin());
    apply(&mut cmd, scratch, agents, tools);
    cmd
}

/// The same environment for an async command.
pub fn tokio_command(scratch: &Path, agents: Agents) -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new(bin());
    cmd.env_clear().envs(vars(scratch, agents, &[]));
    cmd
}

/// Clears `cmd`'s environment and sets the hermetic one.
pub fn apply<'c>(
    cmd: &'c mut Command,
    scratch: &Path,
    agents: Agents,
    tools: &[&str],
) -> &'c mut Command {
    cmd.env_clear().envs(vars(scratch, agents, tools))
}

/// The hermetic environment as pairs (for an agent host's `SpawnSpec.env`).
pub fn vars(scratch: &Path, agents: Agents, tools: &[&str]) -> Vec<(String, String)> {
    let mut env = platform_vars(&home(scratch), tools);
    // The sessions' own temporary folders (`agent/session_tmp.rs`): in the
    // scratch directory, never the user's `/tmp/acpmux-<uid>` (a debug build reads it).
    #[cfg(unix)]
    env.push((
        "ACPMUX_TEST_SESSION_TMP_BASE".into(),
        scratch.join("session-tmp").display().to_string(),
    ));
    if agents == Agents::Deny {
        env.push(("ACPMUX_AGENT_LAUNCH".into(), "deny".into()));
    }
    // Stand-in harnesses at normal CPU class once their start is over, not the product's
    // background default (`cpu_class.rs`): they time their turns with short sleeps, and at
    // background class on a loaded fleet Mac (load 13 to 21 on 10 performance cores) a Codex-steer
    // turn did not end in 18 to 30 s. `tests/cpu_class.rs` sets background itself.
    env.push((acpmux::cpu_class::ENV.into(), "normal".into()));
    env
}

/// `text` as one shell word in single quotes, for a path put into a test's
/// shell script. A Mac mini's checkout path has a space ("Application
/// Support"): unquoted, `python3` got "/Library/Application" (cx-fylng).
pub fn sh_quote(text: impl std::fmt::Display) -> String {
    format!("'{}'", text.to_string().replace('\'', r"'\''"))
}

/// The `HOME` the hermetic environment gives: `<scratch>/home`.
pub fn home(scratch: &Path) -> PathBuf {
    scratch.join("home")
}

#[cfg(unix)]
fn platform_vars(home: &Path, tools: &[&str]) -> Vec<(String, String)> {
    vec![
        ("PATH".into(), bare_path(tools)),
        ("HOME".into(), home.display().to_string()),
        ("TMPDIR".into(), std::env::temp_dir().display().to_string()),
    ]
}

/// Windows: only what a process needs to start (the system directories and
/// the temp directory), the scratch profile as home. No tool links: the
/// Windows stand-in agents are cmd.exe and the test binary itself.
#[cfg(windows)]
fn platform_vars(home: &Path, tools: &[&str]) -> Vec<(String, String)> {
    assert!(tools.is_empty(), "no host tools on Windows");
    let mut env = Vec::new();
    // What cmd.exe (a Windows stand-in agent) needs to start and find ping.
    for key in ["SystemRoot", "SystemDrive", "windir", "TEMP", "TMP", "ComSpec", "PATHEXT"] {
        if let Ok(value) = std::env::var(key) {
            env.push((key.to_owned(), value));
        }
    }
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    env.push(("PATH".into(), format!(r"{root}\System32;{root}")));
    env.push(("USERPROFILE".into(), home.display().to_string()));
    env.push(("HOME".into(), home.display().to_string()));
    env
}

/// `<dir>:/usr/bin:/bin:/usr/sbin:/sbin`, where `<dir>` (one per process and
/// tool set) links `python3` and `tools` from the test's PATH.
#[cfg(unix)]
pub fn bare_path(tools: &[&str]) -> String {
    format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", tool_dir(tools).display())
}

/// The directory of tool links that [`bare_path`] puts first. A link left by
/// an earlier run (same pid) that points elsewhere is replaced; tests of one
/// process make the links one at a time.
#[cfg(unix)]
pub fn tool_dir(tools: &[&str]) -> PathBuf {
    static LINKS: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _held = LINKS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut names = vec!["python3"];
    names.extend(tools.iter().copied().filter(|t| *t != "python3"));
    let dir =
        std::env::temp_dir().join(format!("amx-bin-{}-{}", std::process::id(), names.join("-")));
    std::fs::create_dir_all(&dir).unwrap();
    for name in &names {
        let link = dir.join(name);
        let target = host_tool(name);
        if std::fs::read_link(&link).is_ok_and(|t| t == target) {
            continue;
        }
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&target, &link)
            .unwrap_or_else(|e| panic!("link {} to {}: {e}", target.display(), link.display()));
    }
    dir
}

/// `name` on the test process's own PATH (absolute entries only). For
/// `python3`, the interpreter itself, not a version manager's shim: a shim
/// picks its version from files under HOME, and the daemon's HOME is a
/// scratch folder.
#[cfg(unix)]
fn host_tool(name: &str) -> PathBuf {
    if name == "python3"
        && let Some(python) = std::env::var_os(PYTHON)
    {
        return PathBuf::from(python);
    }
    if let Some(tool) = std::env::var_os(tool_var(name)) {
        return PathBuf::from(tool);
    }
    let found = std::env::var_os("PATH")
        .iter()
        .flat_map(std::env::split_paths)
        .filter(|d| d.is_absolute())
        .map(|d| d.join(name))
        .find(|p| p.is_file())
        .unwrap_or_else(|| panic!("{name} on the test's PATH"));
    if name != "python3" {
        return found;
    }
    static INTERPRETER: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    INTERPRETER
        .get_or_init(|| {
            let out = Command::new(&found)
                .args(["-c", "import sys; print(sys.executable)"])
                .output()
                .unwrap_or_else(|e| panic!("run {}: {e}", found.display()));
            let exe = String::from_utf8(out.stdout).unwrap();
            let exe = PathBuf::from(exe.trim());
            assert!(out.status.success() && exe.is_absolute(), "python3 names no interpreter");
            // `sys.executable` is the path python was started by, which can be
            // a link (ours, too): the file itself.
            std::fs::canonicalize(&exe).unwrap_or(exe)
        })
        .clone()
}
