//! `notify --desktop false` or `--reply` against a daemon without
//! `notification-desktop-v1` or `notification-reply-v1`: an older daemon
//! refuses an unknown field, so the CLI drops it and the notification posts
//! as the flag did before (a banner, with no reply).

use std::io::BufReader;
use std::path::Path;

use serde_json::Value;

use cmux_tui_core::platform::transport;
use cmux_tui_core::{NOTIFICATION_DESKTOP_CAPABILITY, NOTIFICATION_REPLY_CAPABILITY};

/// Removes `desktop` and `reply` from a `notification.create` request the
/// daemon cannot take; true when the request changed.
pub(super) fn drop_unsupported(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
) -> bool {
    if request["operation"] != "notification.create" {
        return false;
    }
    let mut changed = false;
    for (field, capability) in
        [("desktop", NOTIFICATION_DESKTOP_CAPABILITY), ("reply", NOTIFICATION_REPLY_CAPABILITY)]
    {
        if request["params"].get(field).is_none()
            || super::super::launch_credential::advertises(reader, socket, capability)
        {
            continue;
        }
        changed |= request
            .get_mut("params")
            .and_then(Value::as_object_mut)
            .is_some_and(|params| params.remove(field).is_some());
    }
    changed
}
