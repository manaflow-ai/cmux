//! `projfs.mount`, `projfs.unmount` and `projfs.upper` (`projfs-v1`): the person's Mac, over its
//! link, starts and stops this machine's mount helper for a projected folder, and reads what the
//! machine wrote over it (`cmux-tui projfs mount|unmount|upper`, crate `cmux-projfs`).
//!
//! - `projfs.mount {mount, manifest, at, state}`: starts the helper in a session of its own
//!   (`setsid`; stdin and stderr closed, stdout read for its first line only), so it outlives
//!   this request and a restart of this daemon, waits up to [`READY_WAIT`] for the helper's
//!   first JSON line and answers that line as it is: `{ok:true, mount, at, entries, bytes, git,
//!   ms}`, or the helper's own refusal `{ok:false, code, message}` (the Mac copies the folder
//!   instead on any refusal). A helper that prints nothing in time is stopped, what it may have
//!   mounted is unmounted, and the request is refused `projfs.helper_timeout`.
//! - `projfs.unmount {at, state}`: runs the helper's `unmount` and answers its JSON line.
//! - `projfs.upper {state}`: runs the helper's `upper` and answers its JSON line,
//!   `{ok:true, changes:[{path, kind, link?, from?, reason?}]}` or its refusal, bounded in time
//!   ([`UPPER_WAIT`]) and in size ([`MAX_UPPER_BYTES`]): a longer list is refused
//!   `projfs.too_many_changes`, its message naming how many changes it holds.
//!
//! `manifest`, `at` and `state` must lie inside this machine's work roots by `fs.write`'s own
//! rule ([`Roots::resolve_no_follow`]: absolute, no `.` or `..`, under a root, no symlink on the
//! way or at the end), and none may be a root itself; `manifest` is a regular file, `at` and
//! `state` folders. `mount` is the rendezvous's opaque id. Only the Mac (a remote client with a
//! principal) may send either op. Served exactly where `fs-v1` is.

use std::io::{BufRead as _, BufReader, Read as _};
use std::path::Path;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use cmux_process::{Child, Command, Stdio};
use serde_json::{Map, Value};

use crate::fs_ops::Roots;
use crate::projfs_owners::Owners;
use crate::projfs_rendezvous::{Caller, Refusal, envelope, mount_id, only};

#[path = "projfs_upper.rs"]
mod upper;
pub use upper::{MAX_UPPER_BYTES, UPPER_WAIT};

/// The ops this module serves, exactly (all in `projfs-v1`).
pub const PROJFS_MOUNT_COMMANDS: [&str; 3] = ["projfs.mount", "projfs.unmount", "projfs.upper"];
/// How long a started helper has to print its first line.
pub const READY_WAIT: Duration = Duration::from_secs(20);
/// How long the helper's `unmount` may take (it waits up to 10 s for a serving helper itself).
pub const UNMOUNT_WAIT: Duration = Duration::from_secs(30);
/// How long a helper being stopped has between SIGTERM and SIGKILL.
const END_GRACE: Duration = Duration::from_secs(5);
/// The longest first line read from the helper.
const MAX_LINE_BYTES: u64 = 64 * 1024;

/// Makes the command that runs the helper with these arguments (after `projfs`). Production
/// runs this daemon's own executable; tests give a stand-in.
pub type HelperCommand = Arc<dyn Fn(&[String]) -> std::io::Result<Command> + Send + Sync>;

static SERVICE: OnceLock<Mounter> = OnceLock::new();

/// The starter over the installed `fs-v1` roots, when this daemon serves `fs-v1` (a Cloud host).
#[must_use]
pub fn installed() -> Option<&'static Mounter> {
    let fs = crate::fs_ops::installed()?;
    let owners = crate::projfs_rendezvous::installed()?.owners();
    let make = || Mounter::new(fs.roots().clone(), Arc::new(own_helper)).with_owners(owners);
    Some(SERVICE.get_or_init(make))
}

/// `<this executable> projfs <args>`.
fn own_helper(args: &[String]) -> std::io::Result<Command> {
    let mut command = Command::new(std::env::current_exe()?);
    command.arg("projfs").args(args);
    Ok(command)
}

/// The `cmd` of `line` when it is one of [`PROJFS_MOUNT_COMMANDS`], exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    crate::projfs_rendezvous::frame_command(line).filter(|cmd| PROJFS_MOUNT_COMMANDS.contains(cmd))
}

