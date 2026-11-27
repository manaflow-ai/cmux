//! The device hub's side of Mac Screen (docs/device-hub/PROTOCOL.md), moved out of the app's
//! Swift (`MacScreenHub*.swift`): why a session ended or a request was refused, what each
//! approval button and access level means, this Mac's default sharing, the host's ticket
//! admission (consent order, one viewer at a time, Stop Sharing, Revoke) and a viewer tab's
//! progress with the hub (request, approval, ticket, pushes, failure grace). Pure: timers,
//! hub calls and the stream are effects the app runs; text the person reads comes back as a
//! localization key plus its English.

pub mod access;
pub mod host;
pub mod ops;
pub mod reason;
pub mod sharing;
pub mod viewer;

use serde::Serialize;

/// Text the person reads: the app's localization key and its English. When `names` is set,
/// the text's `%@` takes a device's name (the host's, or the viewer's on the indicator).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Message {
    pub key: &'static str,
    pub text: &'static str,
    pub names: bool,
}

impl Message {
    pub(crate) const fn plain(key: &'static str, text: &'static str) -> Self {
        Message { key, text, names: false }
    }

    pub(crate) const fn named(key: &'static str, text: &'static str) -> Self {
        Message { key, text, names: true }
    }

    /// The English with `name` in place of `%@` (what Swift's `String(format:)` gives).
    pub fn english(&self, name: &str) -> String {
        if self.names { self.text.replacen("%@", name, 1) } else { self.text.to_owned() }
    }
}
