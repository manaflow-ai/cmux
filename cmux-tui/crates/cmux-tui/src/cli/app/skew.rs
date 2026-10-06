//! Version skew between this CLI and the app behind its socket.
//!
//! A `cmux` CLI can reach an app that does not speak its methods: the old
//! cmux app at the same socket path, or an older cmux-next. The app then
//! answers `method_not_found`, which by itself reads like a typo. When that
//! happens this asks the app who it is (`system.identify`, which both apps
//! answer with `app_bundle_path` / `app_cli_path`) and rewrites the error to
//! name both sides and the CLI that matches the app.

use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};

/// Who answered: the app's name, version, socket and bundled CLI, as
/// `system.identify` reports them.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Peer {
    pub classic: bool,
    pub name: String,
    pub version: Option<String>,
    pub socket: Option<String>,
    pub cli_path: Option<String>,
}

impl Peer {
    pub(super) fn from_identify(_identify: &Value) -> Option<Self> {
        None
    }
}

/// The skew message for `method`, or `None` when the app is this CLI's own
/// app (then `method_not_found` is a real unknown method).
pub(super) fn message(_method: &str, _peer: &Peer, _this_exe: Option<&Path>) -> Option<String> {
    None
}

/// Rewrites a `method_not_found` answer into the skew message, after one
/// `system.identify` on the same connection. Leaves `error` alone when the
/// app does not identify itself or is this CLI's own app.
pub(super) fn annotate(stream: &mut UnixStream, method: &str, error: &mut Value) {
    let Ok(Ok(identify)) = super::exchange(stream, "system.identify", json!({}), IDENTIFY_TIMEOUT)
    else {
        return;
    };
    let Some(peer) = Peer::from_identify(&identify) else { return };
    let exe = std::env::current_exe().ok();
    if let Some(text) = message(method, &peer, exe.as_deref())
        && let Some(object) = error.as_object_mut()
    {
        object.insert("message".into(), Value::String(text));
        object.insert("code".into(), Value::String("app.version_skew".into()));
    }
}

const IDENTIFY_TIMEOUT: Duration = Duration::from_secs(2);

#[cfg(test)]
mod tests;
