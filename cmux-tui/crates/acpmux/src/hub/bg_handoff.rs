//! Part of `Hub`; see `hub/mod.rs`. A background task whose command handed its work to something
//! that tells the chat itself (`glaeda-gh land` queues a land, and the land queue's notice says
//! when it merged or stopped) has no news in its end. Its exit-0 end into an idle chat starts no
//! turn: the command says so with a last output line that starts with [`HANDED_OFF`], and the end
//! counts as sent (`bg_output` still reads it). A failed end, and one into a running turn, go as
//! before (`bg_notify.rs`).
//!
//! One lane VM's 24 h of transcripts (2026-11-28): 122 of 1,374 task-end wakes were a land
//! request's end ("requested; the daemon takes it next tick"), each a turn with nothing to do
//! before the land queue's own notice came. Leo: "not getting swamped by our own wake-ups, our
//! own tool calls".

use crate::bg_run;
use std::path::Path;

/// The start of the last output line by which a command says another notice brings its outcome.
pub const HANDED_OFF: &str = "acpmux: handed off:";

/// How much of the output's end is read for the last line.
const TAIL: u64 = 4096;

/// Whether `output`'s last non-empty line starts with [`HANDED_OFF`].
pub(super) fn handed_off(output: &str) -> bool {
    output
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .is_some_and(|line| line.starts_with(HANDED_OFF))
}

/// Whether task `id`'s end in `dir` is dropped rather than sent: it went well (`ok`), its chat is
/// `idle`, and its output ends with [`HANDED_OFF`].
pub(super) fn drops_end(dir: &Path, id: &str, ok: bool, idle: bool) -> bool {
    ok && idle && {
        let read = bg_run::read_output(dir, id, None, TAIL).unwrap_or_default();
        handed_off(&String::from_utf8_lossy(&read.data))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_last_handed_off_line_hands_off() {
        assert!(handed_off("o/r#1 requested\nacpmux: handed off: the land queue tells you\n\n"));
        assert!(!handed_off("acpmux: handed off: x\nthen it failed"));
        assert!(!handed_off("o/r#1 requested; the daemon takes it next tick"));
        assert!(!handed_off(""));
    }

    #[test]
    fn a_handed_off_end_into_an_idle_chat_is_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let mut out = bg_run::Spool::create(dir.path(), "t1", 0).unwrap();
        out.write(b"o/r#1 requested\nacpmux: handed off: the land queue tells you\n").unwrap();
        assert!(drops_end(dir.path(), "t1", true, true));
        assert!(!drops_end(dir.path(), "t1", false, true), "a failure is news");
        assert!(!drops_end(dir.path(), "t1", true, false), "a running turn takes it");
        let mut plain = bg_run::Spool::create(dir.path(), "t2", 0).unwrap();
        plain.write(b"done\n").unwrap();
        assert!(!drops_end(dir.path(), "t2", true, true));
    }
}
