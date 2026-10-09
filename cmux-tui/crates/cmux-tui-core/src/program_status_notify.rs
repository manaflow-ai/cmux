//! Notifications for OSC 7501 program status (cx-kxa2).
//!
//! The daemon owns every notification (plans/cmux-next/notifications.md), so
//! a program that reports `blocked` (permission, question, auth), `error` or
//! `done` gets a ledger notification from the session host, exactly once per
//! change: a repeated report of the same state, kind and message (a replay, a
//! program that re-sends its status) posts nothing. The client decides how
//! it shows (banner, sound, Focus, a `done` for a visible tab reads at once)
//! with the same rules as every other terminal notification.

use ghostty_vt::ProgramStatusState;

use crate::Actor;
use crate::SurfaceId;
use crate::mux::{Mux, NotificationLevel, NotificationSource};
use crate::program_status::ProgramStatusNotice;

/// Posts `notices` of `surface`'s terminal as `terminal` notifications. The
/// caller published the records first, so a client that reads the terminal's
/// `extra.program_status` when the notification arrives sees the record
/// (its kind) that caused it.
pub(crate) fn post(mux: &Mux, surface: SurfaceId, notices: Vec<ProgramStatusNotice>) {
    for notice in notices {
        let (title, body, level) = shown(notice);
        if mux
            .post_notification_as(
                &Actor::Daemon,
                title,
                body,
                level,
                Some(surface),
                NotificationSource::Terminal,
            )
            .is_err()
        {
            mux.report_internal_diagnostic("program status notification not posted");
        }
    }
}

/// Title, body and level of one notice: the record's title (else its app
/// name), its message, and `warning` for blocked, `error` for error, `info`
/// for done. The text is the record's already sanitized program text.
pub(crate) fn shown(notice: ProgramStatusNotice) -> (String, String, NotificationLevel) {
    let level = match notice.state {
        ProgramStatusState::Blocked => NotificationLevel::Warning,
        ProgramStatusState::Error => NotificationLevel::Error,
        _ => NotificationLevel::Info,
    };
    (notice.title.or(notice.app).unwrap_or_default(), notice.message.unwrap_or_default(), level)
}

#[cfg(test)]
#[path = "program_status_notify_tests.rs"]
mod tests;
