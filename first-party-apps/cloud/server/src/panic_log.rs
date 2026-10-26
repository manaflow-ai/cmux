//! The server's panic log: one JSON line per panic in
//! `<CMUX_APP_DATA_DIR>/panics.jsonl` (the `cmux-panic-log` format), which
//! the cmux-next app sends to Sentry under the user's telemetry choice.
//! The server's stderr goes to the app's log, where no one reads a panic;
//! the previous hook still writes it there.

use crate::app_env::AppEnv;
use std::path::PathBuf;

/// The log's file name inside the app's data folder.
pub const LOG_NAME: &str = "panics.jsonl";

/// `<data>/panics.jsonl`; `None` when the host gave the server no data folder.
pub fn log_path(env: &AppEnv) -> Option<PathBuf> {
    env.data_dir().map(|data| data.join(LOG_NAME))
}

/// The fields every line of this process carries. `main` installs the hook
/// with them; with no data folder there is no private place for the log, so
/// it installs nothing.
pub fn fields() -> cmux_panic_log::Fields {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "cmux-cloud".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    fields
}
