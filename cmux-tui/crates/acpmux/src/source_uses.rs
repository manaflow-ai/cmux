//! Reverse lookup of recorded source reads in one explicitly authorized session.
//! The session journal remains the only authority; no answer text or tool output is scanned.
use crate::store::{INDEXED_KINDS, Store};
use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const MAX_URI: usize = 4096;
const MAX_FIELD: usize = 256;
const MAX_PAGE: usize = 256 * 1024;
const SCAN_RECORDS: usize = 512;

#[derive(Debug)]
pub struct Query {
    uri: String,
    revision: Option<String>,
    limit: usize,
    cursor: Option<Cursor>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    version: u8,
    session_id: String,
    selection: String,
    before_seq: u64,
    source_offset: usize,
}

fn bounded(v: &Value, max: usize) -> Option<&str> {
    v.as_str().filter(|s| !s.is_empty() && s.len() <= max && !s.chars().any(char::is_control))
}

impl Query {
    pub fn from_params(params: &Value) -> Result<Self> {
        if bounded(&params["sessionId"], MAX_FIELD).is_none() {
            bail!("source_uses.session_required: explicit sessionId is required");
        }
        let uri = bounded(&params["uri"], MAX_URI)
            .ok_or_else(|| {
                anyhow::anyhow!("source_uses.bad_uri: uri must be a bounded exact source URI")
            })?
            .to_owned();
        let revision = match params.get("revision") {
            None | Some(Value::Null) => None,
            Some(v) => Some(
                bounded(v, MAX_FIELD)
                    .ok_or_else(|| anyhow::anyhow!("source_uses.bad_revision"))?
                    .to_owned(),
            ),
        };
        let limit = match params.get("limit") {
            None => 20,
            Some(v) => v
                .as_u64()
                .filter(|n| (1..=100).contains(n))
                .ok_or_else(|| anyhow::anyhow!("source_uses.bad_limit: limit must be 1..100"))?
                as usize,
        };
        let cursor = match params.get("cursor") {
            None | Some(Value::Null) => None,
            Some(v) => {
                let text =
                    bounded(v, 2048).ok_or_else(|| anyhow::anyhow!("source_uses.bad_cursor"))?;
                let c: Cursor = serde_json::from_str(text)
                    .map_err(|_| anyhow::anyhow!("source_uses.bad_cursor"))?;
                if c.version != 1 || c.before_seq == 0 || c.source_offset > 64 {
                    bail!("source_uses.bad_cursor");
                }
                Some(c)
            }
        };
        Ok(Self { uri, revision, limit, cursor })
    }

    fn selection(&self) -> String {
        crate::sha256::sha256_hex(json!([self.uri, self.revision]).to_string().as_bytes())
    }
}

/// Bounded newest-first page. An empty page with nextCursor still has records to inspect.
/// The cursor binds canonical session and selection, and can resume within one source event.
pub fn read(store: &dyn Store, session_id: &str, query: &Query) -> Result<Value> {
    let selection = query.selection();
    let start = query.cursor.clone().unwrap_or_else(|| Cursor {
        version: 1,
        session_id: session_id.into(),
        selection: selection.clone(),
        before_seq: u64::MAX,
        source_offset: 0,
    });
    if start.session_id != session_id || start.selection != selection {
        bail!("source_uses.bad_cursor: cursor belongs to another session or selection");
    }
    let mut uses = Vec::new();
    let mut bytes = 0;
    let mut scanned = 0;
    let mut next = None;
    let mut stale = false;
    let mut resumed = start.source_offset == 0;
    let cursor_at =
        |before_seq, source_offset| Cursor { before_seq, source_offset, ..start.clone() };
    // Every indexed record counts toward the scan budget, including unrelated turns. This
    // prevents a no-hit lookup from walking an entire session's index on each request.
    store.scan_back_indexed(session_id, 0, start.before_seq,
        &|_, kind| !INDEXED_KINDS.iter().any(|k| k.as_bytes() == kind),
        &mut |rec| {
            scanned += 1;
            if !resumed && rec.seq != start.before_seq - 1 {
                stale = true;
                return false;
            }
            let offset = if !resumed { start.source_offset } else { 0 };
            resumed = true;
            if offset > 0 && (rec.dir != "mux" || rec.kind != "turn_sources" || !rec.msg["sources"].is_array()) {
                stale = true;
                return false;
            }
            if rec.dir == "mux" && rec.kind == "turn_sources" {
                if let (Some(turn), Some(reply), Some(sources)) = (
                    bounded(&rec.msg["turnId"], MAX_FIELD), bounded(&rec.msg["replyId"], MAX_FIELD),
                    rec.msg["sources"].as_array(),
                ) {
                    if sources.len() > 64 || offset > sources.len() { stale = true; return false; }
                    for (i, source) in sources.iter().enumerate().skip(offset) {
                        if source["uri"].as_str() != Some(query.uri.as_str())
                            || query.revision.as_deref().is_some_and(|r| source["revision"].as_str() != Some(r)) {
                            continue;
                        }
                        let Some(tool) = bounded(&source["toolCallId"], MAX_FIELD) else { continue };
                        let Some(kind @ ("file" | "web" | "wiki" | "rfd")) = source["kind"].as_str() else { continue };
                        let mut row = json!({"seq":rec.seq,"at":rec.at,"turnId":turn,"replyId":reply,
                            "toolCallId":tool,"kind":kind,"uri":query.uri});
                        for field in ["revision", "title"] {
                            if let Some(value) = bounded(&source[field], MAX_FIELD) { row[field] = json!(value); }
                        }
                        let size = row.to_string().len() + 1;
                        if uses.len() == query.limit || bytes + size > MAX_PAGE - 16 * 1024 {
                            next = Some(cursor_at(rec.seq.saturating_add(1), i));
                            return false;
                        }
                        bytes += size;
                        uses.push(row);
                    }
                }
            }
            if scanned >= SCAN_RECORDS {
                next = Some(cursor_at(rec.seq, 0));
                return false;
            }
            true
        })?;
    if stale || !resumed {
        bail!("source_uses.stale_cursor: source record changed; restart this lookup");
    }
    Ok(json!({"sessionId":session_id,"uri":query.uri,"uses":uses,
        "nextCursor":next.map(|c| serde_json::to_string(&c)).transpose()?, "scanned":scanned}))
}

#[cfg(test)]
#[path = "source_uses_tests.rs"]
mod tests;
