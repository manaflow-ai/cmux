//! The held message box of a bare launch (Home's provisional Chief composer):
//! the sends made before the Chief's owner answered, the draft handed to the
//! real Chief, and what a quit or a release keeps for the next launch.
//!
//! No I/O, no async, no clock: the app owns the page, its stores and the
//! sends; this crate only decides. `ffi` is its C ABI
//! (`include/cmux_launch_draft.h`, Swift module `CCmuxLaunchDraftFFI`),
//! linked into the app through cmux-app-ffi.
//!
//! - [`LaunchDraft::hold`] keeps a send under its key, in order; the same key
//!   again joins the first and is never kept twice.
//! - [`LaunchDraft::resolve`] names the real Chief once; from then on
//!   [`LaunchDraft::next`] is the send to hand over and
//!   [`LaunchDraft::delivered`] marks it handed over: in order, each key once.
//!   A send made after that waits behind the ones before it.
//! - [`LaunchDraft::cancel`] ends the hold before that and gives the held
//!   sends back (their text: [`text_of`]).
//! - [`append_draft`] puts typed text after the Chief's own draft.
//! - [`Parked`] is what a quit or a release keeps, encoded as one string the
//!   next launch decodes.

use std::collections::HashSet;

pub mod ffi;

/// One part of a held send, in the order the composer had them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Part {
    /// What a text part shows; None for any other part (an attachment, a
    /// link, ...), which has no text here.
    pub text: Option<String>,
    /// The part as the app encoded it, handed back as it came (opaque here).
    pub raw: String,
}

/// One send made before the Chief was named, under its intent's key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldSend {
    pub key: String,
    pub parts: Vec<Part>,
}

/// What [`LaunchDraft::hold`] did with a send.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HoldOutcome {
    /// Kept, after the sends held before it, until it is handed to the Chief
    /// (named or not yet).
    Held,
    /// The key was already held: the sender waits on that send (its parts
    /// stay the first send's).
    Joined,
    /// The key was already handed to this Chief: the same answer again, sent
    /// no second time.
    AlreadyDelivered { chief: String },
    /// The hold was cancelled first: refused.
    Cancelled,
}

/// The held message box of one bare launch.
#[derive(Debug, Default)]
pub struct LaunchDraft {
    /// Not handed over yet, in order: before the Chief is named, and after
    /// it until each is [`delivered`](Self::delivered).
    held: Vec<HeldSend>,
    delivered: HashSet<String>,
    chief: Option<String>,
    cancelled: bool,
}

impl LaunchDraft {
    pub fn new() -> Self {
        Self::default()
    }

    /// The real Chief, once named.
    pub fn chief(&self) -> Option<&str> {
        self.chief.as_deref()
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled
    }

    /// The sends not handed over yet, in order (the one being handed over
    /// first).
    pub fn held(&self) -> &[HeldSend] {
        &self.held
    }

    /// Keeps `parts` under `key` until it is handed to the Chief.
    pub fn hold(&mut self, key: &str, parts: Vec<Part>) -> HoldOutcome {
        if self.delivered.contains(key)
            && let Some(chief) = &self.chief
        {
            return HoldOutcome::AlreadyDelivered { chief: chief.clone() };
        }
        if self.cancelled {
            return HoldOutcome::Cancelled;
        }
        if self.held.iter().any(|send| send.key == key) {
            return HoldOutcome::Joined;
        }
        self.held.push(HeldSend { key: key.to_owned(), parts });
        HoldOutcome::Held
    }

    /// The real Chief is `chief`: the held sends go to it, [`next`](Self::next)
    /// first. Once; false for a later call, or one after
    /// [`cancel`](Self::cancel), which changes nothing.
    pub fn resolve(&mut self, chief: &str) -> bool {
        if self.chief.is_some() || self.cancelled {
            return false;
        }
        self.chief = Some(chief.to_owned());
        true
    }

    /// The send to hand to the Chief now: the first one held, once the Chief
    /// is named. The same until it is [`delivered`](Self::delivered).
    pub fn next(&self) -> Option<&HeldSend> {
        self.chief.as_ref()?;
        self.held.first()
    }

    /// The send under `key` was handed to the Chief: it leaves the hold and a
    /// resend of its key gets [`HoldOutcome::AlreadyDelivered`]. False (and
    /// nothing changes) when no Chief is named or no send is held under `key`.
    pub fn delivered(&mut self, key: &str) -> bool {
        if self.chief.is_none() {
            return false;
        }
        let Some(index) = self.held.iter().position(|send| send.key == key) else {
            return false;
        };
        let send = self.held.remove(index);
        self.delivered.insert(send.key);
        true
    }

