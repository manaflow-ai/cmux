//! Files on a Cloud machine through its cmux daemon on the link (contract
//! 2.4, a9 2026-10-04): every `cloud.fs.*` op and every push or pull is one
//! daemon `fs.*` op on the link's `daemon` service, never a Cloud API route.
//!
//! GATE: the daemon must report the capability [`FS_CAPABILITY`] in
//! `cloud.machine.connect_info.daemon.capabilities` (a read, no token).
//! Without it every file op answers a typed `unsupported` that names the
//! capability; there is no fallback. The daemon ops, params and results are
//! the finder ones (request file `daemon-fs-for-cloud.md`: `fs.stat`,
//! `fs.list`, `fs.read`, `fs.write`, `fs.mkdir`, `fs.rename`, `fs.delete`),
//! so the ops light up with no Cloud change when the daemon ships them.

use super::Cancel;
use crate::api::{CloudError, ControlPlane, codes};
use crate::link::carrier::{Children, Dialed, end_all, end_child, open_dial};
use crate::link::dial::dial_args;
use crate::ops::Server;
use serde_json::{Map, Value, json};
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::time::Duration;

/// The daemon capability that carries the `fs.*` ops.
pub const FS_CAPABILITY: &str = "fs-v1";

/// The bound on one daemon file op: the op loop is single-threaded, so a
/// daemon that never answers must not hold it.
pub const DAEMON_OP_TIMEOUT: Duration = Duration::from_secs(30);

/// The largest daemon answer line (a 16 MiB read in base64, plus framing).
const MAX_ANSWER_BYTES: u64 = 24 * 1024 * 1024;

/// The link ended after the request went out and before the daemon's whole
/// answer line (EOF, a read error or the deadline): the op may have acted.
/// Retryable only for a read; an `fs.write` reconciles with `fs.stat`
/// instead ([`write_reconciled`]); another changing op is not retryable.
pub const ANSWER_LOST: &str = "cmux.cloud.link_answer_lost";

/// The ops that change nothing: a lost answer may run again.
const READ_OPS: &[&str] = &["fs.stat", "fs.list", "fs.read"];

fn answer_lost(op: &str, why: impl Into<String>) -> CloudError {
    CloudError { retryable: READ_OPS.contains(&op), ..CloudError::new(ANSWER_LOST, why) }
}

/// Where one daemon op goes: the `cmux` binary that dials, the machine's
/// overlay host id, and the dial child's whole environment. No credential.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DialTarget {
    pub binary: PathBuf,
    pub host: String,
    /// The live `cmux link` socket the host reported (`hub_socket`).
    pub socket: PathBuf,
    pub env: Vec<(String, String)>,
}

/// Sends one daemon `fs.*` op and returns its `data`. The real one dials;
/// tests use a fake.
pub trait DaemonFiles: Send + Sync {
    /// `cancel` ends the op (its dial child) from another thread.
    fn call(
        &self,
        target: &DialTarget,
        op: &str,
        params: Value,
        cancel: &Cancel,
    ) -> Result<Value, CloudError>;
}

/// The real [`DaemonFiles`]: one `cmux link dial --host <host_…>` per op,
/// one v12 request line, one answer line.
pub struct LinkDaemonFiles;

fn unavailable(why: impl Into<String>) -> CloudError {
    CloudError { retryable: true, ..CloudError::new(crate::link::ops::LINK_DOWN, why) }
}

impl DaemonFiles for LinkDaemonFiles {
    fn call(
        &self,
        target: &DialTarget,
        op: &str,
        params: Value,
        cancel: &Cancel,
    ) -> Result<Value, CloudError> {
        let mut request = match params {
            Value::Object(map) => map,
            _ => Map::new(),
        };
        request.insert("id".into(), json!(1));
        request.insert("cmd".into(), json!(op));
        let line = format!("{}\n", Value::Object(request));
        // The whole op (spawn, reply line, request, answer) runs on a worker
        // under one deadline: the op loop is single-threaded, and a link or
        // daemon that hangs at any step must not hold it. On the deadline
        // the dial child (ours, by its handle) is ended, which ends the
        // worker's read or write.
        let children: Children = Arc::default();
        // Set once the whole request line went out: from then on a missing
        // answer may hide an op that acted.
        let sent = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = mpsc::channel();
        let worker = {
            let (target, op) = (target.clone(), op.to_owned());
            let children = Arc::clone(&children);
            let sent = Arc::clone(&sent);
            std::thread::Builder::new()
                .name("cmux-cloud-fs".into())
                .spawn(move || {
                    let _ = sender.send(exchange(&target, &op, &line, &children, &sent));
                })
                .map_err(|e| unavailable(format!("no worker for the daemon op: {e}")))?
        };
        // A cancel ends the dial child (ours) at any step, like the deadline.
        let on_cancel = Arc::clone(&children);
        cancel.on_cancel(move || end_all(&on_cancel));
        let answer = match receiver.recv_timeout(DAEMON_OP_TIMEOUT) {
            Ok(answer) => answer,
            Err(_) => {
                let why = format!(
                    "the machine's daemon did not answer {op} within {} s",
                    DAEMON_OP_TIMEOUT.as_secs()
                );
                Err(if sent.load(Ordering::Acquire) {
                    answer_lost(op, why)
                } else {
                    unavailable(why)
                })
            }
        };
        end_all(&children);
        drop(worker);
        decode_answer(op, &answer?)
    }
}

