//! ACP chat trajectories outside the VM (#25584): the Cloud role keeps a
//! copy of every acpmux session of this machine in cmux Cloud, readable
//! while the VM is paused or gone, and a machine restored from one of its
//! creator's snapshots imports the chats its disk lacks from the source
//! machine's copy, so they survive a pause, a resume and a replacement VM.
//!
//! - [`Mirror::sync`] reads acpmux's store as acpmux writes it
//!   (`sessions/<id>/session.json`, `events/NNNNNN.ndjson`), sends the
//!   records past the server's `last_seq` verbatim and in order, and the
//!   agent's own resume file (a Claude project `<sid>.jsonl`, a Codex
//!   rollout) as appended byte ranges cut at a line end. Only complete
//!   lines are sent: acpmux or the agent may be writing the last one.
//! - [`Mirror::prime`] reads this machine's copy and, read only, the copy
//!   of the machine it was restored from (`from: "parent"`); every chat of
//!   the source that this machine has neither on disk nor in its own copy
//!   waits for [`Mirror::restore`], which writes it as an
//!   `acpmux.bundle.v1` (acpmux `hub/transfer.rs`) and hands it to an
//!   [`Importer`] (`acp session import` as the work user) once acpmux runs.
//!   acpmux puts the agent's resume file back, so the chat continues, and
//!   from then on it is this machine's chat, kept in this machine's copy.
//!   A chat the snapshot's disk already has continues from the snapshot.
//!
//! Each machine writes only its own copy, a contiguous log
//! (`backend/apps/api/src/cloud-trajectory-store.ts`); this side never
//! skips a record. Sans I/O toward the API (the [`Api`] trait), with the
//! file system read directly, so tests use a fake server and a temp dir.

use std::collections::HashMap;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};

use serde_json::{Value, json};

use super::sender::Answer;
use crate::json::JsonField;

/// Records per append; the server takes at most 2000.
pub const BATCH_LINES: usize = 1000;
/// Bytes of records per append (the server's body limit is 8 MiB).
pub const BATCH_BYTES: usize = 2 * 1024 * 1024;
/// The largest record the server keeps (`RECORD_MAX_BYTES`).
pub const RECORD_MAX: usize = 1024 * 1024;
/// One native chunk (the server's limit).
pub const NATIVE_CHUNK: usize = 512 * 1024;
/// Native bytes sent per session per pass; more waits for the next pass.
const NATIVE_PASS_BYTES: u64 = 8 * NATIVE_CHUNK as u64;
/// A session record that changed without new records is sent at most this often.
pub const META_EVERY_MS: u64 = 60_000;
/// How often a session without a found resume file looks again.
const LOCATE_EVERY_MS: u64 = 60_000;
/// Read pages of a restore, at most (a chat of 2000 x 2000 records).
const RESTORE_MAX_PAGES: usize = 2000;
/// Tries of one chat's import before it is left in the source's copy.
pub const RESTORE_TRIES: u32 = 3;

/// One trajectory call: `POST /v1/cloud/machines/{machine}/trajectories/{action}`.
pub trait Api {
    fn call(&mut self, action: &str, body: &Value) -> Answer;
}

/// Imports one bundle into the machine's acpmux.
pub trait Importer {
    /// Whether acpmux runs, so an import neither starts it nor waits.
    fn ready(&self) -> bool;
    fn import(&mut self, bundle: &Path, meta: &Value) -> Result<(), String>;
}

/// Where acpmux keeps its sessions, whose home holds the agents' files, and
/// where a restore stages its bundles.
#[derive(Clone, Debug)]
pub struct Layout {
    pub sessions: PathBuf,
    pub home: PathBuf,
    pub staging: PathBuf,
}

/// The result of one pass.
#[derive(Debug, PartialEq, Eq)]
pub enum Pass {
    /// Everything is sent.
    Idle,
    /// More is waiting: run the next pass soon.
    More,
    /// This deployment keeps no trajectories (`cloud.trajectory.disabled`).
    Disabled,
    /// A transport error or a server error: back off.
    Failed(String),
}

