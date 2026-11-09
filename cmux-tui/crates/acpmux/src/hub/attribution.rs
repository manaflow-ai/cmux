//! Part of `Hub`; see `hub/mod.rs`. Which chat wrote a line (`attribution.rs`): the running turn's
//! edit tool calls are noted as they update ([`absorb`]), the lines they left are recorded once when
//! the turn ends ([`Hub::record_turn_attribution`]), and `_acpmux/attribution` answers a diff's
//! visible lines ([`Hub::attribution`]).

use super::*;
use crate::attribution::{self as attr, Author};
use crate::path_canon::canonical_path;
use std::collections::BTreeMap;
use std::time::Duration;

/// The longest a turn's end waits on reading the files its edits wrote.
// timeout: a slow disk leaves the turn's lines unattributed; the turn settles without them.
const RECORD_LIMIT: Duration = Duration::from_secs(2);

/// Notes a `tool_call` or `tool_call_update` of the running turn. Nothing for replayed history.
pub(super) fn absorb(session: &Session, update: &Value, m: &SessionMeta, replayed: bool) {
    if replayed {
        return;
    }
    let cwd = m.cwd.clone();
    session
        .turn_edits
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .absorb(update, |p| canonical_path(p, Some(&cwd)));
}

/// A file read for the index or a query: none when it is missing, too large or not text.
fn read_text(path: &std::path::Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > attr::MAX_FILE_BYTES {
        return None;
    }
    String::from_utf8(std::fs::read(path).ok()?).ok()
}

impl Hub {
    /// Records the lines the turn `turn_id` of `session` wrote, at `head` (its `gitHead`): read once
    /// per file it edited, off the runtime and bounded. A turn with no head (no repository, or git
    /// could not be read) records nothing; a `trigger` turn (one the person did not prompt) records
    /// no prompt.
    pub(super) async fn record_turn_attribution(
        self: &Arc<Self>,
        session: &Session,
        turn_id: &str,
        head: Option<&str>,
        trigger: bool,
    ) {
        let written = session.turn_edits.lock().unwrap_or_else(|e| e.into_inner()).take_written();
        let Some(head) = head.filter(|h| !h.is_empty()) else { return };
        if written.is_empty() || turn_id.is_empty() {
            return;
        }
        let author = {
            let m = session.meta();
            Author {
                session_id: session.id.clone(),
                turn_id: turn_id.to_owned(),
                head: head.to_owned(),
                model: super::model_options::current_model(&m),
                title: m.title.clone(),
                // A trigger's turn keeps the person's last prompt as `last_prompt`: not its own.
                prompt: if trigger {
                    None
                } else {
                    m.last_prompt.as_deref().and_then(Author::first_line)
                },
                at: crate::store::now_ms(),
            }
        };
        let hub = Arc::clone(self);
        let record = tokio::task::spawn_blocking(move || {
            let mut by_file: BTreeMap<String, Vec<attr::EditBlock>> = BTreeMap::new();
            for block in written {
                by_file.entry(block.path.clone()).or_default().push(block);
            }
            for (abs, blocks) in by_file {
                let Some(repo) = crate::touched_files::repo_of(std::path::Path::new(&abs)) else {
                    continue;
                };
                let Ok(rel) = std::path::Path::new(&abs).strip_prefix(&repo.root) else { continue };
                let Some(text) = read_text(std::path::Path::new(&abs)) else { continue };
                let ranges: Vec<(u32, u32)> =
                    blocks.iter().flat_map(|b| attr::locate(&text, b)).collect();
                let root = repo.root.to_string_lossy();
                let rel = rel.to_string_lossy().replace('\\', "/");
                hub.attribution_index
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .record(&root, &rel, &text, &ranges, &author);
            }
        });
        if tokio::time::timeout(RECORD_LIMIT, record).await.is_err() {
            tracing::debug!(session = %session.id, "turn attribution: file read past its limit");
        }
    }

    /// `_acpmux/attribution {root, head, path, ranges}`: who wrote the lines `ranges` of `path` in
    /// the worktree `root` at `head`, as `{attributions: [...]}` newest first. Only a file the index
    /// holds is read, and only to check its lines are still the ones written. Blocking: run it off
    /// the runtime.
    pub fn attribution(&self, params: &Value) -> Result<Value, RpcError> {
        let root = params
            .get("root")
            .and_then(Value::as_str)
            .filter(|r| r.starts_with('/'))
            .ok_or_else(|| RpcError::invalid_params("root is an absolute path"))?;
        let head = params
            .get("head")
            .and_then(Value::as_str)
            .filter(|h| !h.is_empty())
            .ok_or_else(|| RpcError::invalid_params("head is required"))?;
        let path = attr::query_path(params.get("path")).map_err(RpcError::invalid_params)?;
        let ranges = attr::query_ranges(params.get("ranges")).map_err(RpcError::invalid_params)?;
        let texts =
            attr::query_texts(params.get("texts"), &ranges).map_err(RpcError::invalid_params)?;
        let none = || Ok(json!({"attributions": []}));
        // The index keys a worktree by its canonical top folder (`touched_files::repo_of`).
        let Ok(root) = std::fs::canonicalize(root) else { return none() };
        let root_text = root.to_string_lossy().into_owned();
        if !self
            .attribution_index
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .knows(&root_text, &path)
        {
            return none();
        }
        let Some(text) = read_text(&root.join(&path)) else { return none() };
        // Only the ranges whose shown lines the file still holds are answered.
        let ranges = attr::shown_ranges(&text, &ranges, texts.as_deref());
        if ranges.is_empty() {
            return none();
        }
        let candidates = self
            .attribution_index
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .candidates(&root_text, head, &path, &ranges);
        Ok(json!({"attributions": attr::verify(&text, candidates)}))
    }
}
