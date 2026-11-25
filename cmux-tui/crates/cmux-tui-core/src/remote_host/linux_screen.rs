//! A joined Linux machine's screen identity (Leo, 2026-11-16: "if you have indeed connected a
//! machine, you should be able to just screen share onto it freely").
//!
//! On Linux there is no cmux Remote worker to report a screen UUID; the screen host is
//! `cmux-rd linux-host`, which the acpmux daemon sets up at the join (acpmux
//! `share_host/linux.rs`) and which registers on the device hub as this machine's device. Its
//! device id is in its own private folder (`$XDG_CONFIG_HOME/cmux/screen-host/device.json`,
//! cmux-hub-host `identity::config_dir`), and it is signed in when `account.json` sits beside it.
//!
//! The daemon reports that id as `identify.screen_device_id` and sends `screen-device-changed`
//! when it appears, changes or goes, so the Mac app's sidebar offers View screen on the machine's
//! header (`SidebarScreenActions`: only when the hub lists the id as a screen this Mac views).
//! One read of two small files every [`CHECK_EVERY`]; nothing runs on the identify path.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use super::{Inner, lock, validated_screen_device_id};

/// How often the daemon reads the host's device again: a join or a sign-out while the daemon
/// runs shows within this long.
pub(super) const CHECK_EVERY: Duration = Duration::from_secs(60);

/// The screen host's folder: `$XDG_CONFIG_HOME/cmux/screen-host`, else
/// `~/.config/cmux/screen-host` (cmux-hub-host's `identity::config_dir`, rule for rule: an empty variable counts as unset).
pub(super) fn host_dir(xdg_config_home: Option<PathBuf>, home: Option<PathBuf>) -> Option<PathBuf> {
    let set = |p: &PathBuf| !p.as_os_str().is_empty();
    let base =
        xdg_config_home.filter(set).or_else(|| home.filter(set).map(|h| h.join(".config")))?;
    Some(base.join("cmux").join("screen-host"))
}

/// The signed-in host's device id in `dir`, lowercased and hyphenated; None when the host never
/// signed in, signed out, or its record is not a device this daemon can name.
pub(super) fn device_id_in(dir: &Path) -> Option<String> {
    if !dir.join("account.json").is_file() {
        return None;
    }
    let bytes = std::fs::read(dir.join("device.json")).ok()?;
    let device: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    device.get("id").and_then(serde_json::Value::as_str).and_then(validated_screen_device_id)
}

fn current() -> Option<String> {
    let dir = host_dir(
        std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from),
        std::env::var_os("HOME").map(PathBuf::from),
    )?;
    device_id_in(&dir)
}

/// Reads the host's device now (so the first `identify` already names it), then again every
/// [`CHECK_EVERY`] while the daemon lives, sending `screen-device-changed` on a change.
pub(super) fn watch(inner: &Arc<Inner>) {
    Inner::set_screen_device_id(inner, current());
    let weak = Arc::downgrade(inner);
    let _ = std::thread::Builder::new().name("linux-screen-device".into()).spawn(move || {
        loop {
            std::thread::sleep(CHECK_EVERY);
            let Some(inner) = weak.upgrade() else { return };
            // The daemon's mux is gone: nobody reads the identity any more.
            if lock(&inner.owner).upgrade().is_none() {
                return;
            }
            if Inner::set_screen_device_id(&inner, current()) {
                Inner::emit_screen_device_id(&inner);
            }
        }
    });
}
