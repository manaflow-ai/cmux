//! A blocking JSON-RPC client of the daemon's unix socket (one JSON object per line), and a
//! reader that follows one chat's records across attachments.

use super::run::Run;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

pub struct Conn {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    pending: Vec<u8>,
    next: u64,
    pub bytes_in: u64,
}

impl Conn {
    pub fn connect(path: &Path) -> Result<Conn, String> {
        let s =
            UnixStream::connect(path).map_err(|e| format!("connect {}: {e}", path.display()))?;
        let r = s.try_clone().map_err(|e| e.to_string())?;
        Ok(Conn {
            reader: BufReader::with_capacity(1 << 20, r),
            writer: s,
            pending: Vec::new(),
            next: 0,
            bytes_in: 0,
        })
    }

    pub fn send(&mut self, method: &str, params: Value) -> Result<u64, String> {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer
            .write_all(format!("{line}\n").as_bytes())
            .map_err(|e| format!("{method}: write: {e}"))?;
        Ok(self.next)
    }

    /// The next message, or None when `wait` passed first. Err: the socket closed or broke.
    pub fn read(&mut self, wait: Duration) -> Result<Option<Value>, String> {
        let wait = wait.max(Duration::from_millis(1));
        self.reader.get_ref().set_read_timeout(Some(wait)).map_err(|e| e.to_string())?;
        match self.reader.read_until(b'\n', &mut self.pending) {
            Ok(0) => Err("closed".into()),
            Ok(_) if self.pending.last() == Some(&b'\n') => {
                let line = std::mem::take(&mut self.pending);
                self.bytes_in += line.len() as u64;
                serde_json::from_slice(&line).map(Some).map_err(|e| format!("bad line: {e}"))
            }
            Ok(_) => Err("closed mid-line".into()),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                Ok(None)
            }
            Err(e) => Err(e.to_string()),
        }
    }

    /// Calls `method` and waits up to `within` for its reply; every other message goes to `note`.
    pub fn call_with(
        &mut self,
        method: &str,
        params: Value,
        within: Duration,
        note: &mut dyn FnMut(Value),
    ) -> Result<Value, String> {
        let id = self.send(method, params)?;
        let deadline = Instant::now() + within;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(format!("{method}: no reply in {} s", within.as_secs_f64()));
            }
            let Some(v) = self.read(left)? else { continue };
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                if let Some(err) = v.get("error") {
                    return Err(format!("{method}: {err}"));
                }
                return Ok(v.get("result").cloned().unwrap_or(Value::Null));
            }
            note(v);
        }
    }

    pub fn call(&mut self, method: &str, params: Value, within: Duration) -> Result<Value, String> {
        self.call_with(method, params, within, &mut |_| {})
    }

    /// Closes both directions now, as a client that dies does.
    pub fn slam(&self) {
        let _ = self.writer.shutdown(std::net::Shutdown::Both);
    }
}

/// One record as a reader saw it.
#[derive(Clone, Debug)]
pub struct Rec {
    pub seq: u64,
    pub kind: String,
    /// `msg.params.update.sessionUpdate` of an agent update.
    pub update: Option<String>,
    /// Its `content.text`, when 4 KiB or less (the stand-in agent's markers and words).
    pub text: Option<String>,
}

pub fn rec_of(v: &Value) -> Option<Rec> {
    let seq = v.get("seq")?.as_u64()?;
    let kind = v.get("kind").and_then(Value::as_str).unwrap_or_default().to_owned();
    let up = v.pointer("/msg/params/update");
    let update = up.and_then(|u| u.get("sessionUpdate")).and_then(Value::as_str).map(str::to_owned);
    let text = up
        .and_then(|u| u.pointer("/content/text"))
        .and_then(Value::as_str)
        .filter(|t| t.len() <= 4096)
        .map(str::to_owned);
    Some(Rec { seq, kind, update, text })
}

/// Every record of `session`, read again from the start through attach pages: what the daemon holds.
pub fn read_all(socket: &Path, session: &str) -> Result<Vec<Rec>, String> {
    let mut c = Conn::connect(socket)?;
    let mut out = Vec::new();
    let mut after = 0u64;
    loop {
        let page = c.call(
            "_acpmux/attach",
            json!({"sessionId": session, "afterSeq": after, "limit": 2000, "visible": false}),
            Duration::from_secs(120),
        )?;
        let events = page.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        let mut top = after;
        for e in &events {
            if let Some(r) = rec_of(e) {
                top = top.max(r.seq);
                out.push(r);
            }
        }
        let more = page.get("hasMore").and_then(Value::as_bool).unwrap_or(false);
        if !more || top == after {
            break;
        }
        after = top;
    }
    Ok(out)
}

