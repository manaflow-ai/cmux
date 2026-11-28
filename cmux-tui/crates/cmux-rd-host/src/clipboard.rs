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
/// With `link` only, as its one caller (`serve`).
#[cfg(feature = "link")]
pub fn offered(opted_in: bool) -> bool {
    opted_in && available()
}

#[cfg(feature = "link")]
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

impl Counters {
    /// The session log's line for these counts; `None` when nothing was refused.
    pub fn log_line(&self) -> Option<String> {
        (*self != Self::default()).then(|| {
            format!(
                "cmux-rd host: clipboard: {} refused in view, {} writes failed, {} local texts over {MAX_CLIPBOARD_TEXT} bytes",
                self.view_refused, self.write_failed, self.local_too_large
            )
        })
    }
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
#[path = "clipboard_tests.rs"]
mod tests;
