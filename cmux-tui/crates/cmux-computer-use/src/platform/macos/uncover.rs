//! A window hidden under other windows of its own app, read or typed into
//! in the background.
//!
//! Chromium (Edge, Chrome, apps that embed it) neither paints a window that
//! other windows cover nor builds its page's accessibility tree, so a covered
//! tab read back as an empty tree and a blank screenshot. And keys posted to
//! an app in the background go to its key window, so a window under another
//! one of the same app was refused keys. Raising the window inside its own
//! app (AXRaise on that window, the app not activated) fixes both: the front
//! app stays the person's (checked on macOS 26.6 with Edge in the
//! background: the page painted and its tree filled within about 1.5 s,
//! the frontmost app unchanged). The app's windows that were in front of it
//! are raised back, back to front, when the guard drops, so the app's window
//! order (and its main window) is what it was.
//!
//! Not covered: a window hidden by another app's window (raising it inside
//! its app does not put it over the other app's), and the app the person is
//! using (its windows are what they look at, so they are not reordered).

use std::time::Duration;

use super::Target;
use super::ax::Ax;
use super::cgwindows::{self, CgWindow};
use super::sys::Cf;

/// How long the target stays raised after keys were posted to it, so the
/// app takes them before its key window changes back.
const KEY_LINGER: Duration = Duration::from_millis(250);

/// Why a window is raised inside its app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Why {
    /// To be painted and read: only when a window of its app covers it.
    Covered,
    /// To take keys posted in the background: only when it is not the
    /// app's key window.
    Keys,
}

/// The app windows of `target`'s process in front of it in `stack` (the
/// window server's on-screen list, front to back), front to back, and
/// whether any of them overlaps it. None when `target` is not in `stack`.
pub(super) fn in_front(stack: &[CgWindow], target: u32) -> Option<(Vec<u32>, bool)> {
    let pos = stack.iter().position(|w| w.id == target)?;
    let t = &stack[pos];
    let front: Vec<&CgWindow> =
        stack[..pos].iter().filter(|w| w.pid == t.pid && w.is_app_window()).collect();
    let covered = front.iter().any(|w| w.frame.intersects(&t.frame));
    Some((front.iter().map(|w| w.id).collect(), covered))
}

/// The order the windows that were in front (front to back) are raised in
/// to put them back: back to front, so the front one ends in front.
pub(super) fn restore_order(front: &[u32]) -> Vec<u32> {
    front.iter().rev().copied().collect()
}

/// A window raised inside its app; dropping it puts the app's window order
/// back.
pub(super) struct Uncovered {
    restore: Vec<Ax>,
    main: Option<Ax>,
    linger: Duration,
}

impl Drop for Uncovered {
    fn drop(&mut self) {
        if !self.linger.is_zero() {
            std::thread::sleep(self.linger);
        }
        for w in &self.restore {
            let _ = w.perform("AXRaise");
        }
        if let (Some(main), Some(yes)) = (&self.main, Cf::boolean(true)) {
            if main.try_bool("AXMain").ok().flatten() != Some(true) {
                let _ = main.set("AXMain", &yes);
            }
        }
    }
}

/// Raises `win` (of `t`) inside its app, the app not activated, when `why`
/// needs it; None when it does not, or when it cannot be done without
/// moving what the person looks at (the target's app is the active one,
/// or which app is active is unknown).
pub(super) fn uncover(t: &Target, win: &Ax, why: Why) -> Option<Uncovered> {
    let pid = t.window.pid;
    if super::active_pid().is_none_or(|p| p == pid) {
        return None;
    }
    let (front, covered) = in_front(&cgwindows::on_screen(), t.window.id)?;
    let app = Ax::application(pid)?;
    match why {
        Why::Covered if !covered => return None,
        Why::Keys
            if app.try_element("AXFocusedWindow").ok().flatten().is_some_and(|f| f.same(win)) =>
        {
            return None;
        }
        _ => {}
    }
    let windows = app.windows();
    let restore: Vec<Ax> = restore_order(&front)
        .into_iter()
        .filter_map(|id| windows.iter().find(|w| w.window_id() == Some(id)).cloned())
        .collect();
    let main = app.try_element("AXMainWindow").ok().flatten().filter(|m| !m.same(win));
    win.perform("AXRaise").ok()?;
    let linger = if why == Why::Keys { KEY_LINGER } else { Duration::ZERO };
    Some(Uncovered { restore, main, linger })
}

#[cfg(test)]
#[path = "uncover_tests.rs"]
mod tests;
