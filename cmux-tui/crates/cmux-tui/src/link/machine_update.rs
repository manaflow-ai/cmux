//! `cmux link machine update --socket PATH`: updates a Cloud machine's
//! cmux-tui in place to this client's own build (cx-rppd.13), so a machine
//! whose image baked an older build serves the verbs Move to Cloud, Bring
//! Back Local and local access need ([`super::machine_gate`]).
//!
//! `--socket` is the machine daemon's socket as this Mac reaches it (the
//! socket `cmux link agent move --to-socket` takes). Nothing here takes a
//! path, URL, checksum or command from the caller:
//!
//! 1. The machine's `identify` must show it outdated by the gate's own rule
//!    (another build that lacks one of those verbs); a machine that serves
//!    them all is left alone. (A newer build that lacks one, say without
//!    acpmux configured, is not told apart: there is no version order to
//!    compare yet.) With `--to-bundled` (Update Everything, cx-1mbnu) any
//!    machine whose daemon reports another build than this client's own (or
//!    none) is updated, so every machine runs the build the app bundles.
//!    Two apps of different builds that share a machine therefore each move
//!    it to their own build, also back to an older one; accepted, as Update
//!    Everything only runs when a person asks for it in that app. With
//!    `--if-older` too (the app's automatic update) only a machine whose
//!    build is older than this client's is updated, by the source commit
//!    time both report (`build_time`, [`machine_is_older`]), so two apps of
//!    different builds never move a machine back. It
//!    must serve `fs-v1` and `detached-terminals-v1`, and run the daemon from
//!    `<home>/.cmux/bin/cmux-tui`, the binary its supervisor restarts.
//! 2. The new build is this client's own Linux build, pinned by the signed
//!    manifest beside this executable (`cmux_remote::pinned_linux_payload`):
//!    shipped there, or downloaded once from the immutable per-commit release
//!    and checked against the pin. A payload that does not match is refused
//!    before anything reaches the machine. A build without a manifest (dev
//!    builds) pins its own commit's published manifest, or that of the commit
//!    that published its cmux-tui tree.
//! 3. It is written beside the daemon's binary through `fs-v1`, then run once
//!    in a detached terminal of the machine's own daemon, as the daemon's own
//!    user, with a fixed argv ([`apply`]): it checks its own checksum again,
//!    keeps the running binary as `cmux-tui.prev`, renames itself over the
//!    binary and ends the daemon with SIGTERM, which leaves every terminal
//!    host and chat running. The supervisor starts the new binary, which
//!    adopts them. A new daemon that does not serve within 10 minutes is
//!    rolled back to `cmux-tui.prev`.
//! 4. This command waits for the outcome the apply step records next to the
//!    binary and answers one JSON line: `{"ok":true,"updated":true,"build":..,
//!    "previous_build":..}`, `{"ok":true,"updated":false,..}` for a machine
//!    that needs nothing, or `{"ok":false,"error":..,"error_code":..}` (exit 1;
//!    bad usage exits 64).

use cmux_json::JsonSet as _;

pub(crate) mod apply;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::machine_gate;

const USAGE: &str =
    "usage: cmux link machine update --socket MACHINE_DAEMON_SOCKET [--to-bundled [--if-older]]";
/// Every Cloud image bakes an x86_64 machine (images/cmux-vm inputs.lock.json).
const CLOUD_ARCH: &str = "x86_64";
/// The verbs whose absence makes a machine worth updating.
const NEEDED: [&str; 3] = [
    cmux_tui_core::fs_ops::FS_CAPABILITY,
    cmux_tui_core::server::agent_transfer::AGENT_TRANSFER_CAPABILITY,
    cmux_tui_core::server::agent_transfer::access_requests::ACCESS_REQUEST_CAPABILITY,
];
/// What the old daemon must serve for the update to reach it.
const REACHES: [&str; 2] = [cmux_tui_core::fs_ops::FS_CAPABILITY, "detached-terminals-v1"];
/// Longer than the apply step's own waits (its daemon exit, the new
/// daemon, a rollback): a daemon replays its journal before it listens.
const OUTCOME_TIMEOUT: Duration = Duration::from_secs(25 * 60);
/// Once the new build answers, how long to wait for the recorded outcome.
const OUTCOME_GRACE: Duration = Duration::from_secs(60);

