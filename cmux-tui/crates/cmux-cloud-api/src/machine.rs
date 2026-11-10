//! A machine's exec and file routes. A Worker machine's go through `cmux cloud machine-io`'s
//! logic ([`crate::machine_io`]: straight to the provider with a client session when
//! it can, else the cmux API's `/v1/cloud/machines/{id}/...`). A machine's SCP route
//! ([`scp_endpoint`]) is always cmux-platform's.

use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use reqwest::Method;
use serde_json::{Map, Value, json};

use super::http::{Auth, Body, Http, path_text, vm_error};
use super::owner::is_machine_id;
use super::{Failure, Request, text};
use crate::session::secure_origin;
use crate::{local_file, machine_io};

/// `machine.io` on a Worker machines client: `args` is machine-io's request without the person's
/// fields (`op`, `machine`, `path`, `data_base64`, `mode`, `command`, `timeout_ms`; a `cache_dir` is
/// dropped), and optionally `local_path`: a read or write through a file of the caller's in the
/// transfer folder instead of base64 in the call ([`crate::local_file`]).
pub(crate) async fn worker(request: &Request) -> Result<Value, Failure> {
    worker_in(request, local_file::transfer_dir().as_deref()).await
}

/// [`worker`] with the transfer folder `transfer` (none: the path form is refused).
pub(crate) async fn worker_in(
    request: &Request,
    transfer: Option<&Path>,
) -> Result<Value, Failure> {
    let api = secure_origin(request.api.trim()).map_err(Failure::Transport)?;
    let mut fields = request.args.clone();
    // The daemon and this library keep no session on disk: a caller never picks a cache.
    fields.remove("cache_dir");
    let local = match fields.remove("local_path") {
        None | Some(Value::Null) => None,
        Some(Value::String(path)) => Some(path),
        Some(_) => return Err(local_refusal("local_path is a string")),
    };
    let op = op_name(&request.args);
    let (mut data, mut destination) = (None, None);
    if let Some(path) = &local {
        let dir = transfer.ok_or_else(|| local_refusal("this system has no transfer folder"))?;
        match op {
            "write" if !fields.contains_key("data_base64") => {
                data = Some(local_file::read_source(dir, path).map_err(|e| local_refusal(&e))?);
            }
            "read" => {
                destination =
                    Some(local_file::create_destination(dir, path).map_err(|e| local_refusal(&e))?);
            }
            _ => return Err(local_refusal("local_path is for a file read or a write alone")),
        }
    }
    let result = run(request, &api, fields, data, destination.as_mut().map(|(_, file)| file)).await;
    if let (Some((path, _)), Err(_)) = (&destination, &result) {
        // The destination this call made, by its exact path: a failed read leaves no file.
        let _ = std::fs::remove_file(path);
    }
    result
}

async fn run(
    request: &Request,
    api: &str,
    mut fields: Map<String, Value>,
    data: Option<Vec<u8>>,
    destination: Option<&mut std::fs::File>,
) -> Result<Value, Failure> {
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
    // A read into a local file is not in the answer, so it may come to the path form's limit.
    let limit = if destination.is_some() { local_file::LIMIT } else { FILE_LIMIT };
    fields.insert("max_bytes".into(), json!(limit));
    let mut io: machine_io::Request = serde_json::from_value(Value::Object(fields))
        .map_err(|e| Failure::Transport(format!("not a machine request: {e}")))?;
    io.data_bytes = data;
    let client = machine_io::http_client().map_err(Failure::Transport)?;
    let (route, answer) = machine_io::perform(&client, &io, machine_io::now_ms).await;
    let mut answer = machine_io::scrub(answer, &io.credential);
    if let Some(out) = destination {
        local_file::deliver(&mut answer, out).map_err(|e| local_refusal(&e))?;
    }
    // The line machine-io prints, so a file's verified bytes come back as `dataBase64`.
    let mut line = Capped(Vec::new());
    machine_io::write_line(&mut line, route, &mut answer)
        .map_err(|e| Failure::Transport(format!("the machine's answer could not be read: {e}")))?;
    let line: Value = serde_json::from_slice(&line.0)
        .map_err(|e| Failure::Transport(format!("the machine's answer could not be read: {e}")))?;
    let path = route_path(&io.machine, op_name(&request.args));
    read(&line, &path, limit)
}

