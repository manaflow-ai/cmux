//! Notifications for OSC 7501 program status (cx-kxa2).
//!
//! The daemon owns every notification (plans/cmux-next/notifications.md), so
//! a program that reports `blocked` (permission, question, auth), `error` or
//! `done` gets a ledger notification from the session host, exactly once per
//! change: a repeated report of the same state, kind and message (a replay, a
//! program that re-sends its status) posts nothing. The client decides how
//! it shows (banner, sound, Focus, a `done` for a visible tab reads at once)
//! with the same rules as every other terminal notification.

#[cfg(test)]
#[path = "program_status_notify_tests.rs"]
mod tests;