/// The answer to one `projfs.mount|unmount` request line, in the daemon's envelope. `socket` is
/// this daemon's own socket, which the helper fetches through (`None`: the helper's default).
#[must_use]
pub fn answer_line(
    mounter: Option<&Mounter>,
    caller: Caller,
    socket: Option<&Path>,
    line: &str,
) -> Value {
    let Ok(Value::Object(mut request)) = serde_json::from_str::<Value>(line) else {
        return envelope(&Value::Null, Err(bad("not a JSON object")));
    };
    let id = request.remove("id").unwrap_or(Value::Null);
    let Some(cmd) = frame_command(line) else {
        return envelope(&id, Err(bad("unknown projfs op")));
    };
    request.remove("cmd");
    let Some(principal) = caller.principal() else {
        let denied =
            Refusal { code: "projfs.permission_denied", message: "permission denied".into() };
        return envelope(&id, Err(denied));
    };
    let Some(mounter) = mounter else {
        let unavailable = Refusal {
            code: "projfs.unavailable",
            message: "projected folders are served only on cmux Cloud hosts".into(),
        };
        return envelope(&id, Err(unavailable));
    };
    let result = match cmd {
        "projfs.mount" => mounter.mount(&request, socket, principal),
        "projfs.upper" => mounter.upper(&request, principal),
        _ => mounter.unmount(&request, principal),
    };
    envelope(&id, result)
}

fn bad(message: impl Into<String>) -> Refusal {
    Refusal { code: "projfs.bad_request", message: message.into() }
}

fn failed(message: impl Into<String>) -> Refusal {
    Refusal { code: "projfs.helper_failed", message: message.into() }
}

/// The refusal of a path param `key` that is not what `need` says inside the roots (also what
/// another principal's folder answers).
fn outside(key: &str, need: Need) -> Refusal {
    Refusal {
        code: "projfs.outside_roots",
        message: format!(
            "{key} must be a {} inside this machine's work folders, with no symlink on the way",
            if need == Need::File { "file" } else { "folder" }
        ),
    }
}

fn timed_out(what: &str, wait: Duration) -> Refusal {
    Refusal {
        code: "projfs.helper_timeout",
        message: format!(
            "the mount helper's {what} did not answer within {} ms; it was stopped",
            wait.as_millis()
        ),
    }
}

/// What a path param must name.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Need {
    File,
    Dir,
    /// Not looked at itself (a mountpoint whose helper is gone may not even stat): only its
    /// folder is resolved, and its name is one plain component.
    Named,
}

/// The first line of a helper, or why there is none.
enum Line {
    Got(String),
    /// Its output ended (it exited) with no line.
    Closed,
    /// Nothing within the wait.
    Late,
}

/// Starts and stops mount helpers under these roots.
pub struct Mounter {
    roots: Roots,
    command: HelperCommand,
    ready_wait: Duration,
    unmount_wait: Duration,
    upper_wait: Duration,
    upper_max_bytes: usize,
    owners: Arc<Owners>,
}

impl Mounter {
    #[must_use]
    pub fn new(roots: Roots, command: HelperCommand) -> Self {
        Self::with_waits(roots, command, READY_WAIT, UNMOUNT_WAIT)
    }

    /// [`Mounter::new`] with its waits (tests shorten them).
    #[must_use]
    pub fn with_waits(
        roots: Roots,
        command: HelperCommand,
        ready_wait: Duration,
        unmount_wait: Duration,
    ) -> Self {
        let (upper_wait, upper_max_bytes) = (UPPER_WAIT, MAX_UPPER_BYTES);
        let owners = Arc::new(Owners::new());
        Self { roots, command, ready_wait, unmount_wait, upper_wait, upper_max_bytes, owners }
    }

    /// This starter keeping its mounts' owners in `owners` (the rendezvous's).
    #[must_use]
    pub fn with_owners(mut self, owners: Arc<Owners>) -> Self {
        self.owners = owners;
        self
    }

    /// This starter with `projfs.upper`'s bounds (tests shorten them).
    #[must_use]
    pub fn with_upper_bounds(mut self, wait: Duration, max_bytes: usize) -> Self {
        (self.upper_wait, self.upper_max_bytes) = (wait, max_bytes);
        self
    }

