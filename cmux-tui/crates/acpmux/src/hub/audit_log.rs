//! Part of `Hub`; see `hub/mod.rs`. The approvals audit trail: one line per answer a person (or
//! an ancestor session, or a queue owner) gave, in `<state dir>/audit/approvals.jsonl`.
//!
//! - What is logged: each answered permission, plan approval and question (the
//!   `permission_decision` record, observed in `Hub::append_record_locked` with the ask the
//!   review index kept from its `permission_request`), each queued prompt the owner approved or
//!   declined (`queue_approve.rs`), and each review verdict on a pull request
//!   (`_acpmux/review_verdict`). A prompt the agent withdrew, or a turn's stop cancelled, was
//!   never answered and is not logged. Tool output is never logged; the ask is one line with its
//!   secrets masked (`session::masked_preview`).
//! - Entry: `{v, seq, at, sessionId, host?, harness, vendor, kind, permissionId?, promptId?,
//!   prUrl?, ask, decision {optionId?, kind: allow|deny|answer|accept|changes}, answeredBy
//!   {person, device?, via?, feedItem?}, prevHash, hash}`. `kind` is `approval`, `plan`,
//!   `question`, `queued` or `review`. `answeredBy.person` is true only for an answer the
//!   person's proof stood behind: an allow or an answer (which `respond_permission` accepts only
//!   from the person or under their decision proof), a verdict from the person's connection.
//! - Chain: `hash` = lowercase hex SHA-256 of `prevHash` followed by the entry's canonical JSON
//!   (keys sorted at every level, no spaces) without `hash`. The first entry's `prevHash` is
//!   [`GENESIS`]. `seq` counts from 1. Editing, dropping or reordering a line breaks the link
//!   after it, which `verify` reports.
//! - Writes: the file is opened `O_APPEND` and never rewritten; each line is synced to disk
//!   before it counts. One writer thread numbers, chains and writes every entry. An answer to a
//!   permission (recorded under a session's append lock) only sends its entry down a channel; a
//!   line that cannot be written is counted (`writeErrors` in `_acpmux/audit`) and logged, never
//!   silently dropped. A review verdict waits for its line ([`AuditLog::record_durable`]): the
//!   verdict fails, and its pull request stays in the queue, unless the line is on disk. At start
//!   the thread reads the file once for the chain's head (so a restart continues the chain) and
//!   the pull requests that already have a verdict, by session and URL.
//! - A memory store (tests) keeps the entries in memory, chained the same way.

use std::collections::HashSet;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, mpsc};
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// The audit folder's file.
pub(crate) const FILE: &str = "approvals.jsonl";
/// The entry format.
pub(crate) const VERSION: u64 = 1;
/// The `prevHash` of the first entry.
pub(crate) const GENESIS: &str = "0000000000000000000000000000000000000000000000000000000000000000";
/// The most entries one `_acpmux/audit` page returns.
pub(crate) const MAX_PAGE: usize = 1000;
/// A page's entries when the request names no limit.
pub(crate) const DEFAULT_PAGE: usize = 200;
/// How long a durable record waits for the writer.
const DURABLE_WAIT: Duration = Duration::from_secs(10);

/// A pull request with a verdict: the session that opened it and its URL.
type Reviewed = HashSet<(String, String)>;

enum Msg {
    /// An entry, and where to answer once it is written (the entry as written) or failed.
    Entry(Value, Option<mpsc::Sender<Result<Value, String>>>),
    /// Answered once every entry sent before it is written.
    Flush(mpsc::Sender<()>),
}

/// The chain's head: the last entry's `seq` and `hash`.
#[derive(Clone, Debug, PartialEq)]
struct Head {
    seq: u64,
    hash: String,
}

impl Default for Head {
    fn default() -> Self {
        Head { seq: 0, hash: GENESIS.to_owned() }
    }
}

