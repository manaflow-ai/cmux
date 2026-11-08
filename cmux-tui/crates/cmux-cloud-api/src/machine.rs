//! A machine's exec and file routes. A Worker machine's go through `cmux cloud machine-io`'s
//! logic ([`crate::machine_io`]: straight to the provider with a client session when
//! it can, else the cmux API's `/v1/cloud/machines/{id}/...`); classic's are `/api/vm/{id}/exec` and
//! `/api/vm/{id}/fs/...`, as they were. Either answer reads the same way.

use std::time::Duration;

use cmux_json::JsonSet as _;
use reqwest::Method;
use serde_json::{Map, Value, json};

use super::http::{Http, vm_error};
use super::{Failure, Request, optional_int, text};
use crate::machine_io;
use crate::session::secure_origin;

/// `machine.io` on a Worker machines client: `args` is machine-io's request without the person's
/// fields (`op`, `machine`, `path`, `data_base64`, `mode`, `command`, `timeout_ms`; a `cache_dir` is dropped).
pub(crate) async fn worker(request: &Request) -> Result<Value, Failure> {
    let api = secure_origin(request.api.trim()).map_err(Failure::Transport)?;
    let mut fields = request.args.clone();
    // The daemon and this library keep no session on disk: a caller never picks a cache.
    fields.remove("cache_dir");
    fields.insert("api".into(), json!(api));
    fields.insert("credential".into(), json!(request.credential));
    if let Some(team) = request.team.as_deref().filter(|t| !t.is_empty()) {
        fields.insert("team".into(), json!(team));
    }
    if let Some(version) = &request.app_version {
        fields.insert("app_version".into(), json!(version));
    }
    fields.insert("local_only".into(), json!(request.local_only));
    // A file's bytes come back as base64 inside the answer: 12 MiB less 64 KiB stays under it.
    fields.insert("max_bytes".into(), json!(FILE_LIMIT));
    let io: machine_io::Request = serde_json::from_value(Value::Object(fields))
        .map_err(|e| Failure::Transport(format!("not a machine request: {e}")))?;
    let client = machine_io::http_client().map_err(Failure::Transport)?;
    let (route, answer) = machine_io::perform(&client, &io, machine_io::now_ms).await;
    let mut answer = machine_io::scrub(answer, &io.credential);
    // The line machine-io prints, so a file's verified bytes come back as `dataBase64`.
    let mut line = Capped(Vec::new());
    machine_io::write_line(&mut line, route, &mut answer)
        .map_err(|e| Failure::Transport(format!("the machine's answer could not be read: {e}")))?;
    let line: Value = serde_json::from_slice(&line.0)
        .map_err(|e| Failure::Transport(format!("the machine's answer could not be read: {e}")))?;
    let path = route_path(&io.machine, op_name(&request.args));
    read(&line, &path)
}

/// The most bytes a Worker machine read or listing may come to through the daemon.
const FILE_LIMIT: u64 = 12_517_376;

/// A buffer that refuses to grow past [`crate::MAX_ANSWER_BYTES`], so a file or listing larger
/// than any answer may be is refused while it is copied, never held whole.
struct Capped(Vec<u8>);

impl std::io::Write for Capped {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > crate::MAX_ANSWER_BYTES.saturating_sub(self.0.len()) {
            return Err(std::io::Error::other(format!(
                "the answer is larger than {} bytes",
                crate::MAX_ANSWER_BYTES
            )));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn op_name(args: &Map<String, Value>) -> &str {
    args.get("op").and_then(Value::as_str).unwrap_or_default()
}

/// The route an op names, as an error names it.
fn route_path(machine: &str, op: &str) -> String {
    if op == "exec" {
        format!("/v1/cloud/machines/{machine}/exec")
    } else {
        format!("/v1/cloud/machines/{machine}/fs/{op}")
    }
}

/// A machine-io line (`{route, status, code, body}`): the body of a 2xx, else what the route's
/// refusal says. Status 0 is no answer at all (`code` says why: `timed_out` or `transport`).
pub(crate) fn read(line: &Value, path: &str) -> Result<Value, Failure> {
    let status =
        line.get("status").and_then(Value::as_u64).and_then(|s| u16::try_from(s).ok()).unwrap_or(0);
    let code = line.get("code").and_then(Value::as_str);
    let body = line.get("body").cloned().unwrap_or(Value::Null);
    match status {
        0 if code == Some("timed_out") => Err(Failure::TimedOut(path.to_owned())),
        0 if code == Some("no_backend") => Err(Failure::NoBackend),
        0 if code == Some("decoding") => Err(Failure::Decoding(format!("{path}: not JSON"))),
        0 if code == Some("too_large") => {
            Err(Failure::Transport(format!("{path}: the answer is larger than {FILE_LIMIT} bytes")))
        }
        0 => Err(Failure::Transport(code.unwrap_or("no answer").to_owned())),
        200..=299 => Ok(body),
        _ => Err(vm_error(status, body.to_string().as_bytes(), code)),
    }
}

/// `machine.io` on the classic client: the same ops on `/api/vm/{id}/...`.
pub(crate) async fn classic(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "machine")?;
    let path = || text(args, "path").map(|p| vec![("path", p.to_owned())]);
    let secs = Duration::from_secs;
    match op_name(args) {
        "exec" => {
            let ms = optional_int(args, "timeout_ms").unwrap_or(30_000);
            let body = json!({ "command": text(args, "command")?, "timeoutMs": ms });
            let timeout = Duration::from_millis(u64::try_from(ms.max(0)).unwrap_or(0))
                .saturating_add(secs(5));
            http.classic(Method::POST, &["api", "vm", id, "exec"], &[], Some(body), None, timeout)
                .await
        }
        "dir" => {
            http.classic(
                Method::GET,
                &["api", "vm", id, "fs", "dir"],
                &path()?,
                None,
                None,
                secs(20),
            )
            .await
        }
        "read" => {
            http.classic(
                Method::GET,
                &["api", "vm", id, "fs", "read"],
                &path()?,
                None,
                None,
                secs(120),
            )
            .await
        }
        "stat" => {
            http.classic(
                Method::GET,
                &["api", "vm", id, "fs", "stat"],
                &path()?,
                None,
                None,
                secs(20),
            )
            .await
        }
        "remove" => {
            http.classic(
                Method::DELETE,
                &["api", "vm", id, "fs", "remove"],
                &path()?,
                None,
                None,
                secs(120),
            )
            .await
        }
        "mkdir" => {
            let body = json!({ "path": text(args, "path")? });
            http.classic(
                Method::POST,
                &["api", "vm", id, "fs", "mkdir"],
                &[],
                Some(body),
                None,
                secs(20),
            )
            .await
        }
        "write" => {
            let mut body =
                json!({ "path": text(args, "path")?, "dataBase64": text(args, "data_base64")? });
            if let Some(mode) = optional_int(args, "mode") {
                body.set("mode", json!(mode));
            }
            http.classic(
                Method::POST,
                &["api", "vm", id, "fs", "write"],
                &[],
                Some(body),
                None,
                secs(120),
            )
            .await
        }
        other => Err(Failure::Transport(format!("no machine op {other:?}"))),
    }
}
