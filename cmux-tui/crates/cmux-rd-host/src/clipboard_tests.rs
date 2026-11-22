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

#[cfg(feature = "link")]
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
fn the_session_log_names_refusals_and_says_nothing_without_them() {
    let board = Shared::default();
    let mut ch = ClipboardChannel::new(Box::new(board), 0);
    assert_eq!(ch.counters().log_line(), None);
    ch.on_part(part(1, "secret"), false);
    let line = ch.counters().log_line().expect("a refusal is logged");
    assert!(line.contains("1 refused in view"), "{line}");
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