pub(crate) struct AuditLog {
    tx: StdMutex<mpsc::Sender<Msg>>,
    /// Pull requests (session, URL) whose verdict is written: they leave the review queue.
    reviewed: Arc<StdMutex<Reviewed>>,
    /// Entries the writer could not write.
    write_errors: Arc<AtomicU64>,
    path: Option<PathBuf>,
    /// The entries of a log kept in memory (no state folder).
    memory: Option<Arc<StdMutex<Vec<Value>>>>,
}

impl AuditLog {
    /// The log in `dir` (`<state dir>/audit`), or in memory when `dir` is None.
    pub(crate) fn open(dir: Option<PathBuf>) -> Self {
        let (tx, rx) = mpsc::channel();
        let reviewed = Arc::new(StdMutex::new(HashSet::new()));
        let path = dir.map(|d| d.join(FILE));
        let memory = path.is_none().then(|| Arc::new(StdMutex::new(Vec::new())));
        let write_errors = Arc::new(AtomicU64::new(0));
        let writer = Writer {
            path: path.clone(),
            memory: memory.clone(),
            reviewed: reviewed.clone(),
            write_errors: write_errors.clone(),
            head: Head::default(),
            file: None,
        };
        // The thread ends when the log (its sender) drops.
        let _ =
            std::thread::Builder::new().name("acpmux-audit".into()).spawn(move || writer.run(rx));
        AuditLog { tx: StdMutex::new(tx), reviewed, write_errors, path, memory }
    }

    /// Sends `entry` (without `v`, `seq`, `prevHash` and `hash`) to the writer: never blocks. A
    /// line the writer cannot write counts in [`AuditLog::write_errors`].
    pub(crate) fn record(&self, entry: Value) {
        if self.send(Msg::Entry(entry, None)).is_err() {
            self.lost("the writer is gone");
        }
    }

    /// Writes `entry` and waits until its line is on disk: the entry as written, or why not.
    /// Blocking.
    pub(crate) fn record_durable(&self, entry: Value) -> Result<Value, String> {
        let (tx, rx) = mpsc::channel();
        if self.send(Msg::Entry(entry, Some(tx))).is_err() {
            self.lost("the writer is gone");
            return Err("the audit writer is gone".into());
        }
        // A timeout leaves the outcome to the writer, which counts a failure itself.
        rx.recv_timeout(DURABLE_WAIT)
            .map_err(|_| "the audit writer did not answer".to_owned())
            .and_then(|r| r)
    }

    fn send(&self, msg: Msg) -> Result<(), ()> {
        self.tx.lock().unwrap_or_else(|e| e.into_inner()).send(msg).map_err(|_| ())
    }

    fn lost(&self, why: &str) {
        self.write_errors.fetch_add(1, Ordering::Relaxed);
        tracing::warn!("audit: an entry was not written: {why}");
    }

    /// Entries that could not be written since this daemon started.
    pub(crate) fn write_errors(&self) -> u64 {
        self.write_errors.load(Ordering::Relaxed)
    }

    /// Whether the pull request at `url`, opened by session `session_id`, has a written verdict.
    pub(crate) fn reviewed(&self, session_id: &str, url: &str) -> bool {
        let key = (session_id.to_owned(), url.to_owned());
        self.reviewed.lock().unwrap_or_else(|e| e.into_inner()).contains(&key)
    }

    /// Waits until every entry recorded before this call is written (or the writer is gone).
    pub(crate) fn flush(&self) {
        let (tx, rx) = mpsc::channel();
        let sent = self.tx.lock().unwrap_or_else(|e| e.into_inner()).send(Msg::Flush(tx));
        if sent.is_ok() {
            let _ = rx.recv_timeout(DURABLE_WAIT);
        }
    }