struct Failed {
    code: &'static str,
    error: String,
    /// `build`: the machine's `build_commit` this answer is about (a machine too old to update
    /// in place: what the caller may install over by other means, and only while it still runs it).
    build: Option<String>,
}

impl Failed {
    fn new(code: &'static str, error: impl Into<String>) -> Self {
        Self { code, error: error.into(), build: None }
    }

    /// Names the build the machine ran when this answer was decided.
    fn about(mut self, identity: &Value) -> Self {
        self.build = identity["build_commit"].as_str().filter(|b| !b.is_empty()).map(str::to_owned);
        self
    }
}

pub(super) fn run(args: &[String]) -> i32 {
    if matches!(args.first().map(String::as_str), Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return 0;
    }
    let Some(request) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    match update(&request) {
        Ok(mut line) => {
            line.set("ok", json!(true));
            println!("{line}");
            0
        }
        Err(failed) => {
            let mut line = json!({"ok": false, "error": failed.error, "error_code": failed.code});
            if let Some(build) = failed.build {
                line.set("build", json!(build));
            }
            println!("{line}");
            1
        }
    }
}

/// One `link machine update`'s arguments.
#[derive(Debug, PartialEq, Eq)]
struct Request {
    socket: PathBuf,
    /// `--to-bundled`: update whenever the machine runs another build than
    /// this client's own, not only when it lacks one of [`NEEDED`] (also to
    /// an older build: two apps that share a machine each move it to their
    /// own).
    to_bundled: bool,
    /// `--if-older`, only with `--to-bundled`: and only when the machine's
    /// build is older than this client's ([`machine_is_older`]).
    if_older: bool,
}

/// `update --socket PATH [--to-bundled [--if-older]]`, flags in any order;
/// None for anything else.
fn parse(args: &[String]) -> Option<Request> {
    let mut rest = args.iter();
    if rest.next().map(String::as_str) != Some("update") {
        return None;
    }
    let (mut socket, mut to_bundled, mut if_older) = (None, false, false);
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--socket" if socket.is_none() => socket = Some(PathBuf::from(rest.next()?)),
            "--to-bundled" if !to_bundled => to_bundled = true,
            "--if-older" if !if_older => if_older = true,
            _ => return None,
        }
    }
    if if_older && !to_bundled {
        return None;
    }
    Some(Request { socket: socket?, to_bundled, if_older })
}

/// Whether a machine whose daemon reports `remote` as its `build_time` runs
/// an older build than this client, built at `local` (unix seconds of each
/// source commit). A daemon that reports none (a build from before
/// `build_time` in `identify`, or one that does not know its time) is
/// older, as `cmux_remote::update_need` counts a remote without facts. A
/// client that does not know its own time orders nothing. The same time is
/// the same source tree: not older.
fn machine_is_older(remote: Option<u64>, local: u64) -> bool {
    local != 0 && remote.is_none_or(|remote| remote == 0 || remote < local)
}