    /// `projfs.mount` by `principal`: starts the helper and answers its first line. The mount
    /// id and its folders become `principal`'s; another principal's are refused as folders
    /// that are not there.
    pub fn mount(
        &self,
        params: &Map<String, Value>,
        socket: Option<&Path>,
        principal: &str,
    ) -> Result<Value, Refusal> {
        only(params, &["mount", "manifest", "at", "state"])?;
        let mount = mount_id(params)?;
        let manifest = self.inside(params, "manifest", Need::File)?;
        let at = self.inside(params, "at", Need::Dir)?;
        let state = self.inside(params, "state", Need::Dir)?;
        if !self.owners.claim(principal, &mount, &[&state, &at]) {
            return Err(outside("state", Need::Dir));
        }
        let answer = self.start_mount(&mount, &manifest, &at, &state, socket);
        if !answer.as_ref().is_ok_and(|line| line.get("ok") == Some(&Value::Bool(true))) {
            self.owners.release(principal, &state);
        }
        answer
    }

    /// Starts the helper's `mount` and answers its first line.
    fn start_mount(
        &self,
        mount: &str,
        manifest: &str,
        at: &str,
        state: &str,
        socket: Option<&Path>,
    ) -> Result<Value, Refusal> {
        let mut args: Vec<String> = ["mount", "--mount", mount, "--manifest", manifest]
            .into_iter()
            .chain(["--at", at, "--state", state])
            .map(str::to_owned)
            .collect();
        if let Some(socket) = socket.and_then(Path::to_str) {
            args.extend(["--socket".to_owned(), socket.to_owned()]);
        }
        let mut child = self.start(&args)?;
        match first_line(&mut child, self.ready_wait) {
            Line::Got(text) => {
                let Some(answer) = helper_answer(&text) else {
                    end(&mut child);
                    return Err(failed("the mount helper printed something other than its answer"));
                };
                if answer.get("ok") == Some(&Value::Bool(true)) {
                    keep_serving(child);
                } else {
                    end_later(child);
                }
                Ok(answer)
            }
            Line::Closed => {
                let status = end(&mut child);
                Err(failed(format!("the mount helper exited without an answer ({status})")))
            }
            Line::Late => {
                end(&mut child);
                // What it mounted before it hung, if anything, is taken down again.
                let _ = self.run_unmount(at, state);
                Err(timed_out("mount", self.ready_wait))
            }
        }
    }

    /// `projfs.unmount` by `principal`: runs the helper's `unmount` and answers its line.
    /// Another principal's folders answer as folders that are not there; an unmount that
    /// answered `ok` lets them go.
    pub fn unmount(&self, params: &Map<String, Value>, principal: &str) -> Result<Value, Refusal> {
        only(params, &["at", "state"])?;
        let at = self.inside(params, "at", Need::Named)?;
        let state = self.inside(params, "state", Need::Dir)?;
        if !self.owners.may_use_place(principal, &state) {
            return Err(outside("state", Need::Dir));
        }
        if !self.owners.may_use_place(principal, &at) {
            return Err(outside("at", Need::Named));
        }
        let answer = self.run_unmount(&at, &state)?;
        if answer.get("ok") == Some(&Value::Bool(true)) {
            self.owners.release(principal, &state);
            self.owners.release(principal, &at);
        }
        Ok(answer)
    }

    /// `projfs.upper` by `principal`: runs the helper's `upper` and answers its line, within its
    /// bounds. Another principal's `state` answers as a folder that is not there.
    pub fn upper(&self, params: &Map<String, Value>, principal: &str) -> Result<Value, Refusal> {
        only(params, &["state"])?;
        let state = self.inside(params, "state", Need::Dir)?;
        if !self.owners.may_use_place(principal, &state) {
            return Err(outside("state", Need::Dir));
        }
        let args: Vec<String> =
            ["upper", "--state", &state].into_iter().map(str::to_owned).collect();
        let child = self.start(&args)?;
        upper::answer(child, self.upper_wait, self.upper_max_bytes)
    }

    fn run_unmount(&self, at: &str, state: &str) -> Result<Value, Refusal> {
        let args: Vec<String> =
            ["unmount", "--at", at, "--state", state].into_iter().map(str::to_owned).collect();
        let mut child = self.start(&args)?;
        match first_line(&mut child, self.unmount_wait) {
            Line::Got(text) => {
                end_later(child);
                helper_answer(&text)
                    .ok_or_else(|| failed("the unmount printed something other than its answer"))
            }
            Line::Closed => {
                let status = end(&mut child);
                Err(failed(format!("the unmount exited without an answer ({status})")))
            }
            Line::Late => {
                end(&mut child);
                Err(timed_out("unmount", self.unmount_wait))
            }
        }
    }

