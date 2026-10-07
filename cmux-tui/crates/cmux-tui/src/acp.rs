//! `cmux acp …`: agent sessions through acpmux, which is linked into this
//! binary. The same program runs as `acpmux` when started through a symlink
//! of that name (see `main`).

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use acpmux::cli::entry::{self, Invocation};

/// `cmux acp <args>`.
pub(crate) fn run(args: Vec<OsString>) -> i32 {
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
    let identity = crate::app_identity::AppIdentity::detect(
        |name| std::env::var(name).ok(),
        std::env::current_exe().ok().as_deref(),
    );
    let tag = acpmux_tag(std::env::var("CMUX_TAG").ok(), identity);
    finish(entry::main(
        args,
        Invocation {
            display_name: "cmux acp".into(),
            daemon_prefix: vec!["acp".into()],
            home: home.and_then(|home| tagged_home(tag.as_deref(), &home)),
        },
    ))
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
    let identity = crate::app_identity::AppIdentity::detect(
        |name| std::env::var(name).ok(),
        std::env::current_exe().ok().as_deref(),
    );
    let tag = acpmux_tag(std::env::var("CMUX_TAG").ok(), identity);
    let acpmux_home = home.and_then(|home| tagged_home(tag.as_deref(), &home));
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
    finish(entry::main(args, Invocation { daemon_prefix, ..Invocation::default() }))
}

fn finish(result: anyhow::Result<()>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("cmux acp: {error:#}");
            1
        }
    }
}

/// The tag whose acpmux home `cmux acp` uses: `CMUX_TAG` (set in the
/// app's terminals), else the tag of the app bundle around this executable,
/// so a tagged build started from Finder or a script keeps its acpmux apart
/// from the user's, as its daemon session does (`AppIdentity`).
pub(crate) fn acpmux_tag(
    env_tag: Option<String>,
    identity: Option<crate::app_identity::AppIdentity>,
) -> Option<String> {
    env_tag.filter(|tag| !tag.trim().is_empty()).or_else(|| identity?.tag)
}

/// A tagged dev build keeps its own acpmux daemon and sessions, so it never
/// shares state with the user's cmux or with another tag. Untagged builds use
/// the acpmux default (`~/.acpmux`), shared with a standalone `acpmux`.
pub(crate) fn tagged_home(tag: Option<&str>, home: &Path) -> Option<PathBuf> {
    let slug = sanitize_tag(tag?)?;
    Some(home.join(".acpmux").join("tags").join(slug))
}

/// Same rule as the app's `ControlSocketPath.sanitize`: lowercase, runs of
/// anything outside `[a-z0-9]` become `-`, no leading or trailing `-`.
fn sanitize_tag(raw: &str) -> Option<String> {
    let mut slug = String::with_capacity(raw.len());
    for character in raw.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_lowercase() || character.is_ascii_digit() {
            slug.push(character);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    (!slug.is_empty()).then(|| slug.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn a_tagged_bundle_without_cmux_tag_uses_its_own_acpmux_home() {
        let bundle = crate::app_identity::AppIdentity {
            bundle_id: Some("com.cmuxterm.app.debug.acpx-v2".into()),
            tag: Some("acpx-v2".into()),
            socket_override: None,
        };
        assert_eq!(acpmux_tag(None, Some(bundle.clone())).as_deref(), Some("acpx-v2"));
        assert_eq!(acpmux_tag(Some(" ".into()), Some(bundle.clone())).as_deref(), Some("acpx-v2"));
        assert_eq!(acpmux_tag(Some("own".into()), Some(bundle)).as_deref(), Some("own"));
        let untagged = crate::app_identity::AppIdentity {
            bundle_id: Some("com.cmuxterm.app".into()),
            tag: None,
            socket_override: None,
        };
        assert_eq!(acpmux_tag(None, Some(untagged)), None);
        assert_eq!(acpmux_tag(None, None), None);
    }

    #[test]
    fn tagged_builds_get_their_own_acpmux_home() {
        let home = Path::new("/Users/a");
        assert_eq!(
            tagged_home(Some("Feat_ACP.2"), home),
            Some(PathBuf::from("/Users/a/.acpmux/tags/feat-acp-2"))
        );
        assert_eq!(tagged_home(Some("--"), home), None);
        assert_eq!(tagged_home(Some(""), home), None);
        assert_eq!(tagged_home(None, home), None);
    }
}
