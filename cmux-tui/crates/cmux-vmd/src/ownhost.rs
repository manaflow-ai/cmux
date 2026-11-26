//! cmux-platform's own-host contract (cmux-platform `src/server/cloud/ownhost/API.md`, v1), served
//! beside the daemon's own `/v1/machines` API on the same bearer token.
//!
//! ```text
//! POST   /v1/vms                  {request_id, template_id, vcpus, mem_mib, disk_gib, name, tag}
//! GET    /v1/vms?name=N | ?label=KEY:VALUE&offset=&limit=
//! GET    /v1/vms/{id}
//! DELETE /v1/vms/{id}             {request_id}
//! POST   /v1/vms/{id}/resume      {request_id}
//! POST   /v1/vms/{id}/pause       {request_id}
//! PUT    /v1/vms/{id}/files       {path, mode?, content_b64}      (the bind file)
//! POST   /v1/vms/{id}/exec        {command, stdin_b64?, timeout_ms?}
//! PUT    /v1/templates/{name}     {snapshot_id}
//! GET    /v1/templates
//! DELETE /v1/templates/{name}
//! ```
//!
//! A create forks the template's snapshot: `template_id@<vcpus>x<mem_mib>` first (a snapshot
//! made at that size), then `template_id`. A snapshot keeps the size it was taken at, so every
//! view reports the size the VM really has. Every mutating verb is idempotent on its
//! `request_id`: applied requests are kept in `ownhost/ledger.jsonl` under the daemon root (one
//! line each, compacted on open), so a retry after a daemon restart replays instead of acting
//! twice. The owner tag is stored in the machine's labels as `tag:<key>`.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use axum::Json;
use axum::Router;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post, put};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::host::{CreateRequest, ExecRequest, Host, MachineMeta, RunState, VmdError};
use crate::net::Egress;
use crate::server::{ApiError, ApiResult};

const TAG_PREFIX: &str = "tag:";
/// Applied requests kept for replay; past this the oldest go first.
const LEDGER_CAP: usize = 50_000;
const LIST_MAX: usize = 1000;
const FILE_MAX: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Verb {
    Create,
    Resume,
    Pause,
    Delete,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Record {
    request_id: String,
    verb: Verb,
    /// sha256 of the request's canonical body, so a reuse with another body is caught.
    body: String,
    vm_id: String,
    at_ms: u64,
}

#[derive(Default)]
struct Ledger {
    requests: BTreeMap<String, Record>,
    /// Request ids and names of creates on their way up.
    creating: BTreeSet<String>,
    creating_names: BTreeSet<String>,
}

pub struct OwnHost {
    host: Arc<Host>,
    dir: PathBuf,
    ledger: Mutex<Ledger>,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn rfc3339(ms: u64) -> String {
    chrono::DateTime::from_timestamp_millis(ms as i64)
        .unwrap_or_default()
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

fn bad(msg: impl Into<String>) -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, "invalid_input", msg.into())
}

fn conflict(code: &'static str, msg: impl Into<String>) -> ApiError {
    ApiError(StatusCode::CONFLICT, code, msg.into())
}

fn not_found() -> ApiError {
    ApiError(StatusCode::NOT_FOUND, "vm_not_found", "no such VM".into())
}

/// `[A-Za-z0-9][A-Za-z0-9_-]{0,127}`
pub fn valid_vm_id(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 128
        && b[0].is_ascii_alphanumeric()
        && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'_' || *c == b'-')
}

/// `[a-z0-9][a-z0-9-]{0,127}`
pub fn valid_vm_name(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 128
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

/// `[a-z][a-z0-9_]{0,62}`
pub fn valid_tag_key(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 63
        && b[0].is_ascii_lowercase()
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
}

/// Template names: `[a-z0-9][a-z0-9._@-]{0,127}` (the `@` carries a size suffix).
fn valid_template(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 128
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter().all(|c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'.' | b'_' | b'-' | b'@')
        })
}

fn valid_request_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 256 && s.bytes().all(|c| c.is_ascii_graphic())
}