/// How a follower behaves.
#[derive(Clone)]
pub struct FollowOpts {
    pub name: String,
    /// Close the socket hard and attach again this often (None: stay attached).
    pub reconnect_every: Option<Duration>,
    /// The socket to use (a proxy's, for a slow link).
    pub socket: std::path::PathBuf,
    /// Record each record in events.ndjson (off for very large runs).
    pub log_events: bool,
}

/// What a follower saw.
#[derive(Default, Debug)]
pub struct Followed {
    /// seq -> times delivered (after this reader's own dedupe-free count).
    pub deliveries: HashMap<u64, u32>,
    /// The first record of each seq.
    pub recs: HashMap<u64, Rec>,
    /// Records the daemon sent again at or below the cursor the reader attached after.
    pub resent_below_cursor: u64,
    /// Seqs both in an attach page and live on the same attachment (the client dedupes these).
    pub page_live_overlap: u64,
    pub attaches: u64,
    pub attach_errors: u64,
    pub bytes: u64,
    /// When each seq first arrived, ms since the run's start.
    pub first_ms: HashMap<u64, f64>,
    /// Why each attachment ended (`slam`, `closed`, `stop`, an error) with its count.
    pub ends: HashMap<String, u64>,
    /// `_acpmux/lagged` or a reader.too_slow line the daemon sent.
    pub told_slow: u64,
    /// `_acpmux/lagged` notices: each one costs a re-read from the reader's last record.
    pub lagged: u64,
}

impl Followed {
    pub fn max_seq(&self) -> u64 {
        self.deliveries.keys().copied().max().unwrap_or(0)
    }
}