fn update(request: &Request) -> Result<Value, Failed> {
    let socket = request.socket.as_path();
    let before = machine_gate::identify(socket)
        .ok_or_else(|| Failed::new("machine_unreachable", "the machine daemon did not answer"))?;
    let previous = machine_gate::build_id(&before).map(str::to_owned);
    let current = if request.to_bundled {
        previous.as_deref() == Some(cmux_build_identity::BUILD_IDENTITY)
    } else {
        machine_gate::outdated_identity(&before, &NEEDED).is_none()
    };
    if current {
        return Ok(json!({"updated": false, "build": previous}));
    }
    if request.if_older {
        // The build time only comes with `revisions`; a daemon from before it
        // answers without one. One that does not answer now is not ordered:
        // a newer machine must never be moved back on a lost reply.
        let revisions = machine_gate::call(socket, json!({"cmd": "identify", "revisions": true}))
            .map_err(|error| {
            Failed::new(
                "machine_unreachable",
                format!("the machine daemon did not say its build time: {error}"),
            )
        })?;
        if !machine_is_older(revisions["build_time"].as_u64(), cmux_build_identity::BUILD_TIME) {
            return Ok(json!({"updated": false, "build": previous, "not_older": true}));
        }
    }
    let served = machine_gate::served(&before).unwrap_or_default();
    if let Some(missing) = REACHES.iter().find(|capability| !served.contains(capability)) {
        return Err(Failed::new(
            "machine_update_unsupported",
            format!(
                "the machine's cmux-tui is too old to update in place (no {missing}); recreate the machine"
            ),
        )
        .about(&before));
    }
    let install = install_path(&before).ok_or_else(|| {
        Failed::new(
            "machine_update_unsupported",
            "the machine's daemon does not run from ~/.cmux/bin/cmux-tui; recreate the machine",
        )
        .about(&before)
    })?;
    let daemon_pid = before["pid"].as_u64().ok_or_else(|| {
        Failed::new("machine_update_unsupported", "the machine daemon named no pid").about(&before)
    })?;
    let (payload, sha256, pinned_commit) = pinned_payload()?;
    // A tree-mode DEV bundle pins the build its tree's publishing commit
    // made, which identifies as that commit: a machine already on it runs
    // this client's tree, and updating it again would never end.
    if previous.as_deref() == Some(pinned_commit.as_str()) {
        return Ok(json!({"updated": false, "build": previous, "same_tree": true}));
    }
    let folder = install.rsplit_once('/').map_or("", |(folder, _)| folder).to_owned();
    let nonce = nonce();
    // Both named by this update alone, so two updates never share a file.
    let staged = format!("{folder}/.cmux-tui.update-{nonce}");
    let result = format!("{folder}/.cmux-tui.update-{nonce}.json");
    if let Err(failed) = stage(socket, &payload, &sha256, &staged, &nonce) {
        let _ = super::sync_cli::delete_remote(socket, &staged);
        return Err(failed);
    }
    let argv = apply::argv(&staged, &sha256, &install, daemon_pid, &result);
    let created = machine_gate::call(
        socket,
        json!({"cmd": "create-terminal", "detached": true, "argv": argv, "cwd": folder,
               "name": "cmux machine update"}),
    );
    let terminal = match created {
        Ok(data) => data["terminal_id"].as_str().map(str::to_owned),
        Err(error) => {
            let _ = super::sync_cli::delete_remote(socket, &staged);
            return Err(Failed::new(
                "machine_update_failed",
                format!("the update did not start: {error}"),
            ));
        }
    };
    let outcome = wait_for_outcome(socket, &result, daemon_pid);
    // Best effort: the apply step has ended (or the wait gave up), so its
    // terminal, its outcome and a staged copy it did not rename go.
    if let Some(terminal) = terminal {
        let _ =
            machine_gate::call(socket, json!({"cmd": "close-terminal", "terminal_id": terminal}));
    }
    let _ = super::sync_cli::delete_remote(socket, &result);
    let _ = super::sync_cli::delete_remote(socket, &staged);
    let build = outcome?;
    Ok(json!({"updated": true, "build": build, "previous_build": previous}))
}

/// The daemon's binary, `<home>/.cmux/bin/cmux-tui`, from `identify`'s
/// `cli_path`; None for any other place.
fn install_path(identity: &Value) -> Option<String> {
    let path = identity["cli_path"].as_str()?;
    let plain = path.starts_with('/')
        && path.ends_with("/.cmux/bin/cmux-tui")
        && path.split('/').all(|part| part != ".." && part != ".");
    plain.then(|| path.to_owned())
}

/// This client's pinned Linux build, its SHA-256 and the commit that built it.
fn pinned_payload() -> Result<(PathBuf, String, String), Failed> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| Failed::new("machine_update_failed", e.to_string()))?;
    match runtime.block_on(cmux_remote::pinned_linux_payload(
        CLOUD_ARCH,
        cmux_build_identity::BUILD_IDENTITY,
    )) {
        Ok(Some(pinned)) if apply::is_sha256(&pinned.sha256) => {
            Ok((pinned.path, pinned.sha256, pinned.commit))
        }
        Ok(Some(_)) => {
            Err(Failed::new("machine_update_payload_rejected", "the pinned checksum is malformed"))
        }
        Ok(None) => Err(Failed::new(
            "machine_update_unavailable",
            "this cmux build carries no pinned machine build, and none is published for its commit or cmux-tui tree yet",
        )),
        Err(cmux_remote::ssh_bootstrap::BootstrapError::PayloadDownload(why)) => {
            Err(Failed::new("machine_update_download_failed", why))
        }
        Err(error) => Err(Failed::new("machine_update_payload_rejected", error.to_string())),
    }
}

