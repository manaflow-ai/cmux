//! Cloud command facade: the guest adapter owns Cloud/session commands and
//! delegates to cmux-tui. Every spelling runs the adapter with its arguments
//! unchanged.
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    let mut args = std::env::args_os();
    let program = args.next().unwrap_or_default();
    let tail: Vec<OsString> = args.collect();
    let path = std::env::var_os("CMUX_CLOUD_ADAPTER")
        .unwrap_or_else(|| OsString::from("/usr/local/libexec/cmux-cloud-adapter"));
    if same_file(&path, &program) {
        eprintln!("cmux: command adapter resolves to the Cloud CLI itself");
        return ExitCode::from(127);
    }
    let mut command = Command::new(&path);
    command.args(tail);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        let error = command.exec();
        eprintln!("cmux: cannot start {}: {error}", Path::new(&path).display());
        ExitCode::from(127)
    }
    #[cfg(not(unix))]
    {
        match command.status() {
            Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
            Err(error) => {
                eprintln!("cmux: cannot start {}: {error}", Path::new(&path).display());
                ExitCode::from(127)
            }
        }
    }
}

fn same_file(candidate: &OsStr, program: &OsStr) -> bool {
    let current = std::env::current_exe().unwrap_or_else(|_| program.into());
    let candidate = resolve_command(candidate);
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if let (Ok(a), Ok(b)) = (std::fs::metadata(&candidate), current.metadata()) {
            return a.dev() == b.dev() && a.ino() == b.ino();
        }
    }
    let (Ok(a), Ok(b)) = (candidate.canonicalize(), current.canonicalize()) else {
        return false;
    };
    a == b
}

/// `Command::new` searches PATH for a bare executable name. Resolve the same
/// way before comparing identities so an override cannot recurse through an
/// alias such as `CMUX_CLOUD_ADAPTER=cmux`.
fn resolve_command(candidate: &OsStr) -> PathBuf {
    let path = Path::new(candidate);
    if path.is_absolute() || path.components().count() > 1 {
        return path.to_path_buf();
    }
    if let Some(path_var) = std::env::var_os("PATH") {
        for directory in std::env::split_paths(&path_var) {
            let resolved = directory.join(path);
            if resolved.is_file() {
                return resolved;
            }
        }
    }
    path.to_path_buf()
}
