use std::ffi::OsStr;
use std::path::Path;

const PROGRAM: &str = "/A/cmux DEV x.app/Contents/Resources/bin/cmux-tui";
const HELPER: &str =
    "/A/cmux DEV x.app/Contents/Library/cmux Files (dev).app/Contents/MacOS/cmux-files-host";

#[test]
fn a_dev_owner_launcher_runs_the_owner_through_cmux_files() {
    let program = Path::new(PROGRAM);
    let launcher = OsStr::new(HELPER);
    let through =
        super::super::owner_command_with(program, Some(launcher), |path| path == Path::new(HELPER));
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