    /// Starts the helper with `args` in a session of its own, its stdout piped.
    fn start(&self, args: &[String]) -> Result<Child, Refusal> {
        let mut command = (self.command)(args)
            .map_err(|error| failed(format!("cannot start the mount helper: {error}")))?;
        command.new_session().stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
        command.spawn().map_err(|error| failed(format!("cannot start the mount helper: {error}")))
    }

    /// The path param `key`, checked to lie inside the roots by `fs.write`'s rule and to be
    /// what `need` says; refused `projfs.outside_roots` otherwise.
    fn inside(
        &self,
        params: &Map<String, Value>,
        key: &str,
        need: Need,
    ) -> Result<String, Refusal> {
        let path = params
            .get(key)
            .and_then(Value::as_str)
            .ok_or_else(|| bad(format!("{key} is an absolute path")))?;
        let outside = || outside(key, need);
        if need == Need::Named {
            let (folder, name) = path.rsplit_once('/').ok_or_else(outside)?;
            if matches!(name, "" | "." | "..") {
                return Err(outside());
            }
            let folder = if folder.is_empty() { "/" } else { folder };
            self.roots.resolve_no_follow(folder).map_err(|_| outside())?;
            return Ok(path.to_owned());
        }
        let resolved = self.roots.resolve_no_follow(path).map_err(|_| outside())?;
        if resolved.is_root || resolved.name.is_none() {
            return Err(outside());
        }
        let kind = std::fs::symlink_metadata(path).map_err(|_| outside())?.file_type();
        let fits = match need {
            Need::File => kind.is_file(),
            Need::Dir | Need::Named => kind.is_dir(),
        };
        if fits { Ok(path.to_owned()) } else { Err(outside()) }
    }
}

/// The helper's line as a JSON object with an `ok` boolean, or `None`.
fn helper_answer(text: &str) -> Option<Value> {
    let answer: Value = serde_json::from_str(text.trim()).ok()?;
    answer.get("ok").and_then(Value::as_bool)?;
    answer.is_object().then_some(answer)
}

/// Reads the child's first stdout line on a thread of its own, for at most `wait`.
fn first_line(child: &mut Child, wait: Duration) -> Line {
    let Some(stdout) = child.stdout.take() else { return Line::Closed };
    let (sender, receiver) = mpsc::channel();
    let reader = std::thread::Builder::new().name("projfs-helper-line".into()).spawn(move || {
        let mut line = String::new();
        let read = BufReader::new(stdout.take(MAX_LINE_BYTES)).read_line(&mut line);
        let _ = sender.send(read.map(|_| line));
    });
    if reader.is_err() {
        return Line::Closed;
    }
    match receiver.recv_timeout(wait) {
        Ok(Ok(line)) if !line.trim().is_empty() => Line::Got(line),
        Ok(_) | Err(RecvTimeoutError::Disconnected) => Line::Closed,
        Err(RecvTimeoutError::Timeout) => Line::Late,
    }
}

/// Ends the child: SIGTERM to its session's group (the helper unmounts on it), SIGKILL after
/// [`END_GRACE`], then reaps it. Its status, as text.
fn end(child: &mut Child) -> String {
    if let Ok(Some(status)) = child.try_wait() {
        return status.to_string();
    }
    if let Ok(pid) = libc::pid_t::try_from(child.id()) {
        // SAFETY: the child leads its own session (so its group id is its pid) and is not
        // reaped yet, so the id cannot name another process.
        unsafe { libc::kill(-pid, libc::SIGTERM) };
    }
    if let Ok(Some(status)) = child.wait_timeout(END_GRACE) {
        return status.to_string();
    }
    let _ = child.kill();
    child.wait().map_or_else(|error| format!("not reaped: {error}"), |status| status.to_string())
}

/// [`end`] on a thread of its own: a helper that refused exits by itself, and is reaped there.
fn end_later(mut child: Child) {
    let spawned =
        std::thread::Builder::new().name("projfs-helper-end".into()).spawn(move || end(&mut child));
    // No thread: the child's drop ends it and reaps it the same way.
    drop(spawned);
}

/// The helper serves the mount from now on: it outlives this request (and this daemon), and
/// is reaped here when it exits while this daemon runs.
fn keep_serving(mut child: Child) {
    child.detach("a projected folder's mount helper serves until it is unmounted");
    let _ = std::thread::Builder::new().name("projfs-helper-reap".into()).spawn(move || {
        let _ = child.wait();
    });
}

#[cfg(test)]
#[path = "projfs_mount_tests.rs"]
mod tests;
