//! `cmux acp …`: agent sessions through acpmux, which is linked into this
//! binary. The same program runs as `acpmux` when started through a symlink
//! of that name (see `main`).

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use acpmux::cli::entry::{self, Invocation};

/// `cmux acp <args>`.
pub(crate) fn run(args: Vec<OsString>) -> i32 {
    run_as(args, "cmux acp")
}

/// `cmux <head> <args>` for `head` = `acp`, `chats` or `harness`.
pub(crate) fn run_scope(head: &str, args: Vec<OsString>) -> i32 {
    run_as(args, if head == "acp" { "cmux acp" } else { "cmux" })
}

/// `<display_name> <args>`: `cmux acp …`, or `cmux` for the `cmux chats …` and
/// `cmux harness …` aliases, so usage and errors name the command the user typed.
pub(crate) fn run_as(args: Vec<OsString>, display_name: &str) -> i32 {
    if let [chats, open, rest @ ..] = args.as_slice()
        && chats == "chats"
        && open == "open"
        && !rest.iter().any(|arg| arg == "--json" || arg == "-h" || arg == "--help")
    {
        let words: Vec<String> =
            rest.iter().map(|arg| arg.to_string_lossy().into_owned()).collect();
        return chats_open(&words);
    }
    if args.first().is_some_and(|arg| arg == "open") {
        let words: Vec<String> =
            args[1..].iter().map(|arg| arg.to_string_lossy().into_owned()).collect();
        return open(&words);
    }
    if let [harness, run, rest @ ..] = args.as_slice()
        && harness == "harness"
        && run == "run"
        && rest.iter().any(|arg| arg == "--tab")
    {
        let words: Vec<String> = rest
            .iter()
            .filter(|arg| *arg != "--tab")
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        return harness_tab(&words);
    }
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    finish(
        entry::main(
            args,
            Invocation {
                display_name: display_name.into(),
                daemon_prefix: vec!["acp".into()],
                home: home.and_then(|home| build_home(&home)),
            },
        ),
        display_name,
    )
}

/// `cmux acp open NAME [--pane ID]`: show an agent session in a new tab of
/// a pane (the session's focused pane by default). The tab runs `cmux acp attach NAME`,
/// the acpmux TUI, so it works the same in the app and in the TUI.
fn open(args: &[String]) -> i32 {
    let exe = match std::env::current_exe() {
        Ok(exe) => exe.to_string_lossy().into_owned(),
        Err(error) => {
            eprintln!("cmux acp open: {error}");
            return 1;
        }
    };
    match open_command(args, &exe) {
        Ok(command) => crate::cli::run(&command, ""),
        Err(message) => {
            eprintln!("{message}");
            2
        }
    }
}

/// The `cmux pane <pane> run -- <exe> acp attach NAME` arguments.
fn open_command(args: &[String], exe: &str) -> Result<Vec<String>, String> {
    let messages = &crate::localization::catalog().app_control;
    let (session, pane) = match args {
        [session] => (session, "current"),
        [session, flag, pane] | [flag, pane, session] if flag == "--pane" => {
            (session, pane.as_str())
        }
        _ => return Err(messages.acp_open_usage.to_owned()),
    };
    Ok(["pane", pane, "run", "--", exe, "acp", "attach", session.as_str()]
        .into_iter()
        .map(str::to_owned)
        .collect())
}

/// Point the linked acpmux at the home `cmux acp` uses, for code that talks
/// to the acpmux daemon without going through `cmux acp` (agent messages).
pub(crate) fn configure_home() {
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    if let Some(home) = home.and_then(|home| build_home(&home)) {
        acpmux::config::set_home_override(home);
    }
}

/// The acpmux unix socket the session daemon attaches agent tabs through
/// (`agent-session-attach-v1`): the one `cmux acp` in this daemon's terminals
/// reaches. `ACPMUX_SOCKET`, else the socket of the home `cmux acp` uses
/// (`ACPMUX_HOME`, else its build's home, else `~/.acpmux`). Read once at
/// daemon start, without touching acpmux's process-wide config.
#[cfg(unix)]
pub(crate) fn daemon_socket_path() -> Option<PathBuf> {
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    if let Some(socket) = env_value("ACPMUX_SOCKET") {
        return Some(daemon_socket(Some(&socket), Path::new(""), uid));
    }
    Some(daemon_socket(None, &daemon_acpmux_home()?, uid))
}

