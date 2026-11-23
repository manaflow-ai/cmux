//! The DEV app's owner launcher (docs/cmux-files-host.md): the embedded "cmux Files (dev)"
//! helper, which runs the owner as its child from a pinned, team-signed identity, so macOS asks
//! for Files and Folders once for every DEV build instead of once per tag.
//!
//! Every build of cmux-tui reads [`OWNER_LAUNCHER_ENV`], shipped ones too, so the launcher it
//! names counts only when it is the helper embedded in the owner's own app and that file is there.
//! A shipped app never embeds the helper (`embed-files-host-dev.sh` embeds it only into a Debug DEV
//! build), so there the owner always starts directly, whatever the environment says.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// The app sets it for `server ensure` only in a DEV build that embeds the helper.
pub(super) const OWNER_LAUNCHER_ENV: &str = "CMUX_TUI_OWNER_LAUNCHER";

/// Where the helper sits inside an app bundle.
const EMBEDDED_HELPER: &str =
    "Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host";

/// The launcher to run the owner `program` under: `launcher` when it is the helper embedded in
/// `program`'s own app and `is_file` finds it there; nil (start the owner directly) else.
pub(super) fn owner_launcher<'a>(
    program: &Path,
    launcher: Option<&'a OsStr>,
    is_file: impl Fn(&Path) -> bool,
) -> Option<&'a Path> {
    launcher
        .map(Path::new)
        .filter(|launcher| embedded_helper(program).is_some_and(|helper| helper == *launcher))
        .filter(|launcher| is_file(launcher))
}

/// The helper's path in the outermost app bundle holding `program`; nil outside an app.
fn embedded_helper(program: &Path) -> Option<PathBuf> {
    let app = program
        .ancestors()
        .filter(|ancestor| ancestor.extension().is_some_and(|extension| extension == "app"))
        .last()?;
    Some(app.join(EMBEDDED_HELPER))
}

#[cfg(test)]
#[path = "owner_launcher_tests.rs"]
mod tests;
