//! Staged updates of a cmux-tui binary that a live session runs (cx-stage).
//!
//! On an SSH machine the person runs `~/.cmux/bin/cmux` (install-static.sh)
//! by hand, and its session server and terminal hosts run from that file for
//! weeks. Nothing may stop them to update it. So a newer build is never
//! renamed over the binary while it serves: the Mac app (or anything else)
//! stages it as `<binary>.staged` beside it, and the next session-server
//! start swaps it in here, before it spawns the owner:
//!
//! 1. The staged file must run and answer `remote-probe --json
//!    --build-facts` as cmux-tui within [`PROBE_DEADLINE`].
//! 2. It must be newer than this binary by the one build order
//!    ([`cmux_remote::update_need`]): an older, equal or unordered staged
//!    build is removed, so a staged file never moves a binary back.
//! 3. The current binary is kept as `<binary>.prev` (a hard link), then the
//!    staged file is renamed over the binary (one rename, same folder).
//!
//! Processes that already run the old file (terminal hosts, other sessions'
//! owners, this client) keep their old inode: a rename never touches them.
//! The new owner adopts the terminal hosts, as after any owner restart.
//!
//! [`stale_notice`] is the line the TUI shows when it attaches to a session
//! server older than itself, or while a staged build waits for that restart.

use cmux_process::Stdio;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use cmux_remote::update_need::{BuildFacts, Need, update_need};
use serde_json::Value;

/// The suffix of a staged build beside its binary.
pub(crate) const STAGED_SUFFIX: &str = ".staged";
/// The suffix of the build a promotion replaced.
pub(crate) const PREVIOUS_SUFFIX: &str = ".prev";
/// How long the staged binary may take to answer its probe.
const PROBE_DEADLINE: Duration = Duration::from_secs(10);
/// The probe output this reads at most (the capability list included).
const PROBE_OUTPUT_LIMIT: u64 = 64 * 1024;

/// `<binary>.staged`.
pub(crate) fn staged_path(binary: &Path) -> PathBuf {
    with_suffix(binary, STAGED_SUFFIX)
}

/// `<binary>.prev`.
pub(crate) fn previous_path(binary: &Path) -> PathBuf {
    with_suffix(binary, PREVIOUS_SUFFIX)
}

fn with_suffix(binary: &Path, suffix: &str) -> PathBuf {
    let mut name = binary.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

/// What [`promote`] did.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// No staged build beside the binary.
    NoStaged,
    /// The staged build replaced the binary; `build` is its `build_identity`.
    Promoted { build: Option<String> },
    /// The staged build was removed and the binary left as it was.
    Discarded { reason: String },
}

/// This build's own facts, in the shape `remote-probe --build-facts` reports.
pub(crate) fn own_facts() -> BuildFacts {
    BuildFacts {
        commit: Some(cmux_build_identity::BUILD_IDENTITY.to_owned()),
        time: cmux_build_identity::BUILD_TIME,
        capabilities: Some(
            cmux_tui_core::server::build_capabilities().into_iter().map(str::to_owned).collect(),
        ),
    }
}

/// The facts of a `remote-probe --json` answer (missing fields: unknown).
pub(crate) fn facts_of(probe: &Value) -> BuildFacts {
    BuildFacts {
        commit: probe.get("build_identity").and_then(Value::as_str).map(str::to_owned),
        time: probe.get("build_time").and_then(Value::as_u64).unwrap_or(0),
        capabilities: probe
            .get("daemon_capabilities")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect()),
    }
}

/// Swaps `<binary>.staged` in over `binary` when it is a newer cmux-tui than
/// `current` (the facts of the build at `binary`). Never fails: anything
/// unexpected leaves the binary as it was.
pub(crate) fn promote(binary: &Path, current: &BuildFacts) -> Outcome {
    let staged = staged_path(binary);
    if !staged.is_file() {
        return Outcome::NoStaged;
    }
    let discard = |reason: String| {
        let _ = std::fs::remove_file(&staged);
        Outcome::Discarded { reason }
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755));
    }
    let probe = match probe(&staged) {
        Ok(probe) => probe,
        Err(reason) => return discard(reason),
    };
    if probe.get("app").and_then(Value::as_str) != Some("cmux-tui") {
        return discard("the staged file is not cmux-tui".into());
    }
    let staged_facts = facts_of(&probe);
    // update_need(local, remote): the staged build must be the newer one.
    let (need, reason) = update_need(current, &staged_facts);
    if need != Need::Newer {
        return discard(format!("the staged build is not newer ({reason:?})"));
    }
    let previous = previous_path(binary);
    let _ = std::fs::remove_file(&previous);
    if std::fs::hard_link(binary, &previous).is_err() {
        let _ = std::fs::copy(binary, &previous);
    }
    match std::fs::rename(&staged, binary) {
        Ok(()) => Outcome::Promoted { build: staged_facts.commit },
        Err(error) => discard(format!("rename the staged build: {error}")),
    }
}

