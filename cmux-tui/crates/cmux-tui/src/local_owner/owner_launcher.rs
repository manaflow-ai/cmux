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
mod tests {
    use std::ffi::OsStr;
    use std::path::Path;

    const PROGRAM: &str = "/A/cmux DEV x.app/Contents/Resources/bin/cmux-tui";
    const HELPER: &str =
        "/A/cmux DEV x.app/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host";

    #[test]
    fn a_dev_owner_launcher_runs_the_owner_through_cmux_files() {
        let program = Path::new(PROGRAM);
        let launcher = OsStr::new(HELPER);
        let through = super::super::owner_command_with(program, Some(launcher), |path| {
            path == Path::new(HELPER)
        });
        assert_eq!(through.get_program(), launcher);
        let args: Vec<&OsStr> = through.get_args().collect();
        assert_eq!(args, [OsStr::new("run"), OsStr::new("--"), program.as_os_str()]);

        for launcher in [None, Some(OsStr::new("")), Some(OsStr::new("cmux-files-host"))] {
            let direct = super::super::owner_command_with(program, launcher, |_| true);
            assert_eq!(direct.get_program(), program.as_os_str(), "{launcher:?}");
            assert_eq!(direct.get_args().count(), 0, "{launcher:?}");
        }
        // Shells under the owner never inherit the launcher.
        for command in [through, super::super::owner_command(program, None)] {
            assert!(
                command
                    .get_envs()
                    .any(|(key, value)| key == super::OWNER_LAUNCHER_ENV && value.is_none()),
                "the owner's environment drops {}",
                super::OWNER_LAUNCHER_ENV
            );
        }
    }

    /// A shipped app's cmux-tui reads the same variable, so it must not run the owner under any
    /// program the environment names: only the helper embedded in the owner's own app, and only
    /// when that file is there. A shipped app never embeds it, so there the owner always starts
    /// directly (docs/cmux-files-host.md, Production).
    #[test]
    fn only_the_helper_embedded_in_the_owners_own_app_launches_it() {
        let program = Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux-tui");
        for launcher in [
            "/tmp/evil/cmux-files-host",
            "/bin/sh",
            HELPER,
            // The right place in the owner's app, but a shipped app has no such file.
            "/Applications/cmux NIGHTLY.app/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host",
        ] {
            let command = super::super::owner_command(program, Some(OsStr::new(launcher)));
            assert_eq!(command.get_program(), program.as_os_str(), "{launcher}");
            assert_eq!(command.get_args().count(), 0, "{launcher}");
        }
        // Even an existing file elsewhere is never the launcher.
        let elsewhere = super::super::owner_command_with(
            program,
            Some(OsStr::new("/tmp/evil/cmux-files-host")),
            |_| true,
        );
        assert_eq!(elsewhere.get_program(), program.as_os_str());
        // A program outside any app has no embedded helper.
        let bare = Path::new("/usr/local/bin/cmux-tui");
        let outside = super::super::owner_command_with(bare, Some(OsStr::new(HELPER)), |_| true);
        assert_eq!(outside.get_program(), bare.as_os_str());
    }
}