    /// Ends the hold before the Chief was named: later sends are refused and
    /// the held ones come back, in order, for the draft. After
    /// [`resolve`](Self::resolve) (the sends are the Chief's already), or a
    /// second time, returns none.
    pub fn cancel(&mut self) -> Vec<HeldSend> {
        if self.chief.is_some() || self.cancelled {
            return Vec::new();
        }
        self.cancelled = true;
        std::mem::take(&mut self.held)
    }

    /// What a quit keeps: the held sends' text, then `typed`. The hold goes
    /// on as it was (a quit can be cancelled).
    pub fn save_for_quit(&self, typed: &str) -> Parked {
        Parked::new(&self.held, typed)
    }

    /// What a release before the Chief answered keeps: the hold is cancelled
    /// and its sends' text, then `typed`, are kept. After a resolve only
    /// `typed` is.
    pub fn park(&mut self, typed: &str) -> Parked {
        let held = self.cancel();
        Parked::new(&held, typed)
    }
}

/// The text of one send: its text parts joined, other parts left out.
fn parts_text(parts: &[Part]) -> String {
    parts.iter().filter_map(|part| part.text.as_deref()).collect()
}

/// The text of `sends` (each one's parts), one send per paragraph, sends with
/// no text left out (what a cancel gives back to the draft).
pub fn text_of<'a>(sends: impl IntoIterator<Item = &'a [Part]>) -> String {
    join_lines(sends.into_iter().map(parts_text))
}

/// Non-empty pieces, a line apart.
fn join_lines(pieces: impl IntoIterator<Item = String>) -> String {
    pieces.into_iter().filter(|piece| !piece.is_empty()).collect::<Vec<_>>().join("\n")
}

/// `typed` after the Chief's draft `own`, on a line of its own (`typed`
/// alone when `own` is empty). None when `typed` is empty: nothing changes.
pub fn append_draft(own: &str, typed: &str) -> Option<String> {
    if typed.is_empty() {
        return None;
    }
    if own.is_empty() {
        return Some(typed.to_owned());
    }
    Some(format!("{own}\n{typed}"))
}

/// What a quit or a release before the Chief answered keeps for the next
/// launch: each held send's text, then what was typed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Parked {
    /// One entry per held send with text, in order.
    pub held: Vec<String>,
    pub typed: String,
}

/// First line of an encoded [`Parked`]; a new layout gets a new version.
const PARKED_MAGIC: &str = "cmux.launch-draft/1\n";

impl Parked {
    fn new(held: &[HeldSend], typed: &str) -> Self {
        let held = held
            .iter()
            .map(|send| parts_text(&send.parts))
            .filter(|text| !text.is_empty())
            .collect();
        Self { held, typed: typed.to_owned() }
    }

    pub fn is_empty(&self) -> bool {
        self.held.is_empty() && self.typed.is_empty()
    }

    /// The draft the next launch starts with: the held text, then the typed
    /// text, a line apart.
    pub fn text(&self) -> String {
        join_lines(self.held.iter().cloned().chain([self.typed.clone()]))
    }

    /// One string for the next launch's [`decode`](Self::decode). Empty when
    /// nothing is kept. Layout after the magic line: each held text as
    /// `h<byte length>:<text>`, then the typed text as `t<byte length>:<text>`.
    pub fn encode(&self) -> String {
        if self.is_empty() {
            return String::new();
        }
        let mut out = String::from(PARKED_MAGIC);
        for text in &self.held {
            out.push_str(&format!("h{}:{text}", text.len()));
        }
        out.push_str(&format!("t{}:{}", self.typed.len(), self.typed));
        out
    }

    /// Reads [`encode`](Self::encode)'s string. Anything else (another
    /// version, a cut or edited string, garbage) is empty, never an error.
    pub fn decode(encoded: &str) -> Self {
        Self::try_decode(encoded).unwrap_or_default()
    }