/// A chat the server keeps.
#[derive(Clone, Debug, PartialEq)]
pub struct Remote {
    pub session: String,
    pub generation: u64,
    pub last_seq: u64,
    pub meta: Value,
    pub native: Vec<(String, String, u64)>,
}

enum Reply {
    Ok(Value),
    /// A `cloud.trajectory.*` answer about this chat's copy.
    Refused {
        code: String,
        details: Value,
    },
    /// A 4xx about the request itself (a record too large, say): retrying the same request is no use.
    Invalid(String),
    Failed(String),
}

fn reply(answer: Answer) -> Reply {
    match answer {
        Answer::Transport => Reply::Failed("transport error".to_owned()),
        Answer::Http { status, body } => {
            if status == 200 && *body.field("ok") == true {
                return Reply::Ok(body.field("value").clone());
            }
            let code = body.field("error").field("code").as_str().unwrap_or("").to_owned();
            if code.starts_with("cloud.trajectory.") {
                return Reply::Refused {
                    code,
                    details: body.field("error").field("details").clone(),
                };
            }
            match status {
                400 | 413 => Reply::Invalid(format!("HTTP {status} {code}")),
                _ => Reply::Failed(format!("HTTP {status} {code}")),
            }
        }
    }
}

/// What this side knows the server keeps of one session, and where its
/// log was read up to.
#[derive(Default)]
struct Track {
    generation: u64,
    last_seq: u64,
    meta: Option<String>,
    meta_sent_at: u64,
    /// The segment and byte offset just past the last record the server keeps.
    pos: Option<(u32, u64)>,
    native: HashMap<(String, String), u64>,
    /// The resume files found, and when they were looked for.
    located: Vec<(String, String)>,
    located_at: Option<u64>,
    /// A record or answer this side cannot get past: the session is left alone.
    stuck: bool,
    /// The same for the resume files alone.
    native_stuck: bool,
}

pub struct Mirror {
    layout: Layout,
    tracks: HashMap<String, Track>,
    /// Chats of the restore source waiting for an import, with the tries so far.
    pending: Vec<(Remote, u32)>,
    log: fn(&str),
}

fn remotes_of(value: &Value) -> Vec<Remote> {
    let mut remotes = Vec::new();
    for s in value.field("sessions").as_array().into_iter().flatten() {
        let Some(session) = s.field("session").as_str().filter(|id| plain_id(id)) else {
            continue;
        };
        let native = s
            .field("native")
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|n| {
                Some((
                    n.field("label").as_str()?.to_owned(),
                    n.field("path").as_str()?.to_owned(),
                    n.field("size").as_u64()?,
                ))
            })
            .collect::<Vec<_>>();
        remotes.push(Remote {
            session: session.to_owned(),
            generation: s.field("generation").as_u64().unwrap_or(0),
            last_seq: s.field("last_seq").as_u64().unwrap_or(0),
            meta: s.field("meta").clone(),
            native,
        });
    }
    remotes
}

fn list(api: &mut dyn Api, body: &Value) -> Result<Vec<Remote>, Pass> {
    match reply(api.call("list", body)) {
        Reply::Ok(v) => Ok(remotes_of(&v)),
        Reply::Refused { code, .. } if code == "cloud.trajectory.disabled" => Err(Pass::Disabled),
        Reply::Refused { code, .. } | Reply::Invalid(code) | Reply::Failed(code) => {
            Err(Pass::Failed(code))
        }
    }
}

impl Mirror {
    pub fn new(layout: Layout, log: fn(&str)) -> Mirror {
        Mirror { layout, tracks: HashMap::new(), pending: Vec::new(), log }
    }

