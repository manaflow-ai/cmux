//! Part of `Hub` (a child of `transfer_out.rs`, beside `transfer_history.rs`). Compaction points
//! at ranges (RFD 0075, "What is not done", item 3): a chat that compacted keeps its summary and
//! the names of the turns the summary covers, and reads any of them back in one call.
//!
//! 1. When the log takes a `compaction_summary`, [`Hub::outline_compaction`] packs the log
//!    through it into the chat's pack store (`history-pack`; a pack keeps its sealed segments, so
//!    packing again redoes the tail) on a thread of its own at the lowest CPU priority, and
//!    appends a `mux` record `compaction_outline`: `{summarySeq, session, lastLine, turns: [{range,
//!    at, records, ask}], omitted}`. A turn's `range` is `<session>@<first line>-<last line>`, `at`
//!    its start (ms), `records` its line count and `ask` the first 160 bytes of what was asked,
//!    as `cmux-session-pack`'s `digest::turns` gives them. The newest [`MAX_RECORDED_TURNS`] turns
//!    are in the record and `omitted` counts the older. The record is storage only: no view draws
//!    it (`rows/fold.rs` and the transcript filters ignore any `mux` kind they do not list, as
//!    they do `history_arrived`), and a reader that knows no such kind skips the record. The turn
//!    that took the summary never waits for any of it.
//! 2. `_acpmux/history/read` (`server/history.rs`, the `chat_history` MCP tool) answers from the
//!    pack: an outline, a range's digest, or one record by `seq`, each bounded
//!    ([`MAX_OUTLINE_TURNS`], [`MAX_DIGEST_BYTES`], [`MAX_RECORD_BYTES`]). A chat with no pack yet is packed
//!    by its first call (seconds on a large chat; every call after reads the pack).

use super::transfer_history::{PackTurn, lower_this_thread, pack_error};
use super::transfer_out::scratch_dir;
use super::*;
use cmux_session_pack as pack;
use cmux_session_pack::digest;

/// The kind of the record a compaction summary is followed by.
pub(in crate::hub) const OUTLINE_KIND: &str = "compaction_outline";
/// The newest turns a `compaction_outline` record names; older ones are counted in `omitted`.
pub(in crate::hub) const MAX_RECORDED_TURNS: usize = 200;
/// The most turns one outline answer lists (its default is [`DEFAULT_OUTLINE_TURNS`]).
pub(in crate::hub) const MAX_OUTLINE_TURNS: usize = 200;
const DEFAULT_OUTLINE_TURNS: usize = 50;
/// The longest digest answer, in bytes; a longer range is cut with a note to narrow it.
pub(in crate::hub) const MAX_DIGEST_BYTES: usize = 32 * 1024;
/// The most lines of one range a digest reads.
const MAX_DIGEST_LINES: u64 = 20_000;
/// The most bytes of one record an answer holds; `offset` reads on.
pub(in crate::hub) const MAX_RECORD_BYTES: usize = 64 * 1024;

fn turn_json(t: &digest::Turn) -> Value {
    json!({"range": t.range.to_string(), "at": t.at, "records": t.records, "ask": t.ask})
}

/// The text of `s` up to `max` bytes, cut at a character.
fn cut_str(s: &str, max: usize) -> &str {
    let mut end = max.min(s.len());
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s.get(..end).unwrap_or("")
}

/// `s` from byte `from` on (moved forward to a character).
fn from_str(s: &str, from: usize) -> &str {
    let mut at = from.min(s.len());
    while !s.is_char_boundary(at) {
        at += 1;
    }
    s.get(at..).unwrap_or("")
}

/// The last seq the pack holds.
fn packed_through(m: &pack::Manifest) -> u64 {
    m.segments.iter().filter_map(|s| s.seq.map(|(_, hi)| hi)).max().unwrap_or(0)
}

/// The `compaction_outline` record for the summary at `summary_seq`, from a pack that holds it:
/// the turns through the summary's line, the last one cut at it when the pack goes on past.
fn outline_record(pack: &pack::Pack, session: &str, summary_seq: u64) -> anyhow::Result<Value> {
    let (last_line, _) = pack
        .by_seq(summary_seq)
        .map_err(pack_error)?
        .ok_or_else(|| anyhow::anyhow!("the pack holds no record at seq {summary_seq}"))?;
    let starts: Vec<u64> = pack.manifest.marks().collect();
    let end = starts.partition_point(|s| *s <= last_line);
    let from = end.saturating_sub(MAX_RECORDED_TURNS);
    let mut turns = digest::turns_window(pack, from, end).map_err(pack_error)?;
    if let Some(t) = turns.last_mut()
        && t.range.last > last_line
    {
        t.records = t.records.saturating_sub(t.range.last - last_line);
        t.range.last = last_line;
    }
    Ok(json!({
        "summarySeq": summary_seq,
        "session": session,
        "lastLine": last_line,
        "turns": turns.iter().map(turn_json).collect::<Vec<_>>(),
        "omitted": from,
    }))
}