fn tag_of(m: &MachineMeta) -> BTreeMap<String, String> {
    m.labels
        .iter()
        .filter_map(|(k, v)| k.strip_prefix(TAG_PREFIX).map(|k| (k.to_owned(), v.clone())))
        .collect()
}

fn digest(value: &impl Serialize) -> String {
    let bytes = serde_json::to_vec(value).unwrap_or_default();
    Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect()
}

#[derive(Deserialize)]
struct CreateBody {
    request_id: String,
    template_id: String,
    vcpus: u32,
    mem_mib: u32,
    disk_gib: u32,
    name: String,
    #[serde(default)]
    tag: BTreeMap<String, Value>,
}

/// The fields a replay must match, in a fixed order (the tag map is sorted).
#[derive(Serialize)]
struct CreateKey<'a> {
    template_id: &'a str,
    vcpus: u32,
    mem_mib: u32,
    disk_gib: u32,
    name: &'a str,
    tag: &'a BTreeMap<String, String>,
}

#[derive(Deserialize, Default)]
struct PowerBody {
    #[serde(default)]
    request_id: String,
}

#[derive(Deserialize)]
struct ListQuery {
    name: Option<String>,
    label: Option<String>,
    #[serde(default)]
    offset: usize,
    limit: Option<usize>,
}

#[derive(Deserialize)]
struct FileBody {
    path: String,
    mode: Option<u32>,
    content_b64: String,
}

#[derive(Deserialize)]
struct ExecBody {
    command: String,
    #[serde(default)]
    stdin_b64: String,
    #[serde(default)]
    timeout_ms: u64,
}

#[derive(Deserialize)]
struct TemplateBody {
    snapshot_id: String,
}