    /// Every entry, oldest first. Blocking: reads the file.
    pub(crate) fn all(&self) -> std::io::Result<Vec<Value>> {
        self.flush();
        if let Some(m) = &self.memory {
            return Ok(m.lock().unwrap_or_else(|e| e.into_inner()).clone());
        }
        let Some(path) = &self.path else { return Ok(vec![]) };
        read_lines(path)
    }

    /// One page of entries for `_acpmux/audit`: `{entries, next?, writeErrors}`, `next` the
    /// `cursor` of the page after, `writeErrors` the entries this daemon could not write. With `verify`, also `verify: {ok, entries, brokenAt?, reason?}` over the whole
    /// chain. Blocking: reads the file.
    pub(crate) fn page(&self, q: &Query) -> std::io::Result<Value> {
        let all = self.all()?;
        let limit = q.limit.clamp(1, MAX_PAGE);
        let mut entries = Vec::new();
        let mut next = None;
        for e in &all {
            let seq = e.get("seq").and_then(Value::as_u64).unwrap_or(0);
            let at = e.get("at").and_then(Value::as_u64).unwrap_or(0);
            if q.cursor.is_some_and(|c| seq <= c)
                || q.since.is_some_and(|s| at < s)
                || q.until.is_some_and(|u| at > u)
                || q.session_id.as_deref().is_some_and(|s| e.get("sessionId") != Some(&json!(s)))
            {
                continue;
            }
            if entries.len() == limit {
                next = entries.last().and_then(|l: &Value| l.get("seq")).and_then(Value::as_u64);
                break;
            }
            entries.push(e.clone());
        }
        let mut out = json!({"entries": entries, "writeErrors": self.write_errors()});
        if let Some(n) = next {
            out["next"] = json!(n);
        }
        if q.verify {
            out["verify"] = verify(&all);
        }
        Ok(out)
    }
}

/// `_acpmux/audit` params.
#[derive(Debug, Default, Clone)]
pub(crate) struct Query {
    pub since: Option<u64>,
    pub until: Option<u64>,
    pub session_id: Option<String>,
    pub limit: usize,
    /// The `next` of the page before: entries after that `seq`.
    pub cursor: Option<u64>,
    pub verify: bool,
}

impl Query {
    pub(crate) fn from_params(p: &Value) -> Result<Self, String> {
        let num = |k: &str| -> Result<Option<u64>, String> {
            match p.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(v) => v.as_u64().map(Some).ok_or_else(|| format!("{k} must be a number")),
            }
        };
        let session_id = match p.get("sessionId") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) => Some(s.clone()),
            Some(_) => return Err("sessionId must be a string".into()),
        };
        Ok(Query {
            since: num("since")?,
            until: num("until")?,
            session_id,
            limit: num("limit")?.map_or(DEFAULT_PAGE, |l| l as usize),
            cursor: num("cursor")?,
            verify: p.get("verify").and_then(Value::as_bool).unwrap_or(false),
        })
    }
}

/// The pull request a review verdict entry is about: its session and URL.
fn review_key(entry: &Value) -> Option<(String, String)> {
    if entry.get("kind").and_then(Value::as_str) != Some("review") {
        return None;
    }
    let session = entry.get("sessionId").and_then(Value::as_str)?;
    let url = entry.get("prUrl").and_then(Value::as_str)?;
    Some((session.to_owned(), url.to_owned()))
}

struct Writer {
    path: Option<PathBuf>,
    memory: Option<Arc<StdMutex<Vec<Value>>>>,
    reviewed: Arc<StdMutex<Reviewed>>,
    write_errors: Arc<AtomicU64>,
    head: Head,
    file: Option<std::fs::File>,
}