impl Hub {
    /// After a `compaction_summary` the log took at `summary_seq`: packs the log through it and
    /// appends the outline of the turns it covers (module doc), on a thread of its own.
    pub(in crate::hub) fn outline_compaction(
        self: &Arc<Self>,
        session: &Arc<Session>,
        summary_seq: u64,
    ) {
        let (hub, session) = (self.clone(), session.clone());
        let spawned =
            std::thread::Builder::new().name("acpmux-compaction-outline".into()).spawn(move || {
                lower_this_thread();
                match hub.compaction_outline_record(&session, summary_seq) {
                    Ok(record) => {
                        hub.append(&session, "mux", OUTLINE_KIND, record);
                    }
                    Err(error) => {
                        tracing::warn!(session = %session.id, "compaction not outlined: {error:#}");
                    }
                }
            });
        if let Err(error) = spawned {
            tracing::warn!("compaction not outlined: {error}");
        }
    }

    /// The `compaction_outline` record for the summary at `summary_seq`.
    fn compaction_outline_record(
        &self,
        session: &Session,
        summary_seq: u64,
    ) -> anyhow::Result<Value> {
        let store = self.pack_store(&session.id)?;
        let work = scratch_dir("outline");
        let _turn = PackTurn::take(&session.id);
        // A pack that already holds the summary (a `fresh` read packed past it) is kept: packing
        // through the summary again would cut the pack back to it.
        let held = pack::Manifest::load(&store, &session.id)
            .map_err(pack_error)?
            .filter(|m| packed_through(m) >= summary_seq);
        let manifest = match held {
            Some(m) => m,
            None => {
                let made = self.pack_through(session, summary_seq, &store, &work);
                let _ = crate::home_fs::remove_dir_all(&work);
                made?.0
            }
        };
        outline_record(&pack::Pack::with_manifest(&store, manifest), &session.id, summary_seq)
    }

    /// The chat's pack, packed through its newest records when it has none (or `fresh`).
    fn current_pack(&self, session: &Session, fresh: bool) -> anyhow::Result<pack::Pack> {
        let store = self.pack_store(&session.id)?;
        if !fresh && let Some(m) = pack::Manifest::load(&store, &session.id).map_err(pack_error)? {
            return Ok(pack::Pack::with_manifest(&store, m));
        }
        let _turn = PackTurn::take(&session.id);
        // Another reader may have packed while this one waited for its turn.
        if !fresh && let Some(m) = pack::Manifest::load(&store, &session.id).map_err(pack_error)? {
            return Ok(pack::Pack::with_manifest(&store, m));
        }
        let work = scratch_dir("history-read");
        let newest = session.seq.load(Ordering::SeqCst);
        // The counter may be a record ahead of what the log holds: try the ones before.
        let mut last_error = anyhow::anyhow!("the chat's log is empty");
        for through in (newest.saturating_sub(3).max(1)..=newest).rev() {
            match self.pack_through(session, through, &store, &work) {
                Ok((manifest, _, _)) => {
                    let _ = crate::home_fs::remove_dir_all(&work);
                    return Ok(pack::Pack::with_manifest(&store, manifest));
                }
                Err(e) => last_error = e,
            }
        }
        let _ = crate::home_fs::remove_dir_all(&work);
        Err(last_error)
    }