    /// Reads this machine's copy (every session's track starts from it) and
    /// the restore source's (the chats to import). Answers how many wait.
    pub fn prime(&mut self, api: &mut dyn Api) -> Result<usize, Pass> {
        for remote in list(api, &json!({}))? {
            self.tracks.insert(
                remote.session.clone(),
                Track {
                    generation: remote.generation,
                    last_seq: remote.last_seq,
                    meta: serde_json::to_string(&remote.meta).ok(),
                    native: remote
                        .native
                        .iter()
                        .map(|(l, p, size)| ((l.clone(), p.clone()), *size))
                        .collect(),
                    ..Track::default()
                },
            );
        }
        self.pending.clear();
        for remote in list(api, &json!({ "from": "parent" }))? {
            // Here already (the snapshot's disk, or imported before and maybe deleted since): never again.
            if remote.last_seq == 0
                || self.tracks.contains_key(&remote.session)
                || self.layout.sessions.join(&remote.session).exists()
                || *remote.meta.field("id") != remote.session.as_str()
            {
                continue;
            }
            if *remote.meta.field("harness") == "cmux-harness" {
                (self.log)(&format!(
                    "trajectory {}: cmux-harness chats are not restored",
                    remote.session
                ));
                continue;
            }
            self.pending.push((remote, 0));
        }
        Ok(self.pending.len())
    }

    /// Imports the restore source's chats this machine lacks, once acpmux
    /// runs. Answers how many were imported. A failed import is tried again
    /// at the next pass, at most [`RESTORE_TRIES`] times.
    pub fn restore(&mut self, api: &mut dyn Api, importer: &mut dyn Importer) -> usize {
        if self.pending.is_empty() || !importer.ready() {
            return 0;
        }
        let mut imported = 0;
        for (remote, tries) in std::mem::take(&mut self.pending) {
            if self.layout.sessions.join(&remote.session).exists() {
                continue;
            }
            let stage = self.layout.staging.join(&remote.session);
            let _ = fs::remove_dir_all(&stage);
            let result = stage_bundle(api, &remote, &stage)
                .and_then(|()| importer.import(&stage, &remote.meta));
            let _ = fs::remove_dir_all(&stage);
            match result {
                Ok(()) => {
                    imported += 1;
                    (self.log)(&format!(
                        "trajectory {}: restored {} records",
                        remote.session, remote.last_seq
                    ));
                }
                Err(e) if tries + 1 < RESTORE_TRIES => {
                    (self.log)(&format!(
                        "trajectory {}: restore failed, will retry: {e}",
                        remote.session
                    ));
                    self.pending.push((remote, tries + 1));
                }
                Err(e) => {
                    (self.log)(&format!("trajectory {}: restore failed: {e}", remote.session));
                }
            }
        }
        imported
    }

    /// Chats still waiting for an import.
    pub fn pending(&self) -> usize {
        self.pending.len()
    }

    /// One pass over every local session. `now` is milliseconds.
    pub fn sync(&mut self, api: &mut dyn Api, now: u64) -> Pass {
        let mut ids: Vec<String> = match fs::read_dir(&self.layout.sessions) {
            Ok(rd) => rd
                .flatten()
                .filter_map(|e| e.file_name().to_str().map(str::to_owned))
                .filter(|id| plain_id(id))
                .collect(),
            Err(_) => return Pass::Idle,
        };
        ids.sort();
        let mut pass = Pass::Idle;
        for id in ids {
            match self.sync_session(api, &id, now) {
                Pass::Idle => {}
                Pass::More => pass = Pass::More,
                other => return other,
            }
        }
        pass
    }