impl Writer {
    fn run(mut self, rx: mpsc::Receiver<Msg>) {
        self.load();
        while let Ok(msg) = rx.recv() {
            match msg {
                Msg::Entry(entry, done) => {
                    let written = self.write(entry);
                    match &written {
                        Ok(e) => {
                            if let Some(key) = review_key(e) {
                                self.reviewed.lock().unwrap_or_else(|e| e.into_inner()).insert(key);
                            }
                        }
                        Err(why) => {
                            self.write_errors.fetch_add(1, Ordering::Relaxed);
                            tracing::warn!("audit: an entry was not written: {why}");
                        }
                    }
                    if let Some(done) = done {
                        let _ = done.send(written);
                    }
                }
                Msg::Flush(done) => {
                    let _ = done.send(());
                }
            }
        }
    }

    /// The chain's head and the reviewed pull requests, from the file as it is.
    fn load(&mut self) {
        let Some(path) = &self.path else { return };
        let Ok(entries) = read_lines(path) else { return };
        let mut reviewed = self.reviewed.lock().unwrap_or_else(|e| e.into_inner());
        for e in &entries {
            if let Some(key) = review_key(e) {
                reviewed.insert(key);
            }
        }
        drop(reviewed);
        if let Some(last) = entries.last() {
            self.head = Head {
                seq: last.get("seq").and_then(Value::as_u64).unwrap_or(entries.len() as u64),
                hash: last.get("hash").and_then(Value::as_str).unwrap_or(GENESIS).to_owned(),
            };
        }
    }

    /// Numbers, chains and writes `entry`: the entry as written, or why it was not.
    fn write(&mut self, mut entry: Value) -> Result<Value, String> {
        let Some(o) = entry.as_object_mut() else { return Err("not an object".into()) };
        o.remove("hash");
        o.insert("v".into(), json!(VERSION));
        o.insert("seq".into(), json!(self.head.seq + 1));
        o.insert("prevHash".into(), json!(self.head.hash));
        let hash = entry_hash(&self.head.hash, &entry);
        entry["hash"] = json!(hash);
        if let Some(m) = &self.memory {
            m.lock().unwrap_or_else(|e| e.into_inner()).push(entry.clone());
            self.head = Head { seq: self.head.seq + 1, hash };
            return Ok(entry);
        }
        let Some(path) = self.path.clone() else { return Err("no audit file".into()) };
        let mut line = entry.to_string();
        line.push('\n');
        match self.append(&path, line.as_bytes()) {
            Ok(()) => {
                self.head = Head { seq: self.head.seq + 1, hash };
                Ok(entry)
            }
            Err(e) => {
                // The next entry tries again with a new handle; this one is not chained.
                self.file = None;
                Err(format!("append to {} failed: {e}", path.display()))
            }
        }
    }

    fn append(&mut self, path: &Path, line: &[u8]) -> std::io::Result<()> {
        if self.file.is_none() {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let mut opts = std::fs::OpenOptions::new();
            opts.append(true).create(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                opts.mode(0o600);
            }
            self.file = Some(opts.open(path)?);
        }
        let file = self.file.as_mut().ok_or_else(|| std::io::Error::other("no file"))?;
        file.write_all(line)?;
        file.flush()?;
        file.sync_data()
    }
}

fn read_lines(path: &Path) -> std::io::Result<Vec<Value>> {
    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(e) => return Err(e),
    };
    let mut out = Vec::new();
    for line in std::io::BufReader::new(file).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        // A line that is not JSON stays in the walk as a string, so `verify` names it.
        out.push(serde_json::from_str(&line).unwrap_or(Value::String(line)));
    }
    Ok(out)
}

