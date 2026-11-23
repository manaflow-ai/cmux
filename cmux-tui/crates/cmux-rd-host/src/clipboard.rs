//! The host's half of clipboard text sync (cap `clipboard.text`, cmux-rd-proto `clipboard`).
//!
//! Only a control session touches the shared machine's clipboard: a viewer's `clipboard`
//! in a view session is refused and counted, and the host reads its own clipboard only
//! while the viewer holds control. The host notices a change by the pasteboard's change
//! count, read at [`POLL_INTERVAL_US`] (4 Hz) and only inside the session loop, so the
//! reading stops with the session. A text the viewer just set is not sent back: the change
//! count after the write is taken as seen, and `ClipboardSync` skips a text both sides
//! already have.
//!
//! macOS: NSPasteboard (mac/pasteboard.rs). X11 has no change count: a clipboard there is
//! a selection the owner serves on request (ICCCM), so it needs an owner window and an
//! XFixes selection watch; not done yet, and an X11 host does not offer the cap. Windows
//! has no `serve` session yet (windows_host.rs), so it offers nothing either.

// Off macOS no real pasteboard constructs a channel; the tests' fake one does.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use cmux_rd_proto::clipboard::{ClipboardPart, ClipboardSync, Offer, MAX_CLIPBOARD_TEXT};
use cmux_rd_proto::control::Control;

/// How often a control session reads the pasteboard's change count (4 Hz).
pub const POLL_INTERVAL_US: u64 = 250_000;

/// What a pasteboard read found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TextRead {
    /// No text on the pasteboard (an image, a file, nothing).
    None,
    Text(String),
    /// Text over the bound, of this many UTF-8 bytes; not copied.
    TooLarge(usize),
}

/// The shared machine's clipboard (a fake one in tests).
pub trait Pasteboard {
    /// Grows on every change of the clipboard, by any app.
    fn change_count(&mut self) -> i64;
    /// The clipboard's text, refused unread when over `max` UTF-8 bytes.
    fn read_text(&mut self, max: usize) -> TextRead;
    /// Replaces the clipboard with `text`.
    fn write_text(&mut self, text: &str) -> Result<(), String>;
}

/// Whether this host offers `clipboard.text`: only when the person sharing turned clipboard
/// sync on for this session (`serve`'s setup `"clipboard": true`; `host` never offers it), and
/// only where the host has a clipboard it can watch (macOS). Off by default: a new way for
/// the shared machine's clipboard to leave it is opt-in until a person decides otherwise.
pub fn offered(opted_in: bool) -> bool {
    opted_in && available()
}