    fn sync_session(&mut self, api: &mut dyn Api, id: &str, now: u64) -> Pass {
        let dir = self.layout.sessions.join(id);
        let Ok(text) = fs::read_to_string(dir.join("session.json")) else { return Pass::Idle };
        let Ok(meta) = serde_json::from_str::<Value>(&text) else { return Pass::Idle };
        let Some(generation) = meta.field("createdAt").as_u64() else { return Pass::Idle };
        if *meta.field("id") != id {
            return Pass::Idle;
        }
        let records = self.sync_records(api, id, &dir, &meta, generation, now);
        if matches!(records, Pass::Disabled | Pass::Failed(_)) {
            return records;
        }
        let native = match self.tracks.get(id) {
            Some(t) if t.last_seq > 0 && !t.stuck && !t.native_stuck => {
                self.sync_native(api, id, &meta, now)
            }
            _ => Pass::Idle,
        };
        match (records, native) {
            (_, failed @ (Pass::Disabled | Pass::Failed(_))) => failed,
            (Pass::More, _) | (_, Pass::More) => Pass::More,
            _ => Pass::Idle,
        }
    }

    /// Sends the session's records past the server's copy (and its record when changed).
    fn sync_records(
        &mut self,
        api: &mut dyn Api,
        id: &str,
        dir: &Path,
        meta: &Value,
        generation: u64,
        now: u64,
    ) -> Pass {
        let log = self.log;
        let track = self.tracks.entry(id.to_owned()).or_default();
        if generation < track.generation || track.stuck {
            return Pass::Idle;
        }
        if generation > track.generation {
            *track = Track { generation, ..Track::default() };
        }
        let stuck = |track: &mut Track, why: String| {
            track.stuck = true;
            log(&format!("trajectory {id}: {why}; this chat is no longer kept"));
            Pass::Idle
        };
        let (lines, end, gap) = match read_after(&dir.join("events"), track.pos, track.last_seq) {
            Ok(read) => read,
            Err(e) => return stuck(track, format!("log unreadable: {e}")),
        };
        if let Some(seq) = gap.filter(|_| lines.is_empty()) {
            let last = track.last_seq;
            return stuck(track, format!("the log jumps from {last} to {seq}"));
        }
        if let Some((line, _)) = lines.iter().find(|(l, _)| l.len() > RECORD_MAX) {
            let seq = line_seq(line).unwrap_or(0);
            return stuck(track, format!("record {seq} is larger than {RECORD_MAX} bytes"));
        }
        let meta_text = serde_json::to_string(meta).unwrap_or_default();
        let meta_changed = track.meta.as_deref() != Some(meta_text.as_str());
        let send_meta = meta_changed
            && (!lines.is_empty()
                || track.last_seq == 0
                || now >= track.meta_sent_at + META_EVERY_MS);
        if lines.is_empty() && (!send_meta || track.last_seq == 0) {
            // Every record read is kept: the next pass reads from past them.
            track.pos = end;
            return Pass::Idle;
        }
        let full = lines.len() == BATCH_LINES
            || lines.iter().map(|(l, _)| l.len()).sum::<usize>() >= BATCH_BYTES;
        let mut body = json!({
            "session": id,
            "generation": generation,
            "lines": lines.iter().map(|(l, _)| l.as_str()).collect::<Vec<_>>(),
        });
        if (send_meta || track.last_seq == 0)
            && let Some(fields) = body.as_object_mut()
        {
            fields.insert("meta".to_owned(), meta.clone());
        }
        match reply(api.call("append", &body)) {
            Reply::Ok(v) => {
                track.last_seq = v.field("last_seq").as_u64().unwrap_or(track.last_seq);
                track.pos = lines.last().map(|(_, pos)| Some(*pos)).unwrap_or(end);
                if body.get("meta").is_some() {
                    track.meta = Some(meta_text);
                    track.meta_sent_at = now;
                }
                if full { Pass::More } else { Pass::Idle }
            }
            Reply::Refused { code, details } => match code.as_str() {
                "cloud.trajectory.disabled" => Pass::Disabled,
                "cloud.trajectory.gap" | "cloud.trajectory.not_found" => {
                    *track = Track {
                        generation,
                        last_seq: details.field("last_seq").as_u64().unwrap_or(0),
                        ..Track::default()
                    };
                    Pass::More
                }
                "cloud.trajectory.full" => Pass::Failed(code.clone()),
                _ => stuck(track, format!("{code} {details}")),
            },
            Reply::Invalid(why) => stuck(track, why),
            Reply::Failed(why) => Pass::Failed(why),
        }
    }