/// `hash` of an entry whose `prevHash` is `prev`: SHA-256 of `prev` then the canonical JSON of
/// `entry` without `hash`.
pub(crate) fn entry_hash(prev: &str, entry: &Value) -> String {
    let mut body = entry.clone();
    if let Some(o) = body.as_object_mut() {
        o.remove("hash");
    }
    let mut text = String::new();
    canonical(&body, &mut text);
    let mut h = Sha256::new();
    h.update(prev.as_bytes());
    h.update(text.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// `v` as JSON with every object's keys sorted and no spaces, whatever order the map keeps.
fn canonical(v: &Value, out: &mut String) {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(k.clone()).to_string());
                out.push(':');
                canonical(&m[k], out);
            }
            out.push('}');
        }
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical(x, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// Walks the chain: `{ok, entries, brokenAt?, reason?}`, `brokenAt` the `seq` (or the 1-based
/// line, for a line with none) of the first entry that does not follow the one before it.
pub(crate) fn verify(entries: &[Value]) -> Value {
    let mut prev = Head::default();
    for (i, e) in entries.iter().enumerate() {
        let line = i as u64 + 1;
        let seq = e.get("seq").and_then(Value::as_u64);
        let broken = |reason: &str| {
            json!({"ok": false, "entries": entries.len(), "brokenAt": seq.unwrap_or(line),
                   "line": line, "reason": reason})
        };
        if !e.is_object() {
            return broken("not an entry");
        }
        if seq != Some(prev.seq + 1) {
            return broken("seq");
        }
        if e.get("prevHash").and_then(Value::as_str) != Some(prev.hash.as_str()) {
            return broken("prevHash");
        }
        let hash = entry_hash(&prev.hash, e);
        if e.get("hash").and_then(Value::as_str) != Some(hash.as_str()) {
            return broken("hash");
        }
        prev = Head { seq: prev.seq + 1, hash };
    }
    json!({"ok": true, "entries": entries.len()})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("acpmux-audit-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    fn entry(session: &str, at: u64) -> Value {
        json!({"at": at, "sessionId": session, "harness": "claude", "vendor": "anthropic",
               "kind": "approval", "permissionId": format!("p-{at}"), "ask": "Run: ls",
               "decision": {"optionId": "allow", "kind": "allow"},
               "answeredBy": {"person": true}})
    }

    #[test]
    fn entries_chain_and_verify() {
        let log = AuditLog::open(None);
        for at in 1..=3 {
            log.record(entry("s1", at));
        }
        let all = log.all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0]["prevHash"], GENESIS);
        assert_eq!(all[1]["prevHash"], all[0]["hash"]);
        assert_eq!(all[2]["seq"], 3);
        assert_eq!(all[2]["v"], VERSION);
        assert_eq!(verify(&all), json!({"ok": true, "entries": 3}));
    }

    #[test]
    fn verify_names_the_first_broken_link() {
        let log = AuditLog::open(None);
        for at in 1..=4 {
            log.record(entry("s1", at));
        }
        let mut all = log.all().unwrap();
        all[1]["ask"] = json!("Run: rm -rf /");
        let v = verify(&all);
        assert_eq!(v["ok"], false, "{v}");
        assert_eq!(v["brokenAt"], 2, "{v}");
        assert_eq!(v["reason"], "hash", "{v}");
        let mut dropped = log.all().unwrap();
        dropped.remove(2);
        let v = verify(&dropped);
        assert_eq!((v["brokenAt"].clone(), v["reason"].clone()), (json!(4), json!("seq")), "{v}");
    }

    #[test]
    fn the_hash_ignores_key_order() {
        let a = json!({"b": 1, "a": {"y": 2, "x": [3, {"q": 1, "p": 2}]}});
        let b = json!({"a": {"x": [3, {"p": 2, "q": 1}], "y": 2}, "b": 1});
        assert_eq!(entry_hash(GENESIS, &a), entry_hash(GENESIS, &b));
        assert_ne!(entry_hash(GENESIS, &a), entry_hash("1", &a));
    }

    #[test]
    fn a_restart_continues_the_chain_and_appends_only() {
        let d = dir("restart");
        {
            let log = AuditLog::open(Some(d.clone()));
            log.record(entry("s1", 1));
            log.record(json!({"at": 2, "sessionId": "s1", "kind": "review",
                              "prUrl": "https://github.com/o/r/pull/1", "ask": "Review",
                              "decision": {"kind": "accept"}, "answeredBy": {"person": true}}));
            log.flush();
        }
        let before = std::fs::read_to_string(d.join(FILE)).unwrap();
        let log = AuditLog::open(Some(d.clone()));
        log.record(entry("s2", 3));
        let all = log.all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[2]["seq"], 3);
        assert_eq!(all[2]["prevHash"], all[1]["hash"]);
        assert_eq!(verify(&all)["ok"], true);
        // The verdict a log read back still keeps its pull request out of the queue.
        assert!(log.reviewed("s1", "https://github.com/o/r/pull/1"));
        // Keyed by session: the same URL another session printed still waits for its verdict.
        assert!(!log.reviewed("s2", "https://github.com/o/r/pull/1"));
        let after = std::fs::read_to_string(d.join(FILE)).unwrap();
        assert!(after.starts_with(&before), "the file was rewritten");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(d.join(FILE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_page_filters_and_continues_from_its_cursor() {
        let log = AuditLog::open(None);
        for at in 1..=5 {
            log.record(entry(if at % 2 == 0 { "even" } else { "odd" }, at * 10));
        }
        let q = Query { limit: 2, ..Default::default() };
        let first = log.page(&q).unwrap();
        assert_eq!(first["entries"].as_array().unwrap().len(), 2);
        assert_eq!(first["next"], 2);
        let second = log.page(&Query { cursor: Some(2), ..q.clone() }).unwrap();
        assert_eq!(second["entries"][0]["seq"], 3);
        let odd = log
            .page(&Query {
                session_id: Some("odd".into()),
                since: Some(20),
                limit: 10,
                verify: true,
                ..Default::default()
            })
            .unwrap();
        let seqs: Vec<_> =
            odd["entries"].as_array().unwrap().iter().map(|e| e["seq"].clone()).collect();
        assert_eq!(seqs, vec![json!(3), json!(5)]);
        assert_eq!(odd.get("next"), None);
        assert_eq!(odd["verify"]["ok"], true);
        assert!(Query::from_params(&json!({"since": "x"})).is_err());
        assert_eq!(odd["writeErrors"], 0);
    }

    #[test]
    fn an_entry_that_cannot_be_written_fails_its_verdict_and_is_counted() {
        // The audit folder's path is a file: no line can be written under it.
        let d = dir("unwritable");
        std::fs::write(&d, b"not a folder").unwrap();
        let log = AuditLog::open(Some(d.clone()));
        let verdict = json!({"at": 1, "sessionId": "s1", "kind": "review",
                             "prUrl": "https://github.com/o/r/pull/1", "ask": "Review",
                             "decision": {"kind": "accept"}, "answeredBy": {"person": true}});
        assert!(log.record_durable(verdict).is_err());
        assert!(!log.reviewed("s1", "https://github.com/o/r/pull/1"));
        log.record(entry("s1", 2));
        log.flush();
        assert_eq!(log.write_errors(), 2);
        let _ = std::fs::remove_file(&d);
    }

    #[test]
    fn a_durable_record_answers_with_the_entry_as_written() {
        let d = dir("durable");
        let log = AuditLog::open(Some(d.clone()));
        let written = log
            .record_durable(json!({"at": 1, "sessionId": "s1", "kind": "review",
                                   "prUrl": "https://github.com/o/r/pull/2", "ask": "Review",
                                   "decision": {"kind": "changes"},
                                   "answeredBy": {"person": true}}))
            .unwrap();
        assert_eq!(written["seq"], 1);
        assert_eq!(written["prevHash"], GENESIS);
        assert!(log.reviewed("s1", "https://github.com/o/r/pull/2"));
        let on_disk = std::fs::read_to_string(d.join(FILE)).unwrap();
        assert!(on_disk.contains(written["hash"].as_str().unwrap()));
        assert_eq!(log.write_errors(), 0);
        let _ = std::fs::remove_dir_all(&d);
    }
}