    fn try_decode(encoded: &str) -> Option<Self> {
        let mut rest = encoded.strip_prefix(PARKED_MAGIC)?;
        let mut held = Vec::new();
        loop {
            let tag = rest.chars().next()?;
            let (len, after) = rest[tag.len_utf8()..].split_once(':')?;
            if len.is_empty() || !len.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let len: usize = len.parse().ok()?;
            let text = after.get(..len)?;
            rest = &after[len..];
            match tag {
                'h' => held.push(text.to_owned()),
                't' if rest.is_empty() => return Some(Self { held, typed: text.to_owned() }),
                _ => return None,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A text part (its raw form is any string the app chose).
    fn text_part(s: &str) -> Part {
        Part { text: Some(s.to_owned()), raw: format!("text:{s}") }
    }

    /// A part with no text, such as an attachment.
    fn other(raw: &str) -> Part {
        Part { text: None, raw: raw.to_owned() }
    }

    fn text(s: &str) -> Vec<Part> {
        vec![text_part(s)]
    }

    fn keys(sends: &[HeldSend]) -> Vec<&str> {
        sends.iter().map(|send| send.key.as_str()).collect()
    }

    /// Hands every send over as the app does: `next`, then `delivered`.
    fn deliver_all(draft: &mut LaunchDraft) -> Vec<HeldSend> {
        let mut sent = Vec::new();
        while let Some(send) = draft.next().cloned() {
            assert!(draft.delivered(&send.key));
            sent.push(send);
        }
        sent
    }

    #[test]
    fn holds_keep_order() {
        let mut draft = LaunchDraft::new();
        assert_eq!(draft.hold("a", text("one")), HoldOutcome::Held);
        assert_eq!(draft.hold("b", text("two")), HoldOutcome::Held);
        assert_eq!(draft.hold("c", text("three")), HoldOutcome::Held);
        assert_eq!(keys(draft.held()), ["a", "b", "c"]);
    }

    #[test]
    fn nothing_is_handed_over_before_the_chief_is_named() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        assert_eq!(draft.next(), None);
        assert!(!draft.delivered("a"));
        assert_eq!(keys(draft.held()), ["a"]);
    }

    #[test]
    fn same_key_joins_the_first_and_is_never_duplicated() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        assert_eq!(draft.hold("a", text("other")), HoldOutcome::Joined);
        assert_eq!(draft.held(), [HeldSend { key: "a".into(), parts: text("one") }]);
        assert!(draft.resolve("chief"));
        assert_eq!(keys(&deliver_all(&mut draft)), ["a"]);
    }

    #[test]
    fn resolve_hands_held_sends_over_in_order_with_their_parts() {
        let mut draft = LaunchDraft::new();
        let parts = vec![text_part("look"), other(r#"{"attachment":"att-1"}"#)];
        draft.hold("a", parts.clone());
        draft.hold("b", text("two"));
        assert!(draft.resolve("chief-1"));
        assert_eq!(
            deliver_all(&mut draft),
            [HeldSend { key: "a".into(), parts }, HeldSend { key: "b".into(), parts: text("two") }]
        );
        assert_eq!(draft.chief(), Some("chief-1"));
        assert!(draft.held().is_empty());
    }

    #[test]
    fn a_send_being_handed_over_is_still_held_and_joined() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        draft.resolve("chief-1");
        assert_eq!(draft.next().map(|send| send.key.as_str()), Some("a"));
        // Not handed over yet: a resend waits on it, and a quit keeps its text.
        assert_eq!(draft.hold("a", text("one")), HoldOutcome::Joined);
        assert_eq!(draft.save_for_quit("").text(), "one");
        assert!(draft.delivered("a"));
        assert!(!draft.delivered("a"));
        assert_eq!(draft.next(), None);
    }

    #[test]
    fn resolve_runs_once() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        assert!(draft.resolve("chief-1"));
        assert!(!draft.resolve("chief-2"));
        assert_eq!(draft.chief(), Some("chief-1"));
        assert_eq!(keys(&deliver_all(&mut draft)), ["a"]);
    }

    #[test]
    fn resend_of_a_delivered_key_answers_its_chief() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        draft.resolve("chief-1");
        deliver_all(&mut draft);
        assert_eq!(
            draft.hold("a", text("one")),
            HoldOutcome::AlreadyDelivered { chief: "chief-1".into() }
        );
        assert_eq!(draft.next(), None);
    }