    /// Sends what the agent's resume files grew by since the server's copy.
    fn sync_native(&mut self, api: &mut dyn Api, id: &str, meta: &Value, now: u64) -> Pass {
        let home = self.layout.home.clone();
        let log = self.log;
        let Some(track) = self.tracks.get_mut(id) else { return Pass::Idle };
        if track.located.is_empty() && track.located_at.is_none_or(|at| now >= at + LOCATE_EVERY_MS)
        {
            track.located = locate_native(&home, meta);
            track.located_at = Some(now);
        }
        let mut pass = Pass::Idle;
        for (label, rel) in track.located.clone() {
            let file = home.join(&rel);
            let Ok(size) = fs::symlink_metadata(&file).map(|m| m.len()) else { continue };
            let kept = track.native.get(&(label.clone(), rel.clone())).copied().unwrap_or(0);
            if size == kept {
                continue;
            }
            let mut offset = if size < kept { 0 } else { kept };
            let Ok(bytes) = read_range(&file, offset, size.min(offset + NATIVE_PASS_BYTES)) else {
                continue;
            };
            // Only whole lines: the agent may be writing the last one. A line longer than a
            // pass goes in parts (the file only grows); a restore keeps whole lines (stage_bundle).
            let end = match bytes.iter().rposition(|b| *b == b'\n') {
                Some(at) => at + 1,
                None if bytes.len() as u64 == NATIVE_PASS_BYTES => bytes.len(),
                None => continue,
            };
            for chunk in bytes.get(..end).unwrap_or_default().chunks(NATIVE_CHUNK) {
                let body = json!({
                    "session": id,
                    "generation": track.generation,
                    "label": label,
                    "path": rel,
                    "offset": offset,
                    "data": encode_base64(chunk),
                });
                match reply(api.call("native", &body)) {
                    Reply::Ok(v) => {
                        offset = v.field("size").as_u64().unwrap_or(offset + chunk.len() as u64);
                        track.native.insert((label.clone(), rel.clone()), offset);
                    }
                    Reply::Refused { code, details } if code == "cloud.trajectory.offset" => {
                        let size = details.field("size").as_u64().unwrap_or(0);
                        track.native.insert((label, rel), size);
                        return Pass::More;
                    }
                    Reply::Refused { code, .. } if code == "cloud.trajectory.disabled" => {
                        return Pass::Disabled;
                    }
                    Reply::Refused { code: why, .. } | Reply::Invalid(why) => {
                        track.native_stuck = true;
                        log(&format!(
                            "trajectory {id}: {rel}: {why}; its resume file is no longer kept"
                        ));
                        return Pass::Idle;
                    }
                    Reply::Failed(why) => return Pass::Failed(why),
                }
            }
            if offset < size {
                pass = Pass::More;
            }
        }
        pass
    }
}