/// The socket for a configured `ACPMUX_SOCKET` or an acpmux home, by the rule
/// acpmux and every host share (cmux-agent-pane-policy `socket_path`).
#[cfg(unix)]
fn daemon_socket(configured: Option<&str>, home: &Path, uid: u32) -> PathBuf {
    PathBuf::from(cmux_agent_pane_policy::environment::socket_path(configured, home, uid))
}

/// Gives the session daemon its acpmux [`daemon_acpmux_starter`] and
/// [`daemon_acpmux_handoff`], both naming the daemon's `socket`.
#[cfg(unix)]
pub(crate) fn install_daemon_acpmux(mux: &cmux_tui_core::Mux, socket: &Path) {
    mux.set_acpmux_starter(daemon_acpmux_starter(socket));
    mux.set_acpmux_handoff(daemon_acpmux_handoff(socket));
}

/// How the session daemon starts the acpmux that [`daemon_socket_path`]
/// names when an `agent-session-start` finds nothing there: this binary's
/// `acp daemon start` with that home, as `cmux acp` starts it (acpmux bounds
/// the wait for its socket), without the daemon's terminal identity, and with
/// `CMUX_TUI_SOCKET` naming this daemon's `socket`, which mints each agent's
/// launch credential (acpmux `launch_credential.rs`). None with
/// `ACPMUX_SOCKET`: a fixed socket belongs to an acpmux this daemon does not
/// own.
#[cfg(unix)]
pub(crate) fn daemon_acpmux_starter(socket: &Path) -> Option<cmux_tui_core::server::AcpmuxStarter> {
    if env_value("ACPMUX_SOCKET").is_some() {
        return None;
    }
    let home = daemon_acpmux_home()?;
    let exe = std::env::current_exe().ok()?;
    let socket = socket.to_path_buf();
    Some(std::sync::Arc::new(move || run_acp_daemon(&exe, &home, &socket, &["start"])))
}

/// How the session daemon hands the machine's acpmux off before an
/// `agent-update-apply` (`agent-update-v1`) when it does not know the update
/// method: the installed binary's `acp daemon shutdown --keep-agents` (agents
/// keep running) and then its `acp daemon start` with the home
/// [`daemon_acpmux_starter`] uses, whose acpmux adopts them. The installed
/// binary, not this process's image: after an in-place upgrade that is the
/// newer build (on Linux the running image reads `<path> (deleted)`). None
/// with `ACPMUX_SOCKET`, as the starter.
#[cfg(unix)]
pub(crate) fn daemon_acpmux_handoff(
    socket: &Path,
) -> Option<cmux_tui_core::server::agent_transfer::agent_update::AcpmuxHandoff> {
    if env_value("ACPMUX_SOCKET").is_some() {
        return None;
    }
    let home = daemon_acpmux_home()?;
    let exe = std::env::current_exe().ok()?;
    let socket = socket.to_path_buf();
    Some(std::sync::Arc::new(move || {
        let installed = installed_exe(&exe)?;
        run_acp_daemon(&installed, &home, &socket, &["shutdown", "--keep-agents"])?;
        run_acp_daemon(&installed, &home, &socket, &["start"])
    }))
}

/// The binary installed at the path this process started from: the path
/// without Linux's ` (deleted)` mark of a replaced image; an error when no
/// file is there.
#[cfg(unix)]
fn installed_exe(exe: &Path) -> Result<PathBuf, String> {
    let text = exe.to_string_lossy();
    let path = text.strip_suffix(" (deleted)").map_or_else(|| exe.to_path_buf(), PathBuf::from);
    if path.is_file() {
        Ok(path)
    } else {
        Err(format!("no cmux binary is installed at {}", path.display()))
    }
}

