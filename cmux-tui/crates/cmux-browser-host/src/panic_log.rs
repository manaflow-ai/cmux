//! The host's panic log (`serve --panic-log <path>`). A panic on a session
//! or provider thread ends only that thread and used to leave only a stderr
//! line. The hook appends one JSON line per panic (cmux-panic-log), then runs
//! the default hook. The daemon passes `browser-host-panics.jsonl` at its
//! state root, and the cmux-next app sends new lines to Sentry
//! (`RustPanicSource.browserHost`).

use std::path::PathBuf;

/// Installs the hook; the log is opened (owner-only, never through a link)
/// at each panic.
pub fn install(path: PathBuf) {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "cmux-browser-host".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    cmux_panic_log::install(path, fields, |_| false);
}
