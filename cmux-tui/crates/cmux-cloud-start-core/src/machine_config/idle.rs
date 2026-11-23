//! A machine's idle window, from its `.cmux/machine.toml` (cmuxterm-hq `docs/rfd/0016-one-machine-layer.md`,
//! "Keep-alive policy"): how long the machine stays running after its last activity before the Cloud pauses it.
//!
//! ```toml
//! version = 1
//! role = "lane"        # an agent lane: 5 minutes after its last activity, then pause
//! [idle]
//! minutes = 5          # 1 to 1439 (under the Cloud's 24 h backstop); overrides the role's window
//! ```
//!
//! Only the `lane` role has a window of its own ([`LANE_IDLE_SECONDS`]); a file with neither a lane role nor
//! `[idle]` declares nothing, and the Cloud keeps its own windows (the plan default, 1,800 s, is a product default
//! and is not set here). The applier (`applier.py`) takes the same keys, refuses the same bad values, and keeps the
//! file it applied at [`applied_path`]; cmux-host reads that file on each workload probe ([`read`]) and reports the
//! window as `activity.idle_window_seconds` in `cloud.vm.status.report`, where CloudDO's pause owner (cmux-platform
//! `domain/Pause.ts`) uses it as rung 2's window for this machine.

use std::path::Path;

use serde::Deserialize;

use super::{DIRECTORY, MAX_BYTES};

/// The agent lane role (`role = "lane"`).
pub const LANE_ROLE: &str = "lane";
/// The lane role's window: a fixed keep-alive of 5 minutes after the machine's last activity, then pause
/// (RFD 0016, "Keep-alive policy").
pub const LANE_IDLE_SECONDS: u64 = 300;
/// `[idle] minutes` bounds: at least a minute, and under the Cloud's 24 h backstop.
pub const MIN_MINUTES: u64 = 1;
pub const MAX_MINUTES: u64 = 24 * 60 - 1;

/// The file the applier applied last (a copy of it, the work user's, 0600).
pub fn applied_path() -> String {
    format!("{DIRECTORY}/applied.toml")
}

/// What a `machine.toml` declares about idleness.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct IdlePolicy {
    pub role: Option<String>,
    /// `[idle] minutes`, in seconds.
    pub declared_seconds: Option<u64>,
}

impl IdlePolicy {
    /// The machine's window in seconds: `[idle] minutes` when declared, else the role's, else none.
    pub fn window_seconds(&self) -> Option<u64> {
        self.declared_seconds
            .or_else(|| (self.role.as_deref() == Some(LANE_ROLE)).then_some(LANE_IDLE_SECONDS))
    }
}

#[derive(Deserialize)]
struct File {
    role: Option<toml::Value>,
    idle: Option<toml::Value>,
}

/// A role name: a lowercase letter, then up to 31 lowercase letters, digits or dashes.
fn role_ok(role: &str) -> bool {
    let mut chars = role.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && role.len() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// The idle declarations of a `machine.toml`'s text, or the reason it is refused. Only `role` and `[idle]` are
/// read; the applier checks the rest of the file.
pub fn parse(text: &str) -> Result<IdlePolicy, String> {
    let file: File = toml::from_str(text).map_err(|e| format!("not TOML: {}", e.message()))?;
    let role = match file.role {
        None => None,
        Some(toml::Value::String(r)) if role_ok(&r) => Some(r),
        Some(_) => return Err("role must match [a-z][a-z0-9-]{0,31}".to_owned()),
    };
    let declared_seconds = match file.idle {
        None => None,
        Some(toml::Value::Table(t)) => {
            if t.keys().any(|k| k != "minutes") {
                return Err("[idle] takes only minutes".to_owned());
            }
            match t.get("minutes") {
                None => None,
                Some(toml::Value::Integer(m))
                    if (MIN_MINUTES as i64..=MAX_MINUTES as i64).contains(m) =>
                {
                    Some(*m as u64 * 60)
                }
                Some(_) => {
                    return Err(format!("idle.minutes must be {MIN_MINUTES} to {MAX_MINUTES}"));
                }
            }
        }
        Some(_) => return Err("idle must be a table".to_owned()),
    };
    Ok(IdlePolicy { role, declared_seconds })
}

/// The window of the file the applier applied last, under `root` (`/` on a machine), or None: no file, a file
/// that does not read or parse, or one that declares no window.
pub fn read(root: &Path) -> Option<u64> {
    let path = root.join(applied_path().trim_start_matches('/'));
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES as u64 {
        return None;
    }
    let text = std::fs::read_to_string(&path).ok()?;
    parse(&text).ok()?.window_seconds()
}

#[cfg(test)]
#[path = "idle_tests.rs"]
mod tests;
