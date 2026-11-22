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
    /// `None` when the answer names no app (neither `app` nor
    /// `app_bundle_path`), so there is nothing reliable to say.
    pub(super) fn from_identify(identify: &Value) -> Option<Self> {
        let text = |key: &str| {
            identify
                .get(key)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        let app = text("app");
        let bundle = text("app_bundle_path");
        if app.is_none() && bundle.is_none() {
            return None;
        }
        // The old app reports `app_bundle_path` and, from 0.66, `"app": "cmux"`.
        let classic = app.as_deref().is_none_or(|name| name == "cmux");
        let version = text("version").map(|version| match text("build") {
            Some(build) => format!("{version} ({build})"),
            None => version,
        });
        Some(Self {
            classic,
            name: app.unwrap_or_else(|| "cmux".to_owned()),
            version,
            socket: text("socket_path"),
            cli_path: text("app_cli_path"),
        })
    }
}

/// The skew message for `method`, or `None` when the app is this CLI's own
/// app (then `method_not_found` is a real unknown method).
pub(super) fn message(method: &str, peer: &Peer, this_exe: Option<&Path>) -> Option<String> {
    if let (Some(cli), Some(exe)) = (&peer.cli_path, this_exe)
        && same_file(Path::new(cli), exe)
    {
        return None;
    }
    let messages = &crate::localization::catalog().app_control;
    let socket = peer.socket.as_deref().unwrap_or("?");
    let template = if peer.classic { messages.skew_classic } else { messages.skew_other };
    let version = peer.version.as_deref().map_or_else(String::new, |version| format!(" {version}"));
    let mut text = template
        .replace("{cli}", env!("CARGO_PKG_VERSION"))
        .replace("{method}", method)
        .replace("{app}", &peer.name)
        .replace("{version}", &version)
        .replace("{socket}", socket);
    if let Some(cli) = &peer.cli_path {
        text.push(' ');
        text.push_str(&messages.skew_use_cli.replace("{path}", cli));
    }
    Some(text)
}

fn same_file(left: &Path, right: &Path) -> bool {
    match (left.canonicalize(), right.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
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
