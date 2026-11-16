//! `_acpmux/review_brief`: a chat's review brief (`review_brief.rs`), kept beside its log.
//!
//! The fold is saved as `<session>/review-brief.json` with the last `seq` it read. An open whose
//! chat logged nothing since reads no record; one that did reads only the records past that
//! `seq` (`Store::scan`, which starts at the segment holding it). Only a chat's first brief reads
//! its whole log, and then each line's head only, parsing the few kinds a brief reads. A memory
//! store keeps no file, and folds its log on each ask.

use super::*;
use crate::review_brief::{FILE, Fold, KINDS};

impl Hub {
    /// The brief of `session`'s chat. With `root` (the diff's repository root), paths are
    /// relative to it and an edit outside it is left out.
    pub fn review_brief(&self, session: &Session, root: Option<&str>) -> Result<Value, RpcError> {
        let path = self.store.session_dir(&session.id).map(|dir| dir.join(FILE));
        let saved = path.as_ref().and_then(|p| std::fs::read(p).ok());
        let mut fold = saved.as_deref().map(Fold::read).unwrap_or_default();
        let last = session.meta().last_seq;
        let before = fold.seq;
        if fold.seq == 0 || fold.seq < last {
            let read = if fold.seq == 0 {
                self.store.scan_heads(&session.id, &mut |head| {
                    if KINDS.contains(&head.kind)
                        && let Some(rec) = head.record()
                    {
                        fold.feed(&rec);
                    }
                    true
                })
            } else {
                let after = fold.seq;
                self.store.scan(&session.id, after, &mut |rec| {
                    if KINDS.contains(&rec.kind.as_str()) {
                        fold.feed(&rec);
                    }
                    true
                })
            };
            read.map_err(|e| {
                RpcError::internal(format!("the session's log could not be read: {e}"))
            })?;
            // Records of other kinds still move the fold on, so the next open knows it read them.
            fold.seq = fold.seq.max(last);
        }
        if let Some(path) = path.filter(|_| fold.seq != before)
            && let Ok(bytes) = serde_json::to_vec(&fold)
            && let Err(e) = crate::config::write_atomic(&path, &bytes)
        {
            // The brief is still right; the next open folds again.
            tracing::debug!(session = %session.id, "review brief not saved: {e}");
        }
        Ok(json!({"sessionId": session.id, "seq": fold.seq, "brief": fold.brief(root)}))
    }
}

#[cfg(test)]
#[path = "review_brief_tests.rs"]
mod tests;
