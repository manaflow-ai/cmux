//! The slot backend seam: what a desktop must do for the pool. Linux desktops
//! (`linux.rs`, Xvfb + openbox + a browser in a cgroup v2) are the first; a
//! macOS backend (one virtual display or one VM per slot, driven through the
//! cmux computer-use driver) plugs in as another [`Backend`].

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// What a lease asks for. Unknown fields are ignored so a newer client can
/// ask a backend for things an older pool does not know yet.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default)]
pub struct SlotSpec {
    /// The backend kind: `linux-xvfb` (this host), later `macos-display`, `macos-vm`.
    pub backend: String,
    pub width: u32,
    pub height: u32,
    /// The page the slot's browser opens when the slot is made (`about:blank`).
    pub url: String,
}

impl Default for SlotSpec {
    fn default() -> Self {
        SlotSpec {
            backend: "linux-xvfb".into(),
            width: 1280,
            height: 800,
            url: "about:blank".into(),
        }
    }
}

/// One computer-use action, in the cmux computer-use driver's words
/// (`click`, `type_text`, `press_key` with xdotool key strings, `scroll`,
/// `screenshot`), plus `open_url` and `wait` for a test script.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Action {
    Screenshot,
    Click {
        x: i32,
        y: i32,
        #[serde(default = "one")]
        button: u8,
        #[serde(default = "one")]
        count: u8,
    },
    TypeText {
        text: String,
    },
    PressKey {
        key: String,
    },
    Scroll {
        x: i32,
        y: i32,
        /// `up`, `down`, `left` or `right`.
        direction: String,
        #[serde(default = "three")]
        amount: u8,
    },
    /// Focus the address bar, type the URL, press Return, let the page load.
    OpenUrl {
        url: String,
        #[serde(default = "page_load_ms")]
        wait_ms: u64,
    },
    /// Let the desktop run (a page loading) before the screenshot.
    Wait {
        ms: u64,
    },
}

fn one() -> u8 {
    1
}
fn three() -> u8 {
    3
}
fn page_load_ms() -> u64 {
    1500
}

/// What one action did, with the screenshot taken after it.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ActOutput {
    pub png: Vec<u8>,
    /// The focused window's title after the action, if the backend can read it.
    pub title: Option<String>,
    pub act_ms: f64,
    pub screenshot_ms: f64,
}

/// What a suspend did.
#[derive(Debug, Clone, Default, Serialize)]
pub struct SuspendReport {
    pub freeze_ms: f64,
    pub reclaim_ms: f64,
    pub resident_before_mb: f64,
    pub resident_after_mb: f64,
    /// Compressed in RAM (zswap) after the suspend.
    pub zswap_mb: f64,
    /// On the swap device (an evicted slot).
    pub swap_mb: f64,
}

/// A backend makes desktops.
pub trait Backend: Send + Sync {
    fn kind(&self) -> &'static str;
    fn spawn(&self, id: &str, spec: &SlotSpec) -> Result<Box<dyn Desktop>>;
}

/// One desktop. The pool holds each behind its own lock, so actions on two
/// slots run at once.
pub trait Desktop: Send {
    /// Stop it running and push its memory out (freeze + reclaim on Linux).
    fn suspend(&mut self) -> Result<SuspendReport>;
    /// Let it run again; memory comes back lazily on fault. Returns ms.
    fn resume(&mut self) -> Result<f64>;
    fn act(&mut self, action: &Action) -> Result<ActOutput>;
    /// Resident bytes now, the eviction budget's unit.
    fn resident_bytes(&self) -> u64;
    /// The deeper tier: let suspended memory leave RAM entirely (zswap
    /// writeback to the swap device on Linux, a saved VM on macOS).
    fn evict(&mut self) -> Result<SuspendReport>;
    /// Kill everything the desktop started. Idempotent.
    fn destroy(&mut self);
    /// The ids an operator needs to clean up by owner (cgroup path, PIDs).
    fn owner_record(&self) -> serde_json::Value;
}