/// Writes `payload` to `staged` on the machine, executable, once its local
/// copy hashes to `sha256`.
fn stage(
    socket: &Path,
    payload: &Path,
    sha256: &str,
    staged: &str,
    nonce: &str,
) -> Result<(), Failed> {
    use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
    let local = std::env::temp_dir().join(format!("cmux-machine-update-{nonce}"));
    let copy = local.join("cmux-tui");
    // A fresh private folder: never one somebody planted.
    let staged_locally = std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&local)
        .and_then(|()| std::fs::copy(payload, &copy))
        .and_then(|_| std::fs::set_permissions(&copy, std::fs::Permissions::from_mode(0o755)));
    let checked = staged_locally.and_then(|()| apply::file_sha256(&copy));
    match checked {
        Ok(actual) if actual == sha256 => {}
        Ok(_) => {
            let _ = std::fs::remove_dir_all(&local);
            return Err(Failed::new(
                "machine_update_payload_rejected",
                "the build's copy does not match its pin",
            ));
        }
        Err(error) => {
            let _ = std::fs::remove_dir_all(&local);
            return Err(Failed::new(
                "machine_update_failed",
                format!("cannot stage the build here: {error}"),
            ));
        }
    }
    let written = super::sync_cli::copy_file(socket, &copy, staged);
    let _ = std::fs::remove_dir_all(&local);
    written.map_err(|e| {
        Failed::new("machine_update_failed", format!("cannot copy the build to the machine: {e:#}"))
    })
}

/// Waits for the apply step's recorded outcome; the new build on success.
fn wait_for_outcome(socket: &Path, result: &str, daemon_pid: u64) -> Result<String, Failed> {
    let own = cmux_build_identity::BUILD_IDENTITY;
    let deadline = Instant::now() + OUTCOME_TIMEOUT;
    let mut new_seen: Option<Instant> = None;
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_secs(1));
        if let Some(outcome) = read_outcome(socket, result) {
            return match outcome["state"].as_str() {
                Some("updated") => Ok(own.to_owned()),
                Some("pending") => Err(Failed::new(
                    "machine_update_pending",
                    "the new build is installed but the daemon did not stop; it runs after the machine's next restart",
                )),
                Some("busy") => Err(Failed::new(
                    "machine_update_busy",
                    "another update of this machine is running; try again once it ends",
                )),
                Some("rolled_back") => Err(Failed::new(
                    "machine_update_rolled_back",
                    format!(
                        "the new daemon did not serve, so the machine runs its old build again: {}",
                        detail(&outcome)
                    ),
                )),
                _ => Err(Failed::new("machine_update_failed", detail(&outcome))),
            };
        }
        let Some(now) = machine_gate::identify(socket) else { continue };
        if machine_gate::build_id(&now) == Some(own) && now["pid"].as_u64() != Some(daemon_pid) {
            let seen = *new_seen.get_or_insert_with(Instant::now);
            if seen.elapsed() > OUTCOME_GRACE {
                return Ok(own.to_owned());
            }
        }
    }
    Err(Failed::new(
        "machine_update_unresolved",
        "the machine did not report how the update ended; check it, then run the update again",
    ))
}

fn detail(outcome: &Value) -> String {
    outcome["detail"].as_str().unwrap_or("no detail").to_owned()
}

/// The apply step's outcome file, once it holds a final state.
fn read_outcome(socket: &Path, result: &str) -> Option<Value> {
    let data = super::sync_cli::machine_call(
        socket,
        "fs.read",
        json!({"path": result, "offset": 0, "max_bytes": 64 * 1024}),
    )
    .ok()?;
    let outcome: Value = serde_json::from_str(data["text"].as_str()?).ok()?;
    (outcome["state"].as_str()? != "running").then_some(outcome)
}

/// 16 random hex digits, naming this update's outcome file.
fn nonce() -> String {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap_or_else(|_| {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        bytes = (now as u64 ^ u64::from(std::process::id())).to_le_bytes();
    });
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
#[path = "machine_update/tests.rs"]
mod tests;
