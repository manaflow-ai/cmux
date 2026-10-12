//! `notify --desktop false` against a daemon without `notification-desktop-v1`:
//! an older daemon refuses the unknown `desktop` field, so the CLI drops it and
//! the notification posts with a banner, as `--desktop` did before.

use std::io::BufReader;

use serde_json::Value;

use cmux_tui_core::NOTIFICATION_DESKTOP_CAPABILITY;
use cmux_tui_core::platform::transport;

/// Removes `desktop` from a `notification.create` request the daemon cannot
/// take; true when the request changed.
pub(super) fn drop_unsupported(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    request: &mut Value,
) -> bool {
    if request["operation"] != "notification.create" || request["params"].get("desktop").is_none() {
        return false;
    }
    if super::super::launch_credential::advertises(reader, NOTIFICATION_DESKTOP_CAPABILITY) {
        return false;
    }
    request["params"].as_object_mut().is_some_and(|params| params.remove("desktop").is_some())
}
