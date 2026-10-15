//! A daemon's durable state root inside the test's own folder.
//!
//! Without `CMUX_TUI_STATE_DIR` a daemon keeps durable state, and the shell
//! integration scripts every new shell sources, below `$HOME`. The daemon
//! refuses the scripts when a folder above them could be replaced by another
//! user (`check_trusted_ancestors` in cmux-tui-core's shell_integration.rs),
//! and a build host's step `HOME` can be such a folder: on the AWS Macs it is
//! below `/Volumes/ephemeral0` (root:wheel 0775, no sticky bit). The shell
//! then starts without integration and never reports a prompt, a command or
//! its folder. A test folder below `/tmp` belongs to this user and passes the
//! check on every host, so a fixture keeps the root there.

use std::path::Path;
use std::process::Command;

/// Points `command` at `<dir>/cmux-tui/sessions`, the default layout below a
/// private (0700) `<dir>/cmux-tui`. `dir` is the test's own folder, created
/// by this user.
pub fn use_private_state<'a>(command: &'a mut Command, dir: &Path) -> &'a mut Command {
    let root = dir.join("cmux-tui");
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(&root).unwrap_or_else(|error| panic!("{}: {error}", root.display()));
    command.env("CMUX_TUI_STATE_DIR", root.join("sessions"))
}
