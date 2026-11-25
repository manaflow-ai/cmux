//! The cursor shapes a host has sent a viewer that draws the Mac's cursor image: each new shape
//! once, on the ordered channel, before the telepointers that name it.

use crate::quality::Rect;
use crate::wire::ScreenHostMessage;

/// How many shape ids a host remembers. The viewer keeps more, so every shape the host remembers
/// is still one the viewer has.
pub const SENT_CAPACITY: usize = 64;

/// The shape ids a host remembers sending, newest last: a shape that left it is sent again.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SentCursorShapes {
    ids: Vec<String>,
}

impl SentCursorShapes {
    pub fn ids(&self) -> &[String] {
        &self.ids
    }

    pub fn contains(&self, id: &str) -> bool {
        self.ids.iter().any(|i| i == id)
    }

    /// Records `id`; true when the viewer needs it sent first.
    pub fn needs_send(&mut self, id: &str) -> bool {
        if let Some(index) = self.ids.iter().position(|i| i == id) {
            let id = self.ids.remove(index);
            self.ids.push(id);
            return false;
        }
        self.ids.push(id.to_owned());
        if self.ids.len() > SENT_CAPACITY {
            self.ids.drain(..self.ids.len() - SENT_CAPACITY);
        }
        true
    }

    pub fn reset(&mut self) {
        self.ids.clear();
    }
}

/// The ordered cursor messages and the last shape the link accepted. Sampling and delivery are
/// separate: an unchanged shape produces no new image. One encoded replacement waits for the next
/// sampling tick when the link refuses it.
///
/// A tick: `prepare` with the shape read now (its id and its JSON object), send the text it
/// returns (if any), then `finish` with whether the link took it; `finish` gives the shape's id.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CursorShapeDelivery {
    sent: SentCursorShapes,
    shape: Option<String>,
    display: Option<Rect>,
    pending: Option<(String, String)>,
}

impl CursorShapeDelivery {
    pub fn new() -> Self {
        Self::default()
    }

    /// Takes this tick's read (`None`: no shape known) on `display`; the message text to send now,
    /// if any.
    pub fn prepare(
        &mut self,
        read: Option<(&str, &serde_json::Value)>,
        display: Rect,
    ) -> Option<&str> {
        if self.display != Some(display) {
            // Sizes are fractions of the display: another display's shapes are new ones.
            self.display = Some(display);
            self.sent.reset();
            self.shape = None;
            self.pending = None;
        }
        if let Some((id, cursor)) = read {
            if self.sent.contains(id) {
                self.sent.needs_send(id);
                self.pending = None;
                self.shape = Some(id.to_owned());
            } else {
                // A fresh shape supersedes an unsent one.
                let text = ScreenHostMessage::cursor_shape(cursor.clone()).encode();
                self.pending = Some((id.to_owned(), text));
            }
        }
        self.pending.as_ref().map(|(_, text)| text.as_str())
    }

    /// Whether the link took the text `prepare` returned; the shape's id now. A refused send
    /// neither forgets the payload nor records it as delivered.
    pub fn finish(&mut self, delivered: bool) -> Option<&str> {
        if delivered && let Some((id, _)) = self.pending.take() {
            self.sent.needs_send(&id);
            self.shape = Some(id);
        }
        self.shape.as_deref()
    }

    /// One tick with a synchronous send, as the Swift `current(read:display:sendText:)`.
    pub fn current(
        &mut self,
        read: Option<(&str, &serde_json::Value)>,
        display: Rect,
        send_text: impl FnOnce(&str) -> bool,
    ) -> Option<String> {
        let delivered = self.prepare(read, display).is_some_and(send_text);
        self.finish(delivered).map(str::to_owned)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const D: Rect = Rect { x: 0.0, y: 0.0, w: 100.0, h: 100.0 };

    #[test]
    fn sent_shapes_keep_the_newest_sixty_four() {
        let mut s = SentCursorShapes::default();
        assert!(s.needs_send("a"));
        assert!(!s.needs_send("a"));
        for i in 0..64 {
            s.needs_send(&i.to_string());
        }
        assert!(!s.contains("a"));
        assert_eq!(s.ids().len(), 64);
        assert!(!s.needs_send("0"));
        assert_eq!(s.ids().last().map(String::as_str), Some("0"));
    }

    #[test]
    fn a_shape_is_sent_once_and_retried_when_refused() {
        let mut d = CursorShapeDelivery::new();
        let arrow = json!({"id": "arrow", "png": "AA==", "w": 0.1, "h": 0.1});
        let mut sent = Vec::new();
        assert_eq!(d.current(Some(("arrow", &arrow)), D, |_| false), None);
        assert_eq!(
            d.current(None, D, |t| {
                sent.push(t.to_owned());
                true
            }),
            Some("arrow".into())
        );
        assert_eq!(sent.len(), 1);
        assert!(sent[0].starts_with(r#"{"t":"cursor","cursor":"#));
        assert_eq!(
            d.current(Some(("arrow", &arrow)), D, |_| panic!("no resend")),
            Some("arrow".into())
        );
    }

    #[test]
    fn another_display_forgets_the_shapes() {
        let mut d = CursorShapeDelivery::new();
        let arrow = json!({"id": "arrow"});
        assert_eq!(d.current(Some(("arrow", &arrow)), D, |_| true), Some("arrow".into()));
        let other = Rect { x: 100.0, ..D };
        assert_eq!(d.current(None, other, |_| true), None);
        let mut resent = false;
        d.current(Some(("arrow", &arrow)), other, |_| {
            resent = true;
            true
        });
        assert!(resent);
    }
}
