//! The host's panic log (`--panic-log <path>`, [`crate::protocol::PANIC_LOG_FLAG`]).
//!
//! The supervisor starts the host with no environment and its stderr on
//! /dev/null, and the sandbox then refuses every open. So [`install`] opens
//! the log before the sandbox holds, and the hook writes each panic as one
//! JSON line (cmux-panic-log) through a clone of that handle. The cmux-next
//! app sends new lines to Sentry (`RustPanicSource.appHost`).

use std::path::Path;

/// Opens `path` (owner-only, never through a link) and installs the hook.
/// Call before [`crate::sandbox::apply`].
pub fn install(path: &Path) -> std::io::Result<()> {
    let file = cmux_panic_log::open_log(path)?;
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "cmux-app-host".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), env!("CARGO_PKG_VERSION").into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    cmux_panic_log::install_with_opener(move || file.try_clone(), fields, |_| false);
    Ok(())
}