/// This binary's `acp daemon <args>` with `home` and the session `socket`,
/// blocking.
#[cfg(unix)]
fn run_acp_daemon(exe: &Path, home: &Path, socket: &Path, args: &[&str]) -> Result<(), String> {
    let mut command = std::process::Command::new(exe);
    // acpmux and every agent it starts outlive this call: none of them
    // may claim the terminal this daemon was started from.
    for name in TERMINAL_IDENTITY_ENV {
        command.env_remove(name);
    }
    let what = format!("acpmux daemon {}", args.join(" "));
    let status = command
        .env("ACPMUX_HOME", home)
        .env(acpmux::launch_credential::SESSION_SOCKET_ENV, socket)
        .args(["acp", "daemon"])
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|error| format!("{what}: {error}"))?;
    if status.success() { Ok(()) } else { Err(format!("{what} exited with {status}")) }
}

/// The cmux terminal a process runs in; a detached acpmux has none (the
/// same claims the detached owner drops, local_owner.rs; socket and config
/// variables stay).
#[cfg(unix)]
const TERMINAL_IDENTITY_ENV: [&str; 5] =
    ["CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID"];

/// The acpmux home `cmux acp` uses: `ACPMUX_HOME`, else its build's home
/// ([`build_home`]), else `~/.acpmux`.
#[cfg(unix)]
fn daemon_acpmux_home() -> Option<PathBuf> {
    // Another app's terminal names that app's acpmux (per-build isolation S4).
    if let Some(home) = env_value("ACPMUX_HOME")
        && !crate::app_identity::this_process_in_other_apps_terminal()
    {
        return Some(PathBuf::from(home));
    }
    let home = PathBuf::from(env_value("HOME")?);
    Some(build_home(&home).unwrap_or_else(|| home.join(".acpmux")))
}

