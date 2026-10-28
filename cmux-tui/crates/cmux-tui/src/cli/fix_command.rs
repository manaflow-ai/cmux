//! The exact commands a version-skew error names instead of "update the
//! app" (plans/cmux-next/version-skew.md step 4; the lint is
//! scripts/cmux-next/check-capability-text.py).

use std::path::{Path, PathBuf};

/// This CLI's own binary, by absolute path when it can be resolved: the
/// command must run this build, not whichever `cmux` PATH finds first.
pub(super) fn this_cli() -> PathBuf {
    std::env::current_exe()
        .and_then(cmux_blocking::fs::canonicalize)
        .unwrap_or_else(|_| PathBuf::from("cmux"))
}

/// Stops the daemon at `socket` (its terminals survive the handoff).
pub(super) fn stop_daemon(cli: &Path, socket: &Path) -> String {
    format!("{} daemon stop --socket {}", quote(cli), quote(socket))
}

/// Stops the daemon at `socket` and starts it again with `cli`'s build.
pub(super) fn restart_daemon(cli: &Path, socket: &Path) -> String {
    format!(
        "{} && {} daemon ensure --socket {}",
        stop_daemon(cli, socket),
        quote(cli),
        quote(socket)
    )
}

/// Runs `args` with the daemon's own CLI `daemon_cli`: the version-skew fix
/// that keeps the daemon and every terminal it hosts running. Never name
/// [`stop_daemon`] or [`restart_daemon`] as the fix for a skew an agent
/// meets: stopping the daemon ends the user's session.
pub(super) fn run_with_daemon_cli<I, S>(daemon_cli: &Path, args: I) -> String
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let mut text = quote(daemon_cli);
    for arg in args {
        text.push(' ');
        text.push_str(&quote_arg(&arg.as_ref().to_string_lossy()));
    }
    text
}

fn quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}

/// One argument, quoted only when a shell would read it differently.
pub(super) fn quote_arg(arg: &str) -> String {
    let plain = !arg.is_empty()
        && arg.chars().all(|c| c.is_ascii_alphanumeric() || "-_./:=@%+,".contains(c));
    if plain { arg.to_owned() } else { quote(Path::new(arg)) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_daemon_cli_fix_quotes_only_what_needs_it() {
        let text = run_with_daemon_cli(
            Path::new("/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux"),
            ["--socket", "/tmp/a b.sock", "tab", "list", "it's"],
        );
        assert_eq!(
            text,
            "'/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux' --socket '/tmp/a b.sock' tab list 'it'\\''s'"
        );
    }
}
