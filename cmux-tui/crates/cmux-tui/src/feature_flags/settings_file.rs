//! Which settings file a `cmux` CLI reader uses
//! (plans/cmux-next/settings-react.md, section 7, item 1).
//!
//! The owner of a cmux terminal can run on another settings file than the
//! default one: its launch names the file (`CMUX_NEXT_CONFIG_FILE`) and it
//! reports the file as `path` in `settings.snapshot`. Its terminal children
//! do not inherit that variable (`shell_integration::keys_to_unset_in_child`),
//! so a daemon that a test starts in a terminal with only its own `HOME`
//! never writes the owner's file. A CLI reader in the terminal asks the
//! owner instead:
//!
//! 1. `CMUX_NEXT_CONFIG_FILE` in this process's own environment wins (a
//!    person or a test that sets it).
//! 2. Else, in a cmux terminal (`CMUX_TUI_SOCKET`, `CMUX_MUX_SOCKET`), the
//!    owner's `path`, asked once per process within [`ASK_DEADLINE`], when
//!    that is another file than this process's default one.
//! 3. Else the reader's default file. That is also the answer when the owner
//!    is gone, does not answer in time, or is an older build whose answer
//!    has no `path`: the ask never fails a command.
//!
//! The socket is the one of the terminal this process runs in, on this
//! machine. It is never the command's own route (`--socket`, `--session`,
//! `--machine`), so a reader of a remote command (`remote.ultraMode`) asks
//! the local owner only. Outside a cmux terminal nothing is asked.
//!
//! Only CLI readers use this. An owner takes its file from its own launch
//! (`cmux_config::config_path`, `feature_flags::settings`), never from
//! another owner: a daemon started in a cmux terminal still has that
//! terminal's socket variables.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

/// How long the one ask may take, from connect to answer: the bound of the
/// agent hooks' asks of the same local owner.
const ASK_DEADLINE: Duration = crate::hook_helper::inbox::DEADLINE;

/// The settings file this CLI reads, with `cmux_config::config_path` as the
/// default file.
pub(crate) fn path() -> PathBuf {
    path_or(cmux_config::config_path)
}

/// [`path`] for a reader with its own default rule (`default` reads
/// `CMUX_NEXT_CONFIG_FILE` itself, then picks its default file).
pub(crate) fn path_or(default: impl FnOnce() -> PathBuf) -> PathBuf {
    let named_here =
        std::env::var_os(cmux_config::CONFIG_OVERRIDE).is_some_and(|value| !value.is_empty());
    if named_here {
        return default();
    }
    match owner_path() {
        // An owner on this process's default file moves nothing. The reader
        // keeps its own rule for that file: while the file does not exist,
        // the owner reads classic `cmux.json` as its seed, and so does
        // `user_settings::config_path`.
        Some(path) if path != cmux_config::config_path() => path,
        _ => default(),
    }
}

/// Settings-file `remote.ultraMode` of this CLI's file, read when a tunnel
/// starts (`user_settings::ultra_mode`, with that reader's default file).
#[cfg(unix)]
pub(crate) fn ultra_mode() -> bool {
    use cmux_tui_core::user_settings::{config_path, ultra_mode_at};
    ultra_mode_at(&path_or(config_path))
}

/// The settings file of this terminal's owner, asked once per process.
fn owner_path() -> Option<PathBuf> {
    static ASKED: OnceLock<Option<PathBuf>> = OnceLock::new();
    ASKED.get_or_init(|| ask(&terminal_owner_socket()?)).clone()
}

/// The socket of the owner of the terminal this process runs in.
fn terminal_owner_socket() -> Option<PathBuf> {
    // Unit tests never ask the owner of the terminal they run in.
    if cfg!(test) {
        return None;
    }
    let socket = ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"]
        .into_iter()
        .find_map(|name| std::env::var_os(name).filter(|value| !value.is_empty()))?;
    // A `cmux` bundled in another app than this terminal's: that app's
    // daemon and its settings file are not this build's (app_identity.rs).
    #[cfg(unix)]
    if crate::app_identity::this_process_in_other_apps_terminal() {
        return None;
    }
    Some(PathBuf::from(socket))
}

/// `settings.snapshot` `path` of the owner at `socket`. `None` for no owner,
/// no answer within [`ASK_DEADLINE`], a refusal, and an answer without an
/// absolute `path` (an owner older than the field).
fn ask(socket: &Path) -> Option<PathBuf> {
    let deadline = Instant::now() + ASK_DEADLINE;
    let answer = crate::hook_helper::inbox::request(
        socket,
        "settings.snapshot",
        serde_json::json!({}),
        false,
        deadline,
    );
    let path = answer
        .as_ref()
        .ok()
        .and_then(|snapshot| snapshot.get("path"))
        .and_then(serde_json::Value::as_str)
        .map(PathBuf::from)
        .filter(|path| path.is_absolute());
    if path.is_none() {
        // The cap fired or the owner is gone or older: the command goes on
        // with the default file, and the client log says why.
        let why = match &answer {
            Ok(_) => "its answer names no settings file".to_owned(),
            Err(error) => format!("{error:#}"),
        };
        crate::client_log::warn(
            "settings",
            &format!("no settings file from the owner at {}: {why}", socket.display()),
        );
    }
    path
}