    /// `_acpmux/history/read {sessionId, outline | range | seq, ...}` for chat `session`: blocking
    /// (reads the pack from disk); call it off the async threads.
    ///
    /// - no `range` and no `seq`: the outline, `limit` turns (default 50, at most 200), the
    ///   newest first unless `before` (a line) asks for the ones before it; `compacted: true`
    ///   keeps the turns the chat's newest `compaction_outline` covers.
    /// - `range` (`<session>@<first>-<last>`): the digest of that range.
    /// - `seq`: that record whole, `MAX_RECORD_BYTES` from `offset` (0).
    /// - `fresh: true`: packs the chat's newest records first (slow on a large chat).
    pub(crate) fn history_read(
        &self,
        session: &Session,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let bad = |m: String| RpcError::invalid_params(m);
        let fail = |e: &dyn std::fmt::Display| RpcError::internal(format!("history: {e}"));
        let started = std::time::Instant::now();
        let num = |k: &str| params.get(k).and_then(Value::as_u64);
        let fresh = params.get("fresh").and_then(Value::as_bool) == Some(true);
        let pack = self.current_pack(session, fresh).map_err(|e| fail(&format!("{e:#}")))?;
        let through = packed_through(&pack.manifest);
        let mut answer = if let Some(range) = params.get("range").and_then(Value::as_str) {
            let mut r = pack::RangeId::parse(range).map_err(|e| bad(e.to_string()))?;
            if r.name != session.id {
                return Err(bad(format!(
                    "a chat reads its own history: {} is not {}",
                    r.name, session.id
                )));
            }
            if r.first > r.last || r.first >= pack.manifest.lines {
                return Err(bad(format!(
                    "{range} is outside the packed log ({} lines, 0 to {})",
                    pack.manifest.lines,
                    pack.manifest.lines.saturating_sub(1)
                )));
            }
            r.last = r.last.min(pack.manifest.lines - 1);
            let read_to = r.last.min(r.first.saturating_add(MAX_DIGEST_LINES - 1));
            let mut note = String::new();
            if read_to < r.last {
                note = format!(
                    "\n[range cut: read {} to {read_to} of {}; ask for {}@{}-{}]\n",
                    r.first,
                    r.last,
                    r.name,
                    read_to + 1,
                    r.last
                );
                r.last = read_to;
            }
            let text =
                digest::digest(&pack, &r, digest::Limits::default()).map_err(|e| fail(&e))?;
            let shown = cut_str(&text, MAX_DIGEST_BYTES);
            let mut out = shown.to_owned();
            let cut = text.len() - shown.len();
            if cut > 0 {
                out.push_str(&format!(
                    "\n[digest cut: {cut} more bytes; ask for a narrower range of {r}, or one record by seq]\n"
                ));
            }
            out.push_str(&note);
            json!({"mode": "digest", "range": r.to_string(), "text": out, "cutBytes": cut})
        } else if let Some(seq) = num("seq") {
            let line = match pack.by_seq(seq).map_err(|e| fail(&e))? {
                Some((_, line)) => Some(line),
                // Newer than the pack: read from the log.
                None => self.record_line(session, seq).map_err(|e| fail(&format!("{e:#}")))?,
            };
            let line =
                line.ok_or_else(|| RpcError::not_found(format!("no record with seq {seq}")))?;
            let text = String::from_utf8_lossy(&line);
            let offset = usize::try_from(num("offset").unwrap_or(0)).unwrap_or(usize::MAX);
            let rest = from_str(&text, offset);
            let shown = cut_str(rest, MAX_RECORD_BYTES);
            let next = (shown.len() < rest.len()).then(|| text.len() - rest.len() + shown.len());
            json!({"mode": "record", "seq": seq, "bytes": text.len(), "text": shown, "nextOffset": next})
        } else {
            self.outline_answer(session, &pack, params)?
        };
        if let Some(fields) = answer.as_object_mut() {
            fields.insert("session".into(), json!(session.id));
            fields.insert("packedThroughSeq".into(), json!(through));
            let ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
            fields.insert("ms".into(), json!(ms));
        }
        Ok(answer)
    }