#[cfg(unix)]
fn env_value(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

/// `cmux harness run ID --tab`: a new tab in the current pane whose process
/// is `cmux harness run ID --cwd DIR`, so the tab resolves the profile env
/// itself and no secret is on a command line.
fn harness_tab(words: &[String]) -> i32 {
    let (exe, cwd) = match (std::env::current_exe(), std::env::current_dir()) {
        (Ok(exe), Ok(cwd)) => (exe, cwd),
        (Err(error), _) | (_, Err(error)) => {
            eprintln!("cmux harness run: {error}");
            return 1;
        }
    };
    crate::cli::run(&harness_tab_command(words, &exe.to_string_lossy(), &cwd), "")
}

/// The `pane current run -- <exe> harness run …` arguments, with `--cwd`
/// added when the caller gave none.
fn harness_tab_command(words: &[String], exe: &str, cwd: &Path) -> Vec<String> {
    let mut out: Vec<String> = ["pane", "current", "run", "--", exe, "harness", "run"]
        .into_iter()
        .map(str::to_owned)
        .collect();
    out.extend(words.iter().cloned());
    if !words.iter().any(|w| w == "--cwd" || w.starts_with("--cwd=")) {
        out.push("--cwd".into());
        out.push(cwd.to_string_lossy().into_owned());
    }
    out
}

/// `cmux chats open KEY [--cwd DIR]`: open a chat of any harness in a new
/// tab of the current pane. acpmux plans it (`_acpmux/chat_open`): an
/// adopted chat runs in a daemon session shown by `cmux acp attach`; a
/// terminal chat runs its harness's resume command in its folder; a chat
/// that no harness resumes opens read-only in `less`.
fn chats_open(args: &[String]) -> i32 {
    let messages = &crate::localization::catalog().app_control;
    let (key, cwd) = match args {
        [key] => (key, None),
        [key, flag, cwd] | [flag, cwd, key] if flag == "--cwd" => (key, Some(PathBuf::from(cwd))),
        _ => {
            eprintln!("{}", messages.chats_open_usage);
            return 2;
        }
    };
    let exe = match std::env::current_exe() {
        Ok(exe) => exe.to_string_lossy().into_owned(),
        Err(error) => {
            eprintln!("cmux chats open: {error}");
            return 1;
        }
    };
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let acpmux_home = home.and_then(|home| build_home(&home));
    match acpmux::cli::chats::resolve_blocking(key, cwd.as_deref(), acpmux_home) {
        Ok(outcome) => crate::cli::run(&chat_tab_command(&outcome, &exe), ""),
        Err(error) => {
            let usage = error
                .downcast_ref::<acpmux::cli::errors::AppError>()
                .is_some_and(|e| e.code == acpmux::cli::errors::Code::Usage);
            eprintln!("cmux chats open: {error:#}");
            if usage { 2 } else { 1 }
        }
    }
}

/// The `pane current run -- …` arguments that open a planned chat. Every
/// value is its own argument: the folder, env and argv come from chat
/// files, so none of them is ever part of the shell script (`sh -c` gets
/// a fixed script and the values as `$1`, `$2`, …).
fn chat_tab_command(outcome: &acpmux::cli::chats::OpenOutcome, exe: &str) -> Vec<String> {
    use acpmux::cli::chats::OpenOutcome;
    let mut out: Vec<String> =
        ["pane", "current", "run", "--"].into_iter().map(str::to_owned).collect();
    match outcome {
        OpenOutcome::Session { session_id } => {
            out.extend([exe, "acp", "attach", session_id.as_str()].map(str::to_owned));
        }
        OpenOutcome::Terminal { argv, env, cwd } => {
            out.extend(
                ["/bin/sh", "-c", r#"cd "$1" && shift && exec "$@""#, "sh"].map(str::to_owned),
            );
            out.push(cwd.to_string_lossy().into_owned());
            out.push("/usr/bin/env".to_owned());
            out.extend(env.iter().map(|(key, value)| format!("{key}={value}")));
            out.extend(argv.iter().cloned());
        }
        OpenOutcome::ReadOnly { path } => {
            out.extend(["/usr/bin/less", "--"].map(str::to_owned));
            out.push(path.to_string_lossy().into_owned());
        }
    }
    out
}

/// The binary started as `acpmux`. Its daemon is started from
/// `current_exe`, which resolves an `acpmux` symlink to this binary under
/// its own name, so that start needs the `acp` prefix (`<cmux> acp daemon
/// run`). A copy named `acpmux` (as `host setup` installs) needs none.
pub(crate) fn run_standalone(args: Vec<OsString>) -> i32 {
    let renamed = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.file_name().map(|name| name != "acpmux"))
        .unwrap_or(false);
    let daemon_prefix: Vec<OsString> = if renamed { vec!["acp".into()] } else { Vec::new() };
    finish(entry::main(args, Invocation { daemon_prefix, ..Invocation::default() }), "cmux acp")
}

fn finish(result: anyhow::Result<()>, display_name: &str) -> i32 {
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("{display_name}: {error:#}");
            1
        }
    }
}