impl OwnHost {
    /// Load the ledger (compacting it) from `<root>/ownhost`.
    pub async fn open(host: Arc<Host>) -> anyhow::Result<Arc<Self>> {
        let dir = host.config().root.join("ownhost");
        tokio::fs::create_dir_all(dir.join("templates")).await?;
        let mut ledger = Ledger::default();
        if let Ok(text) = tokio::fs::read_to_string(dir.join("ledger.jsonl")).await {
            for line in text.lines() {
                if let Ok(r) = serde_json::from_str::<Record>(line) {
                    ledger.requests.insert(r.request_id.clone(), r);
                }
            }
        }
        prune(&mut ledger.requests);
        let own = Arc::new(Self { host, dir, ledger: Mutex::new(ledger) });
        own.compact()?;
        Ok(own)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Ledger> {
        self.ledger.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn compact(&self) -> anyhow::Result<()> {
        let mut out = Vec::new();
        for r in self.lock().requests.values() {
            serde_json::to_writer(&mut out, r)?;
            out.push(b'\n');
        }
        let tmp = self.dir.join("ledger.jsonl.tmp");
        std::fs::write(&tmp, out)?;
        std::fs::rename(tmp, self.dir.join("ledger.jsonl"))?;
        Ok(())
    }

    /// Keep an applied request; on disk before its reply goes out.
    fn record(&self, r: Record) -> Result<(), ApiError> {
        let mut line = serde_json::to_vec(&r).map_err(|e| backend(e.into()))?;
        line.push(b'\n');
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("ledger.jsonl"))
            .map_err(|e| backend(e.into()))?;
        f.write_all(&line).and_then(|()| f.sync_data()).map_err(|e| backend(e.into()))?;
        let mut l = self.lock();
        l.requests.insert(r.request_id.clone(), r);
        prune(&mut l.requests);
        Ok(())
    }

    fn template_snapshot(&self, template: &str, vcpus: u32, mem_mib: u32) -> Option<String> {
        [format!("{template}@{vcpus}x{mem_mib}"), template.to_owned()].into_iter().find_map(|t| {
            let sid = std::fs::read_to_string(self.dir.join("templates").join(t)).ok()?;
            let sid = sid.trim().to_owned();
            self.host.snapshot_meta(&sid).map(|_| sid)
        })
    }

    fn view(&self, m: &MachineMeta) -> Value {
        let disk = self.host.disk_bytes(&m.id).div_ceil(1 << 30).max(1);
        json!({
            "vm_id": m.id,
            "state": match m.state { RunState::Running => "running", RunState::Paused => "paused" },
            "name": m.name,
            "tag": tag_of(m),
            "vcpus": m.vcpus,
            "mem_mib": m.mem_mib,
            "disk_gib": disk,
            "created_at": rfc3339(m.created_unix_ms),
        })
    }

    /// The VM's view now (state `deleted` once it is gone), with this request's receipt.
    fn answer(&self, r: &Record, outcome: &str, status: StatusCode) -> axum::response::Response {
        let mut v = match self.host.get(&r.vm_id) {
            Ok(m) => self.view(&m),
            Err(_) => json!({"vm_id": r.vm_id, "state": "deleted"}),
        };
        v["receipt"] = json!({
            "request_id": r.request_id,
            "verb": r.verb,
            "vm_id": r.vm_id,
            "at": rfc3339(r.at_ms),
            "outcome": outcome,
        });
        (status, Json(v)).into_response()
    }

    /// A request id seen before: its replay when it asked the same thing, else 409.
    fn seen(&self, request_id: &str, verb: Verb, body: &str) -> Result<Option<Record>, ApiError> {
        match self.lock().requests.get(request_id) {
            None => Ok(None),
            Some(r) if r.verb == verb && r.body == body => Ok(Some(r.clone())),
            Some(_) => Err(conflict("request_conflict", "request_id was used with another body")),
        }
    }
}

fn backend(e: anyhow::Error) -> ApiError {
    ApiError::from(VmdError::Backend(e))
}

fn prune(requests: &mut BTreeMap<String, Record>) {
    if requests.len() <= LEDGER_CAP {
        return;
    }
    let mut by_age: Vec<(u64, String)> =
        requests.values().map(|r| (r.at_ms, r.request_id.clone())).collect();
    by_age.sort();
    for (_, id) in by_age.into_iter().take(requests.len() - LEDGER_CAP) {
        requests.remove(&id);
    }
}

pub fn routes<S: Clone + Send + Sync + 'static>(own: Arc<OwnHost>) -> Router<S> {
    Router::new()
        .route("/v1/vms", post(create).get(list))
        .route("/v1/vms/{id}", get(get_one).delete(remove))
        .route("/v1/vms/{id}/resume", post(resume))
        .route("/v1/vms/{id}/pause", post(pause))
        .route("/v1/vms/{id}/files", put(write_file))
        .route("/v1/vms/{id}/exec", post(exec))
        .route("/v1/templates", get(templates))
        .route("/v1/templates/{name}", put(put_template).delete(delete_template))
        .with_state(own)
}

type St = State<Arc<OwnHost>>;

/// Clears a create's in-flight marks however it ends.
struct Creating<'a> {
    own: &'a OwnHost,
    request_id: String,
    name: String,
}

impl Drop for Creating<'_> {
    fn drop(&mut self) {
        let mut l = self.own.lock();
        l.creating.remove(&self.request_id);
        l.creating_names.remove(&self.name);
    }
}