    fn outline_answer(
        &self,
        session: &Session,
        pack: &pack::Pack,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let fail = |e: &dyn std::fmt::Display| RpcError::internal(format!("history: {e}"));
        let limit = params
            .get("limit")
            .and_then(Value::as_u64)
            .map_or(DEFAULT_OUTLINE_TURNS, |l| usize::try_from(l).unwrap_or(usize::MAX))
            .clamp(1, MAX_OUTLINE_TURNS);
        let starts: Vec<u64> = pack.manifest.marks().collect();
        let mut end = starts.len();
        // Only the turns the newest compaction's outline covers.
        let mut covered = None;
        if params.get("compacted").and_then(Value::as_bool) == Some(true) {
            let mut newest = None::<u64>;
            // The newest outline sits just after the newest summary, near the pack's end: read
            // from the pack's last segment on (not the whole log), and the whole log only when
            // that holds none (a fresh pack, or a chat whose outline is older).
            let from = pack
                .manifest
                .segments
                .last()
                .and_then(|s| s.seq.map(|(lo, _)| lo.saturating_sub(1)))
                .unwrap_or(0);
            for after in [from, 0] {
                self.store
                    .scan_kinds_after(&session.id, after, &[OUTLINE_KIND], &mut |rec| {
                        newest = rec.msg.get("lastLine").and_then(Value::as_u64).or(newest);
                        true
                    })
                    .map_err(|e| fail(&format!("{e:#}")))?;
                if newest.is_some() || after == 0 {
                    break;
                }
            }
            let last = newest.ok_or_else(|| {
                RpcError::not_found(
                    "this chat has no compaction outline: it has not compacted, or the outline of \
                     its newest compaction is still being made or failed (acpmux's log says)"
                        .to_owned(),
                )
            })?;
            end = starts.partition_point(|s| *s <= last);
            covered = Some(last);
        }
        if let Some(before) = params.get("before").and_then(Value::as_u64) {
            end = end.min(starts.partition_point(|s| *s < before));
        }
        let from = end.saturating_sub(limit);
        let turns = digest::turns_window(pack, from, end).map_err(|e| fail(&e))?;
        let mut text = format!(
            "# {}: {} turns packed ({} records), showing {} to {}{}\n# range\tstarted (ms)\trecords\tasked\n",
            session.id,
            starts.len(),
            pack.manifest.lines,
            from + 1,
            end,
            covered.map_or(String::new(), |l| format!(
                ", those the compaction covers (through line {l})"
            )),
        );
        for t in &turns {
            text.push_str(&format!(
                "{}\t{}\t{}\t{}\n",
                t.range,
                t.at,
                t.records,
                t.ask.replace(['\n', '\t'], " ")
            ));
        }
        if from > 0 {
            let first = turns.first().map_or(0, |t| t.range.first);
            text.push_str(&format!("# {from} older turns: ask again with before={first}\n"));
        }
        Ok(json!({
            "mode": "outline",
            "turns": turns.iter().map(turn_json).collect::<Vec<_>>(),
            "totalTurns": starts.len(),
            "olderTurns": from,
            "text": text,
        }))
    }

    /// The log's record with `seq`, as a line, for a record the pack does not hold yet.
    fn record_line(&self, session: &Session, seq: u64) -> anyhow::Result<Option<Vec<u8>>> {
        let mut found = None;
        self.store.scan(&session.id, seq.saturating_sub(1), &mut |mut e: EventRecord| {
            if e.seq == seq {
                self.display_logged(Some(session), &mut e);
                found = serde_json::to_vec(&e).ok();
            }
            false
        })?;
        Ok(found)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A pack that goes on past a summary (a `fresh` read packed further): the summary's outline
    /// names the turns through the summary's line and nothing after it.
    #[test]
    fn an_outline_from_a_pack_that_goes_on_past_the_summary_ends_at_the_summary() {
        let dir = tempfile::tempdir().unwrap();
        let lines = [
            r#"{"seq":1,"at":10,"dir":"mux","kind":"turn_started","msg":{"promptLine":"one"}}"#,
            r#"{"seq":2,"at":11,"dir":"in","kind":"agent_message_chunk","msg":{"params":{"update":{"content":{"text":"done"}}}}}"#,
            r#"{"seq":3,"at":12,"dir":"mux","kind":"turn_started","msg":{"promptLine":"compact"}}"#,
            r#"{"seq":4,"at":13,"dir":"in","kind":"compaction_summary","msg":{"text":"summary"}}"#,
            r#"{"seq":5,"at":14,"dir":"in","kind":"agent_message_chunk","msg":{"params":{"update":{"content":{"text":"after"}}}}}"#,
            r#"{"seq":6,"at":15,"dir":"mux","kind":"turn_started","msg":{"promptLine":"three"}}"#,
            r#"{"seq":7,"at":16,"dir":"in","kind":"agent_message_chunk","msg":{"params":{"update":{"content":{"text":"later"}}}}}"#,
        ];
        let file = dir.path().join("history.ndjson");
        std::fs::write(&file, lines.join("\n") + "\n").unwrap();
        let store = pack::Store::new(dir.path().join("store"));
        let (manifest, _) =
            pack::pack(&store, "chat", &[file], &pack::Params::default(), false).unwrap();
        assert_eq!(packed_through(&manifest), 7);
        let record =
            outline_record(&pack::Pack::with_manifest(&store, manifest), "chat", 4).unwrap();
        assert_eq!(record["lastLine"], 3);
        let turns = record["turns"].as_array().unwrap();
        assert_eq!(turns.len(), 2, "{record}");
        assert_eq!(turns[1]["range"], "chat@2-3");
        assert_eq!(turns[1]["records"], 2);
        assert_eq!(record["omitted"], 0);
    }
}
