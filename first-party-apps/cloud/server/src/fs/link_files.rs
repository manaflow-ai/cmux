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

use crate::api::{CloudError, ControlPlane, codes};
use crate::link::carrier::{DialStream, open_dial};
use crate::link::dial::dial_args;
use crate::ops::Server;
use serde_json::{Map, Value, json};
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::path::PathBuf;
use std::sync::mpsc;
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
    pub env: Vec<(String, String)>,
}

/// Sends one daemon `fs.*` op and returns its `data`. The real one dials;
/// tests use a fake.
pub trait DaemonFiles: Send + Sync {
    fn call(&self, target: &DialTarget, op: &str, params: Value) -> Result<Value, CloudError>;
}

/// The real [`DaemonFiles`]: one `cmux link dial --host <host_…>` per op,
/// one v12 request line, one answer line.
pub struct LinkDaemonFiles;

fn unavailable(why: impl Into<String>) -> CloudError {
    CloudError { retryable: true, ..CloudError::new(crate::link::ops::LINK_DOWN, why) }
}

impl DaemonFiles for LinkDaemonFiles {
    fn call(&self, target: &DialTarget, op: &str, params: Value) -> Result<Value, CloudError> {
        let DialStream { mut child, mut stdin, stdout } =
            open_dial(&target.binary, &dial_args(&target.host), &target.env)
                .map_err(|code| unavailable(format!("cmux link refused: {}", code.as_str())))?;
        let mut request = match params {
            Value::Object(map) => map,
            _ => Map::new(),
        };
        request.insert("id".into(), json!(1));
        request.insert("cmd".into(), json!(op));
        let line = format!("{}\n", Value::Object(request));
        let sent = stdin.write_all(line.as_bytes()).and_then(|()| stdin.flush());
        drop(stdin);
        // The answer is read on a worker so the op has a deadline; on the
        // deadline the dial child (ours) is ended, which ends the read.
        let (sender, receiver) = mpsc::channel();
        let reader = std::thread::Builder::new().name("cmux-cloud-fs".into()).spawn(move || {
            let mut answer = Vec::new();
            let read = BufReader::new(stdout).take(MAX_ANSWER_BYTES).read_until(b'\n', &mut answer);
            let _ = sender.send(read.map(|_| answer));
        });
        let answer = match (sent, reader) {
            (Err(e), _) => Err(unavailable(format!("the daemon link closed: {e}"))),
            (_, Err(e)) => Err(unavailable(format!("no reader for the daemon answer: {e}"))),
            (Ok(()), Ok(_)) => match receiver.recv_timeout(DAEMON_OP_TIMEOUT) {
                Ok(Ok(answer)) => Ok(answer),
                Ok(Err(e)) => Err(unavailable(format!("the daemon link closed: {e}"))),
                Err(_) => Err(unavailable(format!(
                    "the machine's daemon did not answer {op} within {} s",
                    DAEMON_OP_TIMEOUT.as_secs()
                ))),
            },
        };
        let _ = child.kill();
        let _ = child.wait();
        decode_answer(op, &answer?)
    }
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
        Some(false) => {
            let code = value["error"]["code"].as_str().unwrap_or("fs.error").to_owned();
            let message = value["error"]["message"].as_str().unwrap_or("the daemon refused");
            Err(fs_error(&code, message))
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
    Ok(DialTarget { binary, host: info.host, env })
}

/// One daemon `fs.*` op on `machine`, behind the gate.
pub(crate) fn call<C: ControlPlane>(
    server: &mut Server<C>,
    machine: &str,
    op: &str,
    params: Value,
) -> Result<Value, CloudError> {
    let target = target(server, machine)?;
    let files = std::sync::Arc::clone(&server.edge_parts().0.files);
    files.call(&target, op, params)
}