/// One dial, one request line, one answer line (on the worker).
fn exchange(
    target: &DialTarget,
    op: &str,
    line: &str,
    children: &Children,
    sent: &AtomicBool,
) -> Result<Vec<u8>, CloudError> {
    let Dialed { child, mut stdin, stdout } =
        open_dial(&target.binary, &dial_args(&target.host, &target.socket), &target.env, children)
            .map_err(|code| unavailable(format!("cmux link refused: {}", code.as_str())))?;
    let written = stdin.write_all(line.as_bytes()).and_then(|()| stdin.flush());
    drop(stdin);
    written.map_err(|e| unavailable(format!("the daemon link closed: {e}")))?;
    sent.store(true, Ordering::Release);
    let mut answer = Vec::new();
    BufReader::new(stdout)
        .take(MAX_ANSWER_BYTES)
        .read_until(b'\n', &mut answer)
        .map_err(|e| answer_lost(op, format!("the daemon link closed before the answer: {e}")))?;
    end_child(&child, children);
    // EOF before the whole line (a line at the size bound is a bad answer).
    if answer.last() != Some(&b'\n') && (answer.len() as u64) < MAX_ANSWER_BYTES {
        return Err(answer_lost(op, "the daemon link closed before the answer"));
    }
    Ok(answer)
}

/// `fs.write` with the fs-v1 EOF rule: the daemon renames the new file into
/// place before it writes its answer line, so a kick or shutdown in between
/// gives [`ANSWER_LOST`] although the file changed. Then one `fs.stat` of the
/// path decides (table in `reconcile`). `len` is the raw byte count of the
/// write. A cancel before the call sends nothing; a cancel that ended the
/// dial after the line went out still reconciles (the stat runs on its own
/// cancel, under the op deadline), because the file may be on the machine.
pub fn write_reconciled(
    files: &dyn DaemonFiles,
    target: &DialTarget,
    params: Value,
    len: u64,
    cancel: &Cancel,
) -> Result<Value, CloudError> {
    if cancel.is_cancelled() {
        return Err(cancelled());
    }
    match files.call(target, "fs.write", params.clone(), cancel) {
        Err(e) if e.code == ANSWER_LOST => {
            let path = json!({ "path": params["path"] });
            let stat = files.call(target, "fs.stat", path, &Cancel::default());
            reconcile(&params, len, stat)
        }
        other => other,
    }
}

/// The fs.stat after a lost write answer:
/// - no file, or the `expected` revision still there: not landed (retryable
///   `link_down`);
/// - overwrite (no precondition): never "landed" (the same-size file may be
///   the old one); retryable `link_down` that says it may have landed;
/// - replace, another revision of the written size: landed (`{entry}`); the
///   narrow race with another writer of the same size is accepted;
/// - create, a file of the written size: `indeterminate` with `{current}`
///   (the file may have been there before, refused as fs.exists);
/// - another file: `conflict` with `{current}`; no stat answer: `indeterminate`.
fn reconcile(
    params: &Value,
    len: u64,
    stat: Result<Value, CloudError>,
) -> Result<Value, CloudError> {
    let link_down = |why: &str| CloudError {
        retryable: true,
        ..CloudError::new(crate::link::ops::LINK_DOWN, why.to_owned())
    };
    let not_landed =
        || link_down("The link closed before the daemon answered; the write did not land");
    let entry = match stat {
        Ok(entry) => entry,
        Err(e) if e.upstream_code.as_deref() == Some("fs.not_found") => return Err(not_landed()),
        Err(e) => {
            return Err(CloudError::new(
                codes::INDETERMINATE,
                format!(
                    "The link closed during the write and the file could not be read again ({}); \
                     check the file before writing again",
                    e.message
                ),
            ));
        }
    };
    let revision = entry["revision"].as_str();
    if params["expected"].as_str().is_some_and(|expected| revision == Some(expected)) {
        return Err(not_landed());
    }
    let mode = params["mode"].as_str();
    if mode == Some("overwrite") {
        return Err(link_down(
            "The link closed before the daemon answered; the write may have landed, \
             and writing again is safe",
        ));
    }
    // A size match is the only proof fs-v1 gives (its revision is size and
    // mtime, with no content hash).
    let same_size = entry["kind"] == "file" && entry["size"].as_u64() == Some(len);
    if same_size && mode == Some("create") {
        return Err(CloudError {
            details: Some(json!({ "current": revision })),
            ..CloudError::new(
                codes::INDETERMINATE,
                "The link closed before the daemon answered; a file of this size is at the \
                 path, but it may have been there before. Check the file",
            )
        });
    }
    if same_size {
        return Ok(json!({ "entry": entry }));
    }
    let daemon_code = if mode == Some("create") { "fs.exists" } else { "fs.revision_mismatch" };
    Err(CloudError {
        details: Some(json!({ "current": revision })),
        ..fs_error(daemon_code, "The file changed on the machine while the link was down")
    })
}