async fn create(State(own): St, Json(b): Json<CreateBody>) -> ApiResult {
    if !valid_request_id(&b.request_id) {
        return Err(bad("bad request_id"));
    }
    if !valid_vm_name(&b.name) {
        return Err(bad("bad name"));
    }
    if !valid_template(&b.template_id) {
        return Err(bad("bad template_id"));
    }
    if b.vcpus == 0 || b.mem_mib == 0 || b.disk_gib == 0 {
        return Err(bad("vcpus, mem_mib and disk_gib must be positive"));
    }
    if b.tag.len() > 16 {
        return Err(bad("at most 16 tag keys"));
    }
    let mut tag = BTreeMap::new();
    for (k, v) in &b.tag {
        let Some(v) = v.as_str() else { return Err(bad(format!("tag {k} is not a string"))) };
        if !valid_tag_key(k) || v.len() > 1024 {
            return Err(bad(format!("bad tag key {k:?} or value")));
        }
        tag.insert(k.clone(), v.to_owned());
    }
    let key = digest(&CreateKey {
        template_id: &b.template_id,
        vcpus: b.vcpus,
        mem_mib: b.mem_mib,
        disk_gib: b.disk_gib,
        name: &b.name,
        tag: &tag,
    });
    let _creating = {
        if let Some(r) = own.seen(&b.request_id, Verb::Create, &key)? {
            return Ok(own.answer(&r, "replayed", StatusCode::OK));
        }
        let mut l = own.lock();
        if l.creating.contains(&b.request_id) {
            return Err(ApiError(
                StatusCode::SERVICE_UNAVAILABLE,
                "in_flight",
                "this request is still being applied".into(),
            ));
        }
        if l.creating_names.contains(&b.name) || own.host.list().iter().any(|m| m.name == b.name) {
            return Err(conflict("name_taken", "another VM holds the name"));
        }
        l.creating.insert(b.request_id.clone());
        l.creating_names.insert(b.name.clone());
        Creating { own: &own, request_id: b.request_id.clone(), name: b.name.clone() }
    };
    let Some(sid) = own.template_snapshot(&b.template_id, b.vcpus, b.mem_mib) else {
        return Err(ApiError(
            StatusCode::UNPROCESSABLE_ENTITY,
            "template_not_found",
            "no snapshot for the template".into(),
        ));
    };
    let labels = tag.iter().map(|(k, v)| (format!("{TAG_PREFIX}{k}"), v.clone())).collect();
    let req = CreateRequest {
        name: b.name.clone(),
        labels,
        // The own-host transport never asks for a machine without the internet (API.md).
        egress: Some(Egress::Internet),
        ..CreateRequest::default()
    };
    let (m, _timing) = own.host.fork(&sid, req).await?;
    let r = Record {
        request_id: b.request_id,
        verb: Verb::Create,
        body: key,
        vm_id: m.id,
        at_ms: now_ms(),
    };
    own.record(r.clone())?;
    Ok(own.answer(&r, "applied", StatusCode::CREATED))
}

async fn power(own: Arc<OwnHost>, id: String, b: PowerBody, verb: Verb) -> ApiResult {
    if !valid_vm_id(&id) {
        return Err(not_found());
    }
    if !valid_request_id(&b.request_id) {
        return Err(bad("bad request_id"));
    }
    if let Some(r) = own.seen(&b.request_id, verb, &id)? {
        return Ok(own.answer(&r, "replayed", StatusCode::OK));
    }
    let want = if verb == Verb::Pause { RunState::Paused } else { RunState::Running };
    let m = own.host.get(&id).map_err(|_| not_found())?;
    let r = Record {
        request_id: b.request_id,
        verb,
        body: id.clone(),
        vm_id: id.clone(),
        at_ms: now_ms(),
    };
    if m.state == want {
        return Ok(own.answer(&r, "replayed", StatusCode::OK));
    }
    let done =
        if verb == Verb::Pause { own.host.pause(&id).await } else { own.host.resume(&id).await };
    match done {
        Ok(_) => {}
        // Another request got there first: this one finds the VM as it asked.
        Err(VmdError::InvalidState { .. }) if own.host.get(&id).is_ok_and(|m| m.state == want) => {
            return Ok(own.answer(&r, "replayed", StatusCode::OK));
        }
        Err(VmdError::MachineNotFound) => return Err(not_found()),
        Err(e) => return Err(e.into()),
    }
    own.record(r.clone())?;
    Ok(own.answer(&r, "applied", StatusCode::OK))
}

async fn resume(State(own): St, Path(id): Path<String>, b: Option<Json<PowerBody>>) -> ApiResult {
    power(own, id, b.map(|Json(b)| b).unwrap_or_default(), Verb::Resume).await
}

async fn pause(State(own): St, Path(id): Path<String>, b: Option<Json<PowerBody>>) -> ApiResult {
    power(own, id, b.map(|Json(b)| b).unwrap_or_default(), Verb::Pause).await
}