fn available() -> bool {
    #[cfg(target_os = "macos")]
    {
        crate::mac::pasteboard::available()
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// The session's clipboard channel when the viewer and this host both listed the cap.
pub fn open(negotiated_caps: &[String], now_us: u64) -> Option<ClipboardChannel> {
    if !negotiated_caps.iter().any(|c| c == cmux_rd_core::service::caps::CLIPBOARD_TEXT) {
        return None;
    }
    #[cfg(target_os = "macos")]
    {
        let board = crate::mac::pasteboard::MacPasteboard::open()?;
        Some(ClipboardChannel::new(Box::new(board), now_us))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = now_us;
        None
    }
}

/// What became of one received `clipboard` message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Received {
    /// The text `seq` is on the shared machine's clipboard now.
    Applied(u64),
    /// A part of a longer text; more follow.
    Partial,
    /// Refused (`view`: not a control session; `part`: malformed, out of order or over the
    /// bound; `write`: the pasteboard refused it). Counted.
    Refused(&'static str),
}

/// Refused messages and texts, for the session's log.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Counters {
    pub view_refused: u64,
    pub write_failed: u64,
    pub local_too_large: u64,
}

pub struct ClipboardChannel {
    board: Box<dyn Pasteboard>,
    sync: ClipboardSync,
    /// The change count already handled (sent, set by the viewer, or passed outside control).
    seen_change: i64,
    next_poll_us: u64,
    counters: Counters,
}

impl ClipboardChannel {
    /// A channel that sends only changes after `now_us`, not what the clipboard holds at the
    /// session's start.
    pub fn new(mut board: Box<dyn Pasteboard>, now_us: u64) -> Self {
        let seen_change = board.change_count();
        Self {
            board,
            sync: ClipboardSync::new(),
            seen_change,
            next_poll_us: now_us.saturating_add(POLL_INTERVAL_US),
            counters: Counters::default(),
        }
    }

    /// Takes the viewer's `clipboard` message; `may_control`: the session holds control now.
    pub fn on_part(&mut self, part: ClipboardPart, may_control: bool) -> Received {
        if !may_control {
            self.counters.view_refused += 1;
            return Received::Refused("view");
        }
        match self.sync.receive(part) {
            Ok(Some((seq, text))) => match self.board.write_text(&text) {
                Ok(()) => {
                    // Our own write is not a change to send back.
                    self.seen_change = self.board.change_count();
                    Received::Applied(seq)
                }
                Err(e) => {
                    self.counters.write_failed += 1;
                    eprintln!("cmux-rd host: clipboard write failed: {e}");
                    Received::Refused("write")
                }
            },
            Ok(None) => Received::Partial,
            Err(e) => {
                eprintln!("cmux-rd host: clipboard part dropped: {e:?}");
                Received::Refused("part")
            }
        }
    }

    /// Reads the change count when due and returns the next `clipboard` part to send. Outside
    /// control nothing is read or sent, and a change made meanwhile is never sent later.
    pub fn poll(&mut self, now_us: u64, may_control: bool) -> Option<Control> {
        if now_us >= self.next_poll_us {
            self.next_poll_us = now_us.saturating_add(POLL_INTERVAL_US);
            let count = self.board.change_count();
            if count != self.seen_change {
                self.seen_change = count;
                if may_control {
                    self.offer_current();
                }
            }
        }
        if !may_control {
            self.sync.cancel_outgoing();
            return None;
        }
        self.sync.next_part(now_us).map(Control::from)
    }

    fn offer_current(&mut self) {
        match self.board.read_text(MAX_CLIPBOARD_TEXT) {
            TextRead::Text(text) => {
                if self.sync.offer(&text) == Offer::TooLarge {
                    self.counters.local_too_large += 1;
                }
            }
            TextRead::TooLarge(len) => {
                self.counters.local_too_large += 1;
                eprintln!(
                    "cmux-rd host: clipboard text of {len} bytes not sent (over {MAX_CLIPBOARD_TEXT})"
                );
            }
            TextRead::None => {}
        }
    }

    /// When [`Self::poll`] has work next; `None` outside control.
    pub fn next_deadline_us(&self, may_control: bool) -> Option<u64> {
        let send = self.sync.next_deadline_us().unwrap_or(u64::MAX);
        may_control.then_some(self.next_poll_us.min(send))
    }

    pub fn counters(&self) -> Counters {
        self.counters
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    /// A pasteboard in memory: the test changes it as another app would.
    #[derive(Default)]
    struct Fake {
        count: i64,
        text: Option<String>,
        reads: usize,
        writes: Vec<String>,
    }

    #[derive(Clone, Default)]
    struct Shared(Rc<RefCell<Fake>>);

    impl Shared {
        fn copy(&self, text: &str) {
            let mut f = self.0.borrow_mut();
            f.count += 1;
            f.text = Some(text.to_owned());
        }
    }

    impl Pasteboard for Shared {
        fn change_count(&mut self) -> i64 {
            self.0.borrow().count
        }
        fn read_text(&mut self, max: usize) -> TextRead {
            let mut f = self.0.borrow_mut();
            f.reads += 1;
            match &f.text {
                None => TextRead::None,
                Some(t) if t.len() > max => TextRead::TooLarge(t.len()),
                Some(t) => TextRead::Text(t.clone()),
            }
        }
        fn write_text(&mut self, text: &str) -> Result<(), String> {
            let mut f = self.0.borrow_mut();
            f.count += 1;
            f.text = Some(text.to_owned());
            f.writes.push(text.to_owned());
            Ok(())
        }
    }

    fn part(seq: u64, text: &str) -> ClipboardPart {
        ClipboardPart { seq, text: text.into(), offset: None, total: None }
    }

    fn sent_text(c: Option<Control>) -> Option<String> {
        c.and_then(Control::into_clipboard_part).map(|p| p.text)
    }

    #[test]
    fn the_cap_is_never_offered_unless_the_person_sharing_turned_it_on() {
        assert!(!offered(false));
        // Off macOS there is no clipboard to watch, opt-in or not.
        if !cfg!(target_os = "macos") {
            assert!(!offered(true));
        }
    }

    #[test]
    fn a_view_session_never_applies_the_viewers_clipboard() {
        let board = Shared::default();
        let mut ch = ClipboardChannel::new(Box::new(board.clone()), 0);
        assert_eq!(ch.on_part(part(1, "secret"), false), Received::Refused("view"));
        assert!(board.0.borrow().writes.is_empty());
        assert_eq!(ch.counters().view_refused, 1);
        assert_eq!(ch.on_part(part(2, "ok"), true), Received::Applied(2));
        assert_eq!(board.0.borrow().writes, vec!["ok".to_owned()]);
    }

    #[test]
    fn a_view_session_never_reads_or_sends_the_hosts_clipboard() {
        let board = Shared::default();
        let mut ch = ClipboardChannel::new(Box::new(board.clone()), 0);
        board.copy("host secret");
        for t in 0..10 {
            assert!(ch.poll(t * POLL_INTERVAL_US, false).is_none());
        }
        assert_eq!(board.0.borrow().reads, 0);
        assert_eq!(ch.next_deadline_us(false), None);
        // Control comes back: the change made in view is not sent later.
        assert!(ch.poll(11 * POLL_INTERVAL_US, true).is_none());
        assert_eq!(board.0.borrow().reads, 0);
    }

    #[test]
    fn a_host_change_goes_out_once_at_the_poll_rate() {
        let board = Shared::default();
        board.copy("before the session");
        let mut ch = ClipboardChannel::new(Box::new(board.clone()), 0);
        // What the clipboard held at the start is not sent.
        assert!(ch.poll(POLL_INTERVAL_US, true).is_none());
        board.copy("copied on the host");
        // Not before the next poll.
        assert!(ch.poll(POLL_INTERVAL_US + 1, true).is_none());
        assert_eq!(ch.next_deadline_us(true), Some(2 * POLL_INTERVAL_US));
        assert_eq!(
            sent_text(ch.poll(2 * POLL_INTERVAL_US, true)).as_deref(),
            Some("copied on the host")
        );
        assert!(ch.poll(3 * POLL_INTERVAL_US, true).is_none());
        assert_eq!(board.0.borrow().reads, 1);
    }

    #[test]
    fn the_viewers_text_is_not_echoed_back() {
        let board = Shared::default();
        let mut ch = ClipboardChannel::new(Box::new(board.clone()), 0);
        assert_eq!(ch.on_part(part(1, "from viewer"), true), Received::Applied(1));
        for t in 1..5 {
            assert!(ch.poll(t * POLL_INTERVAL_US, true).is_none());
        }
        // Another app copies the same text again (a new change count): still not sent,
        // the viewer has it.
        board.copy("from viewer");
        assert!(ch.poll(6 * POLL_INTERVAL_US, true).is_none());
        // A different text is.
        board.copy("new on host");
        assert_eq!(sent_text(ch.poll(7 * POLL_INTERVAL_US, true)).as_deref(), Some("new on host"));
    }

    #[test]
    fn a_host_text_over_the_bound_is_counted_not_sent() {
        let board = Shared::default();
        let mut ch = ClipboardChannel::new(Box::new(board.clone()), 0);
        board.copy(&"x".repeat(MAX_CLIPBOARD_TEXT + 1));
        assert!(ch.poll(POLL_INTERVAL_US, true).is_none());
        assert_eq!(ch.counters().local_too_large, 1);
    }
}
