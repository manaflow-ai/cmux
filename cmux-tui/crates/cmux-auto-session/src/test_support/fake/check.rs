//! The field checks every route makes before it reaches a chat: the real store's `http.ts`.
//! An id the real store would refuse is refused here too, so a test that passes names ids the
//! Cloud takes.

use super::record::MAX_INBOX_TEXT;
use crate::wire::{Holder, Repo};

/// One to `max` ASCII letters, digits and the `extra` characters.
fn word(text: &str, max: usize, extra: &[char]) -> bool {
    let allowed = |c: char| c.is_ascii_alphanumeric() || extra.contains(&c);
    !text.is_empty() && text.len() <= max && text.chars().all(allowed)
}

/// A string's length as the real store counts it (UTF-16 units).
fn length(text: &str) -> usize {
    text.encode_utf16().count()
}

/// A chat id: `[A-Za-z0-9_.:-]{1,128}`. `machine` and `assignments` are routes, not chats.
pub(super) fn chat_id(id: &str) -> bool {
    word(id, 128, &['_', '.', ':', '-']) && id != "machine" && id != "assignments"
}

/// A message id: `[A-Za-z0-9_.:-]{1,128}`.
pub(super) fn message_id(id: &str) -> bool {
    word(id, 128, &['_', '.', ':', '-'])
}

/// A laptop's device id: `[A-Za-z0-9_.-]{1,64}`.
pub(super) fn device(id: &str) -> bool {
    word(id, 64, &['_', '.', '-'])
}

/// A Cloud machine's id: `[A-Za-z0-9_-]{1,64}`.
pub(super) fn machine(id: &str) -> bool {
    word(id, 64, &['_', '-'])
}

/// A team id: `team_` and 20 lowercase hex digits.
pub(super) fn team(id: &str) -> bool {
    let hex = |c: char| c.is_ascii_digit() || ('a'..='f').contains(&c);
    id.strip_prefix("team_").is_some_and(|rest| rest.len() == 20 && rest.chars().all(hex))
}

/// A harness name: a lowercase letter or digit, then up to 31 of those and `_ . -`.
pub(super) fn harness(name: &str) -> bool {
    let plain = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit();
    name.len() <= 32
        && name.chars().next().is_some_and(plain)
        && name.chars().all(|c| plain(c) || matches!(c, '_' | '.' | '-'))
}

/// A title: at most 200 characters.
pub(super) fn title(text: &str) -> bool {
    length(text) <= 200
}

/// A repository: a remote of 1 to 2048 characters and a branch of 1 to 255.
pub(super) fn repo(repo: &Repo) -> bool {
    (1..=2048).contains(&length(&repo.remote)) && (1..=255).contains(&length(&repo.branch))
}

/// A message's text: not empty, at most 256 KiB.
pub(super) fn text(text: &str) -> bool {
    (1..=MAX_INBOX_TEXT).contains(&length(text))
}

/// The holder a write names: `device:<id>` or `vm:<machine>`, never `parked`.
pub(super) fn writer(holder: &Holder) -> bool {
    match holder {
        Holder::Device(id) => device(id),
        Holder::Vm(id) => machine(id),
        Holder::Parked => false,
    }
}