/// Writes one of the restore source's chats as an acpmux bundle at `stage`.
fn stage_bundle(api: &mut dyn Api, remote: &Remote, stage: &Path) -> Result<(), String> {
    let err = |e: io::Error| e.to_string();
    let failed = |r: Reply| match r {
        Reply::Ok(_) => String::new(),
        Reply::Refused { code, .. } | Reply::Invalid(code) | Reply::Failed(code) => code,
    };
    fs::create_dir_all(stage.join("events")).map_err(err)?;
    let meta = serde_json::to_vec_pretty(&remote.meta).map_err(|e| e.to_string())?;
    fs::write(stage.join("session.json"), meta).map_err(err)?;
    let mut events = io::BufWriter::new(
        fs::File::create(stage.join("events").join("000001.ndjson")).map_err(err)?,
    );
    let mut after = 0_u64;
    for _ in 0..RESTORE_MAX_PAGES {
        let body = json!({ "session": remote.session, "after_seq": after, "limit": 2000, "from": "parent" });
        let page = match reply(api.call("read", &body)) {
            Reply::Ok(v) => v,
            other => return Err(failed(other)),
        };
        for line in page.field("lines").as_array().into_iter().flatten() {
            let line = line.as_str().ok_or("a kept record is not text")?;
            let seq = line_seq(line).ok_or("a kept record has no seq")?;
            if seq != after + 1 {
                return Err(format!("kept records jump from {after} to {seq}"));
            }
            events.write_all(line.as_bytes()).map_err(err)?;
            events.write_all(b"\n").map_err(err)?;
            after = seq;
        }
        if *page.field("has_more") != true {
            break;
        }
    }
    events.flush().map_err(err)?;
    if after < remote.last_seq {
        return Err(format!("read {after} of {} records", remote.last_seq));
    }
    for (label, path, size) in &remote.native {
        if !native_path(label, path) {
            continue;
        }
        let mut bytes = Vec::new();
        while (bytes.len() as u64) < *size {
            let body = json!({ "session": remote.session, "label": label, "path": path, "offset": bytes.len(), "from": "parent" });
            let chunk = match reply(api.call("native-read", &body)) {
                Reply::Ok(v) => v,
                other => return Err(failed(other)),
            };
            let data = decode_base64(chunk.field("data").as_str().unwrap_or(""))
                .ok_or("a kept file chunk is not base64")?;
            if data.is_empty() {
                return Err(format!("{path}: kept file ends early"));
            }
            bytes.extend_from_slice(&data);
        }
        // A copy cut mid-line (the machine lost between two parts) is restored to its last whole line.
        bytes.truncate(bytes.iter().rposition(|b| *b == b'\n').map_or(0, |at| at + 1));
        let target = stage.join("native").join(label).join(path);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(err)?;
        }
        fs::write(target, bytes).map_err(err)?;
    }
    Ok(())
}

/// A session id that names one directory, as the server accepts it
/// (`isSessionId`): a letter or digit, then letters, digits, `.`, `_` or `-`.
fn plain_id(id: &str) -> bool {
    id.len() <= 128
        && id.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// The paths the server accepts for an agent's own files (`isNativePath`).
pub fn native_path(label: &str, path: &str) -> bool {
    let root = match label {
        "claude-project" => ".claude/projects/",
        "codex-rollout" => ".codex/sessions/",
        _ => return false,
    };
    path.starts_with(root)
        && path.ends_with(".jsonl")
        && path.len() <= 512
        && Path::new(path).components().all(|c| matches!(c, Component::Normal(_)))
}

/// The agent's own resume files for a session, as `(label, path under home)`
/// (acpmux `native::locate`).
pub fn locate_native(home: &Path, meta: &Value) -> Vec<(String, String)> {
    let Some(sid) = meta.field("agentSessionId").as_str().filter(|s| plain_id(s)) else {
        return vec![];
    };
    let (label, root, depth) = match meta.field("harness").as_str() {
        Some("claude") => ("claude-project", home.join(".claude/projects"), 1),
        Some("codex") => ("codex-rollout", home.join(".codex/sessions"), 3),
        _ => return vec![],
    };
    let mut found = Vec::new();
    for file in walk(&root, depth) {
        let Some(name) = file.file_name().and_then(|n| n.to_str()) else { continue };
        let ours = if label == "claude-project" {
            name == format!("{sid}.jsonl")
        } else {
            name.ends_with(".jsonl") && name.contains(sid)
        };
        let Some(rel) = file.strip_prefix(home).ok().and_then(Path::to_str) else { continue };
        if ours && native_path(label, rel) {
            found.push((label.to_owned(), rel.to_owned()));
        }
    }
    found.sort();
    found
}

/// Regular files under `root`, at most `depth` directories down; symlinks
/// are neither followed nor returned.
fn walk(root: &Path, depth: usize) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(rd) = fs::read_dir(root) else { return out };
    for entry in rd.flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() && depth > 0 {
            out.extend(walk(&entry.path(), depth - 1));
        } else if kind.is_file() {
            out.push(entry.path());
        }
    }
    out
}