async fn remove(State(own): St, Path(id): Path<String>, b: Option<Json<PowerBody>>) -> ApiResult {
    if !valid_vm_id(&id) {
        return Err(not_found());
    }
    let b = b.map(|Json(b)| b).unwrap_or_default();
    let request_id = if b.request_id.is_empty() { format!("delete:{id}") } else { b.request_id };
    if !valid_request_id(&request_id) {
        return Err(bad("bad request_id"));
    }
    if let Some(r) = own.seen(&request_id, Verb::Delete, &id)? {
        return Ok(own.answer(&r, "replayed", StatusCode::OK));
    }
    let m = own.host.get(&id).map_err(|_| not_found())?;
    match own.host.delete(&id).await {
        Ok(()) | Err(VmdError::MachineNotFound) => {}
        Err(e) => return Err(e.into()),
    }
    let r = Record { request_id, verb: Verb::Delete, body: id.clone(), vm_id: id, at_ms: now_ms() };
    own.record(r.clone())?;
    let mut v = json!({"vm_id": m.id, "state": "deleted", "name": m.name, "tag": tag_of(&m)});
    v["receipt"] = json!({
        "request_id": r.request_id, "verb": r.verb, "vm_id": r.vm_id,
        "at": rfc3339(r.at_ms), "outcome": "applied",
    });
    Ok(Json(v).into_response())
}

async fn get_one(State(own): St, Path(id): Path<String>) -> ApiResult {
    let m = own.host.get(&id).map_err(|_| not_found())?;
    Ok(Json(own.view(&m)).into_response())
}

async fn list(State(own): St, Query(q): Query<ListQuery>) -> ApiResult {
    let all = own.host.list();
    if let Some(name) = q.name {
        let vms: Vec<Value> =
            all.iter().filter(|m| m.name == name).take(1).map(|m| own.view(m)).collect();
        return Ok(Json(json!({"vms": vms})).into_response());
    }
    let selected: Vec<&MachineMeta> = match &q.label {
        None => all.iter().collect(),
        Some(sel) => {
            let Some((k, v)) = sel.split_once(':') else { return Err(bad("label is KEY:VALUE")) };
            if !valid_tag_key(k) || v.is_empty() {
                return Err(bad("label is KEY:VALUE"));
            }
            let key = format!("{TAG_PREFIX}{k}");
            all.iter().filter(|m| m.labels.get(&key).is_some_and(|x| x == v)).collect()
        }
    };
    let limit = q.limit.unwrap_or(100).clamp(1, LIST_MAX);
    let vms: Vec<Value> = selected.iter().skip(q.offset).take(limit).map(|m| own.view(m)).collect();
    Ok(Json(json!({"vms": vms, "total": selected.len()})).into_response())
}

async fn write_file(State(own): St, Path(id): Path<String>, Json(b): Json<FileBody>) -> ApiResult {
    if !b.path.starts_with('/') || b.path.split('/').any(|c| c == "..") {
        return Err(bad("path must be absolute"));
    }
    let data =
        B64.decode(b.content_b64.as_bytes()).map_err(|_| bad("content_b64 is not base64"))?;
    if data.len() > FILE_MAX {
        return Err(bad("file too large"));
    }
    if b.mode.is_some_and(|m| m > 0o7777) {
        return Err(bad("bad mode"));
    }
    own.host.get(&id).map_err(|_| not_found())?;
    own.host.write_file(&id, &b.path, &data, b.mode).await?;
    Ok(Json(json!({"vm_id": id, "path": b.path, "bytes": data.len()})).into_response())
}

async fn exec(State(own): St, Path(id): Path<String>, Json(b): Json<ExecBody>) -> ApiResult {
    own.host.get(&id).map_err(|_| not_found())?;
    B64.decode(b.stdin_b64.as_bytes()).map_err(|_| bad("stdin_b64 is not base64"))?;
    let req = ExecRequest {
        program: "/bin/sh".into(),
        args: vec!["-c".into(), b.command],
        stdin: b.stdin_b64,
        timeout_ms: b.timeout_ms,
        ..ExecRequest::default()
    };
    let (exit_code, stdout, stderr) = own.host.exec(&id, req).await?;
    Ok(Json(json!({
        "exit_code": exit_code,
        "stdout_b64": B64.encode(stdout),
        "stderr_b64": B64.encode(stderr),
    }))
    .into_response())
}