/// A daemon answer line (`{"id":1,"ok":true,"data":...}` or
/// `{"id":1,"ok":false,"error":{"code","message"}}`) as `data` or a typed
/// error.
pub fn decode_answer(op: &str, line: &[u8]) -> Result<Value, CloudError> {
    let value: Value = serde_json::from_slice(line).map_err(|e| {
        CloudError::new(codes::BAD_RESPONSE, format!("the daemon answered {op} with no JSON: {e}"))
    })?;
    match value["ok"].as_bool() {
        Some(true) => Ok(value.get("data").cloned().unwrap_or(Value::Null)),
        // The daemon's v12 envelope (decision D1): text in `error`, the code
        // in `error_code`, details (for example `{current}`) in `error_details`.
        Some(false) => {
            let code = value["error_code"].as_str().unwrap_or("fs.error").to_owned();
            let message = value["error"].as_str().unwrap_or("the daemon refused");
            let details = value.get("error_details").filter(|d| !d.is_null()).cloned();
            Err(CloudError { details, ..fs_error(&code, message) })
        }
        None => Err(CloudError::new(codes::BAD_RESPONSE, format!("{op}: the answer has no ok"))),
    }
}

/// A daemon `fs.*` error code as an op error; the daemon's code is kept.
pub fn fs_error(code: &str, message: &str) -> CloudError {
    let ours = match code {
        "fs.not_found" => codes::NOT_FOUND,
        "fs.permission_denied" | "fs.read_only" => codes::FORBIDDEN,
        "fs.exists" | "fs.revision_mismatch" | "fs.not_empty" => codes::CONFLICT,
        "params.invalid" | "fs.not_a_file" | "fs.not_a_directory" => codes::INVALID_ARGS,
        "fs.too_large" => super::FILE_TOO_LARGE,
        _ => codes::UPSTREAM,
    };
    CloudError { upstream_code: Some(code.to_owned()), ..CloudError::new(ours, message.to_owned()) }
}

/// The dial target of `machine`'s daemon for file ops, or the typed reason
/// there is none. The capability gate runs first: it needs only a read.
pub(crate) fn target<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
) -> Result<DialTarget, CloudError> {
    let info = crate::link::info::connect_info(server, machine)?;
    if !info.daemon.capabilities.iter().any(|c| c == FS_CAPABILITY) {
        return Err(CloudError::new(
            codes::UNSUPPORTED,
            format!("The machine's cmux daemon has no file ops yet (needs {FS_CAPABILITY})"),
        ));
    }
    if info.state == crate::api::models::MachineStatus::Paused {
        return Err(CloudError::new(
            codes::MACHINE_PAUSED,
            "The machine is paused: start it to use its files",
        ));
    }
    if !info.services.iter().any(|s| s == "daemon") {
        return Err(CloudError::new(
            codes::FORBIDDEN,
            "This Mac may not reach the machine's cmux daemon (team policy)",
        ));
    }
    let paths = server.link_paths()?;
    let (binary, socket) = (paths.binary, paths.hub_socket);
    let env = server.attach().env().child_env().map_err(|e| {
        CloudError::new(
            crate::link::ops::LINK_UNAVAILABLE,
            format!("no private home for the link: {e}"),
        )
    })?;
    Ok(DialTarget { binary, host: info.host, socket, env })
}

/// One file op's way to the machine's daemon: the dial target, the daemon
/// file ops and the op's cancel. Built on the loop (it passes the gate),
/// used on a worker.
pub(crate) struct Daemon {
    pub(crate) files: Arc<dyn DaemonFiles>,
    pub(crate) target: DialTarget,
    pub(crate) cancel: Cancel,
}

impl Daemon {
    /// One daemon `fs.*` op; a cancelled op sends nothing more.
    pub(crate) fn call(&self, op: &str, params: Value) -> Result<Value, CloudError> {
        if self.cancel.is_cancelled() {
            return Err(cancelled());
        }
        self.files.call(&self.target, op, params, &self.cancel)
    }

    /// One `fs.write` of `len` raw bytes, reconciled after a lost answer
    /// ([`write_reconciled`]).
    pub(crate) fn write(&self, params: Value, len: u64) -> Result<Value, CloudError> {
        if self.cancel.is_cancelled() {
            return Err(cancelled());
        }
        write_reconciled(&*self.files, &self.target, params, len, &self.cancel)
    }
}

fn cancelled() -> CloudError {
    CloudError::new(super::FILE_OP_CANCELLED, "The file op was cancelled")
}

/// The [`Daemon`] of `machine`, behind the gate.
pub(crate) fn daemon<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
) -> Result<Daemon, CloudError> {
    let target = target(server, machine)?;
    let files = Arc::clone(&server.edge_parts().0.files);
    Ok(Daemon { files, target, cancel: Cancel::default() })
}
