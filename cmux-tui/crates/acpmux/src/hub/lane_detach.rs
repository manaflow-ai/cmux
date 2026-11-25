//! Part of `Hub`; see `hub/mod.rs`. What ends a lane's link to the session that started it
//! (`lane_reports.rs`), so its turns stop showing in that session's chat:
//!
//! - The person prompts the lane (the app, or a proven person): it is theirs from then on. A
//!   lane started with `--report-to` (`_meta.acpmux.reportTo`, the link's `asked`) asked to
//!   report, and keeps reporting.
//! - Its tag `lane.reportsTo` is removed, or changed so it names another session. Setting the tag
//!   never makes a link: it is shown, never trusted.
//! - `_acpmux/detach_parent` (`acpmux session detach`): ends the link and removes the tag.
//!
//! A session started with no parent (`acpmux new --no-parent`, `_meta.acpmux.parent: null`) never
//! has one (`server/lane_parent.rs`).
//!
//! Leo, 2026-11-01: "why am i seeing their responses in you? that shouldn't happen."

use super::*;
use crate::hub::lane_reports::TAG;

impl Hub {
    /// Ends `lane`'s link, if it has one: no report of it is queued or sent from now on. Its tag
    /// is left to the caller. Whether it had one.
    fn lane_unlink(&self, lane: &str) -> bool {
        let had = self.lane_links(|links| links.remove(lane).is_some());
        if had {
            self.lane_report_unlinked(lane);
        }
        had
    }

    /// Ends `session`'s link and removes its tag (`acpmux session detach`): whether it had a
    /// link.
    pub(crate) fn lane_detach(&self, session: &Session) -> Result<bool, RpcError> {
        let had = self.lane_unlink(&session.id);
        if session.meta().tags.contains_key(TAG) {
            self.set_tags_answered(session, None, &[TAG.to_owned()], None)?;
        }
        Ok(had)
    }

    /// The person prompted `session` directly: a lane that did not ask to report (`--report-to`)
    /// is theirs now and reports to its parent no more.
    pub(crate) fn lane_person_prompted(&self, session: &Session) {
        let asked = self.lane_links(|links| links.get(&session.id).map(|l| l.asked));
        if asked == Some(false) {
            let _ = self.lane_detach(session);
        }
    }

    /// `session`'s tags changed: a removed tag, or one that no longer names its parent, ends its
    /// link.
    pub(in crate::hub) fn lane_tags_changed(&self, session: &Session) {
        let Some(parent) = self.lane_report_parent(&session.id) else { return };
        let tagged = session.meta().tags.get(TAG).map(|t| t.value.clone());
        if tagged.as_deref() != Some(parent.as_str()) {
            self.lane_unlink(&session.id);
        }
    }
}
