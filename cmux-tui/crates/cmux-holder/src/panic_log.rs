//! The holder's panic log: `holder-panics.jsonl` in its socket's directory
//! (the daemon's private 0700 holder directory, `/tmp/cmux-hd-<uid>`),
//! written by cmux-panic-log's std-only writer (feature `minimal`), so the
//! holder still links std and libc only. The cmux-next app sends new lines
//! to Sentry (`RustPanicSource.holder`). Holders of several installs share
//! the directory; each line names its own socket, pid and wire.

use std::path::{Path, PathBuf};

use cmux_panic_log::minimal;

/// The log's file name, beside the socket.
pub const FILE_NAME: &str = "holder-panics.jsonl";

/// Install the hook when `args` name a socket (`--socket PATH`; not for
/// `--version`). Call once, first thing in `main`.
pub fn install(args: &[String]) {
    let Some(socket) = socket_arg(args) else { return };
    let Some(path) = log_path(socket) else { return };
    minimal::install(path, fields(socket), |_| false);
}

/// The log beside `socket`; `None` for a bare file name.
pub fn log_path(socket: &Path) -> Option<PathBuf> {
    let dir = socket.parent().filter(|dir| !dir.as_os_str().is_empty())?;
    Some(dir.join(FILE_NAME))
}

/// Every line's fields: the process, which holder wrote it and its wire.
pub fn fields(socket: &Path) -> minimal::Fields {
    let socket_name = socket.file_name().map(|name| name.to_string_lossy().into_owned());
    vec![
        ("process", "cmux-holder".into()),
        ("holder_pid", std::process::id().into()),
        ("holder_socket", socket_name.unwrap_or_default().into()),
        ("holder_wire", crate::version_line().into()),
        ("os", std::env::consts::OS.into()),
        ("arch", std::env::consts::ARCH.into()),
    ]
}

fn socket_arg(args: &[String]) -> Option<&Path> {
    let index = args.iter().position(|arg| arg == "--socket")?;
    args.get(index + 1).map(Path::new)
}