    #[test]
    fn new_key_after_resolve_waits_behind_the_held_ones_and_goes_once() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        draft.resolve("chief-1");
        assert_eq!(draft.hold("b", text("late")), HoldOutcome::Held);
        assert_eq!(keys(&deliver_all(&mut draft)), ["a", "b"]);
        assert_eq!(
            draft.hold("b", text("late")),
            HoldOutcome::AlreadyDelivered { chief: "chief-1".into() }
        );
        assert!(draft.held().is_empty());
    }

    #[test]
    fn resolve_after_cancel_does_nothing() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        draft.cancel();
        assert!(!draft.resolve("chief-1"));
        assert_eq!(draft.chief(), None);
        assert_eq!(draft.next(), None);
    }

    #[test]
    fn cancel_returns_held_text_one_send_per_paragraph() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", vec![text_part("hel"), text_part("lo")]);
        draft.hold("b", vec![other("att-1")]);
        draft.hold("c", text("world"));
        let held = draft.cancel();
        assert_eq!(keys(&held), ["a", "b", "c"]);
        assert_eq!(text_of(held.iter().map(|send| send.parts.as_slice())), "hello\nworld");
        assert!(draft.is_cancelled());
    }

    #[test]
    fn hold_after_cancel_is_refused() {
        let mut draft = LaunchDraft::new();
        draft.cancel();
        assert_eq!(draft.hold("a", text("one")), HoldOutcome::Cancelled);
        assert!(draft.held().is_empty());
    }

    #[test]
    fn cancel_after_resolve_or_twice_returns_nothing() {
        let mut resolved = LaunchDraft::new();
        resolved.hold("a", text("one"));
        resolved.resolve("chief-1");
        assert!(resolved.cancel().is_empty());
        assert!(!resolved.is_cancelled());
        assert_eq!(keys(&deliver_all(&mut resolved)), ["a"]);
        assert_eq!(
            resolved.hold("a", text("one")),
            HoldOutcome::AlreadyDelivered { chief: "chief-1".into() }
        );

        let mut twice = LaunchDraft::new();
        twice.hold("a", text("one"));
        assert_eq!(twice.cancel().len(), 1);
        assert!(twice.cancel().is_empty());
    }

    #[test]
    fn append_draft_takes_typed_when_own_is_empty_else_a_line_after() {
        assert_eq!(append_draft("", "typed").as_deref(), Some("typed"));
        assert_eq!(append_draft("own", "typed").as_deref(), Some("own\ntyped"));
        assert_eq!(append_draft("own", ""), None);
        assert_eq!(append_draft("", ""), None);
    }

    #[test]
    fn save_for_quit_keeps_held_then_typed_and_the_hold_goes_on() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        draft.hold("b", vec![other("att")]);
        let parked = draft.save_for_quit("typed");
        assert_eq!(parked, Parked { held: vec!["one".into()], typed: "typed".into() });
        assert_eq!(parked.text(), "one\ntyped");
        assert_eq!(draft.held().len(), 2);
        assert!(!draft.is_cancelled());
    }

    #[test]
    fn park_cancels_and_keeps_held_then_typed() {
        let mut draft = LaunchDraft::new();
        draft.hold("a", text("one"));
        assert_eq!(draft.park("typed").text(), "one\ntyped");
        assert!(draft.is_cancelled());

        let mut resolved = LaunchDraft::new();
        resolved.hold("a", text("one"));
        resolved.resolve("chief-1");
        assert_eq!(resolved.park("typed").text(), "typed");
    }

    #[test]
    fn parked_round_trips() {
        let cases = [
            Parked { held: vec!["one".into(), "two\nlines".into()], typed: "typed".into() },
            Parked { held: vec![], typed: "only typed".into() },
            Parked { held: vec!["h1:t3:tricky".into(), "über ✓".into()], typed: String::new() },
        ];
        for parked in cases {
            assert_eq!(Parked::decode(&parked.encode()), parked);
        }
        assert_eq!(Parked::default().encode(), "");
    }

    #[test]
    fn parked_decode_of_anything_bad_is_empty() {
        let good = Parked { held: vec!["one".into()], typed: "typed".into() }.encode();
        let bad = [
            String::new(),
            "plain draft text".to_owned(),
            "cmux.launch-draft/2\nt1:a".to_owned(),
            good.replace("h3:", "h9:"),
            good.replace("h3:", "h-3:"),
            good.replace("h3:", "h:"),
            good.replace("h3:", "x3:"),
            format!("{good}t0:"),
            good[..good.len() - 1].to_owned(),
            format!("{PARKED_MAGIC}h99999999999999999999999:x"),
            format!("{PARKED_MAGIC}h1:\u{e9}t0:"),
            format!("{PARKED_MAGIC}\u{e9}1:xt0:"),
            PARKED_MAGIC.to_owned(),
        ];
        for encoded in bad {
            assert_eq!(Parked::decode(&encoded), Parked::default(), "{encoded:?}");
        }
    }
}
