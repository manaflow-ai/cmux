//! `WindowTargeting`: which shell window a window command acts on, and the next one in the cycle.

use super::run;
use crate::ops::OpResult;
use serde::Deserialize;
use serde_json::Value;

/// The windows a command chooses from (opaque ids).
#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowTargeting {
    #[serde(default)]
    pub key_window: Option<u64>,
    /// `NSApp.orderedWindows`, front to back.
    #[serde(default)]
    pub ordered: Vec<u64>,
    /// The shell windows, in creation order.
    #[serde(default)]
    pub shells: Vec<u64>,
}

impl WindowTargeting {
    /// `WindowTargeting.target`: the key window when it is a shell, else the frontmost shell
    /// (shells not on screen after the shown ones).
    pub fn target(&self) -> Option<u64> {
        if let Some(key) = self.key_window.filter(|k| self.shells.contains(k)) {
            return Some(key);
        }
        let shown: Vec<u64> =
            self.ordered.iter().copied().filter(|w| self.shells.contains(w)).collect();
        shown.first().copied().or_else(|| self.shells.iter().copied().find(|w| !shown.contains(w)))
    }

    /// `WindowTargeting.cycled(_:)`: the shell `offset` places from the target, wrapping; none
    /// under two shells.
    pub fn cycled(&self, offset: i64) -> Option<u64> {
        let n = self.shells.len() as i64;
        if n < 2 {
            return None;
        }
        let current =
            self.target().and_then(|t| self.shells.iter().position(|w| *w == t)).unwrap_or(0)
                as i64;
        Some(self.shells[((current + offset) % n + n).rem_euclid(n) as usize])
    }
}

/// `window.target` [`WindowTargeting`] → id or null.
pub(super) fn op_target(request: &Value) -> OpResult {
    run(request, |r: WindowTargeting| r.target())
}

#[derive(Deserialize)]
struct CycledRequest {
    #[serde(flatten)]
    windows: WindowTargeting,
    offset: i64,
}

/// `window.cycled` `{keyWindow?, ordered?, shells?, offset}` → id or null.
pub(super) fn op_cycled(request: &Value) -> OpResult {
    run(request, |r: CycledRequest| r.windows.cycled(r.offset))
}