/// A refused or failed local file of the path form.
fn local_refusal(message: &str) -> Failure {
    Failure::Transport(format!("local_path: {message}"))
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
pub(crate) fn read(line: &Value, path: &str, limit: u64) -> Result<Value, Failure> {
    let status =
        line.get("status").and_then(Value::as_u64).and_then(|s| u16::try_from(s).ok()).unwrap_or(0);
    let code = line.get("code").and_then(Value::as_str);
    let body = line.get("body").cloned().unwrap_or(Value::Null);
    match status {
        0 if code == Some("timed_out") => Err(Failure::TimedOut(path.to_owned())),
        0 if code == Some("no_backend") => Err(Failure::NoBackend),
        0 if code == Some("decoding") => Err(Failure::Decoding(format!("{path}: not JSON"))),
        0 if code == Some("too_large") => {
            // The route's own words name the limit it hit (a direct read's, or the proxy's).
            let message = body.pointer("/error/message").and_then(Value::as_str);
            let message = message
                .map_or_else(|| format!("the answer is larger than {limit} bytes"), str::to_owned);
            Err(Failure::Transport(format!("{path}: {message}")))
        }
        0 => Err(Failure::Transport(code.unwrap_or("no answer").to_owned())),
        200..=299 => Ok(body),
        _ => Err(vm_error(status, body.to_string().as_bytes(), code)),
    }
}

/// `vm.scp_endpoint`: cmux-platform's `POST /v1/cloud/machines/{id}/ssh-endpoint` with the
/// caller's `publicKey` (the app's `prepareSCP`), answered only when the route is safe
/// ([`safe_scp_endpoint`]). Classic's `/api/vm/{id}/scp-endpoint` is never called: a `stack`
/// call is refused before any request.
pub(crate) async fn scp_endpoint(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    if http.auth == Auth::Stack {
        return Err(Failure::Transport(
            "an SCP route comes from cmux-platform: send the call with auth worker".into(),
        ));
    }
    let id = text(args, "id")?;
    // The id is the only path part that varies, so nothing else ever lands in the URL.
    if !is_machine_id(id) {
        return Err(Failure::Transport("not a Cloud machine id".into()));
    }
    let body = json!({ "publicKey": text(args, "publicKey")? });
    let segments = ["v1", "cloud", "machines", id, "ssh-endpoint"];
    let path = path_text(&segments);
    let reply = http
        .send(
            Method::POST,
            http.url(&segments, &[]),
            Some(Body::Json(body)),
            None,
            Duration::from_secs(100),
            &path,
        )
        .await?;
    if !reply.ok() {
        return Err(vm_error(reply.status, &reply.body, reply.header_code.as_deref()));
    }
    let endpoint =
        reply.json().ok_or_else(|| Failure::Decoding(format!("{path}: the answer is not JSON")))?;
    if safe_scp_endpoint(&endpoint, now_secs()) {
        Ok(endpoint)
    } else {
        Err(Failure::Decoding(format!("{path} returned an unsafe endpoint")))
    }
}

/// A private SCP route the app may hand to `scp`: port 22, user `cmux`, an ed25519 host key,
/// and not expired.
pub(crate) fn safe_scp_endpoint(endpoint: &Value, now: i64) -> bool {
    let either = |a: &str, b: &str| endpoint.get(a).or_else(|| endpoint.get(b));
    endpoint.get("port").and_then(Value::as_i64) == Some(22)
        && endpoint.get("username").and_then(Value::as_str) == Some("cmux")
        && either("hostPublicKey", "host_public_key")
            .and_then(Value::as_str)
            .is_some_and(|k| k.starts_with("ssh-ed25519 "))
        && either("expiresAtUnix", "expires_at_unix")
            .and_then(Value::as_i64)
            .is_some_and(|t| t > now)
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}