/// The acpmux home of the cmux build this process belongs to (per-build
/// isolation, cx-is1kf; `BuildIdentity::acpmux_home`, the app's
/// `AcpmuxEnvironment`): the environment an app terminal sets
/// (`CMUX_BUNDLE_ID`, `CMUX_TAG`), else the app bundle around this
/// executable. NIGHTLY keeps `~/.acpmux`; every other build has
/// `~/.acpmux/builds/<key>`, so no build reaches another build's daemon. None
/// outside any cmux app: acpmux's own default (`~/.acpmux`).
pub(crate) fn build_home(home: &Path) -> Option<PathBuf> {
    let identity = crate::app_identity::AppIdentity::detect(
        |name| std::env::var(name).ok(),
        std::env::current_exe().ok().as_deref(),
    )?;
    let build = identity.build();
    let acpmux_home = build.acpmux_home(home);
    // cmux NEXT adopts its pre-isolation home once (build_adopt.rs).
    crate::build_adopt::acpmux_for_cli(&build, &acpmux_home);
    Some(acpmux_home)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn the_daemon_finds_the_acpmux_socket_where_acpmux_puts_it() {
        let home = Path::new("/Users/me/.cmux/brains/chief/acpmux");
        assert_eq!(daemon_socket(None, home, 501), home.join("acpmux.sock"));
        let long = PathBuf::from(format!("/Users/me/{}", "d".repeat(100)));
        let socket = daemon_socket(None, &long, 501);
        assert!(socket.starts_with("/tmp/acpmux-501/"), "{socket:?}");
        assert_eq!(socket.extension().and_then(|e| e.to_str()), Some("sock"));
    }

    /// The shared cases (cmux-agent-pane-policy tests/cases/environment.json) the
    /// Swift host, the brain host and the Chief run too.
    #[cfg(unix)]
    #[test]
    fn the_daemon_socket_matches_the_shared_cases() {
        let file = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../cmux-agent-pane-policy/tests/cases/environment.json");
        let cases: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap();
        for row in cases["sockets"].as_array().unwrap() {
            let got = daemon_socket(
                None,
                Path::new(row[0].as_str().unwrap()),
                row[1].as_u64().unwrap() as u32,
            );
            assert_eq!(got.to_str(), row[2].as_str(), "home {}", row[0]);
        }
        let configured = cases["configured_sockets"].as_array().unwrap();
        assert!(!configured.is_empty());
        for row in configured {
            let given = row[0].as_str().unwrap();
            let got = daemon_socket(
                Some(given).filter(|g| !g.is_empty()),
                Path::new(row[1].as_str().unwrap()),
                row[2].as_u64().unwrap() as u32,
            );
            assert_eq!(got.to_str(), row[3].as_str(), "configured {given}");
        }
    }

    #[test]
    fn harness_run_tab_runs_the_harness_in_a_new_tab_in_its_folder() {
        let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            harness_tab_command(&words(&["aider"]), "/b/cmux", Path::new("/repo")),
            words(&[
                "pane", "current", "run", "--", "/b/cmux", "harness", "run", "aider", "--cwd",
                "/repo"
            ])
        );
        assert_eq!(
            harness_tab_command(&words(&["aider", "--cwd", "/x"]), "/b/cmux", Path::new("/repo")),
            words(&[
                "pane", "current", "run", "--", "/b/cmux", "harness", "run", "aider", "--cwd", "/x"
            ])
        );
    }

    #[test]
    fn chats_open_runs_each_plan_in_a_new_tab_with_values_as_arguments() {
        use acpmux::cli::chats::OpenOutcome;
        use std::collections::BTreeMap;
        let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
        let session = OpenOutcome::Session { session_id: "s_1".into() };
        assert_eq!(
            chat_tab_command(&session, "/b/cmux"),
            words(&["pane", "current", "run", "--", "/b/cmux", "acp", "attach", "s_1"])
        );
        // A folder and a store path that hold shell syntax stay inert values.
        let terminal = OpenOutcome::Terminal {
            argv: words(&["claude", "--resume", "abc"]),
            env: BTreeMap::from([("CLAUDE_CONFIG_DIR".to_owned(), "/h/a $(x)".to_owned())]),
            cwd: PathBuf::from("/r/it's \"here\"; rm -rf ~"),
        };
        assert_eq!(
            chat_tab_command(&terminal, "/b/cmux"),
            words(&[
                "pane",
                "current",
                "run",
                "--",
                "/bin/sh",
                "-c",
                r#"cd "$1" && shift && exec "$@""#,
                "sh",
                "/r/it's \"here\"; rm -rf ~",
                "/usr/bin/env",
                "CLAUDE_CONFIG_DIR=/h/a $(x)",
                "claude",
                "--resume",
                "abc",
            ])
        );
        let read_only = OpenOutcome::ReadOnly { path: PathBuf::from("/h/t.json") };
        assert_eq!(
            chat_tab_command(&read_only, "/b/cmux"),
            words(&["pane", "current", "run", "--", "/usr/bin/less", "--", "/h/t.json"])
        );
    }

    #[test]
    fn open_runs_the_acpmux_tui_in_a_new_tab() {
        let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            open_command(&words(&["review"]), "/b/cmux").unwrap(),
            words(&["pane", "current", "run", "--", "/b/cmux", "acp", "attach", "review"])
        );
        assert_eq!(
            open_command(&words(&["--pane", "pane_01", "review"]), "/b/cmux").unwrap(),
            words(&["pane", "pane_01", "run", "--", "/b/cmux", "acp", "attach", "review"])
        );
        assert!(open_command(&words(&[]), "/b/cmux").is_err());
    }
}
