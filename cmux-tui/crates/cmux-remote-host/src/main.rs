//! cmux Remote on Windows and Linux. The cmux-tui daemon starts it:
//!
//! ```text
//! cmux-remote-host host --layout-dir D --state-dir S --scope ID [--bootstrap-file F]
//!     (the bootstrap line on fd 3 when inherited, else in F: 0600, read once and deleted)
//! cmux-remote-host worker computer-use --layout-dir D --state-dir S
//! cmux-remote-host probe      (prints this session's display and collectors)
//! cmux-remote-host version
//! ```
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::path::PathBuf;
use std::process::ExitCode;

use cmux_remote_host::{host, platform, worker};

fn option(arguments: &[String], name: &str) -> Option<String> {
    let index = arguments.iter().position(|argument| argument == name)?;
    arguments.get(index + 1).cloned()
}

fn fail(message: &str) -> ExitCode {
    eprintln!("cmux-remote-host: {message}");
    ExitCode::from(2)
}

/// The bootstrap line: fd 3 (a direct spawn), else the bootstrap file.
fn read_bootstrap(file: Option<&str>) -> Option<serde_json::Value> {
    #[cfg(unix)]
    {
        use std::io::BufRead;
        use std::os::fd::FromRawFd;
        // SAFETY: F_GETFD only asks whether descriptor 3 is open.
        if unsafe { libc::fcntl(3, libc::F_GETFD) } >= 0 && file.is_none() {
            // SAFETY: descriptor 3 is the daemon's bootstrap pipe; this takes ownership once.
            let pipe = unsafe { std::fs::File::from_raw_fd(3) };
            let mut line = String::new();
            std::io::BufReader::new(pipe).read_line(&mut line).ok()?;
            return serde_json::from_str(&line).ok();
        }
    }
    let path = PathBuf::from(file?);
    let bytes = platform::read_private(&path).ok();
    let _ = std::fs::remove_file(&path);
    serde_json::from_slice(&bytes?).ok()
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => return fail(&format!("no runtime: {error}")),
    };
    match arguments.first().map(String::as_str) {
        Some("version") => println!("cmux-remote-host {}", env!("CARGO_PKG_VERSION")),
        Some("probe") => {
            let collectors = cmux_remote_host::approver::Collectors::detect();
            let config = cmux_remote_host::config::load();
            let probe = serde_json::json!({
                "display": platform::display_kind(),
                "interactive_session": platform::interactive_session(),
                "collectors": collectors.names(),
                "mode": config.as_ref().map(|config| config.mode.as_str()).ok(),
                "config_error": config.err(),
            });
            println!("{probe}");
        }
        Some("worker") => {
            if arguments.get(1).map(String::as_str) != Some("computer-use") {
                return fail("unknown worker (computer-use)");
            }
            let (Some(layout), Some(state)) = (option(&arguments, "--layout-dir"), option(&arguments, "--state-dir")) else {
                return fail("worker needs --layout-dir and --state-dir");
            };
            if let Err(error) = runtime.block_on(worker::run(PathBuf::from(layout), PathBuf::from(state))) {
                return fail(&error);
            }
        }
        Some("host") => {
            let (Some(layout), Some(state), Some(_scope)) =
                (option(&arguments, "--layout-dir"), option(&arguments, "--state-dir"), option(&arguments, "--scope"))
            else {
                return fail("host needs --layout-dir, --state-dir and --scope");
            };
            // Started without a daemon's bootstrap: nothing to serve.
            let Some(bootstrap) = read_bootstrap(option(&arguments, "--bootstrap-file").as_deref())
                .as_ref()
                .and_then(host::Bootstrap::parse)
            else {
                return ExitCode::SUCCESS;
            };
            let layout = PathBuf::from(layout);
            let state = PathBuf::from(state);
            for dir in [&layout, &state] {
                if let Err(error) = platform::make_private_dir(dir) {
                    return fail(&error);
                }
            }
            let exe = std::env::current_exe().ok();
            let core = runtime.block_on(async {
                host::HostCore::new(bootstrap, host::Layout { dir: layout }, state, exe)
            });
            if let Err(error) = runtime.block_on(host::run(core)) {
                return fail(&error);
            }
            // Workers end with their stdin; nothing else outlives the host.
            runtime.shutdown_timeout(std::time::Duration::from_secs(2));
        }
        _ => return fail("usage: cmux-remote-host host|worker computer-use|probe|version"),
    }
    ExitCode::SUCCESS
}
