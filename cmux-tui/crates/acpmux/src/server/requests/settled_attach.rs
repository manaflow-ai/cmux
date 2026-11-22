//! `_acpmux/attach` with `settled: true` (capability `settled-attach-v1`, cmuxterm-hq#9655 stage
//! 1): the chat's settled view (`hub/settled_view.rs`) first, then only the records logged since.
//!
//! The reply has the shape of any attach reply, so its page is drawn as one: `events` are the
//! view's records followed by every record of the asked kinds logged after the view
//! (`afterSeq` = its `lastSeq`), `lastSeq` and `pageThrough` the log's end, `hasMore` the view's.
//! `settled` adds what the view read with its records, at one moment: its `lastSeq` (the records
//! at or before it are the settled frame), the queue, the pending asks, the seqs a turn can be
//! forked through and the chat's status. A restart has not read the chat's log yet: the queue the
//! summary shows is then the view's (`session.queueFrom: "settled"`), never an empty one the log
//! fills in later, so nothing waits for that log (no `waitLogs`).
//!
//! No view for the asked shape, one of another chat under the same id, or more logged since than
//! one page holds: the attach answers as without `settled` (`settled: null`), and writes the view
//! for the chat's next open.

use super::*;
use crate::hub::settled_view::{SettledKey, SettledView};

/// The saved view an attach asking `settled` may answer with, before it waits for any log.
pub(super) fn saved(
    hub: &Hub,
    session: &crate::hub::Session,
    params: &Value,
) -> Option<(SettledKey, Option<SettledView>)> {
    if params.get("settled") != Some(&Value::Bool(true)) {
        return None;
    }
    let key = SettledKey::of_attach(params)?;
    let view = hub.settled_view(session).filter(|view| view.answers(session, &key));
    Some((key, view))
}

/// The reply from `view`, or none when more was logged since it than one page holds.
pub(super) fn reply(
    hub: &Arc<Hub>,
    conn: &Conn,
    s: &crate::hub::Session,
    view: SettledView,
) -> Result<Option<Value>, RpcError> {
    let filter = view.key.filter()?;
    // Read before the page, as the attach does: a forward page that reads to the log's end
    // holds every record up to it.
    let last = s.meta().last_seq;
    // More logged since the view than a few pages hold: the plain attach reads the newest page
    // back from the log's end, which costs that page. The forward read from the view would cost
    // every record logged since, of any kind, to learn it is more than a page: on Leo's daemon a
    // view hours old read a 5.8 GB chat's later segments on each open (2026-11-18).
    if last.saturating_sub(view.last_seq) > settled_gap_records(view.key.limit) {
        return Ok(None);
    }
    let read = || {
        hub.events_page(
            &s.id,
            view.last_seq,
            None,
            view.key.limit,
            Some(view.key.max_bytes),
            false,
            &filter,
        )
    };
    let delta = crate::qos::on_screen(read).map_err(|e| RpcError::internal(e.to_string()))?;
    if delta.has_more {
        return Ok(None);
    }
    let mut detail = hub.session_detail(s);
    let log_loaded = hub.session_log_loaded(s);
    if !log_loaded {
        detail.set("queue", view.queue.clone());
        detail.set("queued", json!(view.queued));
        detail.set("queueFrom", json!("settled"));
    }
    let mut settled = view.reply_fields();
    settled.set("logLoaded", json!(log_loaded));
    let mut page = crate::hub::EventPage { events: view.records, has_more: view.has_more };
    page.events.extend(delta.events);
    let opener = turn_opener::turn_opener(hub, &s.id, &page);
    hub.lane_report_events_read(conn.caller(), &s.id, &page.events);
    let has_more = page.has_more;
    let events: Vec<Value> = events::values(&s.id, page.events);
    let presence = hub.presence.snapshot(&s.id);
    let mut reply = json!({"session": detail, "events": events, "hasMore": has_more, "lastSeq": last, "pageThrough": last, "presence": presence, "turnOpener": opener, "settled": settled});
    crate::hub::fit_reply(&mut reply);
    Ok(Some(reply))
}

/// The most records logged since a settled view that its open still reads forward: four of its
/// pages' records, of any kind (a turn's reply chunks and tool updates are most of a log), so a
/// view a few turns old answers and one hours old falls back to the plain attach.
pub(super) fn settled_gap_records(limit: usize) -> u64 {
    (limit.max(1) as u64).saturating_mul(4).max(2000)
}
