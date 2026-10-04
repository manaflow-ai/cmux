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
use std::sync::{Arc, mpsc};
use std::time::Duration;

/// The daemon capability that carries the `fs.*` ops.
pub const FS_CAPABILITY: &str = "fs-v1";

/// The bound on one daemon file op: the op loop is single-threaded, so a
/// daemon that never answers must not hold it.
pub const DAEMON_OP_TIMEOUT: Duration = Duration::from_secs(30);

/// The largest daemon answer line (a 16 MiB read in base64, plus framing).
const MAX_ANSWER_BYTES: u64 = 24 * 1024 * 1024;

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
        let (sender, receiver) = mpsc::channel();
        let worker = {
            let target = target.clone();
            let children = Arc::clone(&children);
            std::thread::Builder::new()
                .name("cmux-cloud-fs".into())
                .spawn(move || {
                    let _ = sender.send(exchange(&target, &line, &children));
                })
                .map_err(|e| unavailable(format!("no worker for the daemon op: {e}")))?
        };
        // A cancel ends the dial child (ours) at any step, like the deadline.
        let on_cancel = Arc::clone(&children);
        cancel.on_cancel(move || end_all(&on_cancel));
        let answer = match receiver.recv_timeout(DAEMON_OP_TIMEOUT) {
            Ok(answer) => answer,
            Err(_) => Err(unavailable(format!(
                "the machine's daemon did not answer {op} within {} s",
                DAEMON_OP_TIMEOUT.as_secs()
            ))),
        };
        end_all(&children);
        drop(worker);
        decode_answer(op, &answer?)
    }
}

/// One dial, one request line, one answer line (on the worker).
fn exchange(target: &DialTarget, line: &str, children: &Children) -> Result<Vec<u8>, CloudError> {
    let Dialed { child, mut stdin, stdout } =
        open_dial(&target.binary, &dial_args(&target.host), &target.env, children)
            .map_err(|code| unavailable(format!("cmux link refused: {}", code.as_str())))?;
    let sent = stdin.write_all(line.as_bytes()).and_then(|()| stdin.flush());
    drop(stdin);
    sent.map_err(|e| unavailable(format!("the daemon link closed: {e}")))?;
    let mut answer = Vec::new();
    BufReader::new(stdout)
        .take(MAX_ANSWER_BYTES)
        .read_until(b'\n', &mut answer)
        .map_err(|e| unavailable(format!("the daemon link closed: {e}")))?;
    end_child(&child, children);
    Ok(answer)
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
    let binary = server.link_paths()?.binary;
    let env = server.attach().env().child_env().map_err(|e| {
        CloudError::new(
            crate::link::ops::LINK_UNAVAILABLE,
            format!("no private home for the link: {e}"),
        )
    })?;
    let socket = PathBuf::new();
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