/// The seq of one event line.
pub fn line_seq(line: &str) -> Option<u64> {
    serde_json::from_str::<Value>(line).ok()?.field("seq").as_u64().filter(|s| *s > 0)
}

/// The log's segments, by index.
fn segments(events: &Path) -> io::Result<Vec<(u32, PathBuf)>> {
    let mut out = Vec::new();
    let rd = match fs::read_dir(events) {
        Ok(rd) => rd,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(out),
        Err(e) => return Err(e),
    };
    for entry in rd.flatten() {
        let name = entry.file_name();
        let Some(index) =
            name.to_str().and_then(|n| n.strip_suffix(".ndjson")).and_then(|s| s.parse().ok())
        else {
            continue;
        };
        out.push((index, entry.path()));
    }
    out.sort();
    Ok(out)
}

/// Reads the complete records after `last_seq`, from `pos` on (the start
/// when unknown): up to one batch of consecutive seqs, each with the position
/// just past it. Also answers the position past the last record read (kept
/// or not), and the seq that broke the run, if one did.
#[allow(clippy::type_complexity)]
fn read_after(
    events: &Path,
    pos: Option<(u32, u64)>,
    last_seq: u64,
) -> io::Result<(Vec<(String, (u32, u64))>, Option<(u32, u64)>, Option<u64>)> {
    let mut out: Vec<(String, (u32, u64))> = Vec::new();
    let mut bytes = 0;
    let mut end = pos;
    let mut expect = last_seq + 1;
    let (from_index, from_offset) = pos.unwrap_or((0, 0));
    for (index, path) in segments(events)? {
        if index < from_index {
            continue;
        }
        let mut file = fs::File::open(&path)?;
        let mut offset = if index == from_index { from_offset } else { 0 };
        file.seek(SeekFrom::Start(offset))?;
        let mut reader = BufReader::new(file);
        let mut line = Vec::new();
        loop {
            line.clear();
            let n = reader.read_until(b'\n', &mut line)?;
            if n == 0 || line.last() != Some(&b'\n') {
                break;
            }
            offset += n as u64;
            let text =
                String::from_utf8_lossy(line.strip_suffix(b"\n").unwrap_or(&line)).into_owned();
            if text.trim().is_empty() {
                continue;
            }
            let seq = line_seq(&text).ok_or_else(|| {
                io::Error::other(format!("{} has a line without a seq", path.display()))
            })?;
            if seq < expect {
                // Already kept: the read position moves past it.
                end = Some((index, offset));
                continue;
            }
            if seq != expect {
                return Ok((out, end, Some(seq)));
            }
            bytes += text.len();
            out.push((text, (index, offset)));
            end = Some((index, offset));
            expect += 1;
            if out.len() == BATCH_LINES || bytes >= BATCH_BYTES {
                return Ok((out, end, None));
            }
        }
    }
    Ok((out, end, None))
}

fn read_range(file: &Path, from: u64, to: u64) -> io::Result<Vec<u8>> {
    let mut f = fs::File::open(file)?;
    f.seek(SeekFrom::Start(from))?;
    let mut out = Vec::new();
    f.take(to.saturating_sub(from)).read_to_end(&mut out)?;
    Ok(out)
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding (the server's `atob`/`btoa`).
pub fn encode_base64(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [0, 1, 2].map(|i| chunk.get(i).copied().unwrap_or(0));
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(
                    B64.get((n >> (18 - 6 * i)) as usize & 63).copied().unwrap_or(b'='),
                ));
            } else {
                out.push('=');
            }
        }
    }
    out
}

pub fn decode_base64(text: &str) -> Option<Vec<u8>> {
    let text = text.trim_end_matches('=');
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut acc = 0_u32;
    let mut bits = 0;
    for c in text.bytes() {
        let v = B64.iter().position(|b| *b == c)? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}