async fn templates(State(own): St) -> ApiResult {
    let mut out = BTreeMap::new();
    let mut dir =
        tokio::fs::read_dir(own.dir.join("templates")).await.map_err(|e| backend(e.into()))?;
    while let Ok(Some(e)) = dir.next_entry().await {
        if let (Some(name), Ok(sid)) =
            (e.file_name().to_str().map(str::to_owned), tokio::fs::read_to_string(e.path()).await)
        {
            out.insert(name, sid.trim().to_owned());
        }
    }
    Ok(Json(json!({"templates": out})).into_response())
}

async fn put_template(
    State(own): St,
    Path(name): Path<String>,
    Json(b): Json<TemplateBody>,
) -> ApiResult {
    if !valid_template(&name) {
        return Err(bad("bad template name"));
    }
    if own.host.snapshot_meta(&b.snapshot_id).is_none() {
        return Err(ApiError::from(VmdError::SnapshotNotFound));
    }
    let path = own.dir.join("templates").join(&name);
    let tmp = path.with_extension("tmp");
    tokio::fs::write(&tmp, &b.snapshot_id).await.map_err(|e| backend(e.into()))?;
    tokio::fs::rename(&tmp, &path).await.map_err(|e| backend(e.into()))?;
    Ok(Json(json!({"template": name, "snapshot_id": b.snapshot_id})).into_response())
}

async fn delete_template(State(own): St, Path(name): Path<String>) -> ApiResult {
    if !valid_template(&name) {
        return Err(bad("bad template name"));
    }
    match tokio::fs::remove_file(own.dir.join("templates").join(&name)).await {
        Ok(()) => Ok(StatusCode::NO_CONTENT.into_response()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Err(ApiError(StatusCode::NOT_FOUND, "template_not_found", "no such template".into()))
        }
        Err(e) => Err(backend(e.into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contract_patterns() {
        assert!(valid_vm_id("vm-0123abcd"));
        assert!(!valid_vm_id("-vm"));
        assert!(!valid_vm_id("vm/1"));
        assert!(valid_vm_name("cmux-next-abc-1"));
        assert!(!valid_vm_name("Upper"));
        assert!(!valid_vm_name(&"a".repeat(129)));
        assert!(valid_tag_key("cmux_next_team"));
        assert!(!valid_tag_key("1team"));
        assert!(valid_template("autocloud@2x4096"));
        assert!(!valid_template("../x"));
        assert!(!valid_template(".x"));
    }

    #[test]
    fn create_key_ignores_tag_order() {
        let a: BTreeMap<String, String> =
            [("b".into(), "2".into()), ("a".into(), "1".into())].into_iter().collect();
        let k = |tag: &BTreeMap<String, String>| {
            digest(&CreateKey {
                template_id: "t",
                vcpus: 2,
                mem_mib: 4096,
                disk_gib: 10,
                name: "n",
                tag,
            })
        };
        let mut b = BTreeMap::new();
        b.insert("a".to_owned(), "1".to_owned());
        b.insert("b".to_owned(), "2".to_owned());
        assert_eq!(k(&a), k(&b));
        b.insert("a".to_owned(), "9".to_owned());
        assert_ne!(k(&a), k(&b));
    }

    #[test]
    fn prune_drops_oldest() {
        let mut m = BTreeMap::new();
        for i in 0..(LEDGER_CAP + 3) {
            let id = format!("r{i}");
            m.insert(
                id.clone(),
                Record {
                    request_id: id,
                    verb: Verb::Pause,
                    body: String::new(),
                    vm_id: "v".into(),
                    at_ms: i as u64,
                },
            );
        }
        prune(&mut m);
        assert_eq!(m.len(), LEDGER_CAP);
        assert!(!m.contains_key("r0") && !m.contains_key("r2") && m.contains_key("r3"));
    }

    #[test]
    fn times_are_rfc3339() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00.000Z");
    }
}