/// Follows `session` until `stop`, attaching again after a hard close or a broken socket.
pub fn follow(
    run: &Run,
    session: &str,
    opts: &FollowOpts,
    stop: &AtomicBool,
    progress: &AtomicU64,
) -> Followed {
    let mut f = Followed::default();
    let mut cursor = 0u64;
    let mut attach_n = 0u64;
    while !stop.load(Ordering::SeqCst) {
        let mut c = match Conn::connect(&opts.socket) {
            Ok(c) => c,
            Err(_) => {
                f.attach_errors += 1;
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
        };
        attach_n += 1;
        f.attaches += 1;
        let after = cursor;
        let mut live_this: std::collections::HashSet<u64> = std::collections::HashSet::new();
        let mut page_this: std::collections::HashSet<u64> = std::collections::HashSet::new();
        let started = Instant::now();
        let mut take = |v: &Value, src: &str, f: &mut Followed, cursor: &mut u64| {
            let Some(r) = rec_of(v) else { return };
            let seq = r.seq;
            if seq <= after {
                f.resent_below_cursor += 1;
            }
            let set = if src == "live" { &mut live_this } else { &mut page_this };
            set.insert(seq);
            *f.deliveries.entry(seq).or_insert(0) += 1;
            f.first_ms.entry(seq).or_insert_with(|| run.t_ms());
            if opts.log_events {
                run.events.write(&json!({"t_ms": super::run::round(run.t_ms()), "reader": opts.name, "session": session,
                    "seq": seq, "kind": r.kind, "src": src, "attach": attach_n}));
            }
            f.recs.entry(seq).or_insert(r);
            *cursor = (*cursor).max(seq);
            progress.fetch_max(seq, Ordering::SeqCst);
        };
        let mut end = String::from("stop");
        // Live notifications may come before the reply: `call_with` hands them over.
        let mut early: Vec<Value> = Vec::new();
        let reply = c.call_with(
            "_acpmux/attach",
            json!({"sessionId": session, "afterSeq": after, "limit": 2000, "visible": false, "eventStream": true}),
            Duration::from_secs(60),
            &mut |v| early.push(v),
        );
        f.told_slow += early.iter().filter(|v| note_slow(v)).count() as u64;
        match reply {
            Ok(page) => {
                for e in page.get("events").and_then(Value::as_array).into_iter().flatten() {
                    take(e, "page", &mut f, &mut cursor);
                }
                // A page that did not reach the end: the rest comes on the next attachment, after
                // the page's `pageThrough`, the way acpmux's own replay client pages
                // (`peer_runtime_io.rs`, `caught_up`). Live records that came early are past a gap
                // still to be paged, so a client drops them; counting them would move the cursor
                // over the gap.
                if page.get("hasMore").and_then(Value::as_bool) == Some(true) {
                    if let Some(through) = page.get("pageThrough").and_then(Value::as_u64) {
                        cursor = cursor.max(through);
                    }
                    f.bytes += c.bytes_in;
                    *f.ends.entry("page_more".into()).or_insert(0) += 1;
                    continue;
                }
                let mut lagged = false;
                for v in early.drain(..) {
                    if is_lagged(&v) {
                        lagged = true;
                        break;
                    }
                    if v.get("method").and_then(Value::as_str) == Some("_acpmux/event")
                        && let Some(p) = v.get("params")
                    {
                        take(p, "live", &mut f, &mut cursor);
                    }
                }
                if lagged {
                    f.lagged += 1;
                    f.bytes += c.bytes_in;
                    *f.ends.entry("lagged".into()).or_insert(0) += 1;
                    continue;
                }
            }
            Err(e) => {
                f.attach_errors += 1;
                f.bytes += c.bytes_in;
                *f.ends.entry(short(&e)).or_insert(0) += 1;
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
        }
        loop {
            if stop.load(Ordering::SeqCst) {
                break;
            }
            if let Some(every) = opts.reconnect_every
                && started.elapsed() >= every
            {
                c.slam();
                end = "slam".into();
                break;
            }
            match c.read(Duration::from_millis(50)) {
                Ok(Some(v)) => {
                    if note_slow(&v) {
                        f.told_slow += 1;
                    }
                    // The daemon left records out of this connection (`server/fanout.rs`): a
                    // client reads again from its last record.
                    if is_lagged(&v) {
                        f.lagged += 1;
                        end = "lagged".into();
                        break;
                    }
                    if v.get("method").and_then(Value::as_str) == Some("_acpmux/event")
                        && let Some(p) = v.get("params")
                    {
                        take(p, "live", &mut f, &mut cursor);
                    }
                }
                Ok(None) => {}
                Err(e) => {
                    end = short(&e);
                    break;
                }
            }
        }
        f.page_live_overlap += live_this.intersection(&page_this).count() as u64;
        f.bytes += c.bytes_in;
        *f.ends.entry(end).or_insert(0) += 1;
    }
    f
}

fn short(e: &str) -> String {
    e.chars().take(60).collect()
}

fn is_lagged(v: &Value) -> bool {
    v.get("method").and_then(Value::as_str) == Some("_acpmux/lagged")
}

/// Whether `v` tells this reader it was too slow (a lag notice or the overrun's last line).
fn note_slow(v: &Value) -> bool {
    match v.get("method").and_then(Value::as_str) {
        Some("_acpmux/event") => false,
        Some("_acpmux/lagged") => true,
        _ => v.to_string().contains("too_slow"),
    }
}

/// A follower on a thread of the case's scope: stopped when dropped, joined by the scope.
pub struct Follower<'s> {
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::ScopedJoinHandle<'s, Followed>>,
    /// The highest seq it has seen so far.
    pub progress: Arc<AtomicU64>,
}

impl Drop for Follower<'_> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

impl<'s> Follower<'s> {
    pub fn start<'e>(
        sc: &'s std::thread::Scope<'s, 'e>,
        run: &Run,
        session: &str,
        opts: FollowOpts,
    ) -> Follower<'s> {
        let stop = Arc::new(AtomicBool::new(false));
        let progress = Arc::new(AtomicU64::new(0));
        let (run, session, s, p) =
            (run.clone(), session.to_owned(), stop.clone(), progress.clone());
        let handle = sc.spawn(move || follow(&run, &session, &opts, &s, &p));
        Follower { stop, handle: Some(handle), progress }
    }

    pub fn seen(&self) -> u64 {
        self.progress.load(Ordering::SeqCst)
    }

    /// Waits until it has seen `seq`, or `within` passes: whether it got there.
    pub fn wait_for(&self, seq: u64, within: Duration) -> bool {
        let t = Instant::now();
        while self.seen() < seq {
            if t.elapsed() > within {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        true
    }

    pub fn finish(mut self) -> Result<Followed, String> {
        self.stop.store(true, Ordering::SeqCst);
        let h = self.handle.take().ok_or("a follower finished twice")?;
        h.join().map_err(|_| "a follower thread failed".to_owned())
    }
}

/// Loss and duplication of what a reader got, against what the daemon holds.
#[derive(Debug, Default)]
pub struct Tally {
    pub truth: u64,
    pub missed: u64,
    pub dup_extra: u64,
    pub first_missed: Vec<u64>,
}

impl Tally {
    /// Deliveries past the first that a client could not expect: not a seq both in an attach page
    /// and live on that attachment.
    pub fn dup(&self, got: &Followed) -> u64 {
        self.dup_extra.saturating_sub(got.page_live_overlap)
    }
}

pub fn tally(truth: &[Rec], got: &Followed, upto: u64) -> Tally {
    let mut t = Tally::default();
    for r in truth.iter().filter(|r| r.seq <= upto) {
        t.truth += 1;
        match got.deliveries.get(&r.seq) {
            None => {
                t.missed += 1;
                if t.first_missed.len() < 10 {
                    t.first_missed.push(r.seq);
                }
            }
            Some(n) => t.dup_extra += u64::from(n.saturating_sub(1)),
        }
    }
    t
}