/// Runs `<staged> remote-probe --json --build-facts` within [`PROBE_DEADLINE`].
fn probe(staged: &Path) -> Result<Value, String> {
    let mut child = cmux_process::Command::new(staged)
        .args(["remote-probe", "--json", "--build-facts"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("the staged build does not run: {error}"))?;
    let stdout = child.stdout.take().ok_or("no probe output")?;
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        let read = stdout.take(PROBE_OUTPUT_LIMIT).read_to_string(&mut text);
        let _ = sender.send(read.map(|_| text));
    });
    let output = match receiver.recv_timeout(PROBE_DEADLINE) {
        Ok(Ok(text)) => text,
        Ok(Err(error)) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("read the staged build's probe: {error}"));
        }
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err("the staged build did not answer its probe".into());
        }
    };
    let status = child.wait().map_err(|error| error.to_string())?;
    if !status.success() {
        return Err(format!("the staged build's probe failed ({status})"));
    }
    let line = output
        .lines()
        .rev()
        .find(|line| line.trim_start().starts_with('{'))
        .ok_or("the staged build printed no probe")?;
    serde_json::from_str(line).map_err(|error| format!("the staged build's probe: {error}"))
}

/// The binary this process runs, when it is a file a staged build may replace.
fn own_binary() -> Option<PathBuf> {
    let path = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
    // Linux names a replaced executable "<path> (deleted)": nothing to swap.
    path.is_file().then_some(path)
}

static PROMOTED: OnceLock<PathBuf> = OnceLock::new();

/// Runs `binary` with this client's arguments in its place (same terminal,
/// stdio and environment) and returns its exit code; this process only waits.
#[cfg(unix)]
pub(crate) fn run_installed(binary: &Path) -> std::io::Result<i32> {
    let status = cmux_process::Command::new(binary).args(std::env::args_os().skip(1)).status()?;
    Ok(status.code().unwrap_or(1))
}

/// Before this process spawns a session owner: swaps in a staged build of
/// its own binary. Returns the binary to spawn the owner from when it did
/// (the new file, not this process's old image), else None.
pub(crate) fn promote_own_binary() -> Option<PathBuf> {
    if let Some(binary) = PROMOTED.get() {
        return Some(binary.clone());
    }
    let binary = own_binary()?;
    match promote(&binary, &own_facts()) {
        Outcome::Promoted { build } => {
            crate::client_log::info(
                "staged-update",
                &format!(
                    "installed the staged build {} over {}",
                    build.as_deref().unwrap_or("unknown"),
                    binary.display()
                ),
            );
            let _ = PROMOTED.set(binary.clone());
            Some(binary)
        }
        Outcome::Discarded { reason } => {
            crate::client_log::info("staged-update", &format!("staged build removed: {reason}"));
            None
        }
        Outcome::NoStaged => None,
    }
}

/// The binary a promotion in this process installed, if any: this process
/// still runs the old image and should run the new file instead.
pub(crate) fn promoted() -> Option<&'static Path> {
    PROMOTED.get().map(PathBuf::as_path)
}

/// The TUI's notice for the session server it attached to: the server's
/// `identify` (`build_commit`, `build_time` with `revisions`) against this
/// client's facts, and whether a staged build waits beside this binary.
/// None when the server runs this build or a newer one and nothing waits.
pub(crate) fn stale_notice(
    server: &Value,
    client: &BuildFacts,
    staged_waiting: bool,
) -> Option<String> {
    let messages = &crate::localization::catalog().update_notice;
    let server_commit = server.get("build_commit").and_then(Value::as_str).unwrap_or("");
    let short = |commit: &str| commit.chars().take(7).collect::<String>();
    let different = !server_commit.is_empty() && client.commit.as_deref() != Some(server_commit);
    let server_time = server.get("build_time").and_then(Value::as_u64);
    let older = different
        && client.time != 0
        && server_time.is_none_or(|time| time == 0 || time < client.time);
    if older {
        return Some(
            messages
                .stale_server
                .replace("{server}", &short(server_commit))
                .replace("{client}", &short(client.commit.as_deref().unwrap_or(""))),
        );
    }
    staged_waiting.then(|| messages.staged_waiting.to_string())
}

/// [`stale_notice`] for the owner at `socket`, asked once with a short budget.
#[cfg(unix)]
pub(crate) fn notice_for_owner(socket: &Path) -> Option<String> {
    let server = crate::link::machine_gate::call(
        socket,
        serde_json::json!({"cmd": "identify", "revisions": true}),
    )
    .ok()?;
    let staged_waiting = own_binary().is_some_and(|binary| staged_path(&binary).is_file());
    stale_notice(&server, &own_facts(), staged_waiting)
}

static STARTUP_NOTICE: OnceLock<String> = OnceLock::new();

/// Keeps `notice` for the TUI to show once it starts.
pub(crate) fn set_startup_notice(notice: String) {
    let _ = STARTUP_NOTICE.set(notice);
}

/// The notice [`set_startup_notice`] kept.
pub(crate) fn startup_notice() -> Option<&'static str> {
    STARTUP_NOTICE.get().map(String::as_str)
}

#[cfg(all(test, unix))]
#[path = "staged_update_tests.rs"]
mod tests;
