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
    Scene {
        mount: String,
        ops: Value,
    },
    Log {
        level: String,
        message: String,
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
    /// The engine failed in a way the VM cannot recover from.
    Engine,
}

impl FatalReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Memory => "memory",
            Self::Interrupt => "interrupt",
            Self::Engine => "engine",
        }
    }
}
