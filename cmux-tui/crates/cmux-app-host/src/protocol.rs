//! The fd 3 wire between the app supervisor and one app host process.
//!
//! JSON lines in both directions, one object per line, tagged by `t`. The
//! supervisor writes [`ToHost`] and reads [`FromHost`]. Both sides treat an
//! unknown or malformed line as fatal for the connection: the host exits, the
//! supervisor kills the process. The full table is in the crate docs.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Largest line either side accepts (scene batches dominate).
pub const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;

/// Largest `state` object (`cmux.state`), as JSON bytes. Over it the host
/// logs a warning and keeps the last state it sent.
pub const MAX_KEPT_STATE_BYTES: usize = 64 * 1024;
/// Most keys in one `state` object.
pub const MAX_KEPT_STATE_KEYS: usize = 256;

/// Why a `state` object is refused, or `None` when it is within the caps:
/// an object of at most [`MAX_KEPT_STATE_KEYS`] keys and
/// [`MAX_KEPT_STATE_BYTES`] bytes of JSON.
pub fn kept_state_refusal(values: &Value, json_bytes: usize) -> Option<String> {
    let Some(map) = values.as_object() else {
        return Some("cmux.state: the kept values are not an object".into());
    };
    if map.len() > MAX_KEPT_STATE_KEYS {
        return Some(format!(
            "cmux.state: {} keys is over the {MAX_KEPT_STATE_KEYS} key cap; the last kept values stay",
            map.len()
        ));
    }
    if json_bytes > MAX_KEPT_STATE_BYTES {
        return Some(format!(
            "cmux.state: {json_bytes} bytes is over the {MAX_KEPT_STATE_BYTES} byte cap; the last kept values stay"
        ));
    }
    None
}

/// `cmux-app-host --profile script`: a script session
/// (plans/cmux-next/scripting-runtime.md) instead of an app.
pub const SCRIPT_PROFILE: &str = "script";
/// Engine memory of a script session.
pub const SCRIPT_MEMORY_BYTES: usize = 64 * 1024 * 1024;
/// How long one script step (an entry point plus its job queue) may run
/// without yielding. The wall time of a cell is the caller's timeout.
pub const SCRIPT_STEP_MS: u64 = 2_000;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppInfo {
    pub id: String,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
pub enum ToHost {
    /// First message. `main` is the app's classic script (the host never
    /// opens a file). `ops` are the ops the grant allows, `known_ops` every op
    /// this cmux knows; absent means no local filtering; both only shape errors early, the supervisor checks
    /// every call again.
    Init {
        app: AppInfo,
        #[serde(default)]
        settings: Value,
        api_version: String,
        #[serde(default)]
        ops: Option<Vec<String>>,
        #[serde(default)]
        known_ops: Option<Vec<String>>,
        #[serde(default)]
        locale: Option<String>,
        #[serde(default)]
        strings: Value,
        main: String,
        /// The script's file in its package (`runtime.main`, `main.js`): a
        /// syntax or load error names it (`main.js:2:12`). Absent: `eval_script`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        main_name: Option<String>,
        /// The values the last host of this app kept with `cmux.state`
        /// (`state` below), handed back when the supervisor restarts it for a
        /// local reload or a grant change. Absent on a first start.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        state: Option<Value>,
    },
    Mount {
        mount: String,
        export: String,
        #[serde(default)]
        ctx: Value,
    },
    Unmount {
        mount: String,
    },
    Dispatch {
        mount: String,
        node: String,
        event: String,
        #[serde(default)]
        payload: Value,
    },
    /// A widget mount's host-owned tick (`cmux.widget/1`), at `now_ms` (Unix
    /// ms): the runtime sets the mount's `now()` clock; nothing else runs.
    Tick {
        mount: String,
        now_ms: u64,
    },
    Resolve {
        cb: u64,
        ok: bool,
        #[serde(default)]
        body: Value,
    },
    Event {
        sub: u64,
        #[serde(default)]
        body: Value,
    },
    Settings {
        #[serde(default)]
        values: Value,
    },
    /// The daemon's signals cache (`cmux.watch`): watch `watch`'s entry state
    /// `{value, status, error?, updatedAt}`, or `{fallback: true}` when the daemon does not read
    /// that source (the runtime then reads it itself).
    Watch {
        watch: u64,
        #[serde(default)]
        state: Value,
    },
    Run {
        cb: u64,
        export: String,
        #[serde(default)]
        args: Value,
        /// A gesture token the supervisor minted for a user invocation
        /// (palette, keybinding); ambient while the command runs synchronously.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        gesture: Option<String>,
    },
    Shutdown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
pub enum FromHost {
    Ready {
        runtime: String,
    },
    InitFailed {
        error: String,
    },
    Mounted {
        mount: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    Call {
        cb: u64,
        name: String,
        params: Value,
        options: Value,
    },
    Subscribe {
        sub: u64,
        stream: String,
        filter: Value,
    },
    Unsubscribe {
        sub: u64,
    },
    /// Joins the daemon's signals cache entry of (`name`, `params`) as watch `watch`, for
    /// `mount` (its wire id; absent for code outside a mount), paced by `every_seconds`.
    Watch {
        watch: u64,
        name: String,
        #[serde(default)]
        params: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mount: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        every_seconds: Option<f64>,
    },
    /// Leaves the entry; `refresh: true` instead asks it for a read now.
    Unwatch {
        watch: u64,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        refresh: bool,
    },
    Scene {
        mount: String,
        ops: Value,
    },
    Log {
        level: String,
        message: String,
    },
    /// Every value the app keeps with `cmux.state(key, initial)`, as one
    /// object (at most [`MAX_KEPT_STATE_BYTES`] and [`MAX_KEPT_STATE_KEYS`]).
    /// The supervisor holds the last one in memory and hands it to the next
    /// host's `init` when it restarts the app (a local reload).
    State {
        values: Value,
    },
    Done {
        cb: u64,
        ok: bool,
        body: Value,
    },
    /// The VM hit a limit or broke; the host exits right after this line.
    Fatal {
        reason: FatalReason,
        entry: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum FatalReason {
    /// The VM allocated past its memory limit.
    Memory,
    /// One entry point ran past its interrupt deadline.
    Interrupt,
    /// The VM used up its CPU window ([`crate::vm::CpuBudget`]).
    CpuBudget,
    /// The engine failed in a way the VM cannot recover from.
    Engine,
}

impl FatalReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Memory => "memory",
            Self::Interrupt => "interrupt",
            Self::CpuBudget => "cpu-budget",
            Self::Engine => "engine",
        }
    }
}
